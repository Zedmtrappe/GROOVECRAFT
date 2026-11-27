import XCTest
@testable import GrooveCore

final class HumanisationTests: XCTestCase {
    let file = Fixtures.rockBeat(bars: 8)

    func msPerTick(_ input: HumanisationEngine.Input) -> Double { 60_000.0 / (120 * Double(input.pattern.ppq)) }

    func testRepeatableWithSeedAndDifferentAcrossSeeds() {
        var s = HumaniseSettings()
        s.seed = 42
        let a = HumanisationEngine.humanise(Fixtures.input(file, settings: s))
        let b = HumanisationEngine.humanise(Fixtures.input(file, settings: s))
        XCTAssertEqual(a, b)
        s.seed = 43
        let c = HumanisationEngine.humanise(Fixtures.input(file, settings: s))
        XCTAssertNotEqual(a.notes, c.notes)
    }

    func testOriginalIsNotModified() {
        let input = Fixtures.input(file)
        let before = input.pattern
        _ = HumanisationEngine.humanise(input)
        XCTAssertEqual(input.pattern, before)
    }

    func testZeroSettingsIsIdentity() {
        var s = HumaniseSettings()
        s.intensity = 0
        s.timing.microtiming = 0
        s.timing.drift = 0
        s.timing.velocityInfluence = 0
        s.timing.phraseInfluence = 0
        s.groove.intensity = 0
        s.groove.pushPull = 0
        s.groove.beatEmphasis = 0
        s.groove.offbeatEmphasis = 0
        s.velocity.beatPositionVariation = 0
        s.velocity.repetitionVariation = 0
        s.velocity.phraseDynamics = 0
        s.velocity.accentIntensity = 0
        s.articulation.hihatAccents = 0
        s.articulation.fillBuild = 0
        s.articulation.phraseEndAccent = 0
        s.articulation.lengthVariation = 0
        for f in DrumFamily.allCases { var d = s.drum(f); d.offsetMs = 0; d.special = 0.2; s.setDrum(f, d) }
        let input = Fixtures.input(file, settings: s)
        let out = HumanisationEngine.humanise(input)
        XCTAssertEqual(out.notes.count, input.pattern.notes.count)
        for (o, n) in zip(input.pattern.notes, out.notes.sorted(by: DrumPattern.order)) {
            XCTAssertEqual(o.tick, n.tick, accuracy: 0.001)
            XCTAssertEqual(o.velocity, n.velocity)
        }
    }

    func testTimingAndVelocityStayInsideLimits() {
        for preset in FactoryPresets.all {
            var s = preset.settings
            s.groove.swing = 0
            s.groove.templateID = nil
            s.seed = 7
            let input = Fixtures.input(file, settings: s)
            let out = HumanisationEngine.humanise(input)
            let byID = Dictionary(uniqueKeysWithValues: input.pattern.notes.map { ($0.id, $0) })
            for n in out.notes {
                XCTAssertGreaterThanOrEqual(n.velocity, 1)
                XCTAssertLessThanOrEqual(n.velocity, 127)
                XCTAssertGreaterThanOrEqual(n.tick, 0)
                guard let o = byID[n.id] else { continue }
                let shift = abs(n.tick - o.tick) * msPerTick(input)
                XCTAssertLessThanOrEqual(shift, s.timing.maxDeviationMs + 0.01, "\(preset.name) moved a note \(shift) ms")
                XCTAssertLessThanOrEqual(abs(n.velocity - o.velocity), s.velocity.maxChange + 1, preset.name)
            }
        }
    }

    func testNaturalPresetIsMusicallyPlausible() {
        var s = FactoryPresets.naturalDrummer.settings
        s.seed = 99
        let out = HumanisationEngine.humanise(Fixtures.input(file, settings: s))
        // A good drummer: a few ms of average deviation, not zero and not sloppy.
        XCTAssertGreaterThan(out.stats.meanTimingShiftMs, 1.5)
        XCTAssertLessThan(out.stats.meanTimingShiftMs, 12)
        XCTAssertGreaterThan(out.stats.meanVelocityChange, 2)
        XCTAssertLessThan(out.stats.meanVelocityChange, 20)
    }

