import Foundation

/// One generated performance. Variations are never overwritten: generating again adds a new one.
public struct Variation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var seed: UInt64
    public var settings: HumaniseSettings
    public var notes: [DrumNote]
    public var stats: Performance.Stats
    public var isFavourite: Bool
    public var isEdited: Bool
    public var presetName: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, seed: UInt64, settings: HumaniseSettings, notes: [DrumNote],
                stats: Performance.Stats, presetName: String, isFavourite: Bool = false, isEdited: Bool = false,
                createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.seed = seed
        self.settings = settings
        self.notes = notes
        self.stats = stats
        self.isFavourite = isFavourite
        self.isEdited = isEdited
        self.presetName = presetName
        self.createdAt = createdAt
    }
}

public enum ControlMode: String, Codable, Sendable { case quick, advanced }

/// Everything about a project that can change and be undone.
public struct ProjectState: Codable, Equatable, Sendable {
    public var variations: [Variation] = []
    /// nil = the original MIDI.
    public var selectedVariationID: UUID? = nil
    /// The variation to compare against in A/B (nil = the original).
    public var compareVariationID: UUID? = nil
    public var mode: ControlMode = .quick
    public var quick = QuickControls()
    public var advanced = HumaniseSettings()
    public var presetID: String = FactoryPresets.naturalDrummer.id
    public var useTrackAware: Bool = true
    public var sections: [SectionMarker] = []
    public var alignment = Alignment.none
    public var drumMap = DrumMap.generalMIDI
    public var source = DrumPattern.Source(tracks: [], channel: nil)
    /// Bars to process (nil = everything).
    public var processBars: ClosedRange<Int>? = nil
    public var nextSeed: UInt64 = 1

    public init() {}
}

/// Snapshot-based undo/redo.
public struct History<State: Equatable>: Sendable where State: Sendable {
    public private(set) var undoStack: [(name: String, state: State)] = []
    public private(set) var redoStack: [(name: String, state: State)] = []
    public var limit = 200

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }

    /// Records the state *before* a change.
    public mutating func record(_ before: State, name: String) {
        undoStack.append((name, before))
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    public mutating func undo(current: State) -> State? {
        guard let last = undoStack.popLast() else { return nil }
        redoStack.append((last.name, current))
        return last.state
    }

    public mutating func redo(current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append((next.name, current))
        return next.state
    }

    public mutating func clear() { undoStack.removeAll(); redoStack.removeAll() }
}

public enum GrooveDocumentError: Error, LocalizedError, Equatable {
    case noDrums
    case noMIDI
    public var errorDescription: String? {
        switch self {
        case .noDrums: return "No drum notes were found in this file. Choose the drum track in Drum Mapping."
        case .noMIDI: return "Open a drum MIDI file first."
        }
    }
}

/// The working document: the original MIDI (never modified), its analysis, an optional
/// backing-track analysis, and the undoable project state. UI-independent.
public final class GrooveDocument {
    public private(set) var midi: MIDIFile
    public private(set) var midiName: String
    public private(set) var pattern: DrumPattern
    public private(set) var analysis: PatternAnalysis
    public var backing: BackingAnalysis?
    public var backingName: String?
    public private(set) var state: ProjectState
    public private(set) var history = History<ProjectState>()
    /// True when there are changes since the last save or export.
    public private(set) var isDirty = false
    /// Extra presets the user made (looked up when building settings).
    public var userPresets: [Preset] = []

    public init(midi: MIDIFile, name: String, state: ProjectState? = nil) throws {
        self.midi = midi
        self.midiName = name
        var s = state ?? ProjectState()
        if s.source.tracks.isEmpty { s.source = DrumPattern.detectSource(in: midi) }
        let p = DrumPattern.extract(from: midi, source: s.source)
        guard !p.notes.isEmpty || state != nil else { throw GrooveDocumentError.noDrums }
        pattern = p
        analysis = PatternAnalyzer.analyze(p, tempoMap: midi.tempoMap, map: s.drumMap)
        if state == nil {
            // Sensible defaults from the pattern: swung patterns keep their swing.
            s.advanced = FactoryPresets.naturalDrummer.settings
        }
        self.state = s
    }

    public var tempoMap: TempoMap { midi.tempoMap }

    // MARK: State changes

    /// Applies an undoable change.
    public func change(_ name: String, _ body: (inout ProjectState) -> Void) {
        let before = state
        body(&state)
        guard state != before else { return }
        history.record(before, name: name)
        isDirty = true
        if state.drumMap != before.drumMap || state.source != before.source { reanalyse() }
    }

