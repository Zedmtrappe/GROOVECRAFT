import Foundation

/// A single drum hit taken from (or added to) a MIDI file.
public struct DrumNote: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Stable identity: original notes are numbered in file order, added notes get ids from
    /// `DrumNote.addedIDBase` upward.
    public var id: Int
    public var track: Int
    public var channel: Int
    public var pitch: Int
    /// Start in ticks (fractional, so microtiming isn't lost before export).
    public var tick: Double
    public var length: Double
    public var velocity: Int
    public var origin: Origin

    public enum Origin: String, Codable, Sendable {
        case original
        case ghost       // added ghost note
        case flam        // grace note of a flam
        case drag        // grace notes of a drag/ruff
        case roll        // roll in-fill
        case articulation // e.g. hi-hat opening
        case edited      // original note changed by hand in the editor

        public var isAdded: Bool { self != .original && self != .edited }
    }

    public static let addedIDBase = 1_000_000

    public init(id: Int, track: Int, channel: Int, pitch: Int, tick: Double, length: Double, velocity: Int, origin: Origin = .original) {
        self.id = id
        self.track = track
        self.channel = channel
        self.pitch = pitch
        self.tick = tick
        self.length = length
        self.velocity = velocity
        self.origin = origin
    }

    public var endTick: Double { tick + length }
}

/// The drum part of a MIDI file as a list of notes, with the information needed to write a
/// processed version back into the original file.
public struct DrumPattern: Codable, Equatable, Sendable {
    public var notes: [DrumNote]
    /// Indexes of the tracks that hold the drum part.
    public var drumTracks: [Int]
    public var ppq: Int
    /// When set, only notes on this channel belong to the drum part (e.g. channel 10 in a
    /// format 0 file that also holds bass and keys).
    public var channelFilter: Int?

    public init(notes: [DrumNote], drumTracks: [Int], ppq: Int, channelFilter: Int? = nil) {
        self.notes = notes.sorted(by: DrumPattern.order)
        self.drumTracks = drumTracks
        self.ppq = ppq
        self.channelFilter = channelFilter
    }

    public static func order(_ a: DrumNote, _ b: DrumNote) -> Bool {
        if a.tick != b.tick { return a.tick < b.tick }
        if a.pitch != b.pitch { return a.pitch < b.pitch }
        return a.id < b.id
    }

    public var endTick: Double { notes.map(\.endTick).max() ?? 0 }
    public var pitches: [Int] { Array(Set(notes.map(\.pitch))).sorted() }

    /// Extracts notes from the given tracks (all channels, unless `channel` is set).
    public static func extract(from file: MIDIFile, tracks: [Int], channel: Int? = nil) -> DrumPattern {
        var notes: [DrumNote] = []
        var nextID = 0
        for t in tracks where t < file.tracks.count {
            // Pair note-ons with note-offs per (channel, pitch), first-in first-out.
            var open: [Int: [(tick: Int, velocity: Int, index: Int)]] = [:]
            var pending: [DrumNote] = []
            for event in file.tracks[t].events {
                switch event.kind {
                case .noteOn(let c, let n, let v) where v > 0:
                    if let only = channel, only != c { continue }
                    let key = c * 128 + n
                    let note = DrumNote(id: nextID, track: t, channel: c, pitch: n, tick: Double(event.tick),
                                        length: 0, velocity: v)
                    nextID += 1
                    pending.append(note)
                    open[key, default: []].append((event.tick, v, pending.count - 1))
                case .noteOn(let c, let n, _), .noteOff(let c, let n, _):
                    if let only = channel, only != c { continue }
                    let key = c * 128 + n
                    if var list = open[key], !list.isEmpty {
                        let first = list.removeFirst()
                        open[key] = list
                        pending[first.index].length = Double(max(1, event.tick - first.tick))
                    }
                default:
                    break
                }
            }
            // Unterminated notes get a 16th-note length.
            let fallback = Double(max(1, file.ppq / 4))
            for i in pending.indices where pending[i].length == 0 { pending[i].length = fallback }
            notes += pending
        }
        return DrumPattern(notes: notes, drumTracks: tracks, ppq: file.ppq, channelFilter: channel)
    }

    /// Where the drums are in a file: tracks, plus a channel when drum tracks also carry
    /// other instruments (typical of format 0 files).
    public struct Source: Equatable, Codable, Sendable {
        public var tracks: [Int]
        public var channel: Int?
        public init(tracks: [Int], channel: Int?) { self.tracks = tracks; self.channel = channel }
    }

