import SwiftUI
import UniformTypeIdentifiers
import GrooveCore

struct Sidebar: View {
    @ObservedObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            GCSegmented(options: [(SidebarTab.takes, "Takes"), (SidebarTab.presets, "Presets")], selection: $app.sidebarTab)
                .padding(GC.Space.m)
            Rectangle().fill(GC.Palette.hairline).frame(height: 1)
            switch app.sidebarTab {
            case .takes: TakesList(app: app)
            case .presets: PresetBrowser(app: app)
            }
        }
        .background(GC.Palette.surface)
    }
}

// MARK: - Takes

struct TakesList: View {
    @ObservedObject var app: AppState
    @State private var renaming: UUID?
    @State private var renameText = ""

    var body: some View {
        let doc = app.document
        let selected = doc?.state.selectedVariationID
        let compare = doc?.state.compareVariationID
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    TakeRow(title: "Original", subtitle: "As imported · never changed", stats: nil,
                            isSelected: selected == nil, badge: badge(nil, selected, compare), isFavourite: false,
                            isEdited: false, onSelect: { app.mutate { $0.select(nil) } }, onFavourite: nil)
                    ForEach((doc?.state.variations ?? []).reversed()) { v in
                        TakeRow(title: v.name, subtitle: v.presetName, stats: v.stats, isSelected: selected == v.id,
                                badge: badge(v.id, selected, compare), isFavourite: v.isFavourite, isEdited: v.isEdited,
                                onSelect: { app.mutate { $0.select(v.id) } },
                                onFavourite: { app.mutate { $0.toggleFavourite(v.id) } })
                            .contextMenu {
                                Button("Rename…") { renameText = v.name; renaming = v.id }
                                Button(v.isFavourite ? "Remove from Favourites" : "Mark as Favourite") { app.mutate { $0.toggleFavourite(v.id) } }
                                Button("Compare with Selected (B)") { app.mutate { d in d.changeWithoutUndo { $0.compareVariationID = v.id } } }
                                Divider()
                                Button("Export…") {
                                    app.mutate { $0.select(v.id) }
                                    app.exportSelected()
                                }
                                Divider()
                                Button("Delete", role: .destructive) { app.mutate { $0.delete(v.id) } }
                            }
                    }
                }
                .padding(GC.Space.s)
            }
            if (doc?.state.variations.isEmpty ?? true) {
                VStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 18)).foregroundStyle(GC.Palette.accent)
                    Text("Press Humanise to make your first take.")
                        .font(GC.Font.caption)
                        .foregroundStyle(GC.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                    Text("Every take is kept. The original never changes.")
                        .font(GC.Font.caption)
                        .foregroundStyle(GC.Palette.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(GC.Space.l)
            }
            Spacer(minLength: 0)
            Rectangle().fill(GC.Palette.hairline).frame(height: 1)
            VStack(spacing: GC.Space.s) {
                Button {
                    app.humanise(count: 4)
                } label: {
                    Label("Generate 4 Variations", systemImage: "square.stack.3d.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GCButtonStyle(kind: .secondary))
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .help("Four new takes with different seeds (⇧⌘↩)")
                HStack(spacing: GC.Space.s) {
                    Button("Export All…") { app.exportAllTakes() }
                        .buttonStyle(GCButtonStyle(kind: .ghost))
                        .disabled(doc?.state.variations.isEmpty ?? true)
                    Spacer()
                    Button("Clear") { confirmClear() }
                        .buttonStyle(GCButtonStyle(kind: .ghost))
                        .disabled(doc?.state.variations.isEmpty ?? true)
                        .help("Remove every take that isn't a favourite (undoable)")
                }
            }
            .padding(GC.Space.m)
        }
        .sheet(item: Binding(get: { renaming.map { RenameTarget(id: $0) } }, set: { renaming = $0?.id })) { target in
            RenameSheet(title: "Rename Take", text: $renameText) {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { app.mutate { $0.rename(target.id, to: name) } }
                renaming = nil
            } onCancel: { renaming = nil }
        }
    }

    private func badge(_ id: UUID?, _ selected: UUID?, _ compare: UUID?) -> String? {
        if id == selected { return "A" }
        if id == compare { return "B" }
        return nil
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear takes that aren't favourites?"
        alert.informativeText = "Favourites are kept. You can undo this."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { app.mutate { $0.clearUnfavourited() } }
    }
}

struct RenameTarget: Identifiable { let id: UUID }

