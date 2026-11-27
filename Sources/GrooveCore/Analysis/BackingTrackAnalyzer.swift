import Foundation

/// Offline backing-track analysis: everything runs locally, no network or subscriptions.
///
/// Methods (chosen for reliability over ambition):
/// - Onsets: log-magnitude spectral flux with adaptive median thresholding.
/// - Bass: the same, restricted to 30–160 Hz, gated by low-band energy.
/// - Tempo: comb-filtered autocorrelation of the onset envelope with a broad tempo prior and
///   explicit half/double-time alternatives (and an optional hint from the MIDI tempo).
/// - Beats: dynamic-programming beat tracking (Ellis 2007).
/// - Energy / density: RMS and onset rate curves, normalised over the song.
/// - Sections (estimate): novelty on bar-level features (energy, bass, density, chroma),
///   clustering of similar sections and rule-based labels.
/// - Chords (estimate): chroma template matching per beat.
/// - Vocals (estimate): sustained, tonal mid-band activity.
public enum BackingTrackAnalyzer {
    public struct Options: Sendable {
        /// Tempo of the MIDI part, used to resolve half/double-time ambiguity.
        public var tempoHint: Double?
        public var beatsPerBar: Int
        public init(tempoHint: Double? = nil, beatsPerBar: Int = 4) {
            self.tempoHint = tempoHint
            self.beatsPerBar = max(1, beatsPerBar)
        }
    }

    static let analysisRate = 22_050.0
    static let frameSize = 1024
    static let hop = 256

