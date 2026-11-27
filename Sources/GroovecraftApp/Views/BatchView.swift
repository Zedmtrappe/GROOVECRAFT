import SwiftUI
import UniformTypeIdentifiers
import GrooveCore

@MainActor
final class BatchModel: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        var url: URL
        var include = true
        var status: Status = .pending
        var outputs: [URL] = []
        enum Status: Equatable { case pending, working, done, failed(String) }
    }

    @Published var items: [Item] = []
    @Published var presetID = FactoryPresets.naturalDrummer.id
    @Published var variations = 1
    @Published var naming = ExportNaming.defaultPattern
    @Published var overwrite = false
    @Published var outputFolder: URL?
    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var seed: UInt64 = 1

    func add(_ urls: [URL]) {
        for u in urls where ["mid", "midi", "smf", "kar"].contains(u.pathExtension.lowercased()) {
            if !items.contains(where: { $0.url == u }) { items.append(Item(url: u)) }
        }
        if outputFolder == nil, let first = urls.first {
            outputFolder = first.deletingLastPathComponent().appendingPathComponent("Groovecraft", isDirectory: true)
        }
    }

    func run(presets: [Preset]) {
        guard let folder = outputFolder, !isRunning else { return }
        let preset = presets.first { $0.id == presetID } ?? FactoryPresets.naturalDrummer
        var settings = preset.settings
        settings.seed = seed
        let options = BatchProcessor.Options(settings: settings, presetName: preset.name, outputFolder: folder,
                                             namingPattern: naming, overwrite: overwrite, variationsPerFile: variations)
        let work = items.enumerated().filter { $0.element.include }.map { ($0.offset, $0.element.url) }
        guard !work.isEmpty else { return }
        isRunning = true
        progress = 0
        for (i, _) in work { items[i].status = .pending; items[i].outputs = [] }
        Task.detached(priority: .userInitiated) {
            var done = 0
            for (index, url) in work {
                await MainActor.run { self.items[index].status = .working }
                let result = BatchProcessor.process(url, options: options)
                done += 1
                let finished = done
                await MainActor.run {
                    if let e = result.error { self.items[index].status = .failed(e) } else { self.items[index].status = .done }
                    self.items[index].outputs = result.outputs
                    self.progress = Double(finished) / Double(work.count)
                }
            }
            await MainActor.run { self.isRunning = false }
        }
    }

    var summary: String {
        let done = items.filter { $0.status == .done }.count
        let failed = items.filter { if case .failed = $0.status { return true }; return false }.count
        if done + failed == 0 { return "\(items.filter(\.include).count) file\(items.count == 1 ? "" : "s") ready" }
        return "\(done) done" + (failed > 0 ? " · \(failed) failed" : "")
    }
}