struct TakeRow: View {
    let title: String
    let subtitle: String
    let stats: Performance.Stats?
    let isSelected: Bool
    let badge: String?
    let isFavourite: Bool
    let isEdited: Bool
    let onSelect: () -> Void
    let onFavourite: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: GC.Space.s) {
            Text(badge ?? "")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(badge == "A" ? Color(hex: 0x1B1308) : GC.Palette.textSecondary)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(badge == "A" ? GC.Palette.accent : (badge == "B" ? GC.Palette.controlPressed : Color.clear)))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(GC.Font.heading)
                        .foregroundStyle(isSelected ? GC.Palette.textPrimary : GC.Palette.textSecondary)
                    if isEdited {
                        Image(systemName: "pencil").font(.system(size: 9)).foregroundStyle(GC.Palette.textTertiary)
                            .help("Edited by hand")
                    }
                }
                Text(subtitle)
                    .font(GC.Font.caption)
                    .foregroundStyle(GC.Palette.textTertiary)
                    .lineLimit(1)
                if let s = stats {
                    HStack(spacing: 8) {
                        Label(String(format: "±%.1f ms", s.meanTimingShiftMs), systemImage: "metronome")
                        Label(String(format: "±%.0f vel", s.meanVelocityChange), systemImage: "speaker.wave.2")
                        if s.addedNotes > 0 { Text("+\(s.addedNotes)") }
                    }
                    .labelStyle(CompactLabelStyle())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(GC.Palette.textTertiary)
                }
            }
            Spacer(minLength: 0)
            if let fav = onFavourite {
                Button(action: fav) {
                    Image(systemName: isFavourite ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundStyle(isFavourite ? GC.Palette.accent : GC.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .opacity(isFavourite || hovering ? 1 : 0)
                .help(isFavourite ? "Favourite" : "Mark as favourite")
                .accessibilityLabel(isFavourite ? "Remove favourite" : "Mark as favourite")
            }
        }
        .padding(.horizontal, GC.Space.s)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: GC.Radius.m)
                .fill(isSelected ? GC.Palette.selection : (hovering ? GC.Palette.control.opacity(0.6) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GC.Radius.m)
                .stroke(isSelected ? GC.Palette.accent.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .animation(MotionPreference.animation(GC.Motion.quick), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { onSelect() }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 8.5))
            configuration.title
        }
    }
}

struct RenameSheet: View {
    let title: String
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GC.Space.m) {
            Text(title).font(GC.Font.title)
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(onSave)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save", action: onSave).keyboardShortcut(.defaultAction)
            }
        }
        .padding(GC.Space.xl)
        .background(GC.Palette.surfaceRaised)
    }
}

// MARK: - Presets

struct PresetBrowser: View {
    @ObservedObject var app: AppState
    @State private var search = ""
    @State private var category: String? = nil
    @State private var favouritesOnly = false
    @State private var savingName = ""
    @State private var showSave = false
    @State private var renameTarget: Preset?
    @State private var renameText = ""

    private var categories: [String] {
        var seen: [String] = []
        for p in app.presets where !seen.contains(p.category) { seen.append(p.category) }
        return seen
    }