    /// A change that isn't worth an undo step (e.g. while a slider is being dragged; the
    /// caller records one step when the drag begins).
    public func changeWithoutUndo(_ body: (inout ProjectState) -> Void) {
        let before = state
        body(&state)
        if state != before { isDirty = true }
        if state.drumMap != before.drumMap || state.source != before.source { reanalyse() }
    }

    public func beginContinuousChange(_ name: String) {
        history.record(state, name: name)
    }

    public func undo() {
        guard let s = history.undo(current: state) else { return }
        let mapChanged = s.drumMap != state.drumMap || s.source != state.source
        state = s
        isDirty = true
        if mapChanged { reanalyse() }
    }

    public func redo() {
        guard let s = history.redo(current: state) else { return }
        let mapChanged = s.drumMap != state.drumMap || s.source != state.source
        state = s
        isDirty = true
        if mapChanged { reanalyse() }
    }

    public func markSaved() { isDirty = false }

    func reanalyse() {
        pattern = DrumPattern.extract(from: midi, source: state.source)
        analysis = PatternAnalyzer.analyze(pattern, tempoMap: midi.tempoMap, map: state.drumMap)
    }

    // MARK: Settings

    public func preset(id: String) -> Preset? {
        FactoryPresets.preset(id: id) ?? userPresets.first { $0.id == id }
    }

    /// The engine settings the current controls describe (Quick macros or Advanced values).
    public func currentSettings(seed: UInt64) -> HumaniseSettings {
        let trackAware = state.useTrackAware && (backing != nil || !state.sections.isEmpty)
        switch state.mode {
        case .quick:
            let base = preset(id: state.quick.styleID)?.settings ?? FactoryPresets.naturalDrummer.settings
            return state.quick.settings(base: base, seed: seed, trackAware: trackAware)
        case .advanced:
            var s = state.advanced
            s.seed = seed
            if !trackAware { s.trackAware.enabled = false }
            return s
        }
    }

    public var context: PerformanceContext {
        let audio = backing.map { AudioContext(analysis: $0, alignment: state.alignment) }
        return PerformanceContext(sections: state.sections, audio: audio)
    }

    // MARK: Performances

    public func performance(settings: HumaniseSettings) -> Performance {
        let input = HumanisationEngine.Input(pattern: pattern, tempoMap: tempoMap, map: state.drumMap, analysis: analysis,
                                             settings: settings, context: context, bars: state.processBars)
        return HumanisationEngine.humanise(input)
    }

    func presetLabel() -> String {
        switch state.mode {
        case .quick:
            let style = preset(id: state.quick.styleID)?.name ?? "Custom"
            return "\(style) · \(state.quick.feel.displayName)"
        case .advanced:
            return (preset(id: state.presetID)?.name ?? "Custom") + " (Advanced)"
        }
    }

    /// Humanises with the current controls and adds the result as a new variation.
    @discardableResult
    public func humanise(count: Int = 1) -> [Variation] {
        // Work everything out first, then apply it as one undoable change.
        var seed = state.nextSeed
        let label = presetLabel()
        let existing = state.variations.count
        var made: [Variation] = []
        for k in 0 ..< max(1, count) {
            let settings = currentSettings(seed: seed)
            let perf = performance(settings: settings)
            made.append(Variation(name: "Take \(existing + k + 1)", seed: seed, settings: settings, notes: perf.notes,
                                  stats: perf.stats, presetName: label))
            seed = GrooveDocument.nextSeed(after: seed)
        }
        let finalSeed = seed
        let newTakes = made
        change(count == 1 ? "Humanise" : "Generate Variations") { s in
            s.variations += newTakes
            s.nextSeed = finalSeed
            if let last = newTakes.last {
                // The previous selection becomes the comparison, so A/B is ready immediately.
                s.compareVariationID = s.selectedVariationID
                s.selectedVariationID = last.id
            }
        }
        return made
    }

    /// Re-runs the selected variation with the current controls, keeping its seed
    /// (so only what the controls changed is different). Adds it as a new take.
    @discardableResult
    public func rehumaniseKeepingSeed() -> Variation? {
        guard let current = selectedVariation else { return humanise().first }
        let settings = currentSettings(seed: current.seed)
        let perf = performance(settings: settings)
        let v = Variation(name: "Take \(state.variations.count + 1)", seed: current.seed, settings: settings, notes: perf.notes,
                          stats: perf.stats, presetName: presetLabel())
        change("Re-humanise") { s in
            s.variations.append(v)
            s.compareVariationID = current.id
            s.selectedVariationID = v.id
        }
        return v
    }

