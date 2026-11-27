import XCTest
@testable import GrooveCore

final class DocumentTests: XCTestCase {
    func makeDoc() throws -> GrooveDocument {
        try GrooveDocument(midi: Fixtures.rockBeat(bars: 8), name: "Beat")
    }

    func testHumaniseAddsTakesAndNeverTouchesOriginal() throws {
        let doc = try makeDoc()
        let original = doc.pattern
        let originalData = MIDIWriter.data(for: doc.midi)
        doc.humanise()
        doc.humanise(count: 3)
        XCTAssertEqual(doc.state.variations.count, 4)
        XCTAssertEqual(Set(doc.state.variations.map(\.seed)).count, 4, "each take has its own seed")
        XCTAssertNotEqual(doc.state.variations[0].notes, doc.state.variations[1].notes)
        XCTAssertEqual(doc.pattern, original)
        XCTAssertEqual(MIDIWriter.data(for: doc.midi), originalData)
        XCTAssertEqual(doc.exportData(for: nil), originalData, "exporting the original writes it back unchanged")
        XCTAssertTrue(doc.isDirty)
    }

    func testUndoRedo() throws {
        let doc = try makeDoc()
        doc.humanise()
        let first = doc.state
        doc.humanise()
        XCTAssertEqual(doc.state.variations.count, 2)
        doc.undo()
        XCTAssertEqual(doc.state, first)
        doc.undo()
        XCTAssertTrue(doc.state.variations.isEmpty)
        XCTAssertFalse(doc.history.canUndo)
        doc.redo()
        doc.redo()
        XCTAssertEqual(doc.state.variations.count, 2)
        XCTAssertFalse(doc.history.canRedo)
    }

    func testABAndRevert() throws {
        let doc = try makeDoc()
        let a = doc.humanise()[0]
        let b = doc.humanise()[0]
        XCTAssertEqual(doc.state.selectedVariationID, b.id)
        XCTAssertEqual(doc.state.compareVariationID, a.id)
        doc.toggleAB()
        XCTAssertEqual(doc.state.selectedVariationID, a.id)
        doc.revertToOriginal()
        XCTAssertNil(doc.state.selectedVariationID)
        XCTAssertEqual(doc.selectedNotes, doc.pattern.notes)
    }

    func testRehumaniseKeepsSeed() throws {
        let doc = try makeDoc()
        let a = doc.humanise()[0]
        doc.changeWithoutUndo { $0.quick.velocity = 1 }
        let b = doc.rehumaniseKeepingSeed()!
        XCTAssertEqual(a.seed, b.seed)
        XCTAssertNotEqual(a.notes, b.notes)
    }

    func testEditingTheOriginalMakesAnEditedTake() throws {
        let doc = try makeDoc()
        let target = doc.pattern.notes[3]
        doc.edit(.setVelocity(ids: [target.id], value: 33))
        XCTAssertEqual(doc.state.variations.count, 1)
        XCTAssertTrue(doc.state.variations[0].isEdited)
        XCTAssertEqual(doc.selectedNotes.first { $0.id == target.id }?.velocity, 33)
        XCTAssertEqual(doc.pattern.notes[3].velocity, target.velocity, "original untouched")
        doc.edit(.move(ids: [target.id], deltaTicks: 30))
        XCTAssertEqual(doc.state.variations.count, 1)
        doc.edit(.delete(ids: [target.id]))
        XCTAssertEqual(doc.selectedNotes.count, doc.pattern.notes.count - 1)
        doc.edit(.add(DrumNote(id: 0, track: 1, channel: 9, pitch: 38, tick: 100, length: 60, velocity: 40)))
        XCTAssertEqual(doc.selectedNotes.count, doc.pattern.notes.count)
        doc.undo(); doc.undo(); doc.undo(); doc.undo()
        XCTAssertTrue(doc.state.variations.isEmpty)
    }

    func testFavouritesRenameDeleteAndClear() throws {
        let doc = try makeDoc()
        let takes = doc.humanise(count: 4)
        doc.toggleFavourite(takes[1].id)
        doc.rename(takes[1].id, to: "Keeper")
        doc.delete(takes[3].id)
        XCTAssertEqual(doc.state.variations.count, 3)
        doc.clearUnfavourited()
        XCTAssertEqual(doc.state.variations.map(\.name), ["Keeper"])
    }

