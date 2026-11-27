import Foundation

/// A small synthesised drum kit for the built-in preview. Every sound is generated in code,
/// so no sample licensing is involved. It's for checking feel and dynamics; external MIDI to
/// the user's own drum instrument is the main audition path.
public final class DrumSynth {
    public let sampleRate: Double
    public var gain: Float = 0.8

    enum Kind { case kick, snare, sideStick, closedHat, openHat, pedalHat, ride, rideBell, crash, splash, china, tom, clap, cowbell, tambourine, block, blip }

    struct Voice {
        var kind: Kind = .blip
        var age: Int = 0            // samples since the hit (negative = starts later in the block)
        var amp: Float = 0
        var pan: Float = 0
        var freq: Double = 100
        var phase: Double = 0
        // Six square-wave oscillators for metallic sounds (no arrays: nothing allocates on the audio thread).
        var m0 = 0.0, m1 = 0.0, m2 = 0.0, m3 = 0.0, m4 = 0.0, m5 = 0.0
        var noiseState: UInt32 = 22_222
        var hp1: Float = 0, hpPrev: Float = 0, lp1: Float = 0, lp2: Float = 0
        var active = false
        var choke = false
        var decay: Float = 1        // extra fade after a choke
    }

    private var voices: [Voice]
    private var nextVoice = 0

    public init(sampleRate: Double, polyphony: Int = 48) {
        self.sampleRate = sampleRate
        voices = [Voice](repeating: Voice(), count: polyphony)
    }

    /// Starts a hit `offset` frames into the next rendered block.
    public func trigger(category: DrumCategory, note: Int, velocity: Int, offset: Int = 0) {
        let v = Float(pow(Double(clamp(velocity, 1, 127)) / 127, 1.6))
        var voice = Voice()
        voice.age = -max(0, offset)
        voice.amp = v
        voice.active = true
        voice.noiseState = UInt32(truncatingIfNeeded: 0x9E37 &* (note + 1) &+ velocity &* 31 &+ nextVoice &* 977) | 1
        switch category {
        case .kick: voice.kind = .kick; voice.pan = 0
        case .snare: voice.kind = .snare; voice.pan = -0.05
        case .sideStick: voice.kind = .sideStick; voice.pan = -0.05
        case .closedHat: voice.kind = .closedHat; voice.pan = -0.3
        case .openHat: voice.kind = .openHat; voice.pan = -0.3
        case .pedalHat: voice.kind = .pedalHat; voice.pan = -0.3
        case .ride: voice.kind = .ride; voice.pan = 0.35
        case .rideBell: voice.kind = .rideBell; voice.pan = 0.35
        case .crash: voice.kind = .crash; voice.pan = note % 2 == 0 ? -0.4 : 0.45
        case .splash: voice.kind = .splash; voice.pan = 0.2
        case .china: voice.kind = .china; voice.pan = 0.5
        case .highTom: voice.kind = .tom; voice.freq = 210; voice.pan = -0.2
        case .midTom: voice.kind = .tom; voice.freq = note >= 48 ? 170 : 150; voice.pan = 0
        case .lowTom: voice.kind = .tom; voice.freq = 125; voice.pan = 0.15
        case .floorTom: voice.kind = .tom; voice.freq = note == 43 ? 105 : 88; voice.pan = 0.3
        case .percussion:
            switch note {
            case 39: voice.kind = .clap
            case 56: voice.kind = .cowbell
            case 54: voice.kind = .tambourine
            default: voice.kind = .block; voice.freq = 600 + Double((note * 37) % 500)
            }
            voice.pan = Float((note % 5) - 2) * 0.15
        case .other: voice.kind = .blip; voice.freq = 440 * pow(2, Double(note - 69) / 12)
        }
        // Closed and pedal hats choke a ringing open hat.
        if category == .closedHat || category == .pedalHat {
            for i in voices.indices where voices[i].active && voices[i].kind == .openHat { voices[i].choke = true }
        }
        voices[nextVoice] = voice
        nextVoice = (nextVoice + 1) % voices.count
    }

    public func allNotesOff() {
        for i in voices.indices where voices[i].active { voices[i].choke = true }
    }

    public func reset() {
        for i in voices.indices { voices[i].active = false }
    }

    public var activeVoiceCount: Int { voices.filter(\.active).count }

