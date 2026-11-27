import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GrooveCore

enum InspectorTab: String, CaseIterable, Identifiable {
    case perform, listen, drums, output
    var id: String { rawValue }
    var title: String {
        switch self {
        case .perform: return "Perform"
        case .listen: return "Track"
        case .drums: return "Drums"
        case .output: return "Output"
        }
    }
    var symbol: String {
        switch self {
        case .perform: return "slider.horizontal.3"
        case .listen: return "waveform"
        case .drums: return "square.grid.3x3"
        case .output: return "cable.connector"
        }
    }
}

enum SidebarTab: String, CaseIterable { case takes, presets }

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var symbol: String = "checkmark.circle.fill"
    var isError = false
}

/// User preferences that persist between launches.
struct AppPreferences: Codable, Equatable {
    var output = MIDIOutputSettings()
    var route: MIDIRoute = .virtualSource
    var externalEnabled = true
    var previewKitEnabled = false
    var backingAudible = true
    var previewVolume: Double = 0.8
    var backingVolume: Double = 0.8
    var favouritePresets: Set<String> = []
    var defaultPresetID: String = FactoryPresets.naturalDrummer.id
    var exportFolderPath: String? = nil
    var exportNaming: String = ExportNaming.defaultPattern
    var exportIncludesAddedNotes = true
    var showOriginalGhosts = true
    var snapToGrid = false
    var autoAlignOnImport = true
    var detectSectionsOnImport = true
    var preciseTimestamps = true
    var savedDrumMaps: [DrumMap] = []
    var savedOutputMaps: [OutputNoteMap] = []

    static let key = "preferences.v1"

    static func load() -> AppPreferences {
        guard let data = UserDefaults.standard.data(forKey: key) else { return AppPreferences() }
        return (try? TolerantJSON.decode(AppPreferences.self, from: data, defaults: AppPreferences())) ?? AppPreferences()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: AppPreferences.key) }
    }
}

