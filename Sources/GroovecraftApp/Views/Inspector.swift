import SwiftUI
import GrooveCore

struct Inspector: View {
    @ObservedObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(InspectorTab.allCases) { tab in
                    InspectorTabButton(tab: tab, isSelected: app.inspectorTab == tab) {
                        withAnimation(MotionPreference.animation(GC.Motion.panel)) { app.inspectorTab = tab }
                    }
                }
            }
            .padding(.horizontal, GC.Space.s)
            .padding(.vertical, 6)
            .background(GC.Palette.surface)
            .hairline(.bottom)

            ScrollView {
                VStack(spacing: 0) {
                    switch app.inspectorTab {
                    case .perform: PerformPanel(app: app)
                    case .listen: TrackPanel(app: app)
                    case .drums: DrumsPanel(app: app)
                    case .output: OutputPanel(app: app)
                    }
                }
                .padding(.bottom, GC.Space.xl)
            }
            .scrollIndicators(.automatic)
        }
        .background(GC.Palette.surface)
    }
}

struct InspectorTabButton: View {
    let tab: InspectorTab
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol).font(.system(size: 12, weight: .medium))
                Text(tab.title).font(GC.Font.micro)
            }
            .foregroundStyle(isSelected ? GC.Palette.accent : (hovering ? GC.Palette.textPrimary : GC.Palette.textSecondary))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: GC.Radius.m).fill(isSelected ? GC.Palette.control : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Perform

struct PerformPanel: View {
    @ObservedObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                GCSegmented(options: [(ControlMode.quick, "Quick"), (ControlMode.advanced, "Advanced")],
                            selection: app.undoableBinding(\.mode, "Switch Mode", live: false))
            }
            .padding(GC.Space.m)
            if app.state.mode == .quick {
                QuickPanel(app: app)
                    .transition(.opacity)
            } else {
                AdvancedPanel(app: app)
                    .transition(.opacity)
            }
        }
        .animation(MotionPreference.animation(GC.Motion.standard), value: app.state.mode)
    }
}

