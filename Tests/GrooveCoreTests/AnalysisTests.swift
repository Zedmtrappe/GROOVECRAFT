import XCTest
@testable import GrooveCore

/// Synthesises a band-less "backing track": bass notes on the kick pattern, a click-free
/// mid-range chord pad, noise hats. First half quiet, second half loud and busier.
enum SyntheticSong {
    static func make(bpm: Double = 120, seconds: Double = 32, start: Double = 0.5, rate: Double = 44_100) -> [Float] {
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n)
        var rng = SeededRandom(seed: 11)
        let beat = 60 / bpm
        func add(_ t0: Double, _ dur: Double, _ gain: Double, _ f: (Double) -> Double) {
            let i0 = Int(t0 * rate), i1 = min(n, Int((t0 + dur) * rate))
            guard i0 >= 0, i0 < i1 else { return }
            for i in i0 ..< i1 {
                let t = Double(i - i0) / rate
                out[i] += Float(gain * f(t))
            }
        }
        var t = start
        var beatIndex = 0
        while t < seconds - 1 {
            let loud = t > seconds / 2
            let g = loud ? 1.0 : 0.3
            let inBar = beatIndex % 4
            // Bass on beats 1 and 3 (and the "and" of 3)
            if inBar == 0 || inBar == 2 {
                let freq = inBar == 0 ? 55.0 : 73.4
                add(t, beat * 0.45, 0.6 * g) { x in sin(2 * .pi * freq * x) * min(1, x * 400) * exp(-x * 3) }
            }
            if inBar == 2 {
                add(t + beat / 2, beat * 0.4, 0.5 * g) { x in sin(2 * .pi * 82.4 * x) * min(1, x * 400) * exp(-x * 3) }
            }
            // Pad: A minor triad stabs on every beat (tonal mid-range).
            add(t, beat * 0.8, 0.12 * g) { x in
                let env = min(1, x * 200) * exp(-x * 4)
                return env * (sin(2 * .pi * 220 * x) + sin(2 * .pi * 261.6 * x) + sin(2 * .pi * 329.6 * x)) / 3
            }
            // Hats: 8ths quiet, 16ths loud.
            let subdivisions = loud ? 4 : 2
            for k in 0 ..< subdivisions {
                let ht = t + beat * Double(k) / Double(subdivisions)
                var last = 0.0
                add(ht, 0.03, 0.25 * g) { x in
                    let white = rng.signedUnit()
                    let hp = white - last
                    last = white
                    return hp * exp(-x * 120)
                }
            }
            t += beat
            beatIndex += 1
        }
        return out
    }

    static func kickTimes(bpm: Double = 120, seconds: Double = 32, start: Double = 0.5) -> [Double] {
        var times: [Double] = []
        let beat = 60 / bpm
        var t = start
        var i = 0
        while t < seconds - 1 {
            if i % 4 == 0 || i % 4 == 2 { times.append(t) }
            if i % 4 == 2 { times.append(t + beat / 2) }
            t += beat
            i += 1
        }
        return times
    }
}

final class AnalysisTests: XCTestCase {
    static var cached: BackingAnalysis?

    func analysis() throws -> BackingAnalysis {
        if let a = Self.cached { return a }
        let audio = AudioBuffer(mono: SyntheticSong.make(), sampleRate: 44_100)
        let a = try BackingTrackAnalyzer.analyze(audio)
        Self.cached = a
        return a
    }

    func testTempoEstimate() throws {
        let a = try analysis()
        XCTAssertEqual(a.tempo.bpm, 120, accuracy: 1.5, "estimated \(a.tempo.bpm), alternatives \(a.tempo.alternatives)")
        XCTAssertTrue(a.tempo.alternatives.contains { abs($0 - 60) < 2 || abs($0 - 240) < 2 })
    }

    func testTempoHintResolvesHalfTime() throws {
        let audio = AudioBuffer(mono: SyntheticSong.make(), sampleRate: 44_100)
        let a = try BackingTrackAnalyzer.analyze(audio, options: .init(tempoHint: 60))
        XCTAssertEqual(a.tempo.bpm, 60, accuracy: 1.5)
    }

