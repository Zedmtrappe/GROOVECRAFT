import XCTest
@testable import GrooveCore

final class MIDIFileTests: XCTestCase {
    func testRoundTripType1PreservesEverything() throws {
        var file = Fixtures.rockBeat(bars: 2)
        file.tracks[1].events.insert(MIDIEvent(tick: 0, kind: .controlChange(channel: 9, controller: 7, value: 100)), at: 1)
        file.tracks[1].events.insert(MIDIEvent(tick: 0, kind: .programChange(channel: 9, program: 25)), at: 1)
        file.tracks[1].events.insert(MIDIEvent(tick: 10, kind: .meta(type: MIDIMeta.marker, data: Array("Verse".utf8))), at: 1)
        file.tracks[1].events.insert(MIDIEvent(tick: 20, kind: .sysex(data: [0x7E, 0x7F, 0x09, 0x01, 0xF7])), at: 1)
        file.tracks[1].events.insert(MIDIEvent(tick: 30, kind: .pitchBend(channel: 9, value: 9000)), at: 1)
        file.tracks[1].sortEvents()
        let data = MIDIWriter.data(for: file)
        let back = try MIDIParser.parse(data)
        XCTAssertEqual(back.format, .multiTrack)
        XCTAssertEqual(back.ppq, 480)
        XCTAssertEqual(back.tracks.count, 2)
        XCTAssertEqual(back.tracks[1].name, "Drums")
        XCTAssertEqual(back.tracks[1].events, file.tracks[1].events)
        XCTAssertEqual(back.tracks[0].events, file.tracks[0].events)
        XCTAssertEqual(MIDIWriter.data(for: back), data, "write → read → write must be byte-identical")
    }

    func testType0AndRunningStatus() throws {
        // Hand-made format 0 file using running status and note-on velocity 0 as note-off.
        var bytes: [UInt8] = Array("MThd".utf8) + [0, 0, 0, 6, 0, 0, 0, 1, 0x00, 0x60]
        let track: [UInt8] = [
            0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,       // tempo 120
            0x00, 0x99, 36, 100,                            // note on ch10
            0x00, 42, 80,                                   // running status
            0x18, 36, 0,                                    // note off via velocity 0
            0x00, 42, 0,
            0x00, 0x90, 60, 70,                             // a piano note on channel 1
            0x30, 0x80, 60, 0,
            0x00, 0xFF, 0x2F, 0x00,
        ]
        bytes += Array("MTrk".utf8) + [0, 0, 0, UInt8(track.count)] + track
        let file = try MIDIParser.parse(Data(bytes))
        XCTAssertEqual(file.format, .singleTrack)
        XCTAssertEqual(file.ppq, 96)
        XCTAssertEqual(file.noteCount, 3)
        XCTAssertEqual(file.tempoMap.initialBPM, 120, accuracy: 0.01)

        // Drums are on channel 10 only: the piano note is kept out of the pattern.
        let source = DrumPattern.detectSource(in: file)
        XCTAssertEqual(source.channel, 9)
        let pattern = DrumPattern.extract(from: file, source: source)
        XCTAssertEqual(pattern.notes.count, 2)
        XCTAssertEqual(pattern.notes.first(where: { $0.pitch == 36 })?.length, 24)

        // Writing the pattern back keeps the piano note.
        let out = pattern.applied(to: file)
        let reread = try MIDIParser.parse(MIDIWriter.data(for: out))
        XCTAssertEqual(reread.noteCount, 3)
        XCTAssertEqual(reread.ppq, 960)
    }

    func testInvalidFiles() {
        XCTAssertThrowsError(try MIDIParser.parse(Data())) { XCTAssertEqual($0 as? MIDIFileError, .empty) }
        XCTAssertThrowsError(try MIDIParser.parse(Data("hello world, not midi".utf8))) {
            XCTAssertEqual($0 as? MIDIFileError, .notAMIDIFile)
        }
        // Header promising a track that isn't there.
        let truncated = Data(Array("MThd".utf8) + [0, 0, 0, 6, 0, 1, 0, 2, 0x01, 0xE0])
        XCTAssertThrowsError(try MIDIParser.parse(truncated))
    }