    /// Adds `frames` samples into the stereo buffers.
    public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let sr = sampleRate
        let twoPi = 2.0 * Double.pi
        for vi in voices.indices where voices[vi].active {
            var v = voices[vi]
            let panL = (1 - max(0, v.pan)) * gain
            let panR = (1 + min(0, v.pan)) * gain
            for f in 0 ..< frames {
                if v.age < 0 { v.age += 1; continue }
                let t = Double(v.age) / sr
                var s: Float = 0
                switch v.kind {
                case .kick:
                    let fq = 46 + 120 * exp(-t * 38)
                    v.phase += twoPi * fq / sr
                    let body = Float(sin(v.phase) * exp(-t * 7.5))
                    let click = noise(&v.noiseState) * Float(exp(-t * 900)) * 0.35
                    s = tanhf((body + click) * 1.6) * 0.9
                    if t > 0.9 { v.active = false }
                case .snare:
                    v.phase += twoPi * 186 / sr
                    let tone = Float(sin(v.phase) * exp(-t * 24)) * 0.45 + Float(sin(v.phase * 1.78) * exp(-t * 32)) * 0.22
                    let n = highPass(&v, noise(&v.noiseState), 0.82)
                    s = tone + n * Float(exp(-t * 15)) * 0.75
                    if t > 0.6 { v.active = false }
                case .sideStick:
                    v.phase += twoPi * 920 / sr
                    s = Float(sin(v.phase) * exp(-t * 70)) * 0.5 + highPass(&v, noise(&v.noiseState), 0.6) * Float(exp(-t * 110)) * 0.5
                    if t > 0.2 { v.active = false }
                case .closedHat, .openHat, .pedalHat:
                    let metal = metallic(&v, base: 410, sr: sr)
                    let n = highPass(&v, noise(&v.noiseState) * 0.6 + metal * 0.5, 0.96)
                    let rate: Double = v.kind == .closedHat ? 55 : (v.kind == .pedalHat ? 80 : 5.5)
                    s = n * Float(exp(-t * rate)) * (v.kind == .pedalHat ? 0.45 : 0.7)
                    if t > (v.kind == .openHat ? 1.6 : 0.3) { v.active = false }
                case .ride, .rideBell:
                    let metal = metallic(&v, base: v.kind == .rideBell ? 620 : 520, sr: sr)
                    let n = highPass(&v, metal * 0.7 + noise(&v.noiseState) * 0.25, 0.9)
                    let bell = v.kind == .rideBell ? Float(sin(twoPi * 1220 * t) * exp(-t * 3)) * 0.35 : 0
                    s = (n * Float(exp(-t * 2.6)) + n * Float(exp(-t * 40)) * 0.6 + bell) * 0.45
                    if t > 3 { v.active = false }
                case .crash, .splash, .china:
                    let metal = metallic(&v, base: v.kind == .china ? 330 : 450, sr: sr)
                    var n = highPass(&v, noise(&v.noiseState) * 0.8 + metal * 0.4, 0.88)
                    if v.kind == .china { n = tanhf(n * 2.5) * 0.6 }
                    let rate: Double = v.kind == .splash ? 4.5 : 1.5
                    s = n * Float(exp(-t * rate)) * 0.55
                    if t > (v.kind == .splash ? 1.2 : 3.5) { v.active = false }
                case .tom:
                    let fq = v.freq * (1 + 0.55 * exp(-t * 22))
                    v.phase += twoPi * fq / sr
                    s = Float(sin(v.phase) * exp(-t * 6.5)) * 0.85 + noise(&v.noiseState) * Float(exp(-t * 70)) * 0.15
                    if t > 1.1 { v.active = false }
                case .clap:
                    let burst = t < 0.03 ? Float(exp(-(t.truncatingRemainder(dividingBy: 0.01)) * 300)) : Float(exp(-(t - 0.03) * 18))
                    s = highPass(&v, noise(&v.noiseState), 0.75) * burst * 0.6
                    if t > 0.4 { v.active = false }
                case .cowbell:
                    v.phase += twoPi * 545 / sr
                    let a = v.phase.truncatingRemainder(dividingBy: twoPi) < Double.pi ? 1.0 : -1.0
                    let b = (v.phase * 1.48).truncatingRemainder(dividingBy: twoPi) < Double.pi ? 1.0 : -1.0
                    s = Float((a + b) * 0.25 * exp(-t * 11))
                    if t > 0.6 { v.active = false }
                case .tambourine:
                    s = highPass(&v, noise(&v.noiseState), 0.97) * Float(exp(-t * 9)) * 0.5
                    if t > 0.5 { v.active = false }
                case .block:
                    v.phase += twoPi * v.freq / sr
                    s = Float(sin(v.phase) * exp(-t * 45)) * 0.6
                    if t > 0.25 { v.active = false }
                case .blip:
                    v.phase += twoPi * v.freq / sr
                    s = Float(sin(v.phase) * exp(-t * 20)) * 0.3
                    if t > 0.3 { v.active = false }
                }
                if v.choke {
                    v.decay *= 0.9985
                    if v.decay < 0.001 { v.active = false }
                }
                s *= v.amp * v.decay
                left[f] += s * panL
                right[f] += s * panR
                v.age += 1
                if !v.active { break }
            }
            voices[vi] = v
        }
    }

    @inline(__always)
    private func noise(_ state: inout UInt32) -> Float {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return Float(Int32(bitPattern: state)) / Float(Int32.max)
    }

    @inline(__always)
    private func highPass(_ v: inout Voice, _ x: Float, _ coefficient: Float) -> Float {
        let y = coefficient * (v.hp1 + x - v.hpPrev)
        v.hpPrev = x
        v.hp1 = y
        return y
    }

    @inline(__always)
    private func metallic(_ v: inout Voice, base: Double, sr: Double) -> Float {
        let step = base / sr
        func advance(_ p: inout Double, _ ratio: Double) -> Double {
            p += ratio * step
            if p >= 1 { p -= 1 }
            return p < 0.5 ? 1 : -1
        }
        var sum = advance(&v.m0, 1.0)
        sum += advance(&v.m1, 1.4828)
        sum += advance(&v.m2, 1.8003)
        sum += advance(&v.m3, 2.5463)
        sum += advance(&v.m4, 2.6307)
        sum += advance(&v.m5, 3.8970)
        return Float(sum / 6)
    }
}