struct QuickPanel: View {
    @ObservedObject var app: AppState
    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        let q = app.state.quick
        let style = app.presets.first { $0.id == q.styleID }
        let canListen = app.document?.backing != nil || !(app.document?.state.sections.isEmpty ?? true)
        VStack(alignment: .leading, spacing: 0) {
            PanelSection("Style", subtitle: style?.name) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(FactoryPresets.all) { p in
                        Chip(label: shortName(p.name), detail: p.summary, isSelected: q.styleID == p.id) {
                            app.mutate { d in d.change("Style \(p.name)") { $0.quick.styleID = p.id } }
                            app.liveUpdate()
                        }
                    }
                }
                if let s = style {
                    Text(s.summary)
                        .font(GC.Font.caption)
                        .foregroundStyle(GC.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            divider
            PanelSection("Feel", subtitle: q.feel.hint) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(Feel.allCases) { f in
                        Chip(label: f.displayName, detail: f.hint, isSelected: q.feel == f) {
                            app.mutate { d in d.change("Feel \(f.displayName)") { $0.quick.feel = f } }
                            app.liveUpdate()
                        }
                    }
                }
            }
            divider
            PanelSection("Performance") {
                Grid(horizontalSpacing: 10, verticalSpacing: 16) {
                    GridRow {
                        knob("Humanise", \.quick.humanise, "How human the whole performance feels. Scales timing, dynamics and phrasing together, musically.")
                        knob("Groove", \.quick.groove, "How strongly the style's groove and swing shape the part.")
                        knob("Timing", \.quick.timing, "How loose the timing is. Low is tight; high is a live, wandering feel.")
                    }
                    GridRow {
                        knob("Velocity", \.quick.velocity, "How much the dynamics vary: accents, hand patterns, phrase swells.")
                        knob("Variation", \.quick.variation, "How much the playing changes from phrase to phrase, including optional ghost notes and flams.")
                        knob("Listen", \.quick.listen, canListen ? "How much the drummer responds to the backing track and song sections." : "Add a backing track or section markers to use this.")
                            .opacity(canListen ? 1 : 0.4)
                            .disabled(!canListen)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            divider
            PanelSection("Make it") {
                Button {
                    app.humanise()
                } label: {
                    Label("Humanise", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(GCButtonStyle(kind: .primary, large: true))
                HStack(spacing: 6) {
                    Button("New Take, Same Seed") { app.mutate { $0.rehumaniseKeepingSeed() } }
                        .buttonStyle(GCButtonStyle(kind: .secondary))
                        .help("Re-run the selected take with the current controls, keeping its random seed, as a new take.")
                    Button("Reset") { app.mutate { $0.resetControls() }; app.liveUpdate() }
                        .buttonStyle(GCButtonStyle(kind: .ghost))
                        .help("Reset the controls to the style's defaults")
                }
                Text("Changes apply to the selected take as you let go of a control. Humanise always adds a new take.")
                    .font(GC.Font.caption)
                    .foregroundStyle(GC.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var divider: some View { Rectangle().fill(GC.Palette.hairline).frame(height: 1) }

    private func shortName(_ s: String) -> String {
        s.replacingOccurrences(of: " Performance", with: "").replacingOccurrences(of: " Pocket", with: "")
    }

    private func knob(_ label: String, _ kp: WritableKeyPath<ProjectState, Double>, _ help: String) -> some View {
        GCKnob(label: label, value: app.binding(kp), defaultValue: 0.5, help: help,
               onBegin: { app.beginEdit(label) }, onEnd: { app.endEdit() })
    }
}

// MARK: - Advanced

struct AdvancedPanel: View {
    @ObservedObject var app: AppState
    @AppStorage("adv.timing") private var timingOpen = true
    @AppStorage("adv.velocity") private var velocityOpen = true
    @AppStorage("adv.groove") private var grooveOpen = false
    @AppStorage("adv.random") private var randomOpen = false
    @AppStorage("adv.artic") private var articulationOpen = false
    @AppStorage("adv.drums") private var drumsOpen = false
    @State private var family: DrumFamily = .kick

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            presetPicker
            Rectangle().fill(GC.Palette.hairline).frame(height: 1)
            DisclosureSection(title: "Timing", symbol: "metronome", isExpanded: $timingOpen) { timing }
            DisclosureSection(title: "Velocity & Dynamics", symbol: "speaker.wave.2", isExpanded: $velocityOpen) { velocity }
            DisclosureSection(title: "Groove & Swing", symbol: "waveform.path", isExpanded: $grooveOpen) { groove }
            DisclosureSection(title: "Randomisation", symbol: "dice", isExpanded: $randomOpen) { randomisation }
            DisclosureSection(title: "Articulation", symbol: "music.note.list", isExpanded: $articulationOpen) { articulation }
            DisclosureSection(title: "Individual Drums", symbol: "square.grid.3x3", isExpanded: $drumsOpen) { drums }
            PanelSection("Make it") {
                Button { app.humanise() } label: { Label("Humanise", systemImage: "sparkles").frame(maxWidth: .infinity) }
                    .buttonStyle(GCButtonStyle(kind: .primary, large: true))
                HStack {
                    Button("New Take, Same Seed") { app.mutate { $0.rehumaniseKeepingSeed() } }
                        .buttonStyle(GCButtonStyle(kind: .secondary))
                    Button("Reset to Preset") { app.mutate { $0.resetControls() }; app.liveUpdate() }
                        .buttonStyle(GCButtonStyle(kind: .ghost))
                }
            }
        }
    }

    private var presetPicker: some View {
        PanelSection("Starting point") {
            Menu {
                ForEach(app.presets) { p in
                    Button(p.name) { app.applyPreset(p) }
                }
            } label: {
                HStack {
                    Text(app.presets.first { $0.id == app.state.presetID }?.name ?? "Custom")
                        .font(GC.Font.control)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                }
                .padding(.horizontal, 10)
                .frame(height: GC.Size.controlHeight)
                .background(RoundedRectangle(cornerRadius: GC.Radius.m).fill(GC.Palette.control))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            Text("Advanced mode edits every engine parameter directly. Values start from the chosen preset.")
                .font(GC.Font.caption)
                .foregroundStyle(GC.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Slider helper bound into `advanced`.
    private func slider(_ label: String, _ kp: WritableKeyPath<HumaniseSettings, Double>, _ range: ClosedRange<Double>,
                        _ def: Double, _ format: @escaping (Double) -> String, _ help: String) -> some View {
        let full: WritableKeyPath<ProjectState, Double> = (\ProjectState.advanced).appending(path: kp)
        return GCSlider(label: label, value: app.binding(full), range: range, defaultValue: def, format: format, help: help,
                        onBegin: { app.beginEdit(label) }, onEnd: { app.endEdit() })
    }

    private func toggle(_ label: String, _ kp: WritableKeyPath<HumaniseSettings, Bool>, _ help: String) -> some View {
        let full: WritableKeyPath<ProjectState, Bool> = (\ProjectState.advanced).appending(path: kp)
        return Toggle(label, isOn: app.undoableBinding(full, label)).toggleStyle(GCSwitchStyle()).help(help)
    }

    @ViewBuilder private var timing: some View {
        Group {
        slider("Variation", \.timing.variation, 0 ... 1.5, 0.6, Fmt.percent, "Random timing spread. 100% is about a good session drummer (±8 ms).")
        slider("Maximum deviation", \.timing.maxDeviationMs, 2 ... 60, 22, Fmt.ms, "No hit moves further than this from its original place (swing and groove come on top).")
        slider("Early / late bias", \.timing.biasMs, -20 ... 20, 0, Fmt.signedMs, "Moves the whole kit ahead of (−) or behind (+) the beat.")
        slider("Tightness", \.timing.tightness, 0 ... 1, 0.5, Fmt.percent, "Reduces spread, most on the main beats.")
        slider("Microtiming", \.timing.microtiming, 0 ... 1, 0.5, Fmt.percent, "Each drum's small constant tendency, like a real player's personality.")
        slider("Tempo drift", \.timing.drift, 0 ... 1, 0.35, Fmt.percent, "Slow push and pull of the whole kit across bars.")
        }
        Group {
        slider("Keep existing timing", \.timing.preserveExisting, 0 ... 1, 0.7, Fmt.percent, "If the MIDI was played in, keep its timing and add less.")
        slider("Beat position influence", \.timing.beatPositionInfluence, 0 ... 1, 0.6, Fmt.percent, "Downbeats steadier than off-beats and 16ths.")
        slider("Velocity influence", \.timing.velocityInfluence, 0 ... 1, 0.3, Fmt.percent, "Harder hits land slightly earlier.")
        slider("Phrase influence", \.timing.phraseInfluence, 0 ... 1, 0.4, Fmt.percent, "Fills push forward and land back on the downbeat.")
        }
    }

    @ViewBuilder private var velocity: some View {
        Group {
        slider("Variation", \.velocity.variation, 0 ... 1.5, 0.6, Fmt.percent, "Random dynamic variation. 100% is about ±7 velocity.")
        slider("Dynamic range", \.velocity.range, 0.5 ... 1.6, 1, Fmt.factor, "Compress (below ×1) or expand (above ×1) each drum's dynamics.")
        slider("Level", \.velocity.bias, -30 ... 30, 0, Fmt.signed, "Overall velocity offset.")
        slider("Accents", \.velocity.accentIntensity, 0 ... 1, 0.5, Fmt.percent, "Strength of accents on strong beats.")
        slider("Beat-position dynamics", \.velocity.beatPositionVariation, 0 ... 1, 0.5, Fmt.percent, "Strong beats louder, weak beats softer.")
        slider("Phrase dynamics", \.velocity.phraseDynamics, 0 ... 1, 0.4, Fmt.percent, "Slow swells and fall-backs across phrases.")
        }
        Group {
        slider("Repetition (hand patterns)", \.velocity.repetitionVariation, 0 ... 1, 0.6, Fmt.percent, "Repeated hits alternate like real hands instead of machine-gunning.")
        slider("Ghost-note level", \.velocity.ghostLevel, 0.5 ... 1.5, 1, Fmt.factor, "Level of the part's own ghost notes.")
        toggle("Protect ghost notes", \.velocity.protectGhosts, "Ghost notes never become inaudible or as loud as the main hits.")
        HStack {
            Text("Velocity curve").font(GC.Font.control).foregroundStyle(GC.Palette.textSecondary)
            Spacer()
            Picker("", selection: app.undoableBinding(\.advanced.velocity.curve, "Velocity Curve")) {
                ForEach(VelocityCurve.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)
        }
        HStack(spacing: GC.Space.m) {
            Stepper(value: app.undoableBinding(\.advanced.velocity.minimum, "Minimum Velocity"), in: 1 ... 126) {
                Text("Min \(app.state.advanced.velocity.minimum)").font(GC.Font.value)
            }
            Stepper(value: app.undoableBinding(\.advanced.velocity.maximum, "Maximum Velocity"), in: 2 ... 127) {
                Text("Max \(app.state.advanced.velocity.maximum)").font(GC.Font.value)
            }
        }
        Stepper(value: app.undoableBinding(\.advanced.velocity.maxChange, "Largest Change"), in: 1 ... 80) {
            Text("Largest change ±\(app.state.advanced.velocity.maxChange)").font(GC.Font.value)
        }
        .help("No note's velocity changes by more than this from the original.")
        }
    }

    @ViewBuilder private var groove: some View {
        Group {
        HStack {
            Text("Template").font(GC.Font.control).foregroundStyle(GC.Palette.textSecondary)
            Spacer()
            Picker("", selection: app.undoableBinding(\.advanced.groove.templateID, "Groove Template")) {
                Text("None").tag(String?.none)
                ForEach(GrooveTemplate.factory) { t in Text(t.name).tag(Optional(t.id)) }
            }
            .labelsHidden()
            .frame(width: 170)
        }
        if let custom = app.state.advanced.groove.customTemplate {
            HStack {
                ValueBadge(text: "Using \(custom.name)", color: GC.Palette.accent)
                Spacer()
                Button("Remove") { app.mutate { d in d.change("Remove Groove") { $0.advanced.groove.customTemplate = nil } }; app.liveUpdate() }
                    .buttonStyle(GCButtonStyle(kind: .ghost))
            }
        }
        Button("Extract Groove from a MIDI File…") { extractGroove() }
            .buttonStyle(GCButtonStyle(kind: .secondary))
            .help("Groove transfer: take the timing and accents of a played MIDI performance and apply them here.")
        }
        Group {
        slider("Groove intensity", \.groove.intensity, 0 ... 1, 0.6, Fmt.percent, "How strongly the template is applied.")
        slider("Swing", \.groove.swing, 0 ... 1, 0, Fmt.swing, "50% is straight, 66% a triplet shuffle, 75% a hard shuffle.")
        HStack {
            Text("Swing on").font(GC.Font.control).foregroundStyle(GC.Palette.textSecondary)
            Spacer()
            GCSegmented(options: [(SwingSubdivision.eighth, "8ths"), (SwingSubdivision.sixteenth, "16ths")],
                        selection: app.undoableBinding(\.advanced.groove.swingSubdivision, "Swing Subdivision"), compact: true)
                .frame(width: 120)
        }
        slider("Push / pull", \.groove.pushPull, -1 ... 1, 0, Fmt.pushPull, "Ahead of the beat (urgent) or behind it (laid back). Strongest on the backbeat.")
        slider("Keep the part's own groove", \.groove.preserveExisting, 0 ... 1, 0.8, Fmt.percent, "If the MIDI already swings, don't swing it twice.")
        slider("Beat emphasis", \.groove.beatEmphasis, 0 ... 1, 0.4, Fmt.percent, "Extra weight on the beats.")
        slider("Off-beat emphasis", \.groove.offbeatEmphasis, 0 ... 1, 0.1, Fmt.percent, "Extra weight on the 'and's (disco hats, reggae skanks).")
        }
    }

    @ViewBuilder private var randomisation: some View {
        slider("Intensity", \.intensity, 0 ... 1.5, 1, Fmt.percent, "Master amount for all random variation.")
        slider("Smoothness", \.correlation, 0 ... 1, 0.55, Fmt.percent, "0% = every hit independent; higher = a player's slowly wandering feel.")
        slider("Per-drum difference", \.perDrumVariation, 0 ... 1, 0.5, Fmt.percent, "How differently each drum behaves.")
        slider("Phrase variation", \.phraseVariation, 0 ... 1, 0.4, Fmt.percent, "How much the feel changes from phrase to phrase.")
        HStack {
            Text("Next seed").font(GC.Font.control).foregroundStyle(GC.Palette.textSecondary)
            Spacer()
            Text(String(app.state.nextSeed)).font(GC.Font.value).textSelection(.enabled)
            Button("New") {
                app.mutate { d in d.change("New Seed") { $0.nextSeed = UInt64.random(in: 1 ... 0xFFFF_FFFF_FFFF) } }
            }
            .buttonStyle(GCButtonStyle(kind: .ghost))
        }
        Text("The same seed and settings always give the same take, so results are repeatable.")
            .font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var articulation: some View {
        toggle("Allow added notes", \.articulation.allowAddedNotes, "Lets Groovecraft add ghost notes, flams, drags and rolls. Added notes are marked and can be left out of exports.")
        Group {
            slider("Ghost notes", \.articulation.addGhostNotes, 0 ... 1, 0, Fmt.percent, "Adds quiet snare notes around the backbeat.")
            slider("Flams", \.articulation.flams, 0 ... 1, 0, Fmt.percent, "Grace notes before accented snares in fills and phrase ends.")
            slider("Drags", \.articulation.drags, 0 ... 1, 0, Fmt.percent, "Two grace notes before snare accents late in fills.")
            slider("Rolls", \.articulation.rolls, 0 ... 1, 0, Fmt.percent, "Fills consecutive 16th snares in fills with 32nds.")
            slider("Hi-hat openings", \.articulation.hihatOpenings, 0 ... 1, 0, Fmt.percent, "Opens the last off-beat hat of a phrase now and then (the next hat closes it).")
        }
        .disabled(!app.state.advanced.articulation.allowAddedNotes)
        .opacity(app.state.advanced.articulation.allowAddedNotes ? 1 : 0.45)
        slider("Hi-hat accents", \.articulation.hihatAccents, 0 ... 1, 0.5, Fmt.percent, "Quarter-note lift in the hi-hat and ride pattern.")
        slider("Fill build", \.articulation.fillBuild, 0 ... 1, 0.5, Fmt.percent, "Fills grow in energy towards their end.")
        slider("Phrase-end accent", \.articulation.phraseEndAccent, 0 ... 1, 0.4, Fmt.percent, "Accents the downbeat a fill lands on.")
        slider("Note length variation", \.articulation.lengthVariation, 0 ... 1, 0.3, Fmt.percent, "Varies note lengths (matters for hi-hat and cymbal chokes in some instruments).")
    }

    @ViewBuilder private var drums: some View {
        Picker("", selection: $family) {
            ForEach(DrumFamily.allCases.filter { $0 != .other }) { f in Text(f.displayName).tag(f) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        DrumControls(app: app, family: family)
    }

    private func extractGroove() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.midi]
        panel.message = "Choose a played (not quantised) drum MIDI file to take its groove"
        panel.begin { r in
            guard r == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let midi = try MIDIParser.parse(contentsOf: url)
                    let pattern = DrumPattern.extract(from: midi, source: DrumPattern.detectSource(in: midi))
                    guard let tpl = GrooveTemplate.extract(from: pattern, name: url.deletingPathExtension().lastPathComponent) else {
                        app.alert = AppAlert(title: "Not enough notes", message: "That file doesn't have enough drum notes to take a groove from.")
                        return
                    }
                    app.mutate { d in d.change("Use Groove \(tpl.name)") { $0.advanced.groove.customTemplate = tpl; $0.advanced.groove.intensity = max($0.advanced.groove.intensity, 0.7) } }
                    app.liveUpdate()
                    app.show(Toast(text: "Using the groove of \(tpl.name)", symbol: "waveform.path"))
                } catch {
                    app.alert = AppAlert(title: "Couldn't read the MIDI file", message: error.localizedDescription)
                }
            }
        }
    }
}

struct DrumControls: View {
    @ObservedObject var app: AppState
    let family: DrumFamily

    private func binding(_ kp: WritableKeyPath<DrumSettings, Double>) -> Binding<Double> {
        Binding(
            get: { app.state.advanced.drum(family)[keyPath: kp] },
            set: { v in
                app.mutate { d in d.changeWithoutUndo { s in
                    var drum = s.advanced.drum(family)
                    drum[keyPath: kp] = v
                    s.advanced.setDrum(family, drum)
                } }
            })
    }

    private func slider(_ label: String, _ kp: WritableKeyPath<DrumSettings, Double>, _ range: ClosedRange<Double>,
                        _ def: Double, _ format: @escaping (Double) -> String, _ help: String) -> some View {
        GCSlider(label: label, value: binding(kp), range: range, defaultValue: def, format: format, help: help,
                 onBegin: { app.beginEdit("\(family.displayName) \(label)") }, onEnd: { app.endEdit() })
    }

    private var specialLabel: (String, String) {
        switch family {
        case .kick: return ("Bass interaction", "How strongly the kick follows bass attacks (needs a backing track and Kick ↔ Bass Lock).")
        case .snare: return ("Backbeat emphasis", "Confidence of the snare on 2 and 4.")
        case .hihat: return ("Swing & hand feel", "How much the hats lean into the swing and alternate hands.")
        case .cymbal: return ("Phrase variation", "How much cymbal dynamics change with phrases.")
        case .tom: return ("Fill behaviour", "How much toms build through fills.")
        case .percussion, .other: return ("Groove follow", "How closely percussion follows the groove.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GC.Space.m) {
            slider("Timing variation", \.timing, 0 ... 2, 1, Fmt.factor, "Scales the timing variation for \(family.displayName.lowercased()).")
            slider("Velocity variation", \.velocity, 0 ... 2, 1, Fmt.factor, "Scales the velocity variation for \(family.displayName.lowercased()).")
            slider("Tightness", \.tightness, 0 ... 1, 0.5, Fmt.percent, "How locked-in this drum is.")
            slider("Accents", \.accent, 0 ... 1, 0.5, Fmt.percent, "Accent behaviour on strong beats.")
            slider("Groove position", \.offsetMs, -15 ... 15, 0, Fmt.signedMs, "Constant offset: ahead (−) or behind (+) the beat.")
            slider(specialLabel.0, \.special, 0 ... 1, 0.5, Fmt.percent, specialLabel.1)
            if family == .snare {
                slider("Ghost-note handling", \.ghostHandling, 0 ... 1, 0.5, Fmt.percent, "How much ghost notes may vary.")
            }
        }
    }
}
