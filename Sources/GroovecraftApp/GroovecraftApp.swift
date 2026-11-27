import SwiftUI
import GrooveCore

@main
struct GroovecraftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppState.shared

    var body: some Scene {
        Window(GC.Brand.name, id: "main") {
            MainWindow(app: app, transport: app.transport)
                .frame(minWidth: 1180, minHeight: 720)
        }
        .defaultSize(width: 1440, height: 880)
        .windowStyle(.hiddenTitleBar)
        .commands { GroovecraftCommands(app: app, transport: app.transport) }

        Window("Batch Processing", id: "batch") {
            BatchView(app: app)
        }
        .defaultSize(width: 860, height: 520)

        Settings {
            SettingsView(app: app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave notes hanging in the user's instrument.
        MainActor.assumeIsolated {
            AppState.shared.transport.stop()
            AppState.shared.midi.panic()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in AppState.shared.open(url) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = MainActor.assumeIsolated { AppState.shared.document?.isDirty ?? false }
        guard dirty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit without saving?"
        alert.informativeText = "Your takes and edits haven't been saved as a project or exported."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct GroovecraftCommands: Commands {
    @ObservedObject var app: AppState
    @ObservedObject var transport: TransportController
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open MIDI or Project…") { app.openMIDIPanel() }
                .keyboardShortcut("o")
            Button("Add Backing Track…") { app.importBackingPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!app.hasDocument)
            Button("Open Demo Groove") { app.openDemo() }
            Divider()
            Button("Batch Processing…") { openWindow(id: "batch") }
                .keyboardShortcut("b", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Project") { app.saveProject() }
                .keyboardShortcut("s")
                .disabled(!app.hasDocument)
            Button("Save Project As…") { app.saveProject(saveAs: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!app.hasDocument)
            Divider()
            Button("Export Selected Take…") { app.exportSelected() }
                .keyboardShortcut("e")
                .disabled(!app.hasDocument)
            Button("Export All Takes…") { app.exportAllTakes() }
                .disabled(app.document?.state.variations.isEmpty ?? true)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(app.document?.history.undoName.map { "Undo \($0)" } ?? "Undo") { app.mutate { $0.undo() } }
                .keyboardShortcut("z")
                .disabled(!(app.document?.history.canUndo ?? false))
            Button(app.document?.history.redoName.map { "Redo \($0)" } ?? "Redo") { app.mutate { $0.redo() } }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(app.document?.history.canRedo ?? false))
        }
        CommandMenu("Perform") {
            Button("Humanise") { app.humanise() }
                .keyboardShortcut(.return)
                .disabled(!app.hasDocument)
            Button("Generate 4 Variations") { app.humanise(count: 4) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(!app.hasDocument)
            Button("New Take with Same Seed") { app.mutate { $0.rehumaniseKeepingSeed() } }
                .disabled(app.document?.selectedVariation == nil)
            Divider()
            Button("Swap A / B") { app.mutate { $0.toggleAB() } }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(app.document?.state.variations.isEmpty ?? true)
            Button("Back to Original") { app.mutate { $0.revertToOriginal() } }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(!app.hasDocument)
            Button("Reset Controls") { app.mutate { $0.resetControls() } }
                .disabled(!app.hasDocument)
            Divider()
            Button("Humanise All Bars") { app.mutate { $0.change("Process All Bars") { $0.processBars = nil } } }
                .disabled(app.document?.state.processBars == nil)
        }
        CommandMenu("Transport") {
            Button(transport.isPlaying ? "Stop" : "Play") { transport.togglePlay() }
                .disabled(!app.hasDocument)
            Button("Return to Start") { transport.rewind() }
                .keyboardShortcut(.home, modifiers: [])
                .disabled(!app.hasDocument)
            Button(transport.loopEnabled ? "Loop Off" : "Loop On") { transport.toggleLoop() }
                .disabled(!app.hasDocument)
            Divider()
            Button("Zoom In") { app.pixelsPerBeat = min(400, app.pixelsPerBeat * 1.4) }
                .keyboardShortcut("+")
            Button("Zoom Out") { app.pixelsPerBeat = max(6, app.pixelsPerBeat / 1.4) }
                .keyboardShortcut("-")
            Divider()
            Button("Panic: All Notes Off") { app.panic() }
                .keyboardShortcut(".", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Button("Logic Pro Setup Guide") { app.showLogicGuide = true }
        }
    }
}
