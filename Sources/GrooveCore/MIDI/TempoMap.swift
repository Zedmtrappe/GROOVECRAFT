import Foundation

/// Tempo and time-signature map: converts between ticks, seconds and bars/beats.
public struct TempoMap: Equatable, Codable, Sendable {
    public struct TempoChange: Equatable, Codable, Sendable {
        public var tick: Int
        public var bpm: Double
        public init(tick: Int, bpm: Double) { self.tick = tick; self.bpm = bpm }
    }

    public struct TimeSignature: Equatable, Codable, Sendable {
        public var tick: Int
        public var numerator: Int
        public var denominator: Int
        public init(tick: Int, numerator: Int, denominator: Int) {
            self.tick = tick
            self.numerator = numerator
            self.denominator = denominator
        }
        public var label: String { "\(numerator)/\(denominator)" }
    }

    public var ppq: Int
    public private(set) var tempos: [TempoChange]
    public private(set) var signatures: [TimeSignature]

    public init(ppq: Int, tempos: [TempoChange] = [], signatures: [TimeSignature] = []) {
        self.ppq = max(1, ppq)
        var t = tempos.sorted { $0.tick < $1.tick }
        if t.first?.tick != 0 { t.insert(TempoChange(tick: 0, bpm: t.first?.bpm ?? 120), at: 0) }
        self.tempos = TempoMap.dedupe(t)
        var s = signatures.sorted { $0.tick < $1.tick }
        if s.first?.tick != 0 { s.insert(TimeSignature(tick: 0, numerator: s.first?.numerator ?? 4, denominator: s.first?.denominator ?? 4), at: 0) }
        self.signatures = s
    }

    public init(file: MIDIFile) {
        var tempos: [TempoChange] = []
        var signatures: [TimeSignature] = []
        for track in file.tracks {
            for event in track.events {
                guard case .meta(let type, let data) = event.kind else { continue }
                if type == MIDIMeta.tempo, data.count >= 3 {
                    let mpq = (Int(data[0]) << 16) | (Int(data[1]) << 8) | Int(data[2])
                    if mpq > 0 { tempos.append(TempoChange(tick: event.tick, bpm: 60_000_000.0 / Double(mpq))) }
                } else if type == MIDIMeta.timeSignature, data.count >= 2 {
                    let den = 1 << Int(min(data[1], 6))
                    signatures.append(TimeSignature(tick: event.tick, numerator: max(1, Int(data[0])), denominator: den))
                }
            }
        }
        self.init(ppq: file.ppq, tempos: tempos, signatures: signatures)
    }

    private static func dedupe(_ list: [TempoChange]) -> [TempoChange] {
        var out: [TempoChange] = []
        for change in list {
            if let last = out.last, last.tick == change.tick { out[out.count - 1] = change } else { out.append(change) }
        }
        return out
    }

    public var initialBPM: Double { tempos.first?.bpm ?? 120 }
    public var initialSignature: TimeSignature { signatures.first ?? TimeSignature(tick: 0, numerator: 4, denominator: 4) }
    public var hasTempoChanges: Bool { tempos.count > 1 }

    public func bpm(atTick tick: Int) -> Double {
        var bpm = initialBPM
        for change in tempos where change.tick <= tick { bpm = change.bpm }
        return bpm
    }

    public func signature(atTick tick: Double) -> TimeSignature {
        var sig = initialSignature
        for s in signatures where Double(s.tick) <= tick { sig = s }
        return sig
    }

    /// Seconds from tick 0 to `tick` (fractional ticks allowed).
    public func seconds(atTick tick: Double) -> Double {
        var seconds = 0.0
        var lastTick = 0.0
        var bpm = initialBPM
        for change in tempos.dropFirst() {
            let changeTick = Double(change.tick)
            if changeTick >= tick { break }
            seconds += (changeTick - lastTick) * secondsPerTick(bpm)
            lastTick = changeTick
            bpm = change.bpm
        }
        seconds += (tick - lastTick) * secondsPerTick(bpm)
        return seconds
    }