    func testBeatsLandOnTheBeat() throws {
        let a = try analysis()
        XCTAssertGreaterThan(a.beats.count, 50)
        let truth = stride(from: 0.5, to: 31.0, by: 0.5).map { $0 }
        var hits = 0
        for b in a.beats where b > 2 {
            if truth.contains(where: { abs($0 - b) < 0.035 }) { hits += 1 }
        }
        let considered = a.beats.filter { $0 > 2 }.count
        XCTAssertGreaterThan(Double(hits) / Double(considered), 0.85, "beats: \(a.beats.prefix(12))")
    }

    func testBassOnsetsFollowBassNotes() throws {
        let a = try analysis()
        let kicks = SyntheticSong.kickTimes()
        var found = 0
        for k in kicks where k > 1 {
            if a.bassOnsets.contains(where: { abs($0.time - k) < 0.03 }) { found += 1 }
        }
        XCTAssertGreaterThan(Double(found) / Double(kicks.filter { $0 > 1 }.count), 0.8)
        // Bass onsets mustn't fire on every hat.
        XCTAssertLessThan(a.bassOnsets.count, kicks.count * 2)
    }

    func testEnergyAndDensityFollowTheArrangement() throws {
        let a = try analysis()
        let quiet = a.curveValue(a.energy, at: 8)
        let loud = a.curveValue(a.energy, at: 24)
        XCTAssertGreaterThan(loud, quiet + 0.1)
        XCTAssertGreaterThan(a.curveValue(a.density, at: 24), a.curveValue(a.density, at: 8))
        // There's a boundary near the change at 16 s.
        XCTAssertTrue(a.sections.contains { abs($0.start - 16) < 2.5 }, "sections: \(a.sections.map { ($0.start, $0.kind) })")
        XCTAssertFalse(a.overview.isEmpty)
    }

    func testAutoAlignmentFindsOffset() throws {
        let a = try analysis()
        let file = Fixtures.rockBeat(bars: 12, fills: false)
        let input = Fixtures.input(file)
        let result = AutoAligner.align(pattern: input.pattern, tempoMap: input.tempoMap, map: .generalMIDI, analysis: a)
        XCTAssertEqual(result.alignment.offsetSeconds, 0.5, accuracy: 0.025)
        XCTAssertGreaterThan(result.confidence, 0.1)
        XCTAssertEqual(AutoAligner.tempoMatchStretch(midiBPM: 120, audioBPM: 60), 1, accuracy: 1e-9)
        XCTAssertEqual(AutoAligner.tempoMatchStretch(midiBPM: 120, audioBPM: 118), 120.0 / 118.0, accuracy: 1e-9)
    }

    func testTrackAwareKickBassLock() throws {
        let a = try analysis()
        let file = Fixtures.rockBeat(bars: 12, fills: false)
        var s = HumaniseSettings()
        s.trackAware.enabled = true
        s.trackAware.bandInteraction = 1
        s.trackAware.kickBassLock = 1
        s.timing.variation = 1.2
        // Misalign the MIDI by 15 ms: the lock pulls kicks back onto the bass.
        let alignment = Alignment(offsetSeconds: 0.515)
        let context = PerformanceContext(audio: AudioContext(analysis: a, alignment: alignment))
        let tight = HumanisationEngine.humanise(Fixtures.input(file, settings: s, context: context))
        s.trackAware.kickBassLock = 0
        let loose = HumanisationEngine.humanise(Fixtures.input(file, settings: s, context: context))
        let tempo = file.tempoMap
        func meanError(_ p: Performance) -> Double {
            var errors: [Double] = []
            for n in p.notes where n.pitch == 36 {
                let audioTime = alignment.audioTime(midiSeconds: tempo.seconds(atTick: n.tick))
                if let nearest = a.bassOnsets.min(by: { abs($0.time - audioTime) < abs($1.time - audioTime) }),
                   abs(nearest.time - audioTime) < 0.05 {
                    errors.append(abs(nearest.time - audioTime))
                }
            }
            return errors.reduce(0, +) / Double(max(1, errors.count))
        }
        XCTAssertLessThan(meanError(tight), meanError(loose))
    }

