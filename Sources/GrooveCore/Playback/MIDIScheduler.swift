import Foundation

/// What gets sent to the external instrument.
public struct MIDIOutputSettings: Codable, Equatable, Hashable, Sendable {
    /// Output channel 0–15, or nil to keep each note's own channel.
    public var channel: Int? = 9
    public var noteMap: OutputNoteMap = .identity
    /// Sends MIDI this much earlier than the audio, to make up for the external instrument's
    /// own latency (ms, 0–250).
    public var latencyMs: Double = 0
    /// Extra start offset in ms (+ later, − earlier) relative to the backing track.
    public var startOffsetMs: Double = 0
    public var sendClock: Bool = false
    public var sendTransport: Bool = false
    /// Velocity scale (0.5–1.5) for instruments that respond hotter or softer.
    public var velocityScale: Double = 1
    /// Fixed note length sent to the instrument (ms); 0 = the performance's own lengths.
    public var fixedLengthMs: Double = 0

    public init() {}
}

/// A note scheduled on the song timeline (seconds), ready to send.
public struct TimelineNote: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var channel: Int
    public var note: Int
    public var velocity: Int
    /// Index of the source note in the performance (for the activity display).
    public var sourceID: Int
}

/// The song-timeline version of a performance.
public struct PlaybackPlan: Equatable, Sendable {
    public var notes: [TimelineNote]
    /// Clock ticks (24 per quarter) in song seconds, when clock output is on.
    public var clockTimes: [Double]
    public var duration: Double
    public var tempoMap: TempoMap
    public var stretch: Double

    public init(notes: [DrumNote], tempoMap: TempoMap, settings: MIDIOutputSettings, stretch: Double = 1, includeClock: Bool = false) {
        var timeline: [TimelineNote] = []
        timeline.reserveCapacity(notes.count)
        for n in notes {
            let start = tempoMap.seconds(atTick: n.tick) * stretch
            var end = tempoMap.seconds(atTick: n.endTick) * stretch
            if settings.fixedLengthMs > 0 { end = start + settings.fixedLengthMs / 1000 }
            end = max(end, start + 0.002)
            let vel = Int((Double(n.velocity) * settings.velocityScale).rounded())
            timeline.append(TimelineNote(start: start, end: end, channel: settings.channel ?? n.channel,
                                         note: settings.noteMap.output(for: n.pitch), velocity: clamp(vel, 1, 127), sourceID: n.id))
        }
        timeline.sort { $0.start == $1.start ? $0.note < $1.note : $0.start < $1.start }
        self.notes = timeline
        self.tempoMap = tempoMap
        self.stretch = stretch
        let last = timeline.map(\.end).max() ?? 0
        self.duration = last
        var clocks: [Double] = []
        if includeClock {
            let step = Double(tempoMap.ppq) / 24
            let endTick = tempoMap.tick(atSeconds: last / max(0.0001, stretch)) + Double(tempoMap.ppq) * 4
            var tick = 0.0
            while tick <= endTick {
                clocks.append(tempoMap.seconds(atTick: tick) * stretch)
                tick += step
            }
        }
        self.clockTimes = clocks
    }

