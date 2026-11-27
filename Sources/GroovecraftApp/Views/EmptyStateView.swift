import SwiftUI
import GrooveCore

struct EmptyStateView: View {
    @ObservedObject var app: AppState
    @State private var appeared = false

    var body: some View {
        ZStack {
            RadialGradient(colors: [GC.Palette.accent.opacity(0.07), .clear], center: .center, startRadius: 10, endRadius: 520)
            VStack(spacing: GC.Space.xl) {
                LogoMark(size: 64)
                    .scaleEffect(appeared ? 1 : 0.85)
                    .opacity(appeared ? 1 : 0)
                VStack(spacing: 8) {
                    Text("Programmed drums, played.")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(GC.Palette.textPrimary)
                    Text("Drop a drum MIDI file here. Groovecraft gives it a drummer's timing, dynamics and feel, listens to your song if you add the backing track, and plays it through your own drum instrument in Logic.")
                        .font(GC.Font.body)
                        .foregroundStyle(GC.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
                HStack(spacing: GC.Space.m) {
                    Button {
                        app.openMIDIPanel()
                    } label: { Label("Open Drum MIDI…", systemImage: "folder") }
                        .buttonStyle(GCButtonStyle(kind: .primary, large: true))
                        .keyboardShortcut("o", modifiers: .command)
                    Button {
                        app.openDemo()
                    } label: { Label("Try the Demo Groove", systemImage: "play.circle") }
                        .buttonStyle(GCButtonStyle(kind: .secondary, large: true))
                }
                HStack(spacing: GC.Space.xl) {
                    step("1", "Open MIDI", "Type 0 or 1, any drum map")
                    step("2", "Add the song", "Optional backing track")
                    step("3", "Humanise", "Quick or Advanced")
                    step("4", "Hear it in Logic", "Through your drum plug-in")
                }
                .padding(.top, GC.Space.s)
            }
            .padding(GC.Space.xxl)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(MotionPreference.animation(.easeOut(duration: 0.45))) { appeared = true }
        }
    }

    private func step(_ n: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 4) {
            Text(n)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(GC.Palette.accent)
                .frame(width: 22, height: 22)
                .background(Circle().stroke(GC.Palette.accent.opacity(0.5), lineWidth: 1))
            Text(title).font(GC.Font.heading)
            Text(detail).font(GC.Font.caption).foregroundStyle(GC.Palette.textTertiary)
        }
        .frame(width: 130)
    }
}

/// A built-in demo: a quantised 16-bar groove (verse/chorus), so the app can be tried at once.
enum DemoContent {
    static func midi() -> MIDIFile {
        let ppq = 480
        var events: [MIDIEvent] = [.trackName("Demo Drums")]
        func hit(_ tick: Int, _ note: Int, _ v: Int) {
            events.append(MIDIEvent(tick: tick, kind: .noteOn(channel: 9, note: note, velocity: v)))
            events.append(MIDIEvent(tick: tick + ppq / 8, kind: .noteOff(channel: 9, note: note, velocity: 0)))
        }
        for bar in 0 ..< 16 {
            let start = bar * ppq * 4
            let chorus = bar >= 8
            let fill = bar % 4 == 3
            for e in 0 ..< 8 {
                let t = start + e * ppq / 2
                if fill && e >= 4 { continue }
                hit(t, chorus ? 51 : 42, 100)
            }
            hit(start, 36, 100)
            hit(start + ppq * 2 + ppq / 2, 36, 100)
            if bar % 2 == 1 { hit(start + ppq * 3 + ppq / 2, 36, 100) }
            hit(start + ppq, 38, 100)
            if fill {
                let toms = [38, 38, 50, 50, 47, 47, 43, 43]
                for (k, n) in toms.enumerated() { hit(start + ppq * 2 + k * ppq / 4, n, 100) }
            } else {
                hit(start + ppq * 3, 38, 100)
            }
            if bar == 8 || bar == 0 { hit(start, 49, 100) }
        }
        events.append(.endOfTrack(tick: 16 * ppq * 4))
        var track = MIDITrack(events: events)
        track.sortEvents()
        let tempo = MIDITrack(events: [.trackName("Tempo"), .tempo(tick: 0, bpm: 96), .timeSignature(tick: 0, numerator: 4, denominator: 4),
                                       .endOfTrack(tick: 16 * ppq * 4)])
        return MIDIFile(format: .multiTrack, ppq: ppq, tracks: [tempo, track])
    }
}

extension AppState {
    func openDemo() {
        do {
            let midi = DemoContent.midi()
            var state = ProjectState()
            state.source = DrumPattern.detectSource(in: midi)
            state.sections = [SectionMarker(bar: 0, kind: .verse), SectionMarker(bar: 8, kind: .chorus)]
            let doc = try GrooveDocument(midi: midi, name: "Demo Groove", state: state)
            midiURL = nil
            projectURL = nil
            backingURL = nil
            audio.renderer.clearBacking()
            prefs.previewKitEnabled = true
            setDocument(doc)
            doc.markSaved()
            show(Toast(text: "Demo loaded. Press Humanise, then Space to listen.", symbol: "sparkles"))
        } catch {
            alert = AppAlert(title: "Couldn't load the demo", message: error.localizedDescription)
        }
    }
}

// MARK: - Logic Pro guide

struct LogicGuideView: View {
    @ObservedObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var route = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                LogoMark(size: 22)
                Text("Hear Groovecraft through your drums in Logic Pro").font(GC.Font.title)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(GC.Space.l)
            Rectangle().fill(GC.Palette.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: GC.Space.l) {
                    flow
                    GCSegmented(options: [(0, "Groovecraft port (recommended)"), (1, "IAC Driver")], selection: $route)
                    if route == 0 { virtualSteps } else { iacSteps }
                    section("Record the performance into Logic", "record.circle", [
                        "Choose the take you like in Groovecraft.",
                        "In Logic, record-enable the drum track (R) and press Record. Logic counts in by default.",
                        "Press Space in Groovecraft as Logic starts recording, or start Groovecraft a bar early and trim the region afterwards.",
                        "Stop both. The MIDI is now a normal Logic region you can edit.",
                        "For sample-exact placement, drag an exported MIDI file (⌘E) into Logic instead: it lands exactly on the grid, with the tempo.",
                    ])
                    section("Good to know", "info.circle", [
                        "Logic can't be started or synchronised by Groovecraft. Logic doesn't follow external MIDI clock, so live recording starts by hand and its position depends on when you press play.",
                        "Set Latency compensation in Output if the drums feel late against the backing track. Larger Logic buffer sizes need more.",
                        "If the drums play twice, Logic may also be echoing the MIDI to another track: select only one track, or turn off MIDI Thru for the others.",
                        "Stop and Panic always send note-offs, so no notes are left hanging.",
                        "Drum plug-ins differ in their note layouts. Use Drums ▸ Drum map for the file, and Output ▸ Note remapping for the instrument.",
                    ])
                }
                .padding(GC.Space.xl)
            }
        }
        .frame(width: 620, height: 640)
        .background(GC.Palette.surface)
    }

    private var flow: some View {
        HStack(spacing: 6) {
            node("Groovecraft", "sparkles")
            arrow
            node(route == 0 ? "Virtual MIDI" : "IAC Bus", "cable.connector")
            arrow
            node("Logic Pro", "music.note.house")
            arrow
            node("Drum plug-in", "square.grid.3x3")
            arrow
            node("Speakers", "speaker.wave.2")
        }
        .frame(maxWidth: .infinity)
        .padding(GC.Space.m)
        .background(RoundedRectangle(cornerRadius: GC.Radius.l).fill(GC.Palette.background))
    }

    private var arrow: some View {
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(GC.Palette.textTertiary)
    }

    private func node(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(GC.Palette.accent)
            Text(title).font(GC.Font.micro).foregroundStyle(GC.Palette.textSecondary)
        }
        .frame(width: 92)
    }

    private var virtualSteps: some View {
        section("Set up (about a minute)", "1.circle", [
            "Leave Groovecraft open: it publishes a MIDI port called “Groovecraft” while it's running.",
            "In Logic, create a Software Instrument track and load Superior Drummer, EZdrummer, Slate Drums, Kontakt or Drummer Kit.",
            "Select that track. Logic plays incoming MIDI through the selected track; no extra routing is needed.",
            "Optional: Logic Pro ▸ Settings ▸ MIDI ▸ Inputs lists “Groovecraft”. Make sure it's ticked.",
            "In Groovecraft ▸ Output, choose “Groovecraft (virtual port)” and press Kick or Snare to test.",
            "Press Space in Groovecraft. You'll hear your drum instrument play the selected take.",
        ])
    }

    private var iacSteps: some View {
        section("Set up with the IAC Driver", "1.circle", [
            "Open Audio MIDI Setup (Applications ▸ Utilities). Choose Window ▸ Show MIDI Studio.",
            "Double-click IAC Driver and tick “Device is online”. Bus 1 is fine.",
            "In Groovecraft ▸ Output, choose “IAC Driver Bus 1”.",
            "In Logic, select a track with your drum instrument. Logic receives IAC like any other MIDI input.",
            "Press Kick in Groovecraft to test, then Space to play.",
        ])
    }

    private func section(_ title: String, _ symbol: String, _ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: GC.Space.s) {
            Label(title, systemImage: symbol).font(GC.Font.heading).foregroundStyle(GC.Palette.textPrimary)
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(i + 1)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(GC.Palette.accent)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(GC.Palette.accent.opacity(0.12)))
                    Text(s).font(GC.Font.body).foregroundStyle(GC.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
