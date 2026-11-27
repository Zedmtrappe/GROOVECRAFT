import Foundation
import GrooveCore

/// Everything the arrangement view draws. Built from the document by `ArrangementModel.make`.
struct ArrangementModel {
    struct Lane: Equatable {
        var pitch: Int
        var name: String
        var category: DrumCategory
        var isMapped: Bool
    }

    var ppq: Int = 480
    var tempoMap = TempoMap(ppq: 480)
    var bars: Int = 4
    var endTick: Double = 1920 * 4
    var lanes: [Lane] = []
    var laneIndex: [Int: Int] = [:]
    /// The original part (sorted by tick).
    var original: [DrumNote] = []
    /// The selected performance (sorted by tick).
    var current: [DrumNote] = []
    var originalByID: [Int: DrumNote] = [:]
    var showingOriginal = true
    var showOriginalGhosts = true
    var selection: Set<Int> = []
    var sections: [SectionMarker] = []
    var fillBars: Set<Int> = []
    var backing: BackingAnalysis?
    var alignment = Alignment.none
    var loop: ClosedRange<Double>? = nil
    var loopEnabled = false
    var processBars: ClosedRange<Int>? = nil
    var pixelsPerBeat: Double = 56
    var snap = false
    var isEmpty = true

    static let rulerHeight: CGFloat = 28
    static let sectionHeight: CGFloat = 22
    static let audioHeight: CGFloat = 72
    static let laneHeight: CGFloat = 22
    static let velocityHeight: CGFloat = 76
    static let headerWidth: CGFloat = 136

    var pixelsPerTick: Double { pixelsPerBeat / Double(max(1, ppq)) }
    var hasAudio: Bool { backing != nil }

    var audioTop: CGFloat { Self.rulerHeight + Self.sectionHeight }
    var lanesTop: CGFloat { audioTop + (hasAudio ? Self.audioHeight : 0) }
    var velocityTop: CGFloat { lanesTop + CGFloat(lanes.count) * Self.laneHeight }
    var totalHeight: CGFloat { velocityTop + Self.velocityHeight }

    func x(forTick tick: Double) -> CGFloat { Self.headerWidth + CGFloat(tick * pixelsPerTick) }
    func tick(forX x: CGFloat) -> Double { Double(x - Self.headerWidth) / pixelsPerTick }

    /// Song seconds ↔ ticks (song = MIDI seconds × stretch).
    func tick(forSong seconds: Double) -> Double { tempoMap.tick(atSeconds: seconds / max(0.0001, alignment.stretch)) }
    func song(forTick tick: Double) -> Double { tempoMap.seconds(atTick: tick) * alignment.stretch }

    var contentWidth: CGFloat {
        var endT = endTick + Double(ppq) * 4
        if let b = backing {
            let lastSong = b.duration - alignment.offsetSeconds
            endT = max(endT, tick(forSong: lastSong))
        }
        return x(forTick: endT) + 80
    }

    static func make(document doc: GrooveDocument?, selection: Set<Int>, pixelsPerBeat: Double, showGhosts: Bool,
                     snap: Bool, loop: ClosedRange<Double>, loopEnabled: Bool) -> ArrangementModel {
        var m = ArrangementModel()
        m.pixelsPerBeat = pixelsPerBeat
        m.showOriginalGhosts = showGhosts
        m.snap = snap
        m.loop = loop
        m.loopEnabled = loopEnabled
        guard let doc else { return m }
        m.isEmpty = false
        m.ppq = doc.pattern.ppq
        m.tempoMap = doc.tempoMap
        m.bars = doc.analysis.bars
        m.original = doc.pattern.notes
        m.current = doc.selectedNotes.sorted(by: DrumPattern.order)
        m.endTick = max(doc.pattern.endTick, m.current.map(\.endTick).max() ?? 0, m.tempoMap.tick(atBar: m.bars))
        for n in m.original { m.originalByID[n.id] = n }
        m.showingOriginal = doc.state.selectedVariationID == nil
        m.selection = selection
        m.sections = doc.state.sections
        m.fillBars = doc.analysis.fillBars
        m.backing = doc.backing
        m.alignment = doc.state.alignment
        m.processBars = doc.state.processBars

        // Lanes: every pitch used by the original or the take, ordered like a drum kit.
        let map = doc.state.drumMap
        let pitches = Set(m.original.map(\.pitch)).union(m.current.map(\.pitch))
        var lanes = pitches.map { p in Lane(pitch: p, name: map.name(for: p), category: map.category(for: p), isMapped: map.isMapped(p)) }
        lanes.sort { a, b in
            if a.category.laneOrder != b.category.laneOrder { return a.category.laneOrder < b.category.laneOrder }
            return a.pitch > b.pitch
        }
        m.lanes = lanes
        for (i, l) in lanes.enumerated() { m.laneIndex[l.pitch] = i }
        return m
    }

    /// First index in a tick-sorted array at or after `tick`.
    static func firstIndex(_ notes: [DrumNote], atOrAfter tick: Double) -> Int {
        var lo = 0, hi = notes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if notes[mid].tick < tick { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
