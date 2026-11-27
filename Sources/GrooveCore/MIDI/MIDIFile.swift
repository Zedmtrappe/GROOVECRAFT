import Foundation

/// A Standard MIDI File held in memory, event for event.
///
/// Every event read from a file is kept (including meta, SysEx and controller data), so a file
/// can be written back without silently discarding information. Ticks are absolute.
public struct MIDIFile: Equatable, Codable, Sendable {
    public enum Format: Int, Codable, Sendable {
        case singleTrack = 0
        case multiTrack = 1
        case multiSong = 2
    }

    public var format: Format
    /// Pulses (ticks) per quarter note. SMPTE time division is converted on import.
    public var ppq: Int
    public var tracks: [MIDITrack]

    public init(format: Format = .multiTrack, ppq: Int = 480, tracks: [MIDITrack] = []) {
        self.format = format
        self.ppq = ppq
        self.tracks = tracks
    }

    /// Last tick of any event in the file.
    public var endTick: Int {
        var end = 0
        for track in tracks {
            if let last = track.events.last { end = max(end, last.tick) }
        }
        return end
    }

    public var noteCount: Int {
        var count = 0
        for track in tracks {
            for event in track.events {
                if case .noteOn(_, _, let velocity) = event.kind, velocity > 0 { count += 1 }
            }
        }
        return count
    }

    /// The file's tempo and time-signature map (gathered from every track).
    public var tempoMap: TempoMap { TempoMap(file: self) }

    /// A copy with every tick scaled to a new resolution.
    public func resampled(toPPQ newPPQ: Int) -> MIDIFile {
        guard newPPQ != ppq, newPPQ > 0, ppq > 0 else { return self }
        var copy = self
        copy.ppq = newPPQ
        let ratio = Double(newPPQ) / Double(ppq)
        for t in copy.tracks.indices {
            for e in copy.tracks[t].events.indices {
                let tick = Double(copy.tracks[t].events[e].tick) * ratio
                copy.tracks[t].events[e].tick = Int(tick.rounded())
            }
        }
        return copy
    }
}

public struct MIDITrack: Equatable, Codable, Sendable {
    public var events: [MIDIEvent]

    public init(events: [MIDIEvent] = []) { self.events = events }

    /// The track name meta event (FF 03), if any.
    public var name: String? {
        for event in events {
            if case .meta(let type, let data) = event.kind, type == MIDIMeta.trackName {
                return String(decoding: data, as: UTF8.self)
            }
        }
        return nil
    }

    public var channels: Set<Int> {
        var set = Set<Int>()
        for event in events { if let ch = event.kind.channel { set.insert(ch) } }
        return set
    }

    public var noteOnCount: Int {
        events.reduce(0) { count, event in
            if case .noteOn(_, _, let v) = event.kind, v > 0 { return count + 1 }
            return count
        }
    }

    /// Sorts events by tick, keeping the original order of events at the same tick
    /// (except that note-offs go before note-ons of the same key, so re-triggers are clean).
    public mutating func sortEvents() {
        let indexed = events.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { a, b in
            if a.1.tick != b.1.tick { return a.1.tick < b.1.tick }
            let ra = a.1.kind.sortRank
            let rb = b.1.kind.sortRank
            if ra != rb { return ra < rb }
            return a.0 < b.0
        }
        events = sorted.map { $0.1 }
    }
}

public enum MIDIMeta {
    public static let sequenceNumber: UInt8 = 0x00
    public static let text: UInt8 = 0x01
    public static let copyright: UInt8 = 0x02
    public static let trackName: UInt8 = 0x03
    public static let instrumentName: UInt8 = 0x04
    public static let lyric: UInt8 = 0x05
    public static let marker: UInt8 = 0x06
    public static let cuePoint: UInt8 = 0x07
    public static let channelPrefix: UInt8 = 0x20
    public static let port: UInt8 = 0x21
    public static let endOfTrack: UInt8 = 0x2F
    public static let tempo: UInt8 = 0x51
    public static let smpteOffset: UInt8 = 0x54
    public static let timeSignature: UInt8 = 0x58
    public static let keySignature: UInt8 = 0x59
    public static let sequencerSpecific: UInt8 = 0x7F
}

public struct MIDIEvent: Equatable, Codable, Sendable {
    public var tick: Int
    public var kind: Kind

    public init(tick: Int, kind: Kind) {
        self.tick = tick
        self.kind = kind
    }

    public enum Kind: Equatable, Codable, Sendable {
        case noteOff(channel: Int, note: Int, velocity: Int)
        case noteOn(channel: Int, note: Int, velocity: Int)
        case polyPressure(channel: Int, note: Int, pressure: Int)
        case controlChange(channel: Int, controller: Int, value: Int)
        case programChange(channel: Int, program: Int)
        case channelPressure(channel: Int, pressure: Int)
        case pitchBend(channel: Int, value: Int)
        case meta(type: UInt8, data: [UInt8])
        case sysex(data: [UInt8])
        /// F7 "escape" packet: raw bytes sent as-is.
        case sysexEscape(data: [UInt8])

        public var channel: Int? {
            switch self {
            case .noteOff(let c, _, _), .noteOn(let c, _, _), .polyPressure(let c, _, _),
                 .controlChange(let c, _, _), .programChange(let c, _), .channelPressure(let c, _),
                 .pitchBend(let c, _):
                return c
            default:
                return nil
            }
        }

        public var isEndOfTrack: Bool {
            if case .meta(let type, _) = self, type == MIDIMeta.endOfTrack { return true }
            return false
        }

        /// True for note-on with velocity > 0.
        public var isNoteStart: Bool {
            if case .noteOn(_, _, let v) = self { return v > 0 }
            return false
        }

        /// True for note-off, or note-on with velocity 0.
        public var isNoteEnd: Bool {
            switch self {
            case .noteOff: return true
            case .noteOn(_, _, let v): return v == 0
            default: return false
            }
        }

        var sortRank: Int {
            switch self {
            case .meta(let type, _):
                return type == MIDIMeta.endOfTrack ? 9 : 0
            case .noteOff: return 2
            case .noteOn(_, _, let v): return v == 0 ? 2 : 3
            default: return 1
            }
        }
    }
}

// MARK: - Convenience builders

public extension MIDIEvent {
    static func tempo(tick: Int, bpm: Double) -> MIDIEvent {
        let mpq = Int((60_000_000.0 / bpm).rounded())
        let data: [UInt8] = [UInt8((mpq >> 16) & 0xFF), UInt8((mpq >> 8) & 0xFF), UInt8(mpq & 0xFF)]
        return MIDIEvent(tick: tick, kind: .meta(type: MIDIMeta.tempo, data: data))
    }

    static func timeSignature(tick: Int, numerator: Int, denominator: Int) -> MIDIEvent {
        var power = 0
        var d = max(1, denominator)
        while d > 1 { d >>= 1; power += 1 }
        let data: [UInt8] = [UInt8(numerator & 0xFF), UInt8(power), 24, 8]
        return MIDIEvent(tick: tick, kind: .meta(type: MIDIMeta.timeSignature, data: data))
    }

    static func trackName(_ name: String, tick: Int = 0) -> MIDIEvent {
        MIDIEvent(tick: tick, kind: .meta(type: MIDIMeta.trackName, data: Array(name.utf8)))
    }

    static func endOfTrack(tick: Int) -> MIDIEvent {
        MIDIEvent(tick: tick, kind: .meta(type: MIDIMeta.endOfTrack, data: []))
    }
}