    public static func detectSource(in file: MIDIFile) -> Source {
        let tracks = detectDrumTracks(in: file)
        var channels = Set<Int>()
        for t in tracks where t < file.tracks.count {
            for e in file.tracks[t].events where e.kind.isNoteStart {
                if let c = e.kind.channel { channels.insert(c) }
            }
        }
        if channels.count > 1 && channels.contains(9) { return Source(tracks: tracks, channel: 9) }
        return Source(tracks: tracks, channel: nil)
    }

    public static func extract(from file: MIDIFile, source: Source) -> DrumPattern {
        extract(from: file, tracks: source.tracks, channel: source.channel)
    }

    /// Finds the tracks most likely to hold drums: channel 10, a drum-like name, or notes that
    /// sit mostly in the GM percussion range with short lengths.
    public static func detectDrumTracks(in file: MIDIFile) -> [Int] {
        var scored: [(Int, Double)] = []
        for (i, track) in file.tracks.enumerated() {
            let starts = track.events.filter { $0.kind.isNoteStart }
            guard !starts.isEmpty else { continue }
            var score = 0.0
            let ch10 = starts.filter { $0.kind.channel == 9 }.count
            score += 3.0 * Double(ch10) / Double(starts.count)
            let name = (track.name ?? "").lowercased()
            let drumWords = ["drum", "kit", "perc", "beat", "kick", "snare", "hat", "groove", "superior", "ezd", "bfd", "slate"]
            if drumWords.contains(where: { name.contains($0) }) { score += 2 }
            var inRange = 0
            for e in starts { if case .noteOn(_, let n, _) = e.kind, (35 ... 81).contains(n) { inRange += 1 } }
            score += Double(inRange) / Double(starts.count)
            let distinct = Set(starts.compactMap { e -> Int? in
                if case .noteOn(_, let n, _) = e.kind { return n }
                return nil
            })
            if distinct.count <= 24 { score += 0.3 }
            scored.append((i, score))
        }
        let strong = scored.filter { $0.1 >= 2.0 }.map { $0.0 }
        if !strong.isEmpty { return strong }
        let likely = scored.filter { $0.1 >= 1.0 }.map { $0.0 }
        if !likely.isEmpty { return likely }
        // Fall back to every track with notes: a single-instrument drum file is the usual case.
        return scored.map { $0.0 }
    }

    /// Writes the pattern back into a copy of `source`, replacing the drum tracks' notes and
    /// keeping every other event (controllers, meta events, other tracks) untouched.
    /// The output resolution is raised to at least 960 PPQ so microtiming survives rounding.
    public func applied(to source: MIDIFile, minimumPPQ: Int = 960) -> MIDIFile {
        let outPPQ = max(source.ppq, minimumPPQ)
        var file = source.resampled(toPPQ: outPPQ)
        let scale = Double(outPPQ) / Double(max(1, ppq))
        let trackSet = Set(drumTracks)
        for t in file.tracks.indices where trackSet.contains(t) {
            var kept: [MIDIEvent] = []
            var endTick = 0
            for event in file.tracks[t].events {
                if event.kind.isEndOfTrack { endTick = max(endTick, event.tick); continue }
                switch event.kind {
                case .noteOn(let c, _, _), .noteOff(let c, _, _):
                    // Drop the notes the pattern was taken from; the pattern replaces them.
                    if let only = channelFilter, only != c { kept.append(event) }
                default:
                    kept.append(event)
                }
            }
            for note in notes where note.track == t {
                let start = max(0, Int((note.tick * scale).rounded()))
                let end = max(start + 1, Int((note.endTick * scale).rounded()))
                let v = max(1, min(127, note.velocity))
                kept.append(MIDIEvent(tick: start, kind: .noteOn(channel: note.channel, note: note.pitch, velocity: v)))
                kept.append(MIDIEvent(tick: end, kind: .noteOff(channel: note.channel, note: note.pitch, velocity: 64)))
                endTick = max(endTick, end)
            }
            for e in kept { endTick = max(endTick, e.tick) }
            kept.append(.endOfTrack(tick: endTick))
            var track = MIDITrack(events: kept)
            track.sortEvents()
            file.tracks[t] = track
        }
        return file
    }
}