    private var filtered: [Preset] {
        app.presets.filter { p in
            if let c = category, p.category != c { return false }
            if favouritesOnly && !app.prefs.favouritePresets.contains(p.id) { return false }
            if search.isEmpty { return true }
            return p.name.localizedCaseInsensitiveContains(search) || p.summary.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        let current = app.state.mode == .quick ? app.state.quick.styleID : app.state.presetID
        VStack(spacing: 0) {
            VStack(spacing: GC.Space.s) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(GC.Palette.textTertiary).font(.system(size: 11))
                    TextField("Search presets", text: $search)
                        .textFieldStyle(.plain)
                        .font(GC.Font.body)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: GC.Radius.m).fill(GC.Palette.background))
                .overlay(RoundedRectangle(cornerRadius: GC.Radius.m).stroke(GC.Palette.hairline, lineWidth: 1))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        Chip(label: "All", isSelected: category == nil && !favouritesOnly) { category = nil; favouritesOnly = false }
                        Chip(label: "★", detail: "Favourites", isSelected: favouritesOnly) { favouritesOnly.toggle() }
                        ForEach(categories, id: \.self) { c in
                            Chip(label: c, isSelected: category == c) { category = category == c ? nil : c }
                        }
                    }
                }
            }
            .padding(GC.Space.m)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered) { p in
                        PresetRow(preset: p, isCurrent: p.id == current, isFavourite: app.prefs.favouritePresets.contains(p.id),
                                  onSelect: { app.applyPreset(p) },
                                  onFavourite: {
                                      if app.prefs.favouritePresets.contains(p.id) { app.prefs.favouritePresets.remove(p.id) }
                                      else { app.prefs.favouritePresets.insert(p.id) }
                                  })
                        .contextMenu { presetMenu(p) }
                    }
                    if filtered.isEmpty {
                        Text("No presets match.")
                            .font(GC.Font.caption)
                            .foregroundStyle(GC.Palette.textTertiary)
                            .padding()
                    }
                }
                .padding(GC.Space.s)
            }
            Rectangle().fill(GC.Palette.hairline).frame(height: 1)
            HStack(spacing: GC.Space.s) {
                Button {
                    savingName = ""
                    showSave = true
                } label: { Label("Save Current…", systemImage: "plus") }
                    .buttonStyle(GCButtonStyle(kind: .secondary))
                    .help("Save the current controls as a new preset")
                Spacer()
                Button { importPreset() } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(GCButtonStyle(kind: .ghost))
                    .help("Import a preset file")
            }
            .padding(GC.Space.m)
        }
        .sheet(isPresented: $showSave) {
            RenameSheet(title: "Save Preset", text: $savingName) {
                let name = savingName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { app.savePresetFromCurrent(name: name, category: "User") }
                showSave = false
            } onCancel: { showSave = false }
        }
        .sheet(item: $renameTarget) { p in
            RenameSheet(title: "Rename Preset", text: $renameText) {
                try? app.presetStore.rename(p, to: renameText)
                app.reloadPresets()
                renameTarget = nil
            } onCancel: { renameTarget = nil }
        }
    }

    @ViewBuilder private func presetMenu(_ p: Preset) -> some View {
        Button("Use Preset") { app.applyPreset(p) }
        Button("Duplicate") { _ = try? app.presetStore.duplicate(p); app.reloadPresets() }
        Button("Export…") { exportPreset(p) }
        if !p.isFactory {
            Button("Rename…") { renameText = p.name; renameTarget = p }
            Divider()
            Button("Delete", role: .destructive) {
                let a = NSAlert()
                a.messageText = "Delete preset “\(p.name)”?"
                a.addButton(withTitle: "Delete")
                a.addButton(withTitle: "Cancel")
                if a.runModal() == .alertFirstButtonReturn { try? app.presetStore.delete(p); app.reloadPresets() }
            }
        }
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gcpreset") ?? .json, .json]
        panel.begin { r in
            guard r == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let p = try app.presetStore.importPreset(from: url)
                    app.reloadPresets()
                    app.show(Toast(text: "Imported preset \(p.name)", symbol: "square.and.arrow.down"))
                } catch {
                    app.alert = AppAlert(title: "Couldn't import the preset", message: error.localizedDescription)
                }
            }
        }
    }

    private func exportPreset(_ p: Preset) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = p.name + ".gcpreset"
        panel.begin { r in
            guard r == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try app.presetStore.export(p, to: url) } catch {
                    app.alert = AppAlert(title: "Couldn't export the preset", message: error.localizedDescription)
                }
            }
        }
    }
}

struct PresetRow: View {
    let preset: Preset
    let isCurrent: Bool
    let isFavourite: Bool
    let onSelect: () -> Void
    let onFavourite: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: GC.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(preset.name)
                        .font(GC.Font.heading)
                        .foregroundStyle(isCurrent ? GC.Palette.accent : GC.Palette.textPrimary)
                    Text(preset.category)
                        .font(GC.Font.micro)
                        .foregroundStyle(GC.Palette.textTertiary)
                }
                Text(preset.summary)
                    .font(GC.Font.caption)
                    .foregroundStyle(GC.Palette.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onFavourite) {
                Image(systemName: isFavourite ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(isFavourite ? GC.Palette.accent : GC.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .opacity(isFavourite || hovering ? 1 : 0)
            .accessibilityLabel(isFavourite ? "Remove favourite" : "Mark as favourite")
        }
        .padding(.horizontal, GC.Space.s)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: GC.Radius.m).fill(isCurrent ? GC.Palette.selection : (hovering ? GC.Palette.control.opacity(0.6) : Color.clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(preset.summary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { onSelect() }
    }
}
