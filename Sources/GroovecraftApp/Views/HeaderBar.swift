import SwiftUI
import GrooveCore

struct HeaderBar: View {
    @ObservedObject var app: AppState
    @ObservedObject var transport: TransportController

    var body: some View {
        HStack(spacing: GC.Space.m) {
            Wordmark()
                .padding(.leading, 78)   // room for the window's traffic lights (hidden title bar)
            Rectangle().fill(GC.Palette.hairline).frame(width: 1, height: 22)
            fileInfo
            Spacer(minLength: GC.Space.m)
            if app.hasDocument {
                undoRedo
                comparison
                humaniseButton
                Button {
                    app.exportSelected()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(GCButtonStyle(kind: .secondary))
                .help("Export the selected take as a MIDI file (⌘E)")
            } else {
                Button("Open MIDI…") { app.openMIDIPanel() }
                    .buttonStyle(GCButtonStyle(kind: .secondary))
            }
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(GC.Palette.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .padding(.trailing, GC.Space.m)
        }
        .frame(height: GC.Size.headerHeight)
        .background(
            LinearGradient(colors: [GC.Palette.surfaceRaised, GC.Palette.surface], startPoint: .top, endPoint: .bottom)
        )
        .hairline(.bottom)
    }

    private var fileInfo: some View {
        HStack(spacing: GC.Space.s) {
            if let doc = app.document {
                Image(systemName: "pianokeys")
                    .foregroundStyle(GC.Palette.textTertiary)
                    .font(.system(size: 12))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(doc.midiName)
                            .font(GC.Font.heading)
                            .lineLimit(1)
                        Circle()
                            .fill(doc.isDirty ? GC.Palette.accent : GC.Palette.success)
                            .frame(width: 6, height: 6)
                            .help(doc.isDirty ? "Unsaved changes" : "Saved")
                            .accessibilityLabel(doc.isDirty ? "Unsaved changes" : "Saved")
                    }
                    Text(summary(doc))
                        .font(GC.Font.caption)
                        .foregroundStyle(GC.Palette.textTertiary)
                        .lineLimit(1)
                }
            } else {
                Text(GC.Brand.tagline)
                    .font(GC.Font.caption)
                    .foregroundStyle(GC.Palette.textTertiary)
            }
        }
    }

    private func summary(_ doc: GrooveDocument) -> String {
        let a = doc.analysis
        var parts = [String(format: "%.1f BPM", a.initialBPM), a.signature.label, "\(a.bars) bars", "\(a.noteCount) notes"]
        if let b = doc.backingName { parts.append("♪ " + b) }
        return parts.joined(separator: " · ")
    }

    private var undoRedo: some View {
        HStack(spacing: 2) {
            IconButton(systemName: "arrow.uturn.backward", help: undoHelp) { app.mutate { $0.undo() } }
                .disabled(!(app.document?.history.canUndo ?? false))
            IconButton(systemName: "arrow.uturn.forward", help: redoHelp) { app.mutate { $0.redo() } }
                .disabled(!(app.document?.history.canRedo ?? false))
        }
    }

    private var undoHelp: String {
        if let n = app.document?.history.undoName { return "Undo \(n) (⌘Z)" }
        return "Undo (⌘Z)"
    }

    private var redoHelp: String {
        if let n = app.document?.history.redoName { return "Redo \(n) (⇧⌘Z)" }
        return "Redo (⇧⌘Z)"
    }

    /// A/B: what's selected (A) and what it's compared with (B).
    private var comparison: some View {
        let doc = app.document
        let a = doc?.selectedVariation?.name ?? "Original"
        let bID = doc?.state.compareVariationID
        let b = bID.flatMap { doc?.variation($0)?.name } ?? "Original"
        let canCompare = (doc?.state.variations.isEmpty == false)
        return HStack(spacing: 0) {
            abLabel("A", a, active: true)
            Button {
                app.mutate { $0.toggleAB() }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(canCompare ? GC.Palette.accent : GC.Palette.textDisabled)
            .disabled(!canCompare)
            .help("Swap A and B (⌥⌘B). Works while playing: the switch is seamless.")
            abLabel("B", b, active: false)
        }
        .padding(.horizontal, 4)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: GC.Radius.m).fill(GC.Palette.background.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: GC.Radius.m).stroke(GC.Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Compare: A is \(a), B is \(b)")
    }

    private func abLabel(_ letter: String, _ name: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Text(letter)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(active ? Color(hex: 0x1B1308) : GC.Palette.textSecondary)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(active ? GC.Palette.accent : GC.Palette.control))
            Text(name)
                .font(GC.Font.control)
                .foregroundStyle(active ? GC.Palette.textPrimary : GC.Palette.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: 110, alignment: .leading)
        }
        .padding(.horizontal, 6)
    }

    private var humaniseButton: some View {
        Button {
            app.humanise()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .symbolEffect(.bounce, value: app.isHumanising)
                Text("Humanise")
            }
        }
        .buttonStyle(GCButtonStyle(kind: .primary, large: true))
        .keyboardShortcut(.return, modifiers: .command)
        .help("Create a new humanised take with the current settings (⌘↩)")
    }
}