    public static func analyze(_ input: AudioBuffer, options: Options = Options(),
                               progress: ((Double) -> Void)? = nil) throws -> BackingAnalysis {
        guard !input.mono.isEmpty else { throw AudioFileError.empty }
        let audio = input.downsampled(toAbout: analysisRate)
        let sr = audio.sampleRate
        let frameRate = sr / Double(hop)
        let fft = FFT(size: frameSize)
        let bins = frameSize / 2 + 1
        let binHz = sr / Double(frameSize)
        let frameCount = max(1, (audio.mono.count - frameSize) / hop + 1)

        // Frequency band limits in bins.
        let bassLo = max(1, Int(30 / binHz)), bassHi = max(bassLo + 1, Int(160 / binHz))
        let vocalLo = Int(300 / binHz), vocalHi = min(bins - 1, Int(3400 / binHz))
        let chromaLo = max(1, Int(60 / binHz)), chromaHi = min(bins - 1, Int(2000 / binHz))
        var pitchClassOfBin = [Int](repeating: -1, count: bins)
        for k in chromaLo ... chromaHi {
            let f = Double(k) * binHz
            let midi = 69 + 12 * log2(f / 440)
            pitchClassOfBin[k] = ((Int(midi.rounded()) % 12) + 12) % 12
        }

        var flux = [Double](repeating: 0, count: frameCount)
        var bassFlux = [Double](repeating: 0, count: frameCount)
        var rms = [Double](repeating: 0, count: frameCount)
        var lowRMS = [Double](repeating: 0, count: frameCount)
        var vocalScore = [Double](repeating: 0, count: frameCount)
        var chroma = [[Double]](repeating: [Double](repeating: 0, count: 12), count: frameCount)
        var previous = [Double](repeating: 0, count: bins)
        var mags = [Double](repeating: 0, count: bins)

        audio.mono.withUnsafeBufferPointer { samples in
            for f in 0 ..< frameCount {
                let offset = f * hop
                fft.magnitudes(samples, offset: offset, into: &mags)
                var sumFlux = 0.0, sumBass = 0.0, energy = 0.0, low = 0.0
                var vocalEnergy = 0.0, logSum = 0.0, linSum = 0.0
                var c = [Double](repeating: 0, count: 12)
                for k in 1 ..< bins {
                    let m = mags[k]
                    let lm = log(1 + 100 * m)
                    let d = lm - previous[k]
                    if d > 0 {
                        sumFlux += d
                        if k >= bassLo && k <= bassHi { sumBass += d }
                    }
                    previous[k] = lm
                    let p = m * m
                    energy += p
                    if k >= bassLo && k <= bassHi { low += p }
                    if k >= vocalLo && k <= vocalHi {
                        vocalEnergy += p
                        logSum += log(m + 1e-9)
                        linSum += m
                    }
                    let pc = pitchClassOfBin[k]
                    if pc >= 0 { c[pc] += m }
                }
                flux[f] = sumFlux
                bassFlux[f] = sumBass
                rms[f] = (energy / Double(bins)).squareRoot()
                lowRMS[f] = (low / Double(bassHi - bassLo + 1)).squareRoot()
                let n = Double(max(1, vocalHi - vocalLo + 1))
                let flatness = exp(logSum / n) / max(1e-12, linSum / n)    // 0 = tonal, 1 = noisy
                let bandShare = vocalEnergy / max(1e-12, energy)
                vocalScore[f] = bandShare * (1 - min(1, flatness * 2.5))
                chroma[f] = c
                if f % 512 == 0 { progress?(0.6 * Double(f) / Double(frameCount)) }
            }
        }

        // ---- Onsets ----
        let onsetEnvelope = normalised(highPass(flux, frameRate: frameRate))
        let bassEnvelope = normalised(highPass(bassFlux, frameRate: frameRate))
        let fine = AttackRefiner(samples: audio.mono, sampleRate: sr, lowPassHz: nil)
        let fineBass = AttackRefiner(samples: audio.mono, sampleRate: sr, lowPassHz: 160)
        let onsets = pickPeaks(onsetEnvelope, frameRate: frameRate, minInterval: 0.045, delta: 0.06).map { o in
            BackingAnalysis.Onset(time: fine.refine(o.time), strength: o.strength)
        }
        let lowMax = lowRMS.max() ?? 1
        let bassOnsets = pickPeaks(bassEnvelope, frameRate: frameRate, minInterval: 0.07, delta: 0.08).filter { o in
            let f = min(frameCount - 1, Int(o.time * frameRate) + 2)
            return lowRMS[f] > lowMax * 0.12
        }.map { o in BackingAnalysis.Onset(time: fineBass.refine(o.time), strength: o.strength) }
        progress?(0.7)

        // ---- Tempo & beats ----
        var tempo = estimateTempo(onsetEnvelope, frameRate: frameRate, hint: options.tempoHint)
        let beats = trackBeats(onsets: onsets, bpm: tempo.bpm, duration: audio.duration)
        if let refined = refinedTempo(beats), abs(refined - tempo.bpm) / tempo.bpm < 0.03 {
            tempo.bpm = (refined * 100).rounded() / 100
        }
        let bpb = options.beatsPerBar
        let phase = downbeatPhase(beats: beats, bassEnvelope: bassEnvelope, lowRMS: lowRMS, frameRate: frameRate, beatsPerBar: bpb)
        progress?(0.8)

        // ---- Curves at 10 Hz ----
        let curveRate = 10.0
        let duration = audio.duration
        let points = max(1, Int(duration * curveRate))
        let energyCurve = normalised(resampleDB(rms, frameRate: frameRate, rate: curveRate, count: points), floor: 0)
        let lowCurve = normalised(resampleDB(lowRMS, frameRate: frameRate, rate: curveRate, count: points), floor: 0)
        var densityCurve = [Double](repeating: 0, count: points)
        for o in onsets {
            let i = Int(o.time * curveRate)
            if i >= 0 && i < points { densityCurve[i] += 1 }
        }
        densityCurve = normalised(smooth(densityCurve, radius: Int(curveRate)), floor: 0)
        var vocalCurve = smooth(resample(vocalScore, frameRate: frameRate, rate: curveRate, count: points), radius: Int(curveRate / 2))
        // Vocal estimate only where there's real signal.
        for i in vocalCurve.indices where energyCurve[i] < 0.15 { vocalCurve[i] = 0 }
        vocalCurve = normalised(vocalCurve, floor: 0)
        progress?(0.85)

        // ---- Groove (micro-timing per 16th) ----
        let groove = grooveOffsets(onsets: onsets, beats: beats)

        // ---- Chords & sections ----
        let beatChroma = chromaPerBeat(chroma, beats: beats, frameRate: frameRate)
        let chords = chordChanges(beatChroma, beats: beats)
        let sections = estimateSections(beats: beats, phase: phase, beatsPerBar: bpb, energy: energyCurve, low: lowCurve,
                                        density: densityCurve, curveRate: curveRate, beatChroma: beatChroma, duration: duration)
        progress?(0.95)

        // ---- Overview for drawing ----
        let overviewRate = 150.0
        let overview = waveformOverview(input.mono, sampleRate: input.sampleRate, rate: overviewRate)
        progress?(1)

        let swing = 0.5 + (groove.offsets.count == 4 ? groove.offsets[2] * 0.25 : 0)
        return BackingAnalysis(
            duration: duration, tempo: tempo, beats: beats, downbeatPhase: phase, beatsPerBar: bpb,
            onsets: onsets, bassOnsets: bassOnsets, curveRate: curveRate, energy: energyCurve, lowEnergy: lowCurve,
            density: densityCurve, vocalActivity: vocalCurve, sections: sections, chordChanges: chords,
            grooveOffsets: groove.offsets, grooveConfidence: groove.confidence, swingRatio: clamp(swing, 0.45, 0.75),
            overview: overview, overviewRate: overviewRate)
    }