/// Renders the built-in preview: the backing track and/or the synth kit, driven by the same
/// transport mapping as the MIDI scheduler. Called from the audio thread by the app.
public final class PreviewRenderer {
    public struct Note: Sendable {
        public var start: Double
        public var category: DrumCategory
        public var note: Int
        public var velocity: Int
    }

    public let sampleRate: Double
    public let synth: DrumSynth
    private let lock = NSLock()

    // State shared with the audio thread (guarded by `lock`).
    private var notes: [Note] = []
    private var mapper = LoopMapper(startPosition: 0)
    private var running = false
    private var backingL: [Float] = []
    private var backingR: [Float] = []
    private var alignment = Alignment.none
    private var lastSongPosition: Double = -1

    public var drumsEnabled = true
    public var backingEnabled = true
    public var drumGain: Float = 0.9
    public var backingGain: Float = 0.8

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        synth = DrumSynth(sampleRate: sampleRate)
    }

    /// Sets the backing audio (any rate; resampled once here, off the audio thread).
    public func setBacking(left: [Float], right: [Float], sampleRate rate: Double) {
        let ratio = rate / sampleRate
        let count = Int(Double(left.count) / ratio)
        var l = [Float](repeating: 0, count: count)
        var r = [Float](repeating: 0, count: count)
        for i in 0 ..< count {
            let x = Double(i) * ratio
            let k = Int(x)
            let f = Float(x - Double(k))
            if k + 1 < left.count {
                l[i] = left[k] * (1 - f) + left[k + 1] * f
                r[i] = right[k] * (1 - f) + right[k + 1] * f
            }
        }
        lock.lock()
        backingL = l
        backingR = r
        lock.unlock()
    }

    public func clearBacking() {
        lock.lock(); backingL = []; backingR = []; lock.unlock()
    }

    public var hasBacking: Bool {
        lock.lock(); defer { lock.unlock() }
        return !backingL.isEmpty
    }

    public func setNotes(_ newNotes: [Note], alignment newAlignment: Alignment) {
        let sorted = newNotes.sorted { $0.start < $1.start }
        lock.lock()
        notes = sorted
        alignment = newAlignment
        lock.unlock()
    }

    public func start(mapper newMapper: LoopMapper) {
        lock.lock()
        mapper = newMapper
        running = true
        lastSongPosition = -1
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        running = false
        lock.unlock()
        synth.allNotesOff()
    }

    /// Renders one block. `transportTime` is the transport time of the block's first frame
    /// (it can be negative just before playback starts).
    public func render(transportTime: Double, frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        for i in 0 ..< frames { left[i] = 0; right[i] = 0 }
        guard lock.try() else { return }
        defer { lock.unlock() }
        let blockSeconds = Double(frames) / sampleRate
        if running && transportTime + blockSeconds > 0 {
            let from = max(0, transportTime)
            let segments = mapper.segments(transportFrom: from, to: transportTime + blockSeconds)
            if drumsEnabled {
                for seg in segments {
                    var lo = 0, hi = notes.count
                    while lo < hi { let m = (lo + hi) / 2; if notes[m].start < seg.from { lo = m + 1 } else { hi = m } }
                    var i = lo
                    while i < notes.count && notes[i].start < seg.to {
                        let n = notes[i]
                        let t = seg.transportStart + (n.start - seg.from)
                        let offset = Int(((t - transportTime) * sampleRate).rounded())
                        synth.trigger(category: n.category, note: n.note, velocity: n.velocity, offset: clamp(offset, 0, frames - 1))
                        i += 1
                    }
                    if seg.endsAtWrap { synth.allNotesOff() }
                }
            }
            if backingEnabled && !backingL.isEmpty {
                for f in 0 ..< frames {
                    let t = transportTime + Double(f) / sampleRate
                    if t < 0 { continue }
                    let song = mapper.position(atTransport: t)
                    // Song time is MIDI time × stretch, so the audio time is offset + song time.
                    let idx = Int((alignment.offsetSeconds + song) * sampleRate)
                    if idx >= 0 && idx < backingL.count {
                        left[f] += backingL[idx] * backingGain
                        right[f] += backingR[idx] * backingGain
                    }
                }
            }
        }
        synth.gain = drumGain
        synth.render(frames: frames, left: left, right: right)
    }
}