    func testDownbeatsTighterThanOffbeats() {
        var s = HumaniseSettings()
        s.timing.beatPositionInfluence = 1
        s.timing.drift = 0
        s.timing.microtiming = 0
        s.correlation = 0
        var onBeat: [Double] = []
        var offBeat: [Double] = []
        for seed in 1 ... 20 {
            s.seed = UInt64(seed)
            let input = Fixtures.input(file, settings: s)
            let out = HumanisationEngine.humanise(input)
            let byID = Dictionary(uniqueKeysWithValues: input.pattern.notes.map { ($0.id, $0) })
            for n in out.notes where n.pitch == 42 {
                guard let o = byID[n.id] else { continue }
                let d = abs(n.tick - o.tick)
                if Int(o.tick) % 480 == 0 { onBeat.append(d) } else { offBeat.append(d) }
            }
        }
        let a = onBeat.reduce(0, +) / Double(onBeat.count)
        let b = offBeat.reduce(0, +) / Double(offBeat.count)
        XCTAssertLessThan(a, b)
    }

    func testSwingMovesOffbeats() {
        var s = HumaniseSettings()
        s.intensity = 0
        s.timing.microtiming = 0
        s.timing.drift = 0
        s.groove.swing = 0.68          // ratio 0.67
        s.groove.swingSubdivision = .eighth
        let input = Fixtures.input(file, settings: s)
        let out = HumanisationEngine.humanise(input)
        let byID = Dictionary(uniqueKeysWithValues: input.pattern.notes.map { ($0.id, $0) })
        var moved = 0
        for n in out.notes where n.pitch == 42 {
            guard let o = byID[n.id] else { continue }
            if Int(o.tick) % 480 == 240 {
                XCTAssertEqual(n.tick - o.tick, (s.groove.swingRatio - 0.5) * 480, accuracy: 6)
                moved += 1
            } else if Int(o.tick) % 480 == 0 {
                XCTAssertEqual(n.tick, o.tick, accuracy: 6)
            }
        }
        XCTAssertGreaterThan(moved, 20)
    }

    func testGrooveTemplateApplied() {
        var s = HumaniseSettings()
        s.intensity = 0
        s.timing.microtiming = 0
        s.timing.drift = 0
        s.groove.templateID = "groove.hiphoppocket"
        s.groove.intensity = 1
        let input = Fixtures.input(file, settings: s)
        let out = HumanisationEngine.humanise(input)
        // Snare is pushed back by the template's snare offset (14 ms).
        let snares = out.notes.filter { $0.pitch == 38 && Int($0.tick.rounded()) % 1920 > 900 && Int($0.tick.rounded()) % 1920 < 1000 }
        XCTAssertFalse(snares.isEmpty)
        let byID = Dictionary(uniqueKeysWithValues: input.pattern.notes.map { ($0.id, $0) })
        for n in snares { XCTAssertGreaterThan(n.tick - byID[n.id]!.tick, 5 / msPerTick(input)) }
    }

    func testLimbOrderAndNoOverlaps() {
        var s = FactoryPresets.looseLive.settings
        s.timing.maxDeviationMs = 60
        s.intensity = 1.5
        s.articulation.allowAddedNotes = true
        s.articulation.flams = 1
        s.articulation.drags = 1
        s.articulation.rolls = 1
        s.articulation.addGhostNotes = 1
        for seed in 1 ... 10 {
            s.seed = UInt64(seed)
            let input = Fixtures.input(file, settings: s)
            let out = HumanisationEngine.humanise(input).notes.sorted(by: DrumPattern.order)
            var lastByPitch: [Int: DrumNote] = [:]
            for n in out {
                if let p = lastByPitch[n.pitch] {
                    XCTAssertLessThanOrEqual(p.endTick, n.tick + 0.001, "overlapping notes on \(n.pitch)")
                }
                lastByPitch[n.pitch] = n
            }
            // Hi-hat strokes keep their order.
            let byID = Dictionary(uniqueKeysWithValues: input.pattern.notes.map { ($0.id, $0) })
            let hats = out.filter { $0.pitch == 42 && byID[$0.id] != nil }
            let originalOrder = hats.sorted { byID[$0.id]!.tick < byID[$1.id]!.tick }.map(\.id)
            XCTAssertEqual(hats.map(\.id), originalOrder)
        }
    }