    static func nextSeed(after seed: UInt64) -> UInt64 {
        // Seeds stay below 2^48 so they survive JSON round trips exactly.
        var r = SeededRandom(seed: seed)
        return (r.next() & 0x0000_FFFF_FFFF_FFFF) | 1
    }

    public var selectedVariation: Variation? {
        guard let id = state.selectedVariationID else { return nil }
        return state.variations.first { $0.id == id }
    }

    public func variation(_ id: UUID?) -> Variation? {
        guard let id else { return nil }
        return state.variations.first { $0.id == id }
    }

    /// Notes of the original or of a variation.
    public func notes(for id: UUID?) -> [DrumNote] {
        variation(id)?.notes ?? pattern.notes
    }

    public var selectedNotes: [DrumNote] { notes(for: state.selectedVariationID) }

    public func select(_ id: UUID?) {
        change("Select Take") { s in
            if s.selectedVariationID != id { s.compareVariationID = s.selectedVariationID }
            s.selectedVariationID = id
        }
    }

    /// Swaps the selected and compare performances (the A/B button).
    public func toggleAB() {
        changeWithoutUndo { s in
            let a = s.selectedVariationID
            s.selectedVariationID = s.compareVariationID
            s.compareVariationID = a
        }
    }

    public func revertToOriginal() { select(nil) }

    public func toggleFavourite(_ id: UUID) {
        change("Favourite") { s in
            if let i = s.variations.firstIndex(where: { $0.id == id }) { s.variations[i].isFavourite.toggle() }
        }
    }

    public func rename(_ id: UUID, to name: String) {
        change("Rename Take") { s in
            if let i = s.variations.firstIndex(where: { $0.id == id }) { s.variations[i].name = name }
        }
    }

    public func delete(_ id: UUID) {
        change("Delete Take") { s in
            s.variations.removeAll { $0.id == id }
            if s.selectedVariationID == id { s.selectedVariationID = s.variations.last?.id }
            if s.compareVariationID == id { s.compareVariationID = nil }
        }
    }

    /// Removes every take that isn't a favourite.
    public func clearUnfavourited() {
        change("Clear Takes") { s in
            s.variations.removeAll { !$0.isFavourite }
            if let sel = s.selectedVariationID, !s.variations.contains(where: { $0.id == sel }) { s.selectedVariationID = s.variations.last?.id }
            if let cmp = s.compareVariationID, !s.variations.contains(where: { $0.id == cmp }) { s.compareVariationID = nil }
        }
    }

    /// Resets all controls to the defaults of the chosen style/preset.
    public func resetControls() {
        let defaults = (preset(id: state.presetID) ?? FactoryPresets.naturalDrummer).settings
        change("Reset Controls") { s in
            s.quick = QuickControls()
            s.advanced = defaults
            s.processBars = nil
        }
    }

    // MARK: Editing

    public enum NoteEdit: Sendable {
        case move(ids: Set<Int>, deltaTicks: Double)
        case velocity(ids: Set<Int>, delta: Int)
        case setVelocity(ids: Set<Int>, value: Int)
        case length(ids: Set<Int>, factor: Double)
        case delete(ids: Set<Int>)
        case add(DrumNote)
        case setPitch(ids: Set<Int>, pitch: Int)
    }

    /// Edits notes of the selected performance. Editing the original creates a new
    /// "Edited" take, so the original MIDI itself is never changed.
    public func edit(_ edit: NoteEdit, name: String = "Edit Notes") {
        let originalNotes = pattern.notes
        change(name) { s in
            var notes: [DrumNote]
            var index: Int
            if let id = s.selectedVariationID, let i = s.variations.firstIndex(where: { $0.id == id }) {
                index = i
                notes = s.variations[i].notes
            } else {
                let v = Variation(name: "Edited Original", seed: 0, settings: HumaniseSettings(), notes: originalNotes,
                                  stats: Performance.Stats(), presetName: "Hand edited", isEdited: true)
                s.variations.append(v)
                s.compareVariationID = nil
                s.selectedVariationID = v.id
                index = s.variations.count - 1
                notes = v.notes
            }
            GrooveDocument.apply(edit, to: &notes)
            s.variations[index].notes = notes.sorted(by: DrumPattern.order)
            s.variations[index].isEdited = true
        }
    }