    func testProjectFileRoundTrip() throws {
        let doc = try makeDoc()
        doc.humanise(count: 2)
        doc.addSection(SectionMarker(bar: 4, kind: .chorus))
        doc.change("Align") { $0.alignment = Alignment(offsetSeconds: 1.25) }
        let data = try ProjectFile(document: doc, backingPath: "/tmp/song.wav", backingBookmark: nil).encoded()
        let back = try ProjectFile.decode(data).makeDocument()
        XCTAssertEqual(back.state, doc.state)
        XCTAssertEqual(back.pattern, doc.pattern)
        XCTAssertEqual(back.exportData(for: doc.state.selectedVariationID), doc.exportData(for: doc.state.selectedVariationID))
        XCTAssertEqual(back.backingName, "song.wav")
        XCTAssertFalse(back.isDirty)
    }

    func testDrumMapChangeReanalyses() throws {
        let doc = try makeDoc()
        XCTAssertEqual(doc.analysis.categoryCounts[.closedHat], 56)
        doc.change("Map") { s in s.drumMap.set(DrumMapEntry(note: 42, name: "Shaker", category: .percussion)) }
        XCTAssertNil(doc.analysis.categoryCounts[.closedHat])
        doc.undo()
        XCTAssertEqual(doc.analysis.categoryCounts[.closedHat], 56)
    }

    func testNoDrumsIsAnError() {
        let empty = MIDIFile(format: .multiTrack, ppq: 480, tracks: [MIDITrack(events: [.trackName("Empty"), .endOfTrack(tick: 0)])])
        XCTAssertThrowsError(try GrooveDocument(midi: empty, name: "Empty"))
    }

    func testBatchProcessing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gc-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("Groove A.mid")
        let b = dir.appendingPathComponent("Broken.mid")
        try MIDIWriter.write(Fixtures.rockBeat(bars: 4), to: a)
        try Data("not midi".utf8).write(to: b)
        let sourceBytes = try Data(contentsOf: a)
        let out = dir.appendingPathComponent("Out")
        let options = BatchProcessor.Options(settings: FactoryPresets.funkPocket.settings, presetName: "Funk Pocket", outputFolder: out)
        let r1 = BatchProcessor.process(a, options: options)
        XCTAssertNil(r1.error)
        XCTAssertEqual(r1.outputs.first?.lastPathComponent, "Groove A – Groovecraft Funk Pocket.mid")
        // Running again doesn't overwrite.
        let r2 = BatchProcessor.process(a, options: options)
        XCTAssertEqual(r2.outputs.first?.lastPathComponent, "Groove A – Groovecraft Funk Pocket 2.mid")
        let bad = BatchProcessor.process(b, options: options)
        XCTAssertNotNil(bad.error)
        XCTAssertTrue(bad.outputs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: a), sourceBytes, "source file untouched")
        var multi = options
        multi.variationsPerFile = 3
        multi.namingPattern = "{name} take {n}"
        let r3 = BatchProcessor.process(a, options: multi)
        XCTAssertEqual(r3.outputs.map(\.lastPathComponent), ["Groove A take 1.mid", "Groove A take 2.mid", "Groove A take 3.mid"])
        XCTAssertEqual(ExportNaming.fileName(pattern: "{name}/{preset}", source: "x", preset: "y"), "x-y")
    }

    func testPresetStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gc-presets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PresetStore(folder: dir)
        XCTAssertEqual(store.allPresets.count, FactoryPresets.all.count)
        let saved = try store.save(Preset(name: "Mine", category: "User", settings: FactoryPresets.jazzFeel.settings))
        XCTAssertEqual(store.userPresets.count, 1)
        let dup = try store.duplicate(saved)
        XCTAssertEqual(dup.name, "Mine Copy")
        try store.rename(dup, to: "Renamed")
        XCTAssertTrue(store.userPresets.contains { $0.name == "Renamed" })
        XCTAssertEqual(store.search("jazz").map(\.name).first, "Jazz Feel")
        let exported = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).gcpreset")
        try store.export(saved, to: exported)
        let imported = try store.importPreset(from: exported)
        XCTAssertNotEqual(imported.id, saved.id)
        XCTAssertEqual(imported.settings, saved.settings)
        try store.delete(saved)
        XCTAssertFalse(store.userPresets.contains { $0.id == saved.id })

        // Older preset files with missing fields still load, with defaults filled in.
        let old = #"{"id":"user.old","name":"Old","category":"User","summary":"","settings":{"intensity":0.3,"timing":{"variation":0.9}}}"#
        let oldURL = dir.appendingPathComponent("old.gcpreset")
        try Data(old.utf8).write(to: oldURL)
        let p = try PresetStore.read(oldURL)
        XCTAssertEqual(p.settings.intensity, 0.3)
        XCTAssertEqual(p.settings.timing.variation, 0.9)
        XCTAssertEqual(p.settings.timing.maxDeviationMs, TimingSettings().maxDeviationMs)
    }
}
