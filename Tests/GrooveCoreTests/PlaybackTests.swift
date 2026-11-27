import XCTest
@testable import GrooveCore

final class PlaybackTests: XCTestCase {
    func plan(_ notes: [DrumNote], settings: MIDIOutputSettings = MIDIOutputSettings(), clock: Bool = false) -> PlaybackPlan {
        PlaybackPlan(notes: notes, tempoMap: TempoMap(ppq: 480, tempos: [.init(tick: 0, bpm: 120)]), settings: settings, includeClock: clock)
    }

    func note(_ id: Int, _ tick: Double, _ pitch: Int = 36, _ length: Double = 120, _ v: Int = 100) -> DrumNote {
        DrumNote(id: id, track: 1, channel: 9, pitch: pitch, tick: tick, length: length, velocity: v)
    }

    /// Runs the scheduler in 5 ms steps, like the real-time thread does.
    func run(_ s: MIDIScheduler, until end: Double, step: Double = 0.005) -> [ScheduledMIDI] {
        var out: [ScheduledMIDI] = []
        var t = 0.0
        while t < end {
            t += step
            out += s.process(until: t)
        }
        return out
    }

    func balance(_ events: [ScheduledMIDI]) -> [Int: Int] {
        var on: [Int: Int] = [:]
        for e in events {
            let s = e.bytes[0] & 0xF0
            let key = Int(e.bytes[0] & 0x0F) << 7 | Int(e.bytes[1])
            if s == 0x90 { on[key, default: 0] += 1 }
            if s == 0x80 { on[key, default: 0] -= 1 }
        }
        return on
    }

    func testNotesInOrderWithCorrectTimes() {
        let notes = [note(0, 0), note(1, 240, 42), note(2, 480, 38), note(3, 960)]
        let s = MIDIScheduler(plan: plan(notes), settings: MIDIOutputSettings())
        _ = s.start(at: 0, loop: nil)
        let events = run(s, until: 1.5)
        let ons = events.filter { $0.bytes[0] & 0xF0 == 0x90 }
        XCTAssertEqual(ons.map { $0.time }, [0, 0.25, 0.5, 1.0])
        XCTAssertEqual(ons.map { Int($0.bytes[1]) }, [36, 42, 38, 36])
        XCTAssertEqual(ons.first!.bytes[0], 0x99)  // channel 10
        XCTAssertEqual(ons.first!.bytes[2], 100)
        XCTAssertEqual(zip(events, events.dropFirst()).filter { $0.time > $1.time }.count, 0, "events out of order")
        XCTAssertTrue(balance(events).values.allSatisfy { $0 == 0 }, "every note-on gets a note-off")
        XCTAssertEqual(s.activeNoteCount, 0)
    }

    func testOverlappingRepeatedNoteRetriggers() {
        // Second hit starts before the first ends: a note-off is sent first.
        let notes = [note(0, 0, 38, 400), note(1, 120, 38, 400)]
        let s = MIDIScheduler(plan: plan(notes), settings: MIDIOutputSettings())
        _ = s.start(at: 0, loop: nil)
        let events = run(s, until: 1)
        let kinds = events.map { $0.bytes[0] & 0xF0 }
        XCTAssertEqual(kinds, [0x90, 0x80, 0x90, 0x80])
        XCTAssertEqual(events[1].time, events[2].time, accuracy: 1e-9)
    }

    func testStopReleasesEverythingAndPanics() {
        let notes = [note(0, 0, 46, 4000), note(1, 0, 49, 4000)]
        let s = MIDIScheduler(plan: plan(notes), settings: MIDIOutputSettings())
        _ = s.start(at: 0, loop: nil)
        let events = run(s, until: 0.2)
        XCTAssertEqual(s.activeNoteCount, 2)
        let stop = s.stop(at: 0.2)
        XCTAssertEqual(stop.filter { $0.bytes[0] & 0xF0 == 0x80 }.count, 2)
        XCTAssertTrue(stop.contains { $0.bytes == [0xB9, 123, 0] })
        XCTAssertTrue(balance(events + stop).values.allSatisfy { $0 == 0 })
        XCTAssertTrue(s.process(until: 5).isEmpty, "nothing after stop")
    }

    func testLoopWrapsAndReleasesAtBoundary() {
        // 1-bar loop (2 s) with a long crash that would ring over the loop end.
        let notes = [note(0, 0), note(1, 1440, 49, 2000), note(2, 1920), note(3, 2400)]
        let s = MIDIScheduler(plan: plan(notes), settings: MIDIOutputSettings())
        _ = s.start(at: 0, loop: 0 ... 2)
        let events = run(s, until: 6.1)
        let kicks = events.filter { $0.bytes[0] == 0x99 && $0.bytes[1] == 36 }.map(\.time)
        XCTAssertEqual(kicks, [0, 2, 4, 6])
        // Crash released before each wrap.
        let crashOffs = events.filter { $0.bytes[0] == 0x89 && $0.bytes[1] == 49 }.map(\.time)
        XCTAssertEqual(crashOffs.count, 3)
        for t in crashOffs { XCTAssertLessThan(t.truncatingRemainder(dividingBy: 2), 2) ; XCTAssertGreaterThan(t.truncatingRemainder(dividingBy: 2), 1.99) }
        _ = s.stop(at: 6.1)
        XCTAssertEqual(s.activeNoteCount, 0)
    }

