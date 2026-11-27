import SwiftUI
import GrooveCore

struct TrackPanel: View {
    @ObservedObject var app: AppState

    var body: some View {
        let doc = app.document
        VStack(alignment: .leading, spacing: 0) {
            backingCard(doc)
            divider
            if let b = doc?.backing {
                alignment(doc!, b)
                divider
            }
            trackAware(doc)
            divider
            sections(doc)
            divider
            analysis(doc)
        }
    }

    private var divider: some View { Rectangle().fill(GC.Palette.hairline).frame(height: 1) }

    // MARK: Backing

    @ViewBuilder private func backingCard(_ doc: GrooveDocument?) -> some View {
        PanelSection("Backing track") {
            if let b = doc?.backing {
                HStack(spacing: GC.Space.s) {
                    Image(systemName: "waveform").foregroundStyle(GC.Palette.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(doc?.backingName ?? "Backing").font(GC.Font.heading).lineLimit(1)
                        Text(app.backingFormat ?? "Analysis only (audio file not found)")
                            .font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary).lineLimit(1)
                    }
                    Spacer()
                    Menu {
                        Button("Replace…") { app.importBackingPanel() }
                        Button("Re-analyse") { if let u = app.backingURL { app.importBacking(u) } }
                            .disabled(app.backingURL == nil)
                        Divider()
                        Button("Remove", role: .destructive) { app.removeBacking() }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 24)
                }
                HStack(spacing: GC.Space.l) {
                    stat("Tempo", String(format: "%.1f", b.tempo.bpm), reliable: b.tempo.isReliable)
                    stat("Beats", "\(b.beats.count)", reliable: b.tempo.isReliable)
                    stat("Length", String(format: "%d:%02d", Int(b.duration) / 60, Int(b.duration) % 60), reliable: true)
                }
                Toggle("Hear the backing track", isOn: app.pref(\.backingAudible)).toggleStyle(GCSwitchStyle())
                if let mismatch = doc?.tempoMismatch, abs((doc?.state.alignment.stretch ?? 1) - mismatch.suggestedStretch) > 0.0005 {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(GC.Palette.warning)
                        Text(String(format: "The MIDI is %.1f BPM but the track sounds like %.1f BPM.", mismatch.midi, mismatch.audio))
                            .font(GC.Font.caption).foregroundStyle(GC.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Play the MIDI at the Track's Tempo") {
                        app.mutate { d in d.change("Match Tempo") { $0.alignment.stretch = mismatch.suggestedStretch } }
                        app.mutate { _ = $0.autoAlign() }
                    }
                    .buttonStyle(GCButtonStyle(kind: .secondary))
                    .help("Stretches the MIDI timing to the track's tempo for playback and analysis. Exported MIDI keeps the file's own tempo.")
                }
            } else {
                VStack(alignment: .leading, spacing: GC.Space.s) {
                    Text("Add the rest of the song (ideally everything except drums) and the drummer will listen to it: kick locks with the bass, dynamics follow the energy, sections get their own feel.")
                        .font(GC.Font.caption)
                        .foregroundStyle(GC.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        app.importBackingPanel()
                    } label: { Label("Add Backing Track…", systemImage: "waveform.badge.plus").frame(maxWidth: .infinity) }
                        .buttonStyle(GCButtonStyle(kind: .secondary, large: true))
                    Text("WAV, AIFF, FLAC, MP3, M4A/AAC, ALAC or CAF. The file is only read, never changed.")
                        .font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String, reliable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(GC.Font.section).foregroundStyle(GC.Palette.textTertiary)
            HStack(spacing: 4) {
                Text(value).font(GC.Font.musical)
                if !reliable {
                    Image(systemName: "questionmark.circle").font(.system(size: 10)).foregroundStyle(GC.Palette.warning)
                        .help("Low confidence: check it by ear.")
                }
            }
        }
    }

    // MARK: Alignment

    @ViewBuilder private func alignment(_ doc: GrooveDocument, _ b: BackingAnalysis) -> some View {
        PanelSection("Alignment", trailing: {
            if doc.state.alignment.isAutomatic, let c = app.alignmentConfidence {
                ConfidenceTag(reliable: c > 0.25)
            }
        }) {
            HStack(spacing: GC.Space.s) {
                Text("Audio offset").font(GC.Font.control).foregroundStyle(GC.Palette.textSecondary)
                Spacer()
                nudge("−10", -0.010)
                nudge("−1", -0.001)
                Text(String(format: "%+.3f s", doc.state.alignment.offsetSeconds))
                    .font(GC.Font.value)
                    .frame(width: 70)
                    .accessibilityLabel(String(format: "Audio offset %.3f seconds", doc.state.alignment.offsetSeconds))
                nudge("+1", 0.001)
                nudge("+10", 0.010)
            }
            Text("Where bar 1 of the MIDI falls in the audio. Drag the waveform in the timeline to adjust by eye; ±1 ms buttons for fine work.")
                .font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: GC.Space.s) {
                Button("Auto-Align") {
                    var conf: Double?
                    app.mutate { conf = $0.autoAlign()?.confidence }
                    app.alignmentConfidence = conf
                    app.transport.restartFromCurrentPosition()
                }
                .buttonStyle(GCButtonStyle(kind: .secondary))
                .help("Lines the kick and snare up with the track's attacks.")
                Button("Snap to First Beat") {
                    let first = b.firstDownbeat ?? 0
                    app.mutate { d in d.change("Align to First Beat") { $0.alignment.offsetSeconds = (first * 1000).rounded() / 1000; $0.alignment.isAutomatic = false } }
                }
                .buttonStyle(GCButtonStyle(kind: .ghost))
                Button("Reset") {
                    app.mutate { d in d.change("Reset Alignment") { $0.alignment = Alignment() } }
                }
                .buttonStyle(GCButtonStyle(kind: .ghost))
            }
            if abs(doc.state.alignment.stretch - 1) > 0.0001 {
                HStack {
                    Text(String(format: "MIDI follows the track tempo (×%.4f)", doc.state.alignment.stretch))
                        .font(GC.Font.caption).foregroundStyle(GC.Palette.textSecondary)
                    Spacer()
                    Button("Undo Stretch") { app.mutate { d in d.change("Remove Tempo Match") { $0.alignment.stretch = 1 } } }
                        .buttonStyle(GCButtonStyle(kind: .ghost))
                }
            }
        }
    }