    func testTruncatedTrackIsTolerated() throws {
        let data = MIDIWriter.data(for: Fixtures.rockBeat(bars: 1))
        // Chop the last few bytes (end-of-track) off; the reader still recovers the notes.
        let cut = data.prefix(data.count - 3)
        let file = try MIDIParser.parse(cut)
        XCTAssertGreaterThan(file.noteCount, 10)
        XCTAssertTrue(file.tracks.last!.events.last!.kind.isEndOfTrack)
    }

    func testTempoMapConversions() {
        let map = TempoMap(ppq: 480, tempos: [.init(tick: 0, bpm: 120), .init(tick: 1920, bpm: 60)],
                           signatures: [.init(tick: 0, numerator: 4, denominator: 4), .init(tick: 3840, numerator: 3, denominator: 4)])
        XCTAssertEqual(map.seconds(atTick: 1920), 2.0, accuracy: 1e-9)
        XCTAssertEqual(map.seconds(atTick: 2400), 3.0, accuracy: 1e-9)
        XCTAssertEqual(map.tick(atSeconds: 3.0), 2400, accuracy: 1e-6)
        XCTAssertEqual(map.position(atTick: 0).bar, 0)
        XCTAssertEqual(map.position(atTick: 1920).bar, 1)
        let p = map.position(atTick: 3840 + 1440 + 480)
        XCTAssertEqual(p.bar, 3)
        XCTAssertEqual(p.beat, 1)
        XCTAssertEqual(p.beatsInBar, 3)
        XCTAssertEqual(map.tick(atBar: 3), 3840 + 1440, accuracy: 1e-9)
    }

    func testLargeFile() throws {
        let file = Fixtures.rockBeat(bars: 600)
        let data = MIDIWriter.data(for: file)
        let start = Date()
        let back = try MIDIParser.parse(data)
        XCTAssertEqual(back.noteCount, file.noteCount)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testDrumTrackDetectionAndMapping() {
        let file = Fixtures.rockBeat(bars: 2)
        XCTAssertEqual(DrumPattern.detectDrumTracks(in: file), [1])
        let map = DrumMap.generalMIDI
        XCTAssertEqual(map.category(for: 36), .kick)
        XCTAssertEqual(map.category(for: 42), .closedHat)
        XCTAssertEqual(map.category(for: 44), .pedalHat)
        XCTAssertEqual(map.category(for: 46), .openHat)
        XCTAssertEqual(map.category(for: 51), .ride)
        XCTAssertEqual(map.category(for: 49), .crash)
        XCTAssertEqual(map.category(for: 48).family, .tom)
        XCTAssertEqual(map.category(for: 100), .other)
        var custom = DrumMap(name: "Custom", entries: [DrumMapEntry(note: 24, name: "Big Kick", category: .kick)])
        XCTAssertEqual(custom.category(for: 24), .kick)
        custom.set(DrumMapEntry(note: 25, name: "Snare Rim", category: .snare))
        XCTAssertEqual(custom.note(for: .snare), 25)
    }

    func testPatternAnalysis() {
        let file = Fixtures.rockBeat(bars: 8)
        let input = Fixtures.input(file)
        let a = input.analysis
        XCTAssertEqual(a.bars, 8)
        XCTAssertEqual(a.grid, .straight16)
        XCTAssertTrue(a.isQuantised)
        XCTAssertTrue(a.isFlatVelocity)
        XCTAssertEqual(a.fillBars, [3, 7])
        XCTAssertEqual(a.phraseLength, 4)
        XCTAssertEqual(a.initialBPM, 120, accuracy: 0.001)
        XCTAssertEqual(a.signature.numerator, 4)
        XCTAssertEqual(a.categoryCounts[.kick], 24)
    }
}