    func testStartMidSongAndLatencyCompensation() {
        let notes = [note(0, 0), note(1, 960), note(2, 1920)]
        var settings = MIDIOutputSettings()
        settings.latencyMs = 40
        let s = MIDIScheduler(plan: plan(notes, settings: settings), settings: settings)
        _ = s.start(at: 0.9, loop: nil)
        var events: [ScheduledMIDI] = []
        var t = -0.04
        while t < 1.5 { t += 0.005; events += s.process(until: t) }
        let ons = events.filter { $0.bytes[0] & 0xF0 == 0x90 }.map(\.time)
        // Notes at 1.0 and 2.0 s of the song, sent 40 ms early relative to transport.
        XCTAssertEqual(ons.count, 2)
        XCTAssertEqual(ons[0], 0.1 - 0.04, accuracy: 1e-9)
        XCTAssertEqual(ons[1], 1.1 - 0.04, accuracy: 1e-9)
    }

    func testSwapPlanReleasesNotes() {
        let a = plan([note(0, 0, 46, 3000), note(1, 960)])
        let b = plan([note(10, 960, 38), note(11, 1440, 38)])
        let s = MIDIScheduler(plan: a, settings: MIDIOutputSettings())
        _ = s.start(at: 0, loop: nil)
        var events = run(s, until: 0.3)
        events += s.swap(plan: b, at: 0.3)
        var t = 0.3
        while t < 1.7 { t += 0.005; events += s.process(until: t) }
        let ons = events.filter { $0.bytes[0] & 0xF0 == 0x90 }.map { Int($0.bytes[1]) }
        XCTAssertEqual(ons, [46, 38, 38])
        XCTAssertTrue(balance(events).values.allSatisfy { $0 == 0 })
    }

    func testChannelMappingVelocityAndClock() {
        var settings = MIDIOutputSettings()
        settings.channel = 0
        settings.noteMap = OutputNoteMap(name: "Test", remap: [36: 24])
        settings.velocityScale = 0.5
        settings.sendClock = true
        settings.sendTransport = true
        let p = plan([note(0, 0, 36, 120, 100)], settings: settings, clock: true)
        let s = MIDIScheduler(plan: p, settings: settings)
        let startMsgs = s.start(at: 0, loop: nil)
        XCTAssertEqual(startMsgs.map(\.bytes), [[0xF2, 0, 0], [0xFA]])
        let events = run(s, until: 0.5)
        let on = events.first { $0.bytes[0] & 0xF0 == 0x90 }!
        XCTAssertEqual(on.bytes, [0x90, 24, 50])
        let clocks = events.filter { $0.bytes == [0xF8] }
        XCTAssertTrue((24 ... 25).contains(clocks.count))   // one beat at 120 BPM = 0.5 s = 24 clocks
        XCTAssertEqual(clocks[1].time - clocks[0].time, 0.5 / 24, accuracy: 1e-9)
        XCTAssertTrue(s.stop(at: 0.5).contains { $0.bytes == [0xFC] })
    }

    func testLoopMapper() {
        let m = LoopMapper(startPosition: 1, loop: 2 ... 4)
        XCTAssertEqual(m.position(atTransport: 0), 1)
        XCTAssertEqual(m.position(atTransport: 3), 2, accuracy: 1e-9)
        XCTAssertEqual(m.position(atTransport: 4.5), 3.5, accuracy: 1e-9)
        let segs = m.segments(transportFrom: 2.5, to: 5.5)
        XCTAssertEqual(segs.count, 3)
        XCTAssertEqual(segs[0].from, 3.5, accuracy: 1e-9)
        XCTAssertTrue(segs[0].endsAtWrap)
        XCTAssertEqual(segs[1].from, 2, accuracy: 1e-9)
    }

    func testSynthRendersAndChokes() {
        let synth = DrumSynth(sampleRate: 44_100)
        var l = [Float](repeating: 0, count: 4096)
        var r = [Float](repeating: 0, count: 4096)
        for cat in DrumCategory.allCases { synth.trigger(category: cat, note: 40, velocity: 110) }
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            synth.render(frames: 4096, left: lp.baseAddress!, right: rp.baseAddress!)
        } }
        let peak = l.map { abs($0) }.max()!
        XCTAssertGreaterThan(peak, 0.05)
        XCTAssertFalse(l.contains { $0.isNaN })
        synth.reset()
        synth.trigger(category: .openHat, note: 46, velocity: 100)
        synth.trigger(category: .closedHat, note: 42, velocity: 100)
        for _ in 0 ..< 40 {
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                synth.render(frames: 4096, left: lp.baseAddress!, right: rp.baseAddress!)
            } }
        }
        XCTAssertEqual(synth.activeVoiceCount, 0, "open hat choked, closed hat finished")
    }

    func testPreviewRendererTriggersOnTime() {
        let renderer = PreviewRenderer(sampleRate: 48_000)
        renderer.setNotes([.init(start: 0.1, category: .kick, note: 36, velocity: 127)], alignment: .none)
        renderer.start(mapper: LoopMapper(startPosition: 0))
        var l = [Float](repeating: 0, count: 512)
        var r = [Float](repeating: 0, count: 512)
        var firstSound: Int? = nil
        var frame = 0
        while frame < 48_000 / 4 {
            let t = Double(frame) / 48_000
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                renderer.render(transportTime: t, frames: 512, left: lp.baseAddress!, right: rp.baseAddress!)
            } }
            if firstSound == nil, let i = l.firstIndex(where: { abs($0) > 1e-4 }) { firstSound = frame + i }
            frame += 512
        }
        XCTAssertNotNil(firstSound)
        XCTAssertEqual(Double(firstSound!), 4800, accuracy: 3)
    }
}