    // MARK: - Envelope helpers

    /// Removes slow trends so only attacks remain.
    static func highPass(_ x: [Double], frameRate: Double) -> [Double] {
        let radius = max(1, Int(frameRate * 0.25))
        let local = movingAverage(x, radius: radius)
        return zip(x, local).map { max(0, $0 - $1 * 0.9) }
    }

    static func movingAverage(_ x: [Double], radius: Int) -> [Double] {
        guard !x.isEmpty else { return x }
        var prefix = [Double](repeating: 0, count: x.count + 1)
        for i in x.indices { prefix[i + 1] = prefix[i] + x[i] }
        var out = [Double](repeating: 0, count: x.count)
        for i in x.indices {
            let lo = max(0, i - radius), hi = min(x.count - 1, i + radius)
            out[i] = (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
        }
        return out
    }

    static func smooth(_ x: [Double], radius: Int) -> [Double] { movingAverage(x, radius: max(1, radius)) }

    static func normalised(_ x: [Double], floor: Double? = nil) -> [Double] {
        guard let maxV = x.max(), maxV > 0 else { return x.map { _ in 0 } }
        let minV = floor ?? 0
        let lo = floor == nil ? 0 : (x.min() ?? 0)
        let range = max(1e-12, maxV - lo)
        return x.map { clamp(($0 - lo) / range, minV, 1) }
    }

    static func resample(_ x: [Double], frameRate: Double, rate: Double, count: Int) -> [Double] {
        var out = [Double](repeating: 0, count: count)
        let per = frameRate / rate
        for i in 0 ..< count {
            let lo = Int(Double(i) * per), hi = min(x.count, Int(Double(i + 1) * per))
            if lo < hi {
                var s = 0.0
                for k in lo ..< hi { s += x[k] }
                out[i] = s / Double(hi - lo)
            } else if lo < x.count {
                out[i] = x[lo]
            }
        }
        return out
    }

    /// Resamples an amplitude curve and converts it to a 60 dB scale (0 = −60 dB, 1 = peak).
    static func resampleDB(_ x: [Double], frameRate: Double, rate: Double, count: Int) -> [Double] {
        let r = resample(x, frameRate: frameRate, rate: rate, count: count)
        let peak = max(1e-9, r.max() ?? 1e-9)
        return r.map { v in
            let db = 20 * log10(max(v, 1e-9) / peak)
            return clamp((db + 60) / 60, 0, 1)
        }
    }

    static func pickPeaks(_ env: [Double], frameRate: Double, minInterval: Double, delta: Double) -> [BackingAnalysis.Onset] {
        guard env.count > 3 else { return [] }
        let radius = max(2, Int(frameRate * 0.1))
        let mean = movingAverage(env, radius: radius)
        let minGap = Int(minInterval * frameRate)
        var out: [BackingAnalysis.Onset] = []
        var last = -minGap - 1
        for i in 1 ..< env.count - 1 {
            let v = env[i]
            guard v > env[i - 1], v >= env[i + 1], v > mean[i] + delta else { continue }
            if i - last < minGap {
                if let prev = out.last, v > prev.strength {
                    out[out.count - 1] = BackingAnalysis.Onset(time: refine(env, i, frameRate), strength: v)
                    last = i
                }
                continue
            }
            out.append(BackingAnalysis.Onset(time: refine(env, i, frameRate), strength: v))
            last = i
        }
        return out
    }

    /// Parabolic peak interpolation; times are aligned to the frame centre's attack.
    static func refine(_ env: [Double], _ i: Int, _ frameRate: Double) -> Double {
        let a = env[i - 1], b = env[i], c = env[i + 1]
        let denom = a - 2 * b + c
        let shift = abs(denom) > 1e-12 ? clamp(0.5 * (a - c) / denom, -0.5, 0.5) : 0
        // Frame f covers samples [f*hop, f*hop+frameSize); an attack shows when it enters
        // the frame's centre region.
        let centreOffset = Double(frameSize) / 2 / analysisRate
        return max(0, (Double(i) + shift) / frameRate + centreOffset - Double(hop) / analysisRate)
    }

    // MARK: - Tempo

    static func estimateTempo(_ env: [Double], frameRate: Double, hint: Double?) -> BackingAnalysis.TempoEstimate {
        let n = env.count
        guard n > Int(frameRate * 4) else {
            return .init(bpm: hint ?? 120, confidence: 0, alternatives: [])
        }
        let mean = env.reduce(0, +) / Double(n)
        let x = env.map { $0 - mean }
        let maxLag = min(n - 1, Int(frameRate * 60 / 40 * 4) + 2)
        var acf = [Double](repeating: 0, count: maxLag + 1)
        for lag in 0 ... maxLag {
            var s = 0.0
            var i = 0
            while i + lag < n {
                s += x[i] * x[i + lag]
                i += 1
            }
            acf[lag] = s / Double(n - lag)
        }
        let zero = max(1e-12, acf[0])
        func acfAt(_ lag: Double) -> Double {
            let i = Int(lag)
            guard i + 1 < acf.count, i >= 0 else { return 0 }
            let f = lag - Double(i)
            return (acf[i] * (1 - f) + acf[i + 1] * f) / zero
        }
        // Comb score for each BPM.
        var candidates: [(bpm: Double, score: Double)] = []
        var bpm = 50.0
        while bpm <= 220 {
            let lag = frameRate * 60 / bpm
            var score = 0.0
            for (k, w) in [(1.0, 1.0), (2.0, 0.5), (3.0, 0.33), (4.0, 0.25)] where lag * k < Double(acf.count - 1) {
                score += w * acfAt(lag * k)
            }
            // Half-beat support helps distinguish a beat from a bar.
            score += 0.25 * acfAt(lag / 2)
            let prior = exp(-0.5 * pow(log2(bpm / 115) / 0.9, 2))
            candidates.append((bpm, score * (0.6 + 0.4 * prior)))
            bpm += 0.25
        }
        // Local maxima.
        var peaks: [(bpm: Double, score: Double)] = []
        for i in 1 ..< candidates.count - 1 where candidates[i].score > candidates[i - 1].score && candidates[i].score >= candidates[i + 1].score {
            peaks.append(candidates[i])
        }
        peaks.sort { $0.score > $1.score }
        guard var best = peaks.first, best.score > 0 else {
            return .init(bpm: hint ?? 120, confidence: 0, alternatives: [])
        }
        // A hint from the MIDI tempo resolves octave errors when it is a plausible alternative.
        if let h = hint, h > 0 {
            for p in peaks.prefix(6) {
                for ratio in [1.0, 2.0, 0.5, 1.5, 2.0 / 3.0] where abs(p.bpm * ratio - h) / h < 0.04 {
                    if p.score > best.score * 0.35 { best = (h * (p.bpm * ratio / h), p.score) }
                }
                if abs(best.bpm - h) / h < 0.04 { break }
            }
        }
        let others = peaks.filter { abs($0.bpm - best.bpm) > 2 }
        let second = others.first?.score ?? 0
        let confidence = clamp((best.score - second) / max(1e-9, best.score) * 1.6 + min(0.4, best.score), 0, 1)
        var alternatives: [Double] = []
        for v in [best.bpm / 2, best.bpm * 2] where v >= 40 && v <= 240 { alternatives.append(v) }
        for p in others.prefix(2) where !alternatives.contains(where: { abs($0 - p.bpm) < 2 }) { alternatives.append(p.bpm) }
        return .init(bpm: (best.bpm * 100).rounded() / 100, confidence: confidence, alternatives: alternatives)
    }

    // MARK: - Beats

    /// Beat tracking: find the grid phase that best explains the onsets, then follow the
    /// music with a phase-locked loop (each beat snaps to a nearby strong attack, and the beat
    /// period adapts slowly so small tempo errors and gentle tempo changes don't drift).
    static func trackBeats(onsets: [BackingAnalysis.Onset], bpm: Double, duration: Double) -> [Double] {
        guard bpm > 0, onsets.count >= 4 else { return [] }
        let basePeriod = 60 / bpm
        let sigma = 0.02
        // Phase search over the first 20 seconds.
        let early = onsets.filter { $0.time < 20 }
        var bestPhase = 0.0
        var bestScore = -1.0
        var phase = 0.0
        while phase < basePeriod {
            var score = 0.0
            for o in early {
                let k = ((o.time - phase) / basePeriod).rounded()
                let d = o.time - (phase + k * basePeriod)
                score += o.strength * exp(-d * d / (2 * sigma * sigma))
            }
            if score > bestScore { bestScore = score; bestPhase = phase }
            phase += 0.002
        }
        var beats: [Double] = []
        var period = basePeriod
        var t = bestPhase
        var searchIndex = 0
        while t <= duration {
            // Strongest attack near the predicted beat.
            while searchIndex < onsets.count && onsets[searchIndex].time < t - 0.06 { searchIndex += 1 }
            var bestTime: Double? = nil
            var bestWeight = 0.0
            var k = searchIndex
            while k < onsets.count && onsets[k].time <= t + 0.06 {
                let d = onsets[k].time - t
                let w = onsets[k].strength * exp(-d * d / (2 * 0.025 * 0.025))
                if w > bestWeight { bestWeight = w; bestTime = onsets[k].time }
                k += 1
            }
            let beat: Double
            if let snapped = bestTime, bestWeight > 0.05 {
                beat = t + 0.7 * (snapped - t)
            } else {
                beat = t
            }
            if let last = beats.last {
                let measured = beat - last
                period = clamp(0.85 * period + 0.15 * measured, basePeriod * 0.95, basePeriod * 1.05)
            }
            beats.append(max(0, beat))
            t = beat + period
        }
        return beats
    }

    /// Tempo from the tracked beats (least-squares slope).
    static func refinedTempo(_ beats: [Double]) -> Double? {
        guard beats.count >= 8 else { return nil }
        let n = Double(beats.count)
        let xs = (0 ..< beats.count).map(Double.init)
        let mx = xs.reduce(0, +) / n
        let my = beats.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for i in beats.indices {
            num += (xs[i] - mx) * (beats[i] - my)
            den += (xs[i] - mx) * (xs[i] - mx)
        }
        guard den > 0, num > 0 else { return nil }
        return 60 / (num / den)
    }

    /// Which beat in each bar is the downbeat: the phase with the strongest low end.
    static func downbeatPhase(beats: [Double], bassEnvelope: [Double], lowRMS: [Double], frameRate: Double, beatsPerBar: Int) -> Int {
        guard beats.count >= beatsPerBar * 2, beatsPerBar > 1 else { return 0 }
        var scores = [Double](repeating: 0, count: beatsPerBar)
        let lowMax = max(1e-9, lowRMS.max() ?? 1)
        for (i, t) in beats.enumerated() {
            let f = Int(t * frameRate)
            guard f >= 0 && f < bassEnvelope.count else { continue }
            var b = 0.0
            for k in max(0, f - 2) ... min(bassEnvelope.count - 1, f + 2) { b = max(b, bassEnvelope[k]) }
            scores[i % beatsPerBar] += b + 0.5 * lowRMS[f] / lowMax
        }
        return scores.enumerated().max { $0.element < $1.element }?.offset ?? 0
    }

    // MARK: - Groove

    static func grooveOffsets(onsets: [BackingAnalysis.Onset], beats: [Double]) -> (offsets: [Double], confidence: Double) {
        guard beats.count > 8 else { return ([0, 0, 0, 0], 0) }
        var sum = [Double](repeating: 0, count: 4)
        var weight = [Double](repeating: 0, count: 4)
        var squares = [Double](repeating: 0, count: 4)
        var b = 0
        for o in onsets {
            while b + 1 < beats.count && beats[b + 1] <= o.time { b += 1 }
            guard b + 1 < beats.count, o.time >= beats[b] else { continue }
            let length = beats[b + 1] - beats[b]
            let phase = (o.time - beats[b]) / length * 4
            let step = Int(phase.rounded())
            let offset = phase - Double(step)
            guard abs(offset) < 0.4, step < 4 else { continue }
            let w = o.strength
            sum[step] += offset * w
            squares[step] += offset * offset * w
            weight[step] += w
        }
        var offsets = [Double](repeating: 0, count: 4)
        var spread = 0.0
        var used = 0.0
        for k in 0 ..< 4 where weight[k] > 0 {
            let m = sum[k] / weight[k]
            offsets[k] = m
            let variance = max(0, squares[k] / weight[k] - m * m)
            spread += variance.squareRoot()
            used += 1
        }
        let base = offsets[0]
        offsets = offsets.map { $0 - base }   // relative to the beat itself
        let consistency = used > 0 ? clamp(1 - (spread / used) / 0.2, 0, 1) : 0
        let coverage: Double = weight[1] + weight[2] + weight[3] > 0 ? 1 : 0
        return (offsets, consistency * coverage)
    }

    // MARK: - Harmony

    static func chromaPerBeat(_ chroma: [[Double]], beats: [Double], frameRate: Double) -> [[Double]] {
        guard beats.count > 1 else { return [] }
        var out: [[Double]] = []
        for i in 0 ..< beats.count - 1 {
            let lo = Int(beats[i] * frameRate), hi = min(chroma.count, Int(beats[i + 1] * frameRate))
            var c = [Double](repeating: 0, count: 12)
            if lo < hi {
                for f in lo ..< hi { for k in 0 ..< 12 { c[k] += chroma[f][k] } }
            }
            let norm = max(1e-9, c.reduce(0) { $0 + $1 * $1 }.squareRoot())
            out.append(c.map { $0 / norm })
        }
        return out
    }

    static let noteNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    static func chordChanges(_ beatChroma: [[Double]], beats: [Double]) -> [BackingAnalysis.ChordEvent] {
        guard !beatChroma.isEmpty else { return [] }
        var templates: [(String, [Double])] = []
        for root in 0 ..< 12 {
            var major = [Double](repeating: 0, count: 12)
            var minor = [Double](repeating: 0, count: 12)
            major[root] = 1; major[(root + 4) % 12] = 0.8; major[(root + 7) % 12] = 0.8
            minor[root] = 1; minor[(root + 3) % 12] = 0.8; minor[(root + 7) % 12] = 0.8
            let n = (1 + 0.64 + 0.64).squareRoot()
            templates.append((noteNames[root], major.map { $0 / n }))
            templates.append((noteNames[root] + "m", minor.map { $0 / n }))
        }
        var labels: [(String, Double)] = []
        for c in beatChroma {
            var best = ("N", 0.0)
            for (name, t) in templates {
                var dot = 0.0
                for k in 0 ..< 12 { dot += c[k] * t[k] }
                if dot > best.1 { best = (name, dot) }
            }
            labels.append(best)
        }
        // Keep a chord only when it holds for at least two beats.
        var events: [BackingAnalysis.ChordEvent] = []
        var i = 0
        while i < labels.count {
            var j = i
            while j + 1 < labels.count && labels[j + 1].0 == labels[i].0 { j += 1 }
            if j - i + 1 >= 2 && labels[i].1 > 0.6 && events.last?.name != labels[i].0 {
                events.append(BackingAnalysis.ChordEvent(time: beats[i], name: labels[i].0, confidence: labels[i].1))
            }
            i = j + 1
        }
        return events
    }

    // MARK: - Sections

    static func estimateSections(beats: [Double], phase: Int, beatsPerBar: Int, energy: [Double], low: [Double],
                                 density: [Double], curveRate: Double, beatChroma: [[Double]], duration: Double) -> [EstimatedSection] {
        // Bars from the beat grid.
        var barStarts: [Double] = []
        var barBeatIndex: [Int] = []
        var i = phase
        while i < beats.count {
            barStarts.append(beats[i])
            barBeatIndex.append(i)
            i += beatsPerBar
        }
        guard barStarts.count >= 8 else {
            return [EstimatedSection(start: 0, end: duration, kind: .unknown, energy: 0.5, group: "A")]
        }
        func curveMean(_ c: [Double], _ a: Double, _ b: Double) -> Double {
            let lo = max(0, Int(a * curveRate)), hi = min(c.count, max(lo + 1, Int(b * curveRate)))
            guard lo < hi else { return 0 }
            return c[lo ..< hi].reduce(0, +) / Double(hi - lo)
        }
        var features: [[Double]] = []
        for (k, start) in barStarts.enumerated() {
            let end = k + 1 < barStarts.count ? barStarts[k + 1] : min(duration, start + (barStarts[1] - barStarts[0]))
            var f = [curveMean(energy, start, end) * 3, curveMean(low, start, end) * 2, curveMean(density, start, end) * 2]
            var c = [Double](repeating: 0, count: 12)
            let b0 = barBeatIndex[k]
            for b in b0 ..< min(beatChroma.count, b0 + beatsPerBar) { for p in 0 ..< 12 { c[p] += beatChroma[b][p] } }
            let norm = max(1e-9, c.reduce(0) { $0 + $1 * $1 }.squareRoot())
            f += c.map { $0 / norm }
            features.append(f)
        }
        let bars = features.count
        func distance(_ a: [Double], _ b: [Double]) -> Double {
            var s = 0.0
            for k in a.indices { s += (a[k] - b[k]) * (a[k] - b[k]) }
            return s.squareRoot()
        }
        // Novelty: difference between the 4 bars before and after each bar line.
        let w = 4
        var novelty = [Double](repeating: 0, count: bars)
        for b in w ..< bars - w + 1 {
            var before = [Double](repeating: 0, count: features[0].count)
            var after = before
            for k in 0 ..< w {
                for d in before.indices { before[d] += features[b - 1 - k][d] / Double(w) }
                if b + k < bars { for d in after.indices { after[d] += features[b + k][d] / Double(w) } }
            }
            novelty[b] = distance(before, after)
        }
        let meanNovelty = novelty.reduce(0, +) / Double(bars)
        // Boundaries: novelty peaks, at least 4 bars apart, preferring multiples of 4 bars.
        var boundaries: [Int] = [0]
        let order = novelty.indices.sorted { novelty[$0] > novelty[$1] }
        for b in order where novelty[b] > meanNovelty * 1.4 {
            if boundaries.contains(where: { abs($0 - b) < 4 }) { continue }
            var candidate = b
            for snap in [b - 1, b + 1] where snap > 0 && snap < bars && snap % 4 == 0 && novelty[snap] > novelty[b] * 0.8 { candidate = snap }
            if boundaries.contains(where: { abs($0 - candidate) < 4 }) { continue }
            boundaries.append(candidate)
        }
        boundaries.sort()

        // Section features & clustering.
        struct Span { var start: Int; var end: Int; var feature: [Double]; var energy: Double; var group: Int }
        var spans: [Span] = []
        for (k, s) in boundaries.enumerated() {
            let e = k + 1 < boundaries.count ? boundaries[k + 1] : bars
            var f = [Double](repeating: 0, count: features[0].count)
            for b in s ..< e { for d in f.indices { f[d] += features[b][d] / Double(e - s) } }
            spans.append(Span(start: s, end: e, feature: f, energy: f[0] / 3, group: -1))
        }
        var groups: [[Double]] = []
        for k in spans.indices {
            var assigned = -1
            for (g, centre) in groups.enumerated() where distance(spans[k].feature, centre) < 0.55 { assigned = g; break }
            if assigned < 0 { groups.append(spans[k].feature); assigned = groups.count - 1 }
            spans[k].group = assigned
        }
        let meanEnergy = spans.reduce(0.0) { $0 + $1.energy * Double($1.end - $1.start) } / Double(bars)
        var groupEnergy: [Int: Double] = [:]
        var groupCount: [Int: Int] = [:]
        for s in spans { groupEnergy[s.group, default: 0] += s.energy; groupCount[s.group, default: 0] += 1 }
        let repeated = groupCount.filter { $0.value >= 2 }.map { $0.key }
        let chorusGroup = repeated.max { (groupEnergy[$0]! / Double(groupCount[$0]!)) < (groupEnergy[$1]! / Double(groupCount[$1]!)) }
        let verseGroup = repeated.filter { $0 != chorusGroup }.max { groupCount[$0]! < groupCount[$1]! }

        var kinds = [SectionKind](repeating: .unknown, count: spans.count)
        var seenChorus = 0
        for (k, s) in spans.enumerated() {
            let length = s.end - s.start
            if k == 0 && s.energy < meanEnergy * 0.85 && length <= 8 && s.group != chorusGroup { kinds[k] = .intro; continue }
            if k == spans.count - 1 && s.energy < meanEnergy * 0.85 && s.group != chorusGroup && spans.count > 2 { kinds[k] = .outro; continue }
            if s.group == chorusGroup { kinds[k] = .chorus; seenChorus += 1; continue }
            if s.group == verseGroup { kinds[k] = .verse; continue }
            if s.energy < meanEnergy * 0.7 { kinds[k] = .breakdown; continue }
            if k + 1 < spans.count && spans[k + 1].group == chorusGroup && length <= 8 { kinds[k] = .preChorus; continue }
            kinds[k] = seenChorus >= 1 ? .bridge : .verse
        }
        let letters = Array("ABCDEFGHIJKLMNOP")
        return spans.enumerated().map { k, s in
            let start = barStarts[s.start]
            let end = s.end < barStarts.count ? barStarts[s.end] : duration
            let letter = String(letters[min(letters.count - 1, s.group)])
            return EstimatedSection(start: k == 0 ? 0 : start, end: end, kind: kinds[k], energy: clamp(s.energy, 0, 1), group: letter)
        }
    }

    // MARK: - Overview

    public static func waveformOverview(_ samples: [Float], sampleRate: Double, rate: Double) -> [Float] {
        let per = max(1, Int(sampleRate / rate))
        let count = samples.count / per + 1
        var out = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { s in
            for i in 0 ..< count {
                var peak: Float = 0
                let lo = i * per, hi = min(s.count, lo + per)
                var k = lo
                while k < hi {
                    peak = max(peak, abs(s[k]))
                    k += 1
                }
                out[i] = peak
            }
        }
        let maxPeak = max(1e-6, out.max() ?? 1)
        return out.map { min(1, $0 / maxPeak) }
    }
}

// MARK: - Alignment

public enum AutoAligner {
    public struct Result: Equatable, Sendable {
        public var alignment: Alignment
        /// 0…1: how clearly the best offset beats the others.
        public var confidence: Double
    }

