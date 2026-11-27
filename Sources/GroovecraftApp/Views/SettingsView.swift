import SwiftUI
import GrooveCore

struct SettingsView: View {
    @ObservedObject var app: AppState
    @AppStorage("animations") private var animations = true
    @AppStorage("liveUpdate") private var liveUpdate = true

    var body: some View {
        TabView {
            Form {
                Section("Humanisation") {
                    Picker("Default style for new files", selection: app.pref(\.defaultPresetID)) {
                        ForEach(app.presets) { Text($0.name).tag($0.id) }
                    }
                    Toggle("Update the selected take as I change controls", isOn: $liveUpdate)
                    Toggle("Auto-align backing tracks on import", isOn: app.pref(\.autoAlignOnImport))
                    Toggle("Detect sections on import", isOn: app.pref(\.detectSectionsOnImport))
                }
                Section("Appearance") {
                    Toggle("Animations", isOn: $animations)
                    Text("Animations also follow System Settings ▸ Accessibility ▸ Reduce motion.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Show original positions in the grid", isOn: app.pref(\.showOriginalGhosts))
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Output") {
                    Toggle("Send to external instrument", isOn: app.pref(\.externalEnabled))
                    Picker("MIDI channel", selection: app.pref(\.output.channel)) {
                        Text("Keep original").tag(Int?.none)
                        ForEach(0 ..< 16, id: \.self) { c in Text("\(c + 1)").tag(Optional(c)) }
                    }
                    LabeledContent("Latency compensation") {
                        Slider(value: app.pref(\.output.latencyMs), in: 0 ... 250, step: 1)
                        Text(String(format: "%.0f ms", app.prefs.output.latencyMs)).monospacedDigit().frame(width: 54)
                    }
                    Toggle("Precise timestamps", isOn: app.pref(\.preciseTimestamps))
                    Toggle("Send MIDI clock", isOn: app.pref(\.output.sendClock))
                    Toggle("Send Start / Stop / Song Position", isOn: app.pref(\.output.sendTransport))
                }
                Section("Preview") {
                    Toggle("Built-in preview kit", isOn: app.pref(\.previewKitEnabled))
                    Slider(value: app.pref(\.previewVolume), in: 0 ... 1) { Text("Kit volume") }
                    Slider(value: app.pref(\.backingVolume), in: 0 ... 1) { Text("Backing volume") }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("MIDI & Audio", systemImage: "cable.connector") }

            Form {
                Section("Export") {
                    TextField("File naming", text: app.pref(\.exportNaming))
                    Text("{name} = MIDI file name, {preset} = preset, {n} = take number").font(.caption).foregroundStyle(.secondary)
                    Toggle("Include added notes (ghosts, flams, drags, rolls)", isOn: app.pref(\.exportIncludesAddedNotes))
                    LabeledContent("Default folder") {
                        Text(app.prefs.exportFolderPath ?? "Last used").lineLimit(1).truncationMode(.head)
                        Button("Choose…") { chooseFolder() }
                    }
                    Text("Exports are Standard MIDI Files at 960 PPQ or higher, so micro-timing isn't rounded away. All other events in your file (tempo, markers, controllers, other tracks) are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Export", systemImage: "square.and.arrow.up") }

            ShortcutsList()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 520, height: 440)
        .preferredColorScheme(.dark)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.begin { r in
            guard r == .OK, let url = panel.url else { return }
            Task { @MainActor in app.prefs.exportFolderPath = url.path }
        }
    }
}

struct ShortcutsList: View {
    private let rows: [(String, String)] = [
        ("Space", "Play / Stop"),
        ("⌘↩", "Humanise (new take)"),
        ("⇧⌘↩", "Generate 4 variations"),
        ("⌥⌘B", "Swap A / B"),
        ("⌥⌘O", "Back to the original"),
        ("L", "Loop on / off (in the grid)"),
        ("⌘Z / ⇧⌘Z", "Undo / Redo"),
        ("⌘O", "Open MIDI or project"),
        ("⇧⌘O", "Add backing track"),
        ("⌘S / ⇧⌘S", "Save project / Save as"),
        ("⌘E", "Export selected take"),
        ("⇧⌘B", "Batch processing"),
        ("⌘+ / ⌘−", "Zoom in / out (or ⌘-scroll, pinch)"),
        ("← →", "Nudge selected notes (⌥ finer)"),
        ("↑ ↓", "Velocity of selected notes (⇧ bigger)"),
        ("⌫", "Delete selected notes"),
        ("⌘A", "Select all notes"),
        ("Double-click", "Add a note (grid) or section (sections lane)"),
        ("⌥⌘.", "Panic: all notes off"),
    ]

    var body: some View {
        List(rows, id: \.0) { row in
            HStack {
                Text(row.0).font(.system(.body, design: .monospaced)).frame(width: 130, alignment: .leading)
                Text(row.1)
            }
        }
    }
}