    func testEnergyAndSectionResponse() throws {
        let a = try analysis()
        let file = Fixtures.rockBeat(bars: 15, fills: false)
        var s = HumaniseSettings()
        s.trackAware.enabled = true
        s.trackAware.bandInteraction = 1
        s.trackAware.energyResponse = 1
        let context = PerformanceContext(audio: AudioContext(analysis: a, alignment: Alignment(offsetSeconds: 0.5)))
        let out = HumanisationEngine.humanise(Fixtures.input(file, settings: s, context: context))
        func mean(_ range: Range<Double>) -> Double {
            let v = out.notes.filter { range.contains(file.tempoMap.seconds(atTick: $0.tick)) }.map { Double($0.velocity) }
            return v.reduce(0, +) / Double(max(1, v.count))
        }
        XCTAssertGreaterThan(mean(20 ..< 28), mean(3 ..< 12) + 4)

        // Section markers alone (no audio): chorus louder than verse.
        var s2 = HumaniseSettings()
        s2.trackAware.enabled = true
        s2.trackAware.sectionAwareness = 1
        let markers = PerformanceContext(sections: [SectionMarker(bar: 0, kind: .verse), SectionMarker(bar: 8, kind: .chorus)])
        let f2 = Fixtures.rockBeat(bars: 16, fills: false)
        let o2 = HumanisationEngine.humanise(Fixtures.input(f2, settings: s2, context: markers))
        let verse = o2.notes.filter { $0.tick < 8 * 1920 }.map { Double($0.velocity) }
        let chorus = o2.notes.filter { $0.tick >= 8 * 1920 }.map { Double($0.velocity) }
        XCTAssertGreaterThan(chorus.reduce(0, +) / Double(chorus.count), verse.reduce(0, +) / Double(verse.count) + 5)
    }

    func testWAVAndAIFFReading() throws {
        let tone = (0 ..< 4410).map { Float(sin(Double($0) * 2 * .pi * 440 / 44_100) * 0.5) }
        let wav = PCMFileReader.wavData(tone, sampleRate: 44_100)
        let back = try PCMFileReader.read(wav)
        XCTAssertEqual(back.sampleRate, 44_100)
        XCTAssertEqual(back.mono.count, tone.count)
        XCTAssertEqual(Double(back.mono[100]), Double(tone[100]), accuracy: 1e-3)

        // 24-bit stereo big-endian AIFF.
        var aiff: [UInt8] = []
        func be32(_ v: Int) { aiff += [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        func be16(_ v: Int) { aiff += [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        let frames = 1000
        let ssnd = 8 + frames * 6
        aiff += Array("FORM".utf8); be32(4 + 26 + 8 + ssnd); aiff += Array("AIFF".utf8)
        aiff += Array("COMM".utf8); be32(18); be16(2); be32(frames); be16(24)
        aiff += [0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0]       // 44100 as 80-bit extended
        aiff += Array("SSND".utf8); be32(ssnd); be32(0); be32(0)
        for i in 0 ..< frames {
            let v = Int(Double(i % 100) / 100 * 4_000_000) - 2_000_000
            for _ in 0 ..< 2 { aiff += [UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        }
        let a = try PCMFileReader.read(Data(aiff))
        XCTAssertEqual(a.sampleRate, 44_100, accuracy: 0.01)
        XCTAssertEqual(a.channels, 2)
        XCTAssertEqual(a.mono.count, frames)
        XCTAssertEqual(Double(a.mono[50]), Double(Int(0.5 * 4_000_000) - 2_000_000) / 8_388_608, accuracy: 1e-4)

        XCTAssertThrowsError(try PCMFileReader.read(Data("nope nope nope".utf8)))
        XCTAssertThrowsError(try BackingTrackAnalyzer.analyze(AudioBuffer(mono: [], sampleRate: 44_100)))
    }

    func testVeryShortAndSilentAudio() throws {
        let silent = AudioBuffer(mono: [Float](repeating: 0, count: 44_100 * 3), sampleRate: 44_100)
        let a = try BackingTrackAnalyzer.analyze(silent)
        XCTAssertTrue(a.onsets.isEmpty)
        XCTAssertEqual(a.tempo.confidence, 0, accuracy: 0.5)
        let tiny = AudioBuffer(mono: [0.1, -0.1, 0.2], sampleRate: 44_100)
        _ = try BackingTrackAnalyzer.analyze(tiny)
    }
}