    /// Finds the audio offset at which the drum part's kick and snare hits best line up with
    /// the backing track's attacks. Searches ±`range` seconds around the first downbeat.
    public static func align(pattern: DrumPattern, tempoMap: TempoMap, map: DrumMap, analysis: BackingAnalysis,
                             stretch: Double = 1, range: Double = 8) -> Result {
        var hits: [(time: Double, bass: Bool)] = []
        for n in pattern.notes {
            let family = map.category(for: n.pitch).family
            guard family == .kick || family == .snare else { continue }
            hits.append((tempoMap.seconds(atTick: n.tick) * stretch, family == .kick))
            if hits.count >= 600 { break }
        }
        guard !hits.isEmpty, !analysis.onsets.isEmpty else {
            return Result(alignment: Alignment(offsetSeconds: 0, stretch: stretch, isAutomatic: true), confidence: 0)
        }
        // Rasterise onsets at 1 ms with a small spread.
        let resolution = 0.001
        let length = Int(analysis.duration / resolution) + 2
        var all = [Double](repeating: 0, count: length)
        var bass = [Double](repeating: 0, count: length)
        func splat(_ arr: inout [Double], _ t: Double, _ s: Double) {
            let c = Int(t / resolution)
            for d in -12 ... 12 {
                let i = c + d
                if i >= 0 && i < length { arr[i] = max(arr[i], s * exp(-Double(d * d) / 50)) }
            }
        }
        for o in analysis.onsets { splat(&all, o.time, o.strength) }
        for o in analysis.bassOnsets { splat(&bass, o.time, o.strength) }

        let centre = analysis.firstDownbeat ?? 0
        func score(_ offset: Double) -> Double {
            // Repeating patterns line up at many offsets: prefer the one nearest the first
            // downbeat of the track.
            let preference = 1 - 0.015 * abs(offset - centre)
            var s = 0.0
            for h in hits {
                let i = Int((h.time + offset) / resolution)
                guard i >= 0 && i < length else { continue }
                s += h.bass ? (bass[i] * 1.5 + all[i] * 0.5) : all[i]
            }
            return s * preference
        }
        var best = (offset: 0.0, score: -1.0)
        var scores: [Double] = []
        var offset = max(-range, centre - range)
        while offset <= centre + range {
            let s = score(offset)
            scores.append(s)
            if s > best.score { best = (offset, s) }
            offset += 0.01
        }
        var fine = best
        var o = best.offset - 0.012
        while o <= best.offset + 0.012 {
            let s = score(o)
            if s > fine.score { fine = (o, s) }
            o += 0.001
        }
        let mean = scores.reduce(0, +) / Double(max(1, scores.count))
        let sorted = scores.sorted(by: >)
        let runnerUp = sorted.count > 30 ? sorted[30] : mean
        let confidence = fine.score > 0 ? clamp((fine.score - max(mean, runnerUp)) / fine.score * 1.5, 0, 1) : 0
        let rounded = (fine.offset * 1000).rounded() / 1000
        return Result(alignment: Alignment(offsetSeconds: rounded, stretch: stretch, isAutomatic: true), confidence: confidence)
    }