struct TransportBar: View {
    @ObservedObject var app: AppState
    @ObservedObject var transport: TransportController

    var body: some View {
        HStack(spacing: GC.Space.m) {
            HStack(spacing: 4) {
                IconButton(systemName: "backward.end.fill", help: "Return to start (↩ Home)") { transport.rewind() }
                Button {
                    transport.togglePlay()
                } label: {
                    Image(systemName: transport.isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(transport.isPlaying ? Color(hex: 0x1B1308) : GC.Palette.textPrimary)
                        .frame(width: 34, height: 28)
                        .background(RoundedRectangle(cornerRadius: GC.Radius.m).fill(transport.isPlaying ? GC.Palette.accent : GC.Palette.control))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(transport.isPlaying ? "Stop (Space)" : "Play (Space)")
                .accessibilityLabel(transport.isPlaying ? "Stop" : "Play")
                IconButton(systemName: "repeat", help: "Loop (L). Drag in the bar ruler to set the loop.", isActive: transport.loopEnabled) {
                    transport.toggleLoop()
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(transport.positionDisplay)
                    .font(GC.Font.musical)
                    .foregroundStyle(transport.isPlaying ? GC.Palette.accentBright : GC.Palette.textPrimary)
                    .monospacedDigit()
                Text(transport.timeDisplay)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(GC.Palette.textTertiary)
            }
            .frame(width: 84, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Position \(transport.positionDisplay)")

            tempoInfo

            Rectangle().fill(GC.Palette.hairline).frame(width: 1, height: 20)
            playingInfo
            Spacer(minLength: 8)
            outputInfo
            Rectangle().fill(GC.Palette.hairline).frame(width: 1, height: 20)
            viewOptions
        }
        .padding(.horizontal, GC.Space.m)
        .frame(height: GC.Size.transportHeight)
        .background(GC.Palette.surface)
        .hairline(.bottom)
    }

    private var tempoInfo: some View {
        let doc = app.document
        let midiBPM = doc?.tempoMap.initialBPM ?? 120
        let stretch = doc?.state.alignment.stretch ?? 1
        return VStack(alignment: .leading, spacing: 0) {
            Text(String(format: "%.1f BPM", midiBPM / stretch))
                .font(GC.Font.value)
            if let b = doc?.backing {
                Text(String(format: "track %.1f", b.tempo.bpm))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(b.tempo.isReliable ? GC.Palette.textTertiary : GC.Palette.warning)
            } else if doc?.tempoMap.hasTempoChanges == true {
                Text("tempo map").font(.system(size: 10)).foregroundStyle(GC.Palette.textTertiary)
            }
        }
        .help("Playback tempo. The backing track's detected tempo is shown underneath.")
    }

    private var playingInfo: some View {
        let name = app.document?.selectedVariation?.name ?? "Original"
        return HStack(spacing: 6) {
            Circle()
                .fill(app.document?.state.selectedVariationID == nil ? GC.Palette.reference : GC.Palette.accent)
                .frame(width: 7, height: 7)
            Text(name)
                .font(GC.Font.control)
                .lineLimit(1)
            if let bars = app.document?.state.processBars {
                ValueBadge(text: "bars \(bars.lowerBound + 1)–\(bars.upperBound + 1)", color: GC.Palette.warning)
                    .help("Only these bars are humanised. Right-click the grid ▸ Humanise All Bars to clear.")
            }
        }
    }

    private var outputInfo: some View {
        let status = app.outputStatus
        return Button {
            app.inspectorTab = .output
        } label: {
            HStack(spacing: 6) {
                ActivityLED(isOn: status.connected, color: GC.Palette.success)
                ActivityLED(isOn: app.midiActivity, color: GC.Palette.accent)
                Text(status.text)
                    .font(GC.Font.caption)
                    .foregroundStyle(GC.Palette.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: 170, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .help("MIDI output: connection (green) and activity (amber). Click for output settings.")
    }

    private var viewOptions: some View {
        HStack(spacing: 2) {
            IconButton(systemName: "square.on.square.dashed", help: "Show original positions and changes", isActive: app.prefs.showOriginalGhosts) {
                app.prefs.showOriginalGhosts.toggle()
            }
            IconButton(systemName: "squareshape.split.3x3", help: "Snap edits to 16ths (hold ⌘ while dragging to snap once)", isActive: app.prefs.snapToGrid) {
                app.prefs.snapToGrid.toggle()
            }
            IconButton(systemName: "minus.magnifyingglass", help: "Zoom out (⌘−)") { app.pixelsPerBeat = max(6, app.pixelsPerBeat / 1.4) }
            IconButton(systemName: "plus.magnifyingglass", help: "Zoom in (⌘+)") { app.pixelsPerBeat = min(400, app.pixelsPerBeat * 1.4) }
        }
    }
}