struct BatchView: View {
    @ObservedObject var app: AppState
    @StateObject private var model = BatchModel()
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Batch Processing").font(GC.Font.title)
                Spacer()
                Text(model.summary).font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary)
            }
            .padding(GC.Space.l)
            Rectangle().fill(GC.Palette.hairline).frame(height: 1)
            HStack(spacing: 0) {
                fileList
                Rectangle().fill(GC.Palette.hairline).frame(width: 1)
                options.frame(width: 300)
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .background(GC.Palette.surface)
        .preferredColorScheme(.dark)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.add([url]) } }
                }
            }
            return true
        }
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 30)).foregroundStyle(targeted ? GC.Palette.accent : GC.Palette.textTertiary)
                    Text("Drop drum MIDI files here").font(GC.Font.heading)
                    Text("Every file is processed with the same preset. Originals are never changed.")
                        .font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary)
                    Button("Add Files…") { addFiles() }.buttonStyle(GCButtonStyle(kind: .secondary))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach($model.items) { $item in
                        HStack(spacing: GC.Space.s) {
                            Toggle("", isOn: $item.include).toggleStyle(.checkbox).labelsHidden()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.url.lastPathComponent).font(GC.Font.control)
                                statusText(item)
                            }
                            Spacer()
                            if !item.outputs.isEmpty {
                                Button { NSWorkspace.shared.activateFileViewerSelecting(item.outputs) } label: { Image(systemName: "magnifyingglass") }
                                    .buttonStyle(.plain)
                                    .help("Show in Finder")
                            }
                        }
                    }
                    .onDelete { model.items.remove(atOffsets: $0) }
                }
                .scrollContentBackground(.hidden)
                HStack {
                    Button("Add Files…") { addFiles() }.buttonStyle(GCButtonStyle(kind: .ghost))
                    Button("Remove Unticked") { model.items.removeAll { !$0.include } }.buttonStyle(GCButtonStyle(kind: .ghost))
                    Spacer()
                    Button("Clear") { model.items.removeAll() }.buttonStyle(GCButtonStyle(kind: .ghost)).disabled(model.isRunning)
                }
                .padding(GC.Space.s)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func statusText(_ item: BatchModel.Item) -> some View {
        switch item.status {
        case .pending: Text("Waiting").font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary)
        case .working: Text("Processing…").font(GC.Font.caption).foregroundStyle(GC.Palette.accent)
        case .done: Text("Done · \(item.outputs.map(\.lastPathComponent).joined(separator: ", "))").font(GC.Font.caption).foregroundStyle(GC.Palette.success).lineLimit(1)
        case .failed(let e): Text(e).font(GC.Font.caption).foregroundStyle(GC.Palette.danger).lineLimit(2)
        }
    }

    private var options: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PanelSection("Preset") {
                    Picker("", selection: $model.presetID) {
                        ForEach(app.presets) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    Stepper("Takes per file: \(model.variations)", value: $model.variations, in: 1 ... 8)
                        .font(GC.Font.control)
                    HStack {
                        Text("Seed").font(GC.Font.control).foregroundStyle(GC.Palette.textSecondary)
                        Spacer()
                        Text(String(model.seed)).font(GC.Font.value)
                        Button("New") { model.seed = UInt64.random(in: 1 ... 0xFFFF_FFFF) }.buttonStyle(GCButtonStyle(kind: .ghost))
                    }
                }
                PanelSection("Output") {
                    Button {
                        chooseFolder()
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text(model.outputFolder?.path ?? "Choose a folder…").lineLimit(1).truncationMode(.head)
                            Spacer()
                        }
                    }
                    .buttonStyle(GCButtonStyle(kind: .secondary))
                    TextField("Naming", text: $model.naming)
                        .textFieldStyle(.roundedBorder)
                        .font(GC.Font.value)
                    Text("{name} = file name, {preset} = preset, {n} = take number")
                        .font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary)
                    Toggle("Overwrite files with the same name", isOn: $model.overwrite).toggleStyle(GCSwitchStyle())
                        .help("Off: a number is added instead (e.g. “… 2.mid”). Your original files are never overwritten either way.")
                }
                PanelSection("Run") {
                    if model.isRunning {
                        ProgressView(value: model.progress).tint(GC.Palette.accent)
                    }
                    Button {
                        model.run(presets: app.presets)
                    } label: { Label("Process \(model.items.filter(\.include).count) Files", systemImage: "gearshape.2").frame(maxWidth: .infinity) }
                        .buttonStyle(GCButtonStyle(kind: .primary, large: true))
                        .disabled(model.isRunning || model.outputFolder == nil || !model.items.contains(where: \.include))
                    if let folder = model.outputFolder, model.items.contains(where: { $0.status == .done }) {
                        Button("Show Output Folder") { NSWorkspace.shared.open(folder) }
                            .buttonStyle(GCButtonStyle(kind: .ghost))
                    }
                }
            }
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.midi]
        panel.allowsMultipleSelection = true
        panel.begin { r in
            guard r == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in model.add(urls) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.begin { r in
            guard r == .OK, let url = panel.url else { return }
            Task { @MainActor in model.outputFolder = url }
        }
    }
}
