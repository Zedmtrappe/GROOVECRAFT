import SwiftUI
import GrooveCore

struct OutputPanel: View {
    @ObservedObject var app: AppState
    @State private var remapFrom = 36
    @State private var remapTo = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            external
            divider
            timing
            divider
            mappingSection
            divider
            preview
            divider
            PanelSection("Help") {
                Button {
                    app.showLogicGuide = true
                } label: { Label("Logic Pro Setup Guide", systemImage: "questionmark.circle").frame(maxWidth: .infinity) }
                    .buttonStyle(GCButtonStyle(kind: .secondary))
                Button(role: .destructive) {
                    app.panic()
                } label: { Label("Panic: All Notes Off", systemImage: "exclamationmark.octagon").frame(maxWidth: .infinity) }
                    .buttonStyle(GCButtonStyle(kind: .danger))
                    .help("Stops playback and sends All Notes Off on every channel (⌥⌘.)")
            }
        }
    }

    private var divider: some View { Rectangle().fill(GC.Palette.hairline).frame(height: 1) }

    // MARK: External instrument

    private var external: some View {
        let status = app.outputStatus
        return PanelSection("External instrument", trailing: {
            HStack(spacing: 5) {
                ActivityLED(isOn: status.connected, color: GC.Palette.success)
                ActivityLED(isOn: app.midiActivity, color: GC.Palette.accent)
            }
        }) {
            Toggle("Send MIDI to my drum instrument", isOn: app.pref(\.externalEnabled)).toggleStyle(GCSwitchStyle())
                .help("Play the performance through Superior Drummer, EZdrummer, Slate, Kontakt or any MIDI drum instrument.")
            VStack(alignment: .leading, spacing: 4) {
                Text("Send to").font(GC.Font.control).foregroundStyle(GC.Palette.textSecondary)
                routeRow(title: "Groovecraft (virtual port)", subtitle: app.midi.hasVirtualSource ? "Recommended. Logic lists it as an input called “Groovecraft”." : "Unavailable on this Mac. Use the IAC Driver.",
                         isOn: app.prefs.route == .virtualSource, enabled: app.midi.hasVirtualSource) {
                    app.prefs.route = .virtualSource
                }
                ForEach(app.destinations) { d in
                    routeRow(title: d.name, subtitle: d.isIAC ? "IAC Driver bus" : (d.isOffline ? "Offline" : "MIDI destination"),
                             isOn: app.prefs.route == .destination(uniqueID: d.id), enabled: !d.isOffline) {
                        app.prefs.route = .destination(uniqueID: d.id)
                    }
                }
                if !app.destinations.contains(where: { $0.isIAC }) {
                    Text("No IAC bus found. To use one: Audio MIDI Setup ▸ Window ▸ Show MIDI Studio ▸ IAC Driver ▸ “Device is online”.")
                        .font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                Button("Refresh") { app.refreshDestinations() }
                    .buttonStyle(GCButtonStyle(kind: .ghost))
            }
            HStack {
                Text("Channel").font(GC.Font.control).foregroundStyle(GC.Palette.textSecondary)
                Spacer()
                Picker("", selection: app.pref(\.output.channel)) {
                    Text("Keep original").tag(Int?.none)
                    ForEach(0 ..< 16, id: \.self) { c in Text("\(c + 1)\(c == 9 ? " (drums)" : "")").tag(Optional(c)) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Test").font(GC.Font.control).foregroundStyle(GC.Palette.textSecondary)
                HStack(spacing: 6) {
                    ForEach([DrumCategory.kick, .snare, .closedHat, .crash, .ride], id: \.self) { c in
                        Button(c == .closedHat ? "Hat" : c.displayName) { app.sendTestNote(category: c) }
                            .buttonStyle(GCButtonStyle(kind: .secondary))
                    }
                }
            }
        }
    }

    private func routeRow(title: String, subtitle: String, isOn: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: GC.Space.s) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isOn ? GC.Palette.accent : GC.Palette.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(GC.Font.control).foregroundStyle(GC.Palette.textPrimary)
                    Text(subtitle).font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: GC.Radius.m).fill(isOn ? GC.Palette.selection : GC.Palette.control.opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: Timing

    private var timing: some View {
        PanelSection("Timing & sync") {
            GCSlider(label: "Latency compensation", value: app.pref(\.output.latencyMs), range: 0 ... 250, defaultValue: 0,
                     format: Fmt.ms, help: "Sends MIDI this much earlier than the backing audio, to make up for the drum instrument's own latency (Logic's buffer size).")
            GCSlider(label: "Start offset", value: app.pref(\.output.startOffsetMs), range: -100 ... 100, defaultValue: 0,
                     format: Fmt.signedMs, help: "Moves the MIDI relative to the backing track while auditioning.")
            GCSlider(label: "Velocity scale", value: app.pref(\.output.velocityScale), range: 0.5 ... 1.5, defaultValue: 1,
                     format: Fmt.factor, help: "For instruments that respond hotter or softer than expected.")
            Toggle("Send MIDI clock", isOn: app.pref(\.output.sendClock)).toggleStyle(GCSwitchStyle())
                .help("24 pulses per quarter note at the playback tempo.")
            Toggle("Send Start / Stop / Song Position", isOn: app.pref(\.output.sendTransport)).toggleStyle(GCSwitchStyle())
            Toggle("Precise timestamps", isOn: app.pref(\.preciseTimestamps)).toggleStyle(GCSwitchStyle())
                .help("Hands CoreMIDI exact future timestamps (recommended). Turn off only if an app ignores timestamps.")
            Text("Clock and transport are standard MIDI messages. Logic Pro doesn't follow external MIDI clock, so they're mainly for other apps and hardware. Groovecraft can't start Logic's transport; see the setup guide for recording.")
                .font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Note remapping

    private var mappingSection: some View {
        let remap = app.prefs.output.noteMap.remap
        return PanelSection("Note remapping", subtitle: remap.isEmpty ? "Notes sent unchanged" : "\(remap.count) note\(remap.count == 1 ? "" : "s") remapped") {
            Text("If your drum instrument uses a different layout, send a note to another number. Applies to auditioning only; exports keep your mapping.")
                .font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
            ForEach(remap.keys.sorted(), id: \.self) { from in
                HStack {
                    Text("\(from) \(MIDINoteName.name(from))").font(GC.Font.value)
                    Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(GC.Palette.textTertiary)
                    Text("\(remap[from] ?? from) \(MIDINoteName.name(remap[from] ?? from))").font(GC.Font.value)
                    Spacer()
                    Button { app.prefs.output.noteMap.remap.removeValue(forKey: from) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                        .buttonStyle(.plain).foregroundStyle(GC.Palette.textTertiary)
                }
            }
            HStack(spacing: 6) {
                Stepper("\(remapFrom)", value: $remapFrom, in: 0 ... 127).font(GC.Font.value)
                Image(systemName: "arrow.right").font(.system(size: 9))
                Stepper("\(remapTo)", value: $remapTo, in: 0 ... 127).font(GC.Font.value)
                Button("Add") {
                    app.prefs.output.noteMap.remap[remapFrom] = remapTo
                    app.prefs.output.noteMap.name = "Custom"
                }
                .buttonStyle(GCButtonStyle(kind: .secondary))
            }
            HStack {
                Menu("Saved Maps") {
                    Button("None (unchanged)") { app.prefs.output.noteMap = .identity }
                    ForEach(app.prefs.savedOutputMaps, id: \.self) { m in Button(m.name) { app.prefs.output.noteMap = m } }
                    Divider()
                    Button("Save Current…") { saveOutputMap() }
                        .disabled(remap.isEmpty)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 120)
                Spacer()
            }
        }
    }

    private func saveOutputMap() {
        let alert = NSAlert()
        alert.messageText = "Name this note remapping"
        let field = NSTextField(string: "My Instrument")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var m = app.prefs.output.noteMap
        m.name = field.stringValue.isEmpty ? "My Instrument" : field.stringValue
        app.prefs.savedOutputMaps.removeAll { $0.name == m.name }
        app.prefs.savedOutputMaps.append(m)
        app.prefs.output.noteMap = m
    }

    // MARK: Internal preview

    private var preview: some View {
        PanelSection("Built-in preview") {
            Toggle("Preview drum kit", isOn: app.pref(\.previewKitEnabled)).toggleStyle(GCSwitchStyle())
                .help("A simple synthesised kit for checking feel when no drum instrument is connected.")
            GCSlider(label: "Kit volume", value: app.pref(\.previewVolume), range: 0 ... 1, defaultValue: 0.8, format: Fmt.percent)
                .disabled(!app.prefs.previewKitEnabled)
                .opacity(app.prefs.previewKitEnabled ? 1 : 0.5)
            GCSlider(label: "Backing volume", value: app.pref(\.backingVolume), range: 0 ... 1, defaultValue: 0.8, format: Fmt.percent)
            Text("The preview kit is synthesised by Groovecraft (no samples). For realistic sound, use your own drum instrument through MIDI.")
                .font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