    private func nudge(_ label: String, _ delta: Double) -> some View {
        Button(label) {
            app.mutate { d in d.change("Nudge Alignment") { s in
                s.alignment.offsetSeconds = ((s.alignment.offsetSeconds + delta) * 1000).rounded() / 1000
                s.alignment.isAutomatic = false
            } }
            app.transport.restartFromCurrentPosition()
        }
        .buttonStyle(GCButtonStyle(kind: .ghost))
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .help("Move the audio \(label) ms")
    }

    // MARK: Track-aware

    @ViewBuilder private func trackAware(_ doc: GrooveDocument?) -> some View {
        let hasContext = doc?.backing != nil || !(doc?.state.sections.isEmpty ?? true)
        PanelSection("Track-Aware Humanisation") {
            Toggle("Listen to the song", isOn: app.undoableBinding(\.useTrackAware, "Track-Aware")).toggleStyle(GCSwitchStyle())
                .help("Use the backing track and section markers to shape the performance.")
            if !hasContext {
                Text("Add a backing track or section markers to use these controls. Without them, Groovecraft humanises from the MIDI alone.")
                    .font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            if app.state.mode == .quick {
                GCSlider(label: "Listen amount", value: app.binding(\.quick.listen), defaultValue: 0.6, format: Fmt.percent,
                         help: "How much the drummer responds to the band. Switch to Advanced for each control.",
                         onBegin: { app.beginEdit("Listen") }, onEnd: { app.endEdit() })
                Text("Quick mode uses balanced settings for the details below. Switch to Advanced to set each one.")
                    .font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                Group {
                    ta("Band interaction", \.bandInteraction, 0.7, Fmt.percent, "Master amount for everything below.")
                    ta("Kick ↔ Bass lock", \.kickBassLock, 0.5, Fmt.lockLabel, "Loose: ignore the bass. Natural: lean towards bass attacks. Tight: lock kick hits to them (without quantising the rest).")
                    ta("Groove match", \.grooveMatch, 0.4, Fmt.percent, "Borrow the band's own micro-timing feel.")
                    ta("Energy response", \.energyResponse, 0.5, Fmt.percent, "Louder passages → stronger hits and cymbals; quiet passages → softer.")
                    ta("Section awareness", \.sectionAwareness, 0.5, Fmt.percent, "Verses restrained, choruses confident, breakdowns spacious. Varies a little per section so it isn't formulaic.")
                }
                Group {
                    ta("Arrangement sensitivity", \.arrangementSensitivity, 0.4, Fmt.percent, "Busy arrangement → tighter, simpler drums; sparse → more nuance.")
                    ta("Phrase awareness", \.phraseAwareness, 0.5, Fmt.percent, "Builds into section changes and accents the new section's first downbeat.")
                    ta("Vocal space", \.vocalSpace, 0.4, Fmt.percent, "Holds back added notes and cymbals where the vocal-like range is busy (an estimate).")
                }
            }
        }
        .disabled(!hasContext && app.state.mode == .advanced)
    }

    private func ta(_ label: String, _ kp: WritableKeyPath<TrackAwareSettings, Double>, _ def: Double,
                    _ format: @escaping (Double) -> String, _ help: String) -> some View {
        let full: WritableKeyPath<ProjectState, Double> = (\ProjectState.advanced.trackAware).appending(path: kp)
        return GCSlider(label: label, value: app.binding(full), defaultValue: def, format: format, help: help,
                        onBegin: { app.beginEdit(label) }, onEnd: { app.endEdit() })
    }

    // MARK: Sections

    @ViewBuilder private func sections(_ doc: GrooveDocument?) -> some View {
        PanelSection("Sections", trailing: {
            Menu {
                ForEach(SectionKind.allCases.filter { $0 != .unknown }) { kind in
                    Button(kind.displayName) { addMarker(kind) }
                }
            } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
                .help("Add a section marker at the playhead")
        }) {
            let markers = doc?.state.sections ?? []
            if markers.isEmpty {
                Text("Mark verses, choruses and breakdowns so each gets its own feel. Double-click the Sections lane in the timeline, or detect them from the backing track.")
                    .font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(markers) { m in
                HStack(spacing: GC.Space.s) {
                    Text("Bar \(m.bar + 1)").font(GC.Font.value).foregroundStyle(GC.Palette.textSecondary).frame(width: 54, alignment: .leading)
                    Picker("", selection: Binding(get: { m.kind }, set: { k in
                        var u = m
                        if u.label == u.kind.displayName { u.label = k.displayName }
                        u.kind = k
                        app.mutate { $0.updateSection(u) }
                        app.liveUpdate()
                    })) {
                        ForEach(SectionKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    if m.isEstimate { ValueBadge(text: "est.", color: GC.Palette.warning).help("Estimated from the audio") }
                    Spacer()
                    Button { app.mutate { $0.removeSection(m.id) } } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(GC.Palette.textTertiary)
                        .help("Remove marker")
                }
            }
            if doc?.backing != nil {
                Button("Detect Sections from Backing Track") { app.mutate { $0.applyEstimatedSections() }; app.liveUpdate() }
                    .buttonStyle(GCButtonStyle(kind: .secondary))
                Text("Detected sections are estimates (marked “est.” and “?”). Relabel or move them as needed.")
                    .font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func addMarker(_ kind: SectionKind) {
        guard let doc = app.document else { return }
        let tick = app.transport.tick(atSong: app.transport.position)
        let bar = doc.tempoMap.position(atTick: max(0, tick)).bar
        app.mutate { $0.addSection(SectionMarker(bar: bar, kind: kind)) }
        app.liveUpdate()
    }

    // MARK: Analysis

    @ViewBuilder private func analysis(_ doc: GrooveDocument?) -> some View {
        if let doc {
            let a = doc.analysis
            PanelSection("MIDI analysis") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("Tempo", a.hasTempoChanges ? String(format: "%.1f BPM (changes)", a.initialBPM) : String(format: "%.1f BPM", a.initialBPM))
                    row("Time signature", a.signature.label)
                    row("Length", String(format: "%d bars · %.0f beats · %d:%02d", a.bars, a.lengthBeats, Int(a.durationSeconds) / 60, Int(a.durationSeconds) % 60))
                    row("Notes", "\(a.noteCount) on \(doc.pattern.drumTracks.count) track\(doc.pattern.drumTracks.count == 1 ? "" : "s") (of \(doc.midi.tracks.count))")
                    row("Density", String(format: "%.1f notes per bar", a.notesPerBar))
                    row("Grid", a.grid.displayName + (a.swingRatio > 0.53 ? String(format: ", swung %.0f%%", a.swingRatio * 100) : ""))
                    row("Feel", a.isQuantised ? "Quantised" : String(format: "Played (±%.1f ms)", a.meanGridDeviationMs))
                    row("Dynamics", a.isFlatVelocity ? "Flat velocities" : "Varied velocities")
                    row("Ghost notes", "\(a.ghostNoteIDs.count)")
                    row("Structure", a.structureSummary)
                }
            }
            if let b = doc.backing {
                divider
                PanelSection("Track analysis") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        row("Tempo", String(format: "%.1f BPM · %.0f%% confidence", b.tempo.bpm, b.tempo.confidence * 100))
                        if !b.tempo.alternatives.isEmpty {
                            row("Could also be", b.tempo.alternatives.prefix(3).map { String(format: "%.1f", $0) }.joined(separator: ", "))
                        }
                        row("Bass attacks", "\(b.bassOnsets.count)")
                        row("Onsets", "\(b.onsets.count)")
                        row("Band swing", String(format: "%.0f%% (consistency %.0f%%)", b.swingRatio * 100, b.grooveConfidence * 100))
                        row("Sections", "\(b.sections.count) estimated")
                        row("Chord changes", b.chordChanges.isEmpty ? "—" : "\(b.chordChanges.count) estimated (first: \(b.chordChanges.prefix(4).map(\.name).joined(separator: " ")))")
                        row("Vocal activity", vocalSummary(b))
                    }
                    Text("Tempo, beats, onsets, bass and energy are measured. Sections, chords and vocals are estimates.")
                        .font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary)
            Text(value).font(GC.Font.caption).foregroundStyle(GC.Palette.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func vocalSummary(_ b: BackingAnalysis) -> String {
        guard !b.vocalActivity.isEmpty else { return "—" }
        let busy = b.vocalActivity.filter { $0 > 0.5 }.count
        let share = Double(busy) / Double(b.vocalActivity.count)
        return String(format: "estimate: busy %.0f%% of the song", share * 100)
    }
}