    func testAddedNotesAreOptionalAndMarked() {
        var s = FactoryPresets.funkPocket.settings
        s.articulation.addGhostNotes = 1
        s.articulation.allowAddedNotes = false
        let input = Fixtures.input(file, settings: s)
        XCTAssertEqual(HumanisationEngine.humanise(input).notes.count, input.pattern.notes.count)
        s.articulation.allowAddedNotes = true
        let out = HumanisationEngine.humanise(Fixtures.input(file, settings: s))
        let added = out.notes.filter { $0.origin.isAdded }
        XCTAssertGreaterThan(added.count, 0)
        XCTAssertEqual(out.stats.addedNotes, added.count)
        for n in added {
            XCTAssertGreaterThanOrEqual(n.id, DrumNote.addedIDBase)
            if n.origin == .ghost { XCTAssertLessThanOrEqual(n.velocity, 50) }
        }
        // Removing added notes gives back exactly the original note set.
        XCTAssertEqual(Set(out.notes.filter { !$0.origin.isAdded }.map(\.id)), Set(input.pattern.notes.map(\.id)))
    }

    func testGhostNotesProtected() {
        var f = Fixtures.rockBeat(bars: 4, fills: false)
        // Add quiet snare ghosts.
        for bar in 0 ..< 4 {
            let t = bar * 1920 + 480 * 2 + 360
            f.tracks[1].events.append(MIDIEvent(tick: t, kind: .noteOn(channel: 9, note: 38, velocity: 30)))
            f.tracks[1].events.append(MIDIEvent(tick: t + 60, kind: .noteOff(channel: 9, note: 38, velocity: 0)))
        }
        f.tracks[1].sortEvents()
        var s = HumaniseSettings()
        s.velocity.variation = 1.5
        s.intensity = 1.5
        let input = Fixtures.input(f, settings: s)
        XCTAssertEqual(input.analysis.ghostNoteIDs.count, 4)
        for seed in 1 ... 10 {
            s.seed = UInt64(seed)
            let out = HumanisationEngine.humanise(Fixtures.input(f, settings: s))
            for n in out.notes where input.analysis.ghostNoteIDs.contains(n.id) {
                XCTAssertGreaterThanOrEqual(n.velocity, 18)
                XCTAssertLessThanOrEqual(n.velocity, 44)
            }
        }
    }

    func testBarRangeOnlyChangesSelection() {
        var input = Fixtures.input(file)
        input.bars = 2 ... 3
        let out = HumanisationEngine.humanise(input)
        let byID = Dictionary(uniqueKeysWithValues: input.pattern.notes.map { ($0.id, $0) })
        for n in out.notes {
            guard let o = byID[n.id] else { continue }
            let bar = Int(o.tick) / 1920
            if bar < 2 || bar > 3 {
                XCTAssertEqual(n.tick, o.tick)
                XCTAssertEqual(n.velocity, o.velocity)
            }
        }
    }

    func testExtremeValuesDoNotBreak() {
        var s = HumaniseSettings()
        s.intensity = 1000
        s.timing.variation = 1e6
        s.timing.maxDeviationMs = 1e6
        s.velocity.variation = 1e6
        s.velocity.range = 100
        s.velocity.minimum = 200
        s.velocity.maximum = -5
        s.groove.swing = 50
        s.correlation = 5
        s.articulation.allowAddedNotes = true
        s.articulation.addGhostNotes = 10
        s.articulation.hihatOpenings = 10
        let out = HumanisationEngine.humanise(Fixtures.input(file, settings: s))
        for n in out.notes {
            XCTAssertFalse(n.tick.isNaN)
            XCTAssertGreaterThanOrEqual(n.tick, 0)
            XCTAssertTrue((1 ... 127).contains(n.velocity))
            XCTAssertGreaterThan(n.length, 0)
        }
        let empty = DrumPattern(notes: [], drumTracks: [], ppq: 480)
        let input = HumanisationEngine.Input(pattern: empty, tempoMap: TempoMap(ppq: 480), map: .generalMIDI,
                                             analysis: PatternAnalyzer.analyze(empty, tempoMap: TempoMap(ppq: 480), map: .generalMIDI),
                                             settings: s)
        XCTAssertTrue(HumanisationEngine.humanise(input).notes.isEmpty)
    }