    public func tick(atSeconds target: Double) -> Double {
        var seconds = 0.0
        var lastTick = 0.0
        var bpm = initialBPM
        for change in tempos.dropFirst() {
            let changeTick = Double(change.tick)
            let segment = (changeTick - lastTick) * secondsPerTick(bpm)
            if seconds + segment > target { break }
            seconds += segment
            lastTick = changeTick
            bpm = change.bpm
        }
        return lastTick + (target - seconds) / secondsPerTick(bpm)
    }

    private func secondsPerTick(_ bpm: Double) -> Double { 60.0 / (max(1, bpm) * Double(ppq)) }

    /// Ticks in one beat (the signature's denominator note) at `tick`.
    public func ticksPerBeat(atTick tick: Double) -> Double {
        let sig = signature(atTick: tick)
        return Double(ppq) * 4.0 / Double(sig.denominator)
    }

    public func ticksPerBar(atTick tick: Double) -> Double {
        let sig = signature(atTick: tick)
        return ticksPerBeat(atTick: tick) * Double(sig.numerator)
    }

    /// Musical position of a tick: zero-based bar, zero-based beat and fractional beat.
    public struct Position: Equatable, Sendable {
        public var bar: Int
        public var beat: Int
        public var beatFraction: Double
        public var beatsInBar: Int
        public var ticksPerBeat: Double
        public var barStartTick: Double

        /// Display string such as "5.3.25" (1-based bar.beat.percent).
        public var display: String {
            "\(bar + 1).\(beat + 1).\(Int((beatFraction * 100).rounded(.down)))"
        }
    }

    public func position(atTick tick: Double) -> Position {
        var bar = 0
        var barStart = 0.0
        for (i, sig) in signatures.enumerated() {
            let sigStart = Double(sig.tick)
            let next = i + 1 < signatures.count ? Double(signatures[i + 1].tick) : Double.infinity
            let tpBeat = Double(ppq) * 4.0 / Double(sig.denominator)
            let tpBar = tpBeat * Double(sig.numerator)
            if tick < next || i == signatures.count - 1 {
                let into = max(0, tick - sigStart)
                let bars = (into / tpBar).rounded(.down)
                bar += Int(bars)
                barStart = sigStart + bars * tpBar
                let inBar = tick - barStart
                let beatValue = inBar / tpBeat
                let beat = Int(beatValue.rounded(.down))
                return Position(bar: bar, beat: min(beat, sig.numerator - 1), beatFraction: beatValue - Double(beat),
                                beatsInBar: sig.numerator, ticksPerBeat: tpBeat, barStartTick: barStart)
            }
            let span = next - sigStart
            bar += Int((span / tpBar).rounded(.up))
        }
        return Position(bar: 0, beat: 0, beatFraction: 0, beatsInBar: 4, ticksPerBeat: Double(ppq), barStartTick: 0)
    }

    /// Tick at the start of a zero-based bar.
    public func tick(atBar targetBar: Int) -> Double {
        var bar = 0
        for (i, sig) in signatures.enumerated() {
            let sigStart = Double(sig.tick)
            let tpBar = Double(ppq) * 4.0 / Double(sig.denominator) * Double(sig.numerator)
            let next = i + 1 < signatures.count ? Double(signatures[i + 1].tick) : Double.infinity
            let barsHere = next.isInfinite ? Int.max : Int(((next - sigStart) / tpBar).rounded(.up))
            if targetBar - bar < barsHere {
                return sigStart + Double(targetBar - bar) * tpBar
            }
            bar += barsHere
        }
        return 0
    }

    /// Number of bars needed to contain `endTick`.
    public func barCount(endTick: Int) -> Int {
        let pos = position(atTick: Double(max(0, endTick - 1)))
        return pos.bar + 1
    }
}