    static func apply(_ edit: NoteEdit, to notes: inout [DrumNote]) {
        func markEdited(_ i: Int) { if notes[i].origin == .original { notes[i].origin = .edited } }
        switch edit {
        case .move(let ids, let delta):
            for i in notes.indices where ids.contains(notes[i].id) { notes[i].tick = max(0, notes[i].tick + delta); markEdited(i) }
        case .velocity(let ids, let delta):
            for i in notes.indices where ids.contains(notes[i].id) { notes[i].velocity = clamp(notes[i].velocity + delta, 1, 127); markEdited(i) }
        case .setVelocity(let ids, let value):
            for i in notes.indices where ids.contains(notes[i].id) { notes[i].velocity = clamp(value, 1, 127); markEdited(i) }
        case .length(let ids, let factor):
            for i in notes.indices where ids.contains(notes[i].id) { notes[i].length = max(1, notes[i].length * factor); markEdited(i) }
        case .delete(let ids):
            notes.removeAll { ids.contains($0.id) }
        case .add(var note):
            let used = Set(notes.map(\.id))
            var id = max(DrumNote.addedIDBase * 2, (notes.map(\.id).max() ?? 0) + 1)
            while used.contains(id) { id += 1 }
            note.id = id
            note.origin = .edited
            notes.append(note)
        case .setPitch(let ids, let pitch):
            for i in notes.indices where ids.contains(notes[i].id) { notes[i].pitch = clamp(pitch, 0, 127); markEdited(i) }
        }
    }

    // MARK: Sections & alignment

    public func addSection(_ marker: SectionMarker) {
        change("Add Section Marker") { s in
            s.sections.removeAll { $0.bar == marker.bar }
            s.sections.append(marker)
            s.sections.sort { $0.bar < $1.bar }
        }
    }

    public func updateSection(_ marker: SectionMarker) {
        change("Edit Section Marker") { s in
            if let i = s.sections.firstIndex(where: { $0.id == marker.id }) {
                var m = marker
                m.isEstimate = false
                s.sections[i] = m
                s.sections.sort { $0.bar < $1.bar }
            }
        }
    }

    public func removeSection(_ id: UUID) {
        change("Remove Section Marker") { s in s.sections.removeAll { $0.id == id } }
    }

    /// Replaces estimated markers with the ones from the backing analysis (user markers stay).
    public func applyEstimatedSections() {
        guard let b = backing else { return }
        let estimated = b.sectionMarkers(alignment: state.alignment, tempoMap: tempoMap, totalBars: analysis.bars)
        change("Detect Sections") { s in
            let user = s.sections.filter { !$0.isEstimate }
            var merged = user
            for m in estimated where !user.contains(where: { abs($0.bar - m.bar) < 2 }) { merged.append(m) }
            s.sections = merged.sorted { $0.bar < $1.bar }
        }
    }

    public func autoAlign() -> AutoAligner.Result? {
        guard let b = backing else { return nil }
        let result = AutoAligner.align(pattern: pattern, tempoMap: tempoMap, map: state.drumMap, analysis: b,
                                       stretch: state.alignment.stretch)
        change("Auto Align") { s in s.alignment = result.alignment }
        return result
    }

    /// Tempo of the audio vs the MIDI, when they differ noticeably.
    public var tempoMismatch: (midi: Double, audio: Double, suggestedStretch: Double)? {
        guard let b = backing, b.tempo.isReliable else { return nil }
        let stretch = AutoAligner.tempoMatchStretch(midiBPM: tempoMap.initialBPM, audioBPM: b.tempo.bpm)
        guard abs(stretch - 1) > 0.004 else { return nil }
        return (tempoMap.initialBPM, b.tempo.bpm, stretch)
    }

    // MARK: Export

    /// The MIDI file for a performance: the original file with its drum notes replaced.
    /// Added notes can be left out.
    public func exportFile(for id: UUID?, includeAddedNotes: Bool = true) -> MIDIFile {
        var out = pattern
        var notes = notes(for: id)
        if !includeAddedNotes { notes.removeAll { $0.origin.isAdded } }
        out.notes = notes
        guard id != nil else { return midi }   // the original is written back untouched
        return out.applied(to: midi)
    }

    public func exportData(for id: UUID?, includeAddedNotes: Bool = true) -> Data {
        MIDIWriter.data(for: exportFile(for: id, includeAddedNotes: includeAddedNotes))
    }

    public func markExported() { isDirty = false }
}

// MARK: - Project files

/// A saved Groovecraft project (.groovecraft): the original MIDI bytes, the backing-track
/// location and analysis, and the full project state including every take.
public struct ProjectFile: Codable, Sendable {
    public var formatVersion: Int = 1
    public var midiName: String
    public var midiData: Data
    public var backingPath: String?
    public var backingBookmark: Data?
    public var backingAnalysis: BackingAnalysis?
    public var state: ProjectState