    /// Index of the first note starting at or after `time`.
    func firstNote(atOrAfter time: Double) -> Int {
        var lo = 0, hi = notes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if notes[mid].start < time { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    func firstClock(atOrAfter time: Double) -> Int {
        var lo = 0, hi = clockTimes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if clockTimes[mid] < time { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Song position in 16th notes (for Song Position Pointer).
    public func sixteenths(atSong seconds: Double) -> Int {
        let tick = tempoMap.tick(atSeconds: seconds / max(0.0001, stretch))
        return Int((tick / (Double(tempoMap.ppq) / 4)).rounded(.down))
    }
}

/// A MIDI message with the transport time it must be sent at.
public struct ScheduledMIDI: Equatable, Sendable {
    public var time: Double
    public var bytes: [UInt8]
    public init(time: Double, bytes: [UInt8]) { self.time = time; self.bytes = bytes }
}

/// The MIDI scheduler's logic, independent of CoreMIDI and of any clock: the platform layer
/// asks it for everything due up to a transport time and sends the messages with exact
/// timestamps. It guarantees correct ordering, no stuck notes (every note-on gets a note-off,
/// on stop, on loop wrap and when switching performances) and clean re-triggers.
public final class MIDIScheduler {
    public private(set) var plan: PlaybackPlan
    public private(set) var mapper: LoopMapper
    public private(set) var processedUntil: Double = 0
    public private(set) var isRunning = false
    var settings: MIDIOutputSettings

    /// Active notes: (channel << 7 | note) → scheduled transport time of its note-off.
    private var active: [Int: Double] = [:]
    /// Pending note-offs (transport time, channel, note).
    private var pendingOffs: [(time: Double, channel: Int, note: Int)] = []
    private var channelsUsed = Set<Int>()

    public init(plan: PlaybackPlan, settings: MIDIOutputSettings) {
        self.plan = plan
        self.settings = settings
        self.mapper = LoopMapper(startPosition: 0)
        for n in plan.notes { channelsUsed.insert(n.channel) }
    }

    /// The latency/offset shift applied to every note (seconds, transport time).
    var shift: Double { (settings.startOffsetMs - settings.latencyMs) / 1000 }

    public func start(at position: Double, loop: ClosedRange<Double>?) -> [ScheduledMIDI] {
        mapper = LoopMapper(startPosition: position, loop: loop)
        processedUntil = min(0, shift)
        isRunning = true
        active.removeAll()
        pendingOffs.removeAll()
        var out: [ScheduledMIDI] = []
        if settings.sendTransport {
            out.append(ScheduledMIDI(time: 0, bytes: MIDIBytes.songPosition(plan.sixteenths(atSong: position))))
            out.append(ScheduledMIDI(time: 0, bytes: position <= 0.0001 ? MIDIBytes.start : MIDIBytes.continue))
        }
        return out
    }

    /// Everything due in (processedUntil, until], in time order.
    public func process(until: Double) -> [ScheduledMIDI] {
        guard isRunning, until > processedUntil else { return [] }
        var events: [ScheduledMIDI] = []
        let from = processedUntil
        processedUntil = until

        // Song windows are shifted by the latency compensation: a note at song time s is sent
        // at transport time (s − position) + shift.
        let segments = mapper.segments(transportFrom: max(0, from - shift), to: until - shift)
        for seg in segments {
            var i = plan.firstNote(atOrAfter: seg.from)
            while i < plan.notes.count && plan.notes[i].start < seg.to {
                let n = plan.notes[i]
                let t = seg.transportStart + (n.start - seg.from) + shift
                let key = (n.channel << 7) | n.note
                if active[key] != nil {
                    // Re-trigger: release the previous strike first.
                    events.append(ScheduledMIDI(time: t, bytes: MIDIBytes.noteOff(n.channel, n.note)))
                    pendingOffs.removeAll { $0.channel == n.channel && $0.note == n.note }
                }
                events.append(ScheduledMIDI(time: t, bytes: MIDIBytes.noteOn(n.channel, n.note, n.velocity)))
                var offTime = t + (n.end - n.start)
                // Notes never ring past the loop end.
                if let wrap = mapper.nextWrap(after: t - shift) {
                    offTime = min(offTime, wrap + shift - 0.0005)
                }
                active[key] = offTime
                pendingOffs.append((offTime, n.channel, n.note))
                i += 1
            }
            if !plan.clockTimes.isEmpty && settings.sendClock {
                var c = plan.firstClock(atOrAfter: seg.from)
                while c < plan.clockTimes.count && plan.clockTimes[c] < seg.to {
                    events.append(ScheduledMIDI(time: seg.transportStart + (plan.clockTimes[c] - seg.from), bytes: MIDIBytes.clock))
                    c += 1
                }
            }
        }
        // Note-offs that fall due in this window.
        pendingOffs.sort { $0.time < $1.time }
        while let first = pendingOffs.first, first.time <= until {
            pendingOffs.removeFirst()
            let key = (first.channel << 7) | first.note
            if let t = active[key], abs(t - first.time) < 1e-9 { active[key] = nil }
            events.append(ScheduledMIDI(time: max(from, first.time), bytes: MIDIBytes.noteOff(first.channel, first.note)))
        }
        return order(events)
    }

    /// Note-offs go before note-ons at the same instant; otherwise time order.
    func order(_ events: [ScheduledMIDI]) -> [ScheduledMIDI] {
        events.enumerated().sorted { a, b in
            if abs(a.element.time - b.element.time) > 1e-9 { return a.element.time < b.element.time }
            let ra = rank(a.element.bytes), rb = rank(b.element.bytes)
            if ra != rb { return ra < rb }
            return a.offset < b.offset
        }.map { $0.element }
    }

    private func rank(_ bytes: [UInt8]) -> Int {
        guard let s = bytes.first else { return 3 }
        if s == 0xF2 { return 0 }
        if s == 0xFA || s == 0xFB { return 1 }
        if s & 0xF0 == 0x80 { return 2 }
        if s == 0xF8 { return 3 }
        return 4
    }

    /// Stop: release every sounding note and send panic messages on the channels in use.
    public func stop(at time: Double) -> [ScheduledMIDI] {
        var out = releaseAll(at: time)
        for c in channelsUsed.sorted() {
            for bytes in MIDIBytes.panic(c) { out.append(ScheduledMIDI(time: time, bytes: bytes)) }
        }
        if settings.sendTransport { out.append(ScheduledMIDI(time: time, bytes: MIDIBytes.stop)) }
        isRunning = false
        return out
    }

    private func releaseAll(at time: Double) -> [ScheduledMIDI] {
        var out: [ScheduledMIDI] = []
        for key in active.keys.sorted() {
            out.append(ScheduledMIDI(time: time, bytes: MIDIBytes.noteOff(key >> 7, key & 0x7F)))
        }
        active.removeAll()
        pendingOffs.removeAll()
        return out
    }

    /// Switches to another performance mid-playback (A/B). Sounding notes are released now;
    /// playback continues from the same position in the new plan with no gap.
    public func swap(plan newPlan: PlaybackPlan, at time: Double) -> [ScheduledMIDI] {
        let out = releaseAll(at: time)
        plan = newPlan
        for n in newPlan.notes { channelsUsed.insert(n.channel) }
        return out
    }

    public func update(settings newSettings: MIDIOutputSettings) { settings = newSettings }

    /// Notes currently sounding (for tests and the activity display).
    public var activeNoteCount: Int { active.count }

    /// Everything a "panic" button should send, whatever the state.
    public static func panicMessages(channels: [Int] = Array(0 ..< 16)) -> [[UInt8]] {
        var out: [[UInt8]] = []
        for c in channels { out += MIDIBytes.panic(c) }
        return out
    }
}
