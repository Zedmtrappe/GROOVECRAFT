import SwiftUI
import UniformTypeIdentifiers
import GrooveCore

struct DrumsPanel: View {
    @ObservedObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let doc = app.document {
                tracks(doc)
                Rectangle().fill(GC.Palette.hairline).frame(height: 1)
                mapping(doc)
            }
        }
    }

    // MARK: Drum tracks

    @ViewBuilder private func tracks(_ doc: GrooveDocument) -> some View {
        PanelSection("Drum tracks", subtitle: "\(doc.midi.tracks.count) in file · format \(doc.midi.format.rawValue)") {
            ForEach(Array(doc.midi.tracks.enumerated()), id: \.offset) { index, track in
                let notes = track.noteOnCount
                let isOn = doc.state.source.tracks.contains(index)
                HStack(spacing: GC.Space.s) {
                    Toggle("", isOn: Binding(get: { isOn }, set: { on in
                        app.mutate { d in d.change(on ? "Use Track" : "Ignore Track") { s in
                            if on { s.source.tracks = Array(Set(s.source.tracks + [index])).sorted() }
                            else { s.source.tracks.removeAll { $0 == index } }
                        } }
                    }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(notes == 0)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.name ?? "Track \(index + 1)").font(GC.Font.control).lineLimit(1)
                        Text(notes == 0 ? "no notes" : "\(notes) notes · channel \(track.channels.sorted().map { String($0 + 1) }.joined(separator: ", "))")
                            .font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary)
                    }
                    Spacer()
                }
                .opacity(notes == 0 ? 0.5 : 1)
            }
            HStack {
                Text("Channel").font(GC.Font.control).foregroundStyle(GC.Palette.textSecondary)
                Spacer()
                Picker("", selection: app.undoableBinding(\.source.channel, "Drum Channel", live: false)) {
                    Text("All channels").tag(Int?.none)
                    ForEach(0 ..< 16, id: \.self) { c in Text("Channel \(c + 1)\(c == 9 ? " (GM drums)" : "")").tag(Optional(c)) }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            Button("Detect Automatically") {
                let source = DrumPattern.detectSource(in: doc.midi)
                app.mutate { d in d.change("Detect Drum Tracks") { $0.source = source } }
            }
            .buttonStyle(GCButtonStyle(kind: .ghost))
            Text("Changing tracks re-reads the drum part. Existing takes keep their notes.")
                .font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Mapping

    @ViewBuilder private func mapping(_ doc: GrooveDocument) -> some View {
        let map = doc.state.drumMap
        let used = doc.pattern.pitches
        let unmapped = doc.analysis.unmappedNotes
        PanelSection("Drum map", subtitle: map.name, trailing: {
            Menu {
                Button("General MIDI") { setMap(.generalMIDI) }
                ForEach(app.prefs.savedDrumMaps, id: \.id) { m in Button(m.name) { setMap(m) } }
                Divider()
                Button("Save This Map…") { saveMap(map) }
                Button("Use as Default for New Files") { saveDefault(map) }
                Button("Import Map…") { importMap() }
                Button("Export Map…") { exportMap(map) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
        }) {
            if !unmapped.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(GC.Palette.warning)
                    Text("\(unmapped.count) note number\(unmapped.count == 1 ? " isn't" : "s aren't") in the map (\(unmapped.map(String.init).joined(separator: ", "))). They're treated as “Other”. Give them a drum below so they're humanised correctly.")
                        .font(GC.Font.caption).foregroundStyle(GC.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Notes used in this file. Not every file or drum plug-in follows General MIDI, so check that each note plays the right drum.")
                .font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
            ForEach(used, id: \.self) { pitch in
                MapRow(app: app, pitch: pitch, entry: map.entry(for: pitch), count: doc.pattern.notes.filter { $0.pitch == pitch }.count)
            }
        }
    }

    private func setMap(_ m: DrumMap) {
        app.mutate { d in d.change("Drum Map \(m.name)") { $0.drumMap = m } }
    }

    private func saveMap(_ map: DrumMap) {
        let alert = NSAlert()
        alert.messageText = "Save drum map"
        let field = NSTextField(string: map.isFactory ? "My Drum Map" : map.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var m = map
        m.id = "user.\(UUID().uuidString)"
        m.name = field.stringValue.isEmpty ? "My Drum Map" : field.stringValue
        m.isFactory = false
        app.prefs.savedDrumMaps.append(m)
        setMap(m)
    }

    private func saveDefault(_ map: DrumMap) {
        var m = map
        m.id = "user.default"
        m.isFactory = false
        app.prefs.savedDrumMaps.removeAll { $0.id == "user.default" }
        app.prefs.savedDrumMaps.append(m)
        app.show(Toast(text: "New files will use this drum map", symbol: "square.grid.3x3"))
    }

    private func exportMap(_ map: DrumMap) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = map.name + ".gcdrummap"
        panel.begin { r in
            guard r == .OK, let url = panel.url else { return }
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? e.encode(map).write(to: url)
        }
    }

    private func importMap() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gcdrummap") ?? .json, .json]
        panel.begin { r in
            guard r == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            Task { @MainActor in
                do {
                    var m = try TolerantJSON.decode(DrumMap.self, from: data, defaults: DrumMap(name: url.deletingPathExtension().lastPathComponent, entries: []))
                    m.id = "user.\(UUID().uuidString)"
                    m.isFactory = false
                    app.prefs.savedDrumMaps.append(m)
                    setMap(m)
                } catch {
                    app.alert = AppAlert(title: "Couldn't import the drum map", message: error.localizedDescription)
                }
            }
        }
    }
}

struct MapRow: View {
    @ObservedObject var app: AppState
    let pitch: Int
    let entry: DrumMapEntry?
    let count: Int
    @State private var name = ""

    var body: some View {
        HStack(spacing: GC.Space.s) {
            Button {
                app.audition(pitch: pitch)
            } label: {
                Text("\(pitch)")
                    .font(GC.Font.value)
                    .frame(width: 30, height: 22)
                    .background(RoundedRectangle(cornerRadius: 4).fill(GC.Palette.control))
            }
            .buttonStyle(.plain)
            .help("\(MIDINoteName.name(pitch)) · \(count) notes. Click to hear it.")
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .font(GC.Font.control)
                .onSubmit(commitName)
                .onAppear { name = entry?.name ?? "" }
                .onChange(of: entry?.name ?? "") { _, newValue in name = newValue }
            Picker("", selection: Binding(get: { entry?.category ?? .other }, set: { cat in
                var e = entry ?? DrumMapEntry(note: pitch, name: name.isEmpty ? cat.displayName : name, category: cat)
                e.category = cat
                if entry == nil || e.name.isEmpty { e.name = cat.displayName }
                app.mutate { d in d.change("Map Note \(pitch)") { $0.drumMap.set(e); $0.drumMap.name = $0.drumMap.isFactory ? "Custom" : $0.drumMap.name; $0.drumMap.isFactory = false } }
            })) {
                ForEach(DrumCategory.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(width: 118)
            if entry == nil {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(GC.Palette.warning)
                    .help("Not in the map")
            }
        }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != entry?.name else { return }
        let e = DrumMapEntry(note: pitch, name: trimmed, category: entry?.category ?? DrumMap.guessCategory(note: pitch))
        app.mutate { d in d.change("Rename Drum") { $0.drumMap.set(e); $0.drumMap.isFactory = false } }
    }
}