    func testPresetsAreDistinct() {
        let presets = FactoryPresets.all
        XCTAssertGreaterThanOrEqual(presets.count, 12)
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)
        var outputs: [[DrumNote]] = []
        for p in presets {
            var s = p.settings
            s.seed = 5
            outputs.append(HumanisationEngine.humanise(Fixtures.input(file, settings: s)).notes)
        }
        for i in presets.indices {
            for j in presets.indices where j > i {
                XCTAssertNotEqual(presets[i].settings, presets[j].settings, "\(presets[i].name) = \(presets[j].name)")
                XCTAssertNotEqual(outputs[i], outputs[j], "\(presets[i].name) sounds like \(presets[j].name)")
            }
        }
    }

    func testExportedPerformanceRoundTrips() throws {
        var s = FactoryPresets.funkPocket.settings
        s.seed = 3
        let input = Fixtures.input(file, settings: s)
        let perf = HumanisationEngine.humanise(input)
        var exported = input.pattern
        exported.notes = perf.notes
        let out = exported.applied(to: file)
        let back = try MIDIParser.parse(MIDIWriter.data(for: out))
        XCTAssertEqual(back.ppq, 960)
        XCTAssertEqual(back.noteCount, perf.notes.count)
        XCTAssertEqual(back.tracks[0].events.filter { if case .meta = $0.kind { return true }; return false }.count,
                       file.tracks[0].events.filter { if case .meta = $0.kind { return true }; return false }.count)
        let reread = DrumPattern.extract(from: back, source: DrumPattern.detectSource(in: back))
        let a = reread.notes.map { ($0.tick / 2).rounded() }
        let b = perf.notes.sorted(by: DrumPattern.order).map { $0.tick.rounded() }
        XCTAssertEqual(a.count, b.count)
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 1) }
        XCTAssertEqual(back.tracks[1].name, "Drums")
    }

    func testGrooveExtractionTransfer() {
        // Extract the groove from a humanised hip-hop take and apply it to the straight beat.
        var s = HumaniseSettings()
        s.intensity = 0
        s.timing.microtiming = 0
        s.timing.drift = 0
        s.groove.templateID = "groove.hiphoppocket"
        s.groove.intensity = 1
        let input = Fixtures.input(file, settings: s)
        var played = input.pattern
        played.notes = HumanisationEngine.humanise(input).notes
        let tpl = GrooveTemplate.extract(from: played, name: "Taken")
        XCTAssertNotNil(tpl)
        XCTAssertEqual(tpl!.timing.count, 16)
        XCTAssertGreaterThan(tpl!.timing[2], 0.01)   // the off-beat 8th is late in the source
        XCTAssertEqual(tpl!.timing[0], 0, accuracy: 0.05)
    }

    func testQuickModeMacros() {
        var q = QuickControls()
        let base = FactoryPresets.naturalDrummer.settings
        q.humanise = 0
        let low = q.settings(base: base, seed: 1, trackAware: false)
        q.humanise = 1
        let high = q.settings(base: base, seed: 1, trackAware: false)
        XCTAssertLessThan(low.intensity, high.intensity)
        let lowOut = HumanisationEngine.humanise(Fixtures.input(file, settings: low))
        let highOut = HumanisationEngine.humanise(Fixtures.input(file, settings: high))
        XCTAssertLessThan(lowOut.stats.meanTimingShiftMs, highOut.stats.meanTimingShiftMs)
        q.feel = .laidBack
        XCTAssertGreaterThan(q.settings(base: base, seed: 1, trackAware: false).groove.pushPull, 0)
        q.feel = .shuffle
        XCTAssertGreaterThan(q.settings(base: base, seed: 1, trackAware: false).groove.swingRatio, 0.6)
    }
}