    public init(document: GrooveDocument, backingPath: String?, backingBookmark: Data?) {
        midiName = document.midiName
        midiData = MIDIWriter.data(for: document.midi)
        self.backingPath = backingPath
        self.backingBookmark = backingBookmark
        backingAnalysis = document.backing
        state = document.state
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> ProjectFile {
        let d = JSONDecoder()
        return try d.decode(ProjectFile.self, from: data)
    }

    public func makeDocument() throws -> GrooveDocument {
        let midi = try MIDIParser.parse(midiData)
        let doc = try GrooveDocument(midi: midi, name: midiName, state: state)
        doc.backing = backingAnalysis
        doc.backingName = backingPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        doc.markSaved()
        return doc
    }
}

// MARK: - Batch processing

public enum ExportNaming {
    /// "{name}" is the source file name, "{preset}" the preset, "{n}" the take number.
    public static let defaultPattern = "{name} – Groovecraft {preset}"

    public static func fileName(pattern: String, source: String, preset: String, take: Int = 1) -> String {
        var s = pattern.isEmpty ? defaultPattern : pattern
        s = s.replacingOccurrences(of: "{name}", with: source)
        s = s.replacingOccurrences(of: "{preset}", with: preset)
        s = s.replacingOccurrences(of: "{n}", with: String(take))
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        s = s.components(separatedBy: illegal).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "Groovecraft Export" : s
    }

    /// A URL that doesn't overwrite an existing file (adds " 2", " 3", …) unless allowed.
    public static func uniqueURL(folder: URL, base: String, ext: String = "mid", overwrite: Bool) -> URL {
        let first = folder.appendingPathComponent(base).appendingPathExtension(ext)
        if overwrite || !FileManager.default.fileExists(atPath: first.path) { return first }
        var n = 2
        while true {
            let u = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: u.path) { return u }
            n += 1
        }
    }
}

public enum BatchProcessor {
    public struct Options: Sendable {
        public var settings: HumaniseSettings
        public var presetName: String
        public var map: DrumMap
        public var outputFolder: URL
        public var namingPattern: String
        public var overwrite: Bool
        public var variationsPerFile: Int
        public init(settings: HumaniseSettings, presetName: String, map: DrumMap = .generalMIDI, outputFolder: URL,
                    namingPattern: String = ExportNaming.defaultPattern, overwrite: Bool = false, variationsPerFile: Int = 1) {
            self.settings = settings
            self.presetName = presetName
            self.map = map
            self.outputFolder = outputFolder
            self.namingPattern = namingPattern
            self.overwrite = overwrite
            self.variationsPerFile = max(1, variationsPerFile)
        }
    }

    public struct Result: Sendable {
        public var source: URL
        public var outputs: [URL]
        public var error: String?
        public var notes: Int
    }

    /// Humanises one file and writes the result(s). Never touches the source file.
    public static func process(_ url: URL, options: Options) -> Result {
        do {
            let midi = try MIDIParser.parse(contentsOf: url)
            let source = DrumPattern.detectSource(in: midi)
            let pattern = DrumPattern.extract(from: midi, source: source)
            guard !pattern.notes.isEmpty else { throw GrooveDocumentError.noDrums }
            let analysis = PatternAnalyzer.analyze(pattern, tempoMap: midi.tempoMap, map: options.map)
            try FileManager.default.createDirectory(at: options.outputFolder, withIntermediateDirectories: true)
            var outputs: [URL] = []
            for take in 1 ... options.variationsPerFile {
                var settings = options.settings
                settings.seed = options.settings.seed &+ UInt64(take - 1) &* 7919
                let input = HumanisationEngine.Input(pattern: pattern, tempoMap: midi.tempoMap, map: options.map,
                                                     analysis: analysis, settings: settings)
                var out = pattern
                out.notes = HumanisationEngine.humanise(input).notes
                let file = out.applied(to: midi)
                let base = ExportNaming.fileName(pattern: options.namingPattern, source: url.deletingPathExtension().lastPathComponent,
                                                 preset: options.presetName, take: take)
                let name = options.variationsPerFile > 1 && !options.namingPattern.contains("{n}") ? "\(base) \(take)" : base
                let target = ExportNaming.uniqueURL(folder: options.outputFolder, base: name, overwrite: options.overwrite)
                guard target.standardizedFileURL != url.standardizedFileURL else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try MIDIWriter.write(file, to: target)
                // Verify what was written reads back with every note.
                let check = try MIDIParser.parse(contentsOf: target)
                guard check.noteCount == file.noteCount else { throw MIDIFileError.invalidData("verification failed") }
                outputs.append(target)
            }
            return Result(source: url, outputs: outputs, error: nil, notes: pattern.notes.count)
        } catch {
            return Result(source: url, outputs: [], error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, notes: 0)
        }
    }
}