    /// Stretch that makes MIDI at `midiBPM` follow audio at `audioBPM`.
    public static func tempoMatchStretch(midiBPM: Double, audioBPM: Double) -> Double {
        guard midiBPM > 0, audioBPM > 0 else { return 1 }
        var audio = audioBPM
        // Compare like with like: fold half/double time onto the MIDI tempo.
        while audio < midiBPM * 0.7 { audio *= 2 }
        while audio > midiBPM * 1.42 { audio /= 2 }
        return midiBPM / audio
    }
}

/// Finds the precise attack time of an onset in the waveform: the steepest rise of a ~3 ms
/// energy envelope near the spectral-flux peak (which on its own is early by up to a frame).
struct AttackRefiner {
    let envelope: [Double]
    let hopSeconds: Double

    init(samples: [Float], sampleRate: Double, lowPassHz: Double?) {
        var x = samples
        if let cutoff = lowPassHz {
            // Two cascaded one-pole low-pass filters.
            let a = exp(-2 * Double.pi * cutoff / sampleRate)
            var y1 = 0.0, y2 = 0.0
            for i in x.indices {
                y1 = (1 - a) * Double(x[i]) + a * y1
                y2 = (1 - a) * y1 + a * y2
                x[i] = Float(y2)
            }
        }
        let window = max(8, Int(sampleRate * 0.003))
        let hop = max(4, window / 2)
        var env: [Double] = []
        env.reserveCapacity(x.count / hop + 1)
        var i = 0
        while i + window <= x.count {
            var e = 0.0
            for k in i ..< i + window { e += Double(x[k]) * Double(x[k]) }
            env.append(log(1e-10 + e / Double(window)))
            i += hop
        }
        envelope = env
        hopSeconds = Double(hop) / sampleRate
    }

    func refine(_ rough: Double) -> Double {
        guard envelope.count > 4 else { return rough }
        let lo = max(2, Int((rough - 0.02) / hopSeconds))
        let hi = min(envelope.count - 1, Int((rough + 0.06) / hopSeconds))
        guard lo < hi else { return rough }
        var best = lo
        var bestRise = -Double.infinity
        for k in lo ... hi {
            let rise = envelope[k] - envelope[k - 2]
            if rise > bestRise { bestRise = rise; best = k }
        }
        // The rise ends at window k; the attack starts about one hop before.
        return max(0, Double(best - 1) * hopSeconds)
    }
}
