import SwiftUI
import GrooveCore

/// Play / stop / loop and the playhead. Starts the MIDI thread and the audio engine on one
/// shared host-time anchor so external MIDI, the preview kit and the backing track line up.
@MainActor
final class TransportController: ObservableObject {
    weak var app: AppState?

    @Published private(set) var isPlaying = false
    /// Song position in seconds (MIDI time × stretch).
    @Published private(set) var position: Double = 0
    @Published var loopEnabled = false
    /// Loop region in song seconds.
    @Published var loopRange: ClosedRange<Double> = 0 ... 8
    /// Where Play starts from.
    @Published var startPosition: Double = 0

    private var anchor: UInt64 = 0
    private var mapper = LoopMapper(startPosition: 0)
    private var timer: Timer?
    private var plan: PlaybackPlan?

    var tempoMap: TempoMap? { app?.document?.tempoMap }
    var stretch: Double { app?.document?.state.alignment.stretch ?? 1 }

    // MARK: Conversions

    func tick(atSong seconds: Double) -> Double {
        guard let map = tempoMap else { return 0 }
        return map.tick(atSeconds: seconds / max(0.0001, stretch))
    }

    func song(atTick tick: Double) -> Double {
        guard let map = tempoMap else { return 0 }
        return map.seconds(atTick: tick) * stretch
    }

    var positionTick: Double { tick(atSong: position) }

    var positionDisplay: String {
        guard let map = tempoMap else { return "1.1.00" }
        return map.position(atTick: max(0, positionTick)).display
    }

    var timeDisplay: String {
        let t = max(0, position)
        let m = Int(t) / 60
        let s = t - Double(m * 60)
        return String(format: "%d:%06.3f", m, s)
    }

    // MARK: Loop

    func resetLoop() {
        guard let doc = app?.document else { return }
        let bars = min(4, max(1, doc.analysis.bars))
        loopRange = song(atTick: 0) ... song(atTick: doc.tempoMap.tick(atBar: bars))
        startPosition = 0
        position = 0
    }

    func setLoop(bars: ClosedRange<Int>) {
        guard let map = tempoMap else { return }
        let a = song(atTick: map.tick(atBar: bars.lowerBound))
        let b = song(atTick: map.tick(atBar: bars.upperBound + 1))
        guard b > a else { return }
        loopRange = a ... b
        loopEnabled = true
        if isPlaying { restartFromCurrentPosition() }
    }

    func toggleLoop() {
        loopEnabled.toggle()
        if isPlaying { restartFromCurrentPosition() }
    }

    // MARK: Transport

    func togglePlay() {
        if isPlaying { stop() } else { play() }
    }

    func play(from start: Double? = nil) {
        guard let app, let doc = app.document else { return }
        stopEngines()
        var from = start ?? startPosition
        if loopEnabled && (from < loopRange.lowerBound || from >= loopRange.upperBound) { from = loopRange.lowerBound }
        let settings = app.prefs.output
        let newPlan = PlaybackPlan(notes: doc.selectedNotes, tempoMap: doc.tempoMap, settings: settings,
                                   stretch: doc.state.alignment.stretch, includeClock: settings.sendClock)
        plan = newPlan
        let loop: ClosedRange<Double>? = loopEnabled ? loopRange : nil
        mapper = LoopMapper(startPosition: from, loop: loop)
        // A short lead-in leaves time for the first messages and audio buffers.
        let leadIn = max(0.06, settings.latencyMs / 1000 + 0.03)
        anchor = HostClock.now + HostClock.ticks(leadIn)

        if app.prefs.externalEnabled {
            let scheduler = MIDIScheduler(plan: newPlan, settings: settings)
            let initial = scheduler.start(at: from, loop: loop)
            app.midiThread.lookahead = app.prefs.preciseTimestamps ? 0.004 : 0.0
            app.midiThread.start(scheduler: scheduler, anchor: anchor, initial: initial)
        }
        let renderer = app.audio.renderer
        renderer.drumsEnabled = app.prefs.previewKitEnabled
        renderer.backingEnabled = app.prefs.backingAudible
        renderer.drumGain = Float(app.prefs.previewVolume)
        renderer.backingGain = Float(app.prefs.backingVolume)
        renderer.setNotes(previewNotes(newPlan, doc: doc), alignment: doc.state.alignment)
        if app.prefs.previewKitEnabled || renderer.hasBacking {
            app.audio.play(anchor: anchor, mapper: mapper)
            if let err = app.audio.lastError { app.show(Toast(text: err, symbol: "speaker.slash.fill", isError: true)) }
        }
        position = from
        isPlaying = true
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in AppState.shared.transport.tickUI() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func previewNotes(_ plan: PlaybackPlan, doc: GrooveDocument) -> [PreviewRenderer.Note] {
        // The preview kit plays what the pattern means (categories from the drum map),
        // not the output remapping meant for the external instrument.
        let map = doc.state.drumMap
        return doc.selectedNotes.map { n in
            PreviewRenderer.Note(start: doc.tempoMap.seconds(atTick: n.tick) * doc.state.alignment.stretch,
                                 category: map.category(for: n.pitch), note: n.pitch, velocity: n.velocity)
        }
    }

    func tickUI() {
        guard isPlaying else { return }
        let t = HostClock.interval(from: anchor, to: HostClock.now)
        position = t < 0 ? mapper.startPosition : mapper.position(atTransport: t)
        // Stop at the end when not looping.
        if !loopEnabled, let plan {
            var end = plan.duration + 0.5
            if let backing = app?.document?.backing, app?.audio.renderer.hasBacking == true, app?.prefs.backingAudible == true {
                end = max(end, backing.duration - (app?.document?.state.alignment.offsetSeconds ?? 0))
            }
            if position > end { stop(); position = startPosition }
        }
    }

    func stop() {
        guard isPlaying else { stopEngines(); return }
        stopEngines()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    private func stopEngines() {
        app?.midiThread.stop(sendRelease: true)
        app?.audio.stop()
    }

    /// Return to the start position (or the loop start).
    func rewind() {
        let wasPlaying = isPlaying
        stop()
        startPosition = loopEnabled ? loopRange.lowerBound : 0
        position = startPosition
        if wasPlaying { play() }
    }

    func seek(to song: Double) {
        let s = max(0, song)
        startPosition = s
        if isPlaying { play(from: s) } else { position = s }
    }

    func restartFromCurrentPosition() {
        guard isPlaying else { return }
        play(from: position)
    }

    /// The selected take (or its notes) changed while playing: switch without stopping.
    func performanceChanged() {
        guard let app, let doc = app.document, isPlaying else { return }
        let settings = app.prefs.output
        let newPlan = PlaybackPlan(notes: doc.selectedNotes, tempoMap: doc.tempoMap, settings: settings,
                                   stretch: doc.state.alignment.stretch, includeClock: settings.sendClock)
        if let old = plan, old.stretch != newPlan.stretch {
            // Alignment changed: restart so everything lines up again.
            plan = newPlan
            restartFromCurrentPosition()
            return
        }
        plan = newPlan
        if app.midiThread.isRunning { app.midiThread.swap(plan: newPlan) }
        app.audio.renderer.setNotes(previewNotes(newPlan, doc: doc), alignment: doc.state.alignment)
    }
}