/// The app's central state. Owns the document, the MIDI and audio engines and the transport.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // Document
    @Published private(set) var document: GrooveDocument?
    @Published private(set) var revision = 0
    @Published var midiURL: URL?
    @Published var projectURL: URL?
    @Published var backingURL: URL?
    @Published var backingFormat: String?
    @Published var isAnalysing = false
    @Published var analysisProgress: Double = 0
    @Published var analysisStatus = ""
    @Published var alignmentConfidence: Double?

    // UI
    @Published var alert: AppAlert?
    @Published var toast: Toast?
    @Published var inspectorTab: InspectorTab = .perform
    @Published var sidebarTab: SidebarTab = .takes
    @Published var selection: Set<Int> = []
    @Published var pixelsPerBeat: Double = 56
    @Published var showLogicGuide = false
    @Published var isDropTargeted = false
    @Published var isHumanising = false

    // Output
    @Published var prefs = AppPreferences.load() { didSet { if prefs != oldValue { prefsChanged(oldValue) } } }
    @Published var destinations: [MIDIDestinationInfo] = []
    @Published var midiActivity = false
    @Published private(set) var presets: [Preset] = FactoryPresets.all

    let midi = MIDIOutput()
    let midiThread: MIDIPlaybackThread
    let audio = AudioEngine()
    let transport: TransportController
    let presetStore: PresetStore
    private var activityCounter = 0
    private var keyMonitor: Any?

    private init() {
        midiThread = MIDIPlaybackThread(output: midi)
        transport = TransportController()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        presetStore = PresetStore(folder: support.appendingPathComponent("Groovecraft/Presets", isDirectory: true))
        presets = presetStore.allPresets
        transport.app = self
        midi.setRoute(prefs.route)
        destinations = midi.destinations()
        midi.onSetupChanged = {
            Task { @MainActor in AppState.shared.refreshDestinations() }
        }
        midiThread.onActivity = {
            Task { @MainActor in AppState.shared.flashActivity() }
        }
        audio.volume = Float(prefs.previewVolume)
        installKeyMonitor()
    }

    // MARK: Document access

    var hasDocument: Bool { document != nil }

    /// Runs a change on the document and refreshes everything that depends on it.
    func mutate(_ body: (GrooveDocument) -> Void) {
        guard let doc = document else { return }
        let before = doc.state.selectedVariationID
        let beforeNotes = doc.selectedNotes
        objectWillChange.send()
        body(doc)
        revision += 1
        if transport.isPlaying && (doc.state.selectedVariationID != before || doc.selectedNotes != beforeNotes) {
            transport.performanceChanged()
        }
        selection = selection.filter { id in doc.selectedNotes.contains { $0.id == id } }
    }

    func setDocument(_ doc: GrooveDocument?) {
        transport.stop()
        objectWillChange.send()
        document = doc
        doc?.userPresets = presetStore.userPresets
        selection = []
        revision += 1
        if let d = doc {
            let beats = max(4, d.analysis.lengthBeats)
            pixelsPerBeat = beats > 256 ? 28 : (beats > 96 ? 40 : 56)
            transport.resetLoop()
        }
    }

    var windowTitle: String {
        guard let d = document else { return GC.Brand.name }
        return d.midiName + (d.isDirty ? " — Edited" : "")
    }

    // MARK: Opening files

    func openMIDIPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.midi, UTType(filenameExtension: "mid") ?? .midi, UTType(filenameExtension: "groovecraft") ?? .json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a drum MIDI file (or a Groovecraft project)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self.open(url) }
        }
    }

    func open(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "groovecraft" { openProject(url); return }
        if AudioFileLoader.supportedExtensions.contains(ext) { importBacking(url); return }
        openMIDI(url)
    }

    func openMIDI(_ url: URL) {
        if let d = document, d.isDirty, !confirmDiscard() { return }
        do {
            let midi = try MIDIParser.parse(contentsOf: url)
            var state = ProjectState()
            state.source = DrumPattern.detectSource(in: midi)
            if let saved = prefs.savedDrumMaps.first(where: { $0.id == "user.default" }) { state.drumMap = saved }
            state.quick.styleID = prefs.defaultPresetID
            state.presetID = prefs.defaultPresetID
            state.advanced = (presetStore.allPresets.first { $0.id == prefs.defaultPresetID } ?? FactoryPresets.naturalDrummer).settings
            let doc = try GrooveDocument(midi: midi, name: url.deletingPathExtension().lastPathComponent, state: state)
            if doc.pattern.notes.isEmpty {
                alert = AppAlert(title: "No drum notes found", message: GrooveDocumentError.noDrums.errorDescription ?? "")
            }
            midiURL = url
            projectURL = nil
            backingURL = nil
            backingFormat = nil
            audio.renderer.clearBacking()
            setDocument(doc)
            doc.markSaved()
            show(Toast(text: "Opened \(url.lastPathComponent) · \(doc.analysis.noteCount) notes", symbol: "music.note"))
        } catch {
            alert = AppAlert(title: "Couldn't open \(url.lastPathComponent)", message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func importBackingPanel() {
        guard document != nil else {
            alert = AppAlert(title: "Open a drum MIDI file first", message: "The backing track is analysed against the drum part, so open the MIDI file, then add the backing track.")
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose the backing track (ideally the mix without drums)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self.importBacking(url) }
        }
    }

    func importBacking(_ url: URL) {
        guard let doc = document else {
            alert = AppAlert(title: "Open a drum MIDI file first", message: "Then drop the backing track onto the window.")
            return
        }
        transport.stop()
        isAnalysing = true
        analysisProgress = 0
        analysisStatus = "Reading audio…"
        let hint = doc.tempoMap.initialBPM
        let beatsPerBar = doc.tempoMap.initialSignature.numerator
        Task.detached(priority: .userInitiated) {
            do {
                let loaded = try AudioFileLoader.load(url)
                await MainActor.run { AppState.shared.analysisStatus = "Listening to the track…" }
                let analysis = try BackingTrackAnalyzer.analyze(loaded.analysisBuffer, options: .init(tempoHint: hint, beatsPerBar: beatsPerBar)) { p in
                    Task { @MainActor in AppState.shared.analysisProgress = p }
                }
                await MainActor.run {
                    AppState.shared.finishBackingImport(url: url, loaded: loaded, analysis: analysis)
                }
            } catch {
                await MainActor.run {
                    let app = AppState.shared
                    app.isAnalysing = false
                    app.alert = AppAlert(title: "Couldn't use \(url.lastPathComponent)", message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
        }
    }

    private func finishBackingImport(url: URL, loaded: AudioFileLoader.Loaded, analysis: BackingAnalysis) {
        guard let doc = document else { isAnalysing = false; return }
        audio.renderer.setBacking(left: loaded.left, right: loaded.right, sampleRate: loaded.sampleRate)
        objectWillChange.send()
        doc.backing = analysis
        doc.backingName = url.lastPathComponent
        backingURL = url
        backingFormat = loaded.formatDescription
        var message = "Analysed \(url.lastPathComponent) · \(String(format: "%.1f", analysis.tempo.bpm)) BPM"
        if prefs.autoAlignOnImport, let result = doc.autoAlign() {
            alignmentConfidence = result.confidence
            message += " · aligned at \(String(format: "%+.3f", result.alignment.offsetSeconds)) s"
        }
        if prefs.detectSectionsOnImport { doc.applyEstimatedSections() }
        doc.change("Use Backing Track") { $0.useTrackAware = true }
        isAnalysing = false
        revision += 1
        inspectorTab = .listen
        show(Toast(text: message, symbol: "waveform"))
    }

    func removeBacking() {
        transport.stop()
        mutate { doc in
            doc.backing = nil
            doc.backingName = nil
            doc.change("Remove Backing Track") { s in s.sections.removeAll { $0.isEstimate } }
        }
        backingURL = nil
        backingFormat = nil
        alignmentConfidence = nil
        audio.renderer.clearBacking()
    }

    // MARK: Projects

    func openProject(_ url: URL) {
        if let d = document, d.isDirty, !confirmDiscard() { return }
        do {
            let file = try ProjectFile.decode(Data(contentsOf: url))
            let doc = try file.makeDocument()
            setDocument(doc)
            projectURL = url
            midiURL = nil
            backingURL = nil
            backingFormat = nil
            audio.renderer.clearBacking()
            // Reconnect the backing audio for listening (analysis is stored in the project).
            if let path = file.backingPath, FileManager.default.fileExists(atPath: path) {
                let audioURL = URL(fileURLWithPath: path)
                backingURL = audioURL
                Task.detached(priority: .userInitiated) {
                    if let loaded = try? AudioFileLoader.load(audioURL) {
                        await MainActor.run {
                            let app = AppState.shared
                            app.audio.renderer.setBacking(left: loaded.left, right: loaded.right, sampleRate: loaded.sampleRate)
                            app.backingFormat = loaded.formatDescription
                        }
                    }
                }
            } else if file.backingPath != nil {
                show(Toast(text: "Backing audio not found; its analysis is still used.", symbol: "exclamationmark.triangle.fill", isError: true))
            }
            show(Toast(text: "Opened project \(url.deletingPathExtension().lastPathComponent)", symbol: "folder"))
        } catch {
            alert = AppAlert(title: "Couldn't open the project", message: error.localizedDescription)
        }
    }

    func saveProject(saveAs: Bool = false) {
        guard let doc = document else { return }
        if let url = projectURL, !saveAs { writeProject(doc, to: url); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "groovecraft") ?? .json]
        panel.nameFieldStringValue = doc.midiName + ".groovecraft"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self.writeProject(doc, to: url) }
        }
    }

    private func writeProject(_ doc: GrooveDocument, to url: URL) {
        do {
            let file = ProjectFile(document: doc, backingPath: backingURL?.path, backingBookmark: nil)
            try file.encoded().write(to: url, options: .atomic)
            projectURL = url
            objectWillChange.send()
            doc.markSaved()
            revision += 1
            show(Toast(text: "Saved \(url.lastPathComponent)", symbol: "square.and.arrow.down"))
        } catch {
            alert = AppAlert(title: "Couldn't save the project", message: error.localizedDescription)
        }
    }

    private func confirmDiscard() -> Bool {
        let a = NSAlert()
        a.messageText = "Discard unsaved changes?"
        a.informativeText = "Your takes and edits in this session haven't been saved as a project or exported."
        a.addButton(withTitle: "Discard")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        return a.runModal() == .alertFirstButtonReturn
    }

    // MARK: Export

    func exportSelected() {
        guard let doc = document else { return }
        let id = doc.state.selectedVariationID
        let takeName = doc.variation(id)?.name ?? "Original"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.midi]
        let preset = doc.variation(id)?.presetName ?? "Original"
        let base = ExportNaming.fileName(pattern: prefs.exportNaming, source: doc.midiName, preset: preset)
        panel.nameFieldStringValue = (id == nil ? doc.midiName + " (original)" : base + " – " + takeName) + ".mid"
        if let folder = prefs.exportFolderPath { panel.directoryURL = URL(fileURLWithPath: folder) }
        panel.message = "Export \(takeName) as a Standard MIDI File"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self.writeExport(id: id, to: url) }
        }
    }

    func writeExport(id: UUID?, to url: URL) {
        guard let doc = document else { return }
        if let source = midiURL, source.standardizedFileURL == url.standardizedFileURL {
            alert = AppAlert(title: "Choose a different name", message: "Groovecraft never overwrites your original MIDI file.")
            return
        }
        do {
            let data = doc.exportData(for: id, includeAddedNotes: prefs.exportIncludesAddedNotes)
            try data.write(to: url, options: .atomic)
            // Verify the file reads back intact.
            let check = try MIDIParser.parse(Data(contentsOf: url))
            let expected = try MIDIParser.parse(data)
            guard check.noteCount == expected.noteCount else { throw MIDIFileError.invalidData("verification failed") }
            prefs.exportFolderPath = url.deletingLastPathComponent().path
            objectWillChange.send()
            doc.markExported()
            revision += 1
            show(Toast(text: "Exported \(url.lastPathComponent)", symbol: "square.and.arrow.up"))
        } catch {
            alert = AppAlert(title: "Export failed", message: error.localizedDescription)
        }
    }

    func exportAllTakes() {
        guard let doc = document, !doc.state.variations.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for all takes"
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            Task { @MainActor in
                var written = 0
                for v in doc.state.variations {
                    let base = ExportNaming.fileName(pattern: self.prefs.exportNaming, source: doc.midiName, preset: v.presetName) + " – " + v.name
                    let url = ExportNaming.uniqueURL(folder: folder, base: base, overwrite: false)
                    do {
                        try doc.exportData(for: v.id, includeAddedNotes: self.prefs.exportIncludesAddedNotes).write(to: url, options: .atomic)
                        written += 1
                    } catch {
                        self.alert = AppAlert(title: "Couldn't export \(v.name)", message: error.localizedDescription)
                    }
                }
                self.show(Toast(text: "Exported \(written) take\(written == 1 ? "" : "s")", symbol: "square.and.arrow.up.on.square"))
            }
        }
    }

    // MARK: Humanise

    func humanise(count: Int = 1) {
        guard let doc = document else { return }
        guard !doc.pattern.notes.isEmpty else {
            alert = AppAlert(title: "Nothing to humanise", message: GrooveDocumentError.noDrums.errorDescription ?? "")
            return
        }
        withAnimation(MotionPreference.animation(GC.Motion.emphasis)) { isHumanising = true }
        mutate { $0.humanise(count: count) }
        let take = doc.selectedVariation
        if let t = take {
            show(Toast(text: "\(t.name) · ±\(String(format: "%.1f", t.stats.meanTimingShiftMs)) ms · \(t.stats.addedNotes) added", symbol: "sparkles"))
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            withAnimation(MotionPreference.animation(GC.Motion.standard)) { self.isHumanising = false }
        }
    }

    // MARK: Presets

    func reloadPresets() {
        presetStore.reload()
        presets = presetStore.allPresets
        document?.userPresets = presetStore.userPresets
    }

    func savePresetFromCurrent(name: String, category: String) {
        guard let doc = document else { return }
        var settings = doc.currentSettings(seed: 1)
        settings.seed = 1
        let p = Preset(name: name, category: category.isEmpty ? "User" : category, summary: "Saved from \(doc.midiName)", settings: settings)
        do {
            let saved = try presetStore.save(p)
            reloadPresets()
            mutate { d in d.change("Choose Preset") { s in s.presetID = saved.id; s.quick.styleID = saved.id } }
            show(Toast(text: "Saved preset \(name)", symbol: "star.fill"))
        } catch {
            alert = AppAlert(title: "Couldn't save the preset", message: error.localizedDescription)
        }
    }

    func applyPreset(_ preset: Preset) {
        mutate { doc in
            doc.change("Choose Preset \(preset.name)") { s in
                s.presetID = preset.id
                s.quick.styleID = preset.id
                var settings = preset.settings
                settings.trackAware.enabled = s.advanced.trackAware.enabled
                s.advanced = settings
            }
        }
    }

    // MARK: Output

    private func prefsChanged(_ old: AppPreferences) {
        prefs.save()
        if prefs.route != old.route { midi.setRoute(prefs.route) }
        if prefs.output != old.output {
            midiThread.update(settings: prefs.output)
            if transport.isPlaying { transport.performanceChanged() }
        }
        if prefs.previewVolume != old.previewVolume { audio.renderer.drumGain = Float(prefs.previewVolume) }
        if prefs.backingVolume != old.backingVolume { audio.renderer.backingGain = Float(prefs.backingVolume) }
        if prefs.previewKitEnabled != old.previewKitEnabled { audio.renderer.drumsEnabled = prefs.previewKitEnabled }
        if prefs.backingAudible != old.backingAudible { audio.renderer.backingEnabled = prefs.backingAudible }
        if prefs.externalEnabled != old.externalEnabled && transport.isPlaying {
            transport.restartFromCurrentPosition()
        }
    }

    func refreshDestinations() { destinations = midi.destinations() }

    func sendTestNote(category: DrumCategory) {
        let map = document?.state.drumMap ?? .generalMIDI
        let note = map.note(for: category) ?? 38
        let out = prefs.output.noteMap.output(for: note)
        midi.sendTestNote(channel: prefs.output.channel ?? 9, note: out, velocity: 100)
        if prefs.previewKitEnabled {
            audio.startEngine()
            audio.renderer.synth.trigger(category: category, note: note, velocity: 100)
        }
        flashActivity()
    }

    func panic() {
        transport.stop()
        midi.panic()
        audio.renderer.synth.reset()
        show(Toast(text: "All notes off sent", symbol: "exclamationmark.octagon.fill"))
    }

    func flashActivity() {
        midiActivity = true
        activityCounter += 1
        let mine = activityCounter
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            if self.activityCounter == mine { self.midiActivity = false }
        }
    }

    var outputStatus: (connected: Bool, text: String) {
        guard prefs.externalEnabled else { return (false, "External MIDI off") }
        switch prefs.route {
        case .virtualSource:
            return midi.hasVirtualSource ? (true, "Groovecraft virtual port") : (false, "Virtual port unavailable")
        case .destination(let uid):
            if let d = destinations.first(where: { $0.id == uid }) {
                return d.isOffline ? (false, "\(d.name) (offline)") : (true, d.name)
            }
            return (false, "Destination not found")
        }
    }

    // MARK: Misc

    func show(_ t: Toast) {
        withAnimation(MotionPreference.animation(GC.Motion.panel)) { toast = t }
        let id = t.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if self.toast?.id == id {
                withAnimation(MotionPreference.animation(GC.Motion.standard)) { self.toast = nil }
            }
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in AppState.shared.open(url) }
            }
        }
        return handled
    }

    /// Space bar starts/stops playback unless a text field is being edited.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // Space = play/stop, L = loop, unless a text field is being edited.
            guard mods.isEmpty, event.keyCode == 49 || event.keyCode == 37 else { return event }
            if let responder = event.window?.firstResponder, responder is NSText || responder is NSTextField {
                return event
            }
            let isSpace = event.keyCode == 49
            Task { @MainActor in
                let app = AppState.shared
                guard app.hasDocument else { return }
                if isSpace { app.transport.togglePlay() } else { app.transport.toggleLoop() }
            }
            return nil
        }
    }
}
