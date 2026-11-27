import Foundation

/// What Groovecraft understands about an imported drum part.
public struct PatternAnalysis: Equatable, Sendable {
    public enum Grid: String, Codable, Sendable {
        case straight8, straight16, straight32, triplet8, triplet16, mixed
        public var displayName: String {
            switch self {
            case .straight8: return "8ths"
            case .straight16: return "16ths"
            case .straight32: return "32nds"
            case .triplet8: return "8th triplets"
            case .triplet16: return "16th triplets"
            case .mixed: return "Mixed"
            }
        }
    }

    public var noteCount: Int
    public var bars: Int
    public var lengthBeats: Double
    public var durationSeconds: Double
    public var initialBPM: Double
    public var signature: TempoMap.TimeSignature
    public var hasTempoChanges: Bool
    public var grid: Grid
    /// 0.5 = straight. 0.667 = triplet swing. Measured on off-beat 8ths (or 16ths).
    public var swingRatio: Double
    /// Average distance of notes from the nearest grid point, in ms (0 = fully quantised).
    public var meanGridDeviationMs: Double
    /// 0 = every velocity identical, 1 = widely varied.
    public var velocityVariety: Double
    public var notesPerBar: Double
    public var categoryCounts: [DrumCategory: Int]
    /// Notes identified as ghost notes (quiet snare notes between the main hits).
    public var ghostNoteIDs: Set<Int>
    /// Notes identified as accents.
    public var accentIDs: Set<Int>
    /// Bars that look like fills (toms, or much busier than usual).
    public var fillBars: Set<Int>
    /// Most likely phrase length in bars (4 or 8 normally).
    public var phraseLength: Int
    /// A short description such as "4-bar phrase, repeats 4×, fills in bars 4, 8".
    public var structureSummary: String
    public var unmappedNotes: [Int]

    public var isQuantised: Bool { meanGridDeviationMs < 2.0 }
    public var isFlatVelocity: Bool { velocityVariety < 0.15 }
}

public enum PatternAnalyzer {
    public static func analyze(_ pattern: DrumPattern, tempoMap: TempoMap, map: DrumMap) -> PatternAnalysis {
        let notes = pattern.notes
        let ppq = Double(pattern.ppq)
        let endTick = max(pattern.endTick, ppq)
        let bars = max(1, tempoMap.barCount(endTick: Int(endTick.rounded(.up))))
        let sig = tempoMap.initialSignature

        var counts: [DrumCategory: Int] = [:]
        for n in notes { counts[map.category(for: n.pitch), default: 0] += 1 }

        let grid = detectGrid(notes, ppq: ppq)
        let deviation = meanDeviationMs(notes, grid: grid, ppq: ppq, tempoMap: tempoMap)
        let swing = detectSwing(notes, ppq: ppq)
        let variety = velocityVariety(notes, map: map)
        let ghosts = detectGhosts(notes, map: map, ppq: ppq)
        let accents = detectAccents(notes, map: map, ghosts: ghosts)
        let fills = detectFills(notes, map: map, tempoMap: tempoMap, bars: bars)
        let phrase = detectPhraseLength(notes, tempoMap: tempoMap, bars: bars, fills: fills)
        let unmapped = Array(Set(notes.map(\.pitch).filter { !map.isMapped($0) })).sorted()

        let summary = structureSummary(bars: bars, phrase: phrase, fills: fills)
        return PatternAnalysis(
            noteCount: notes.count, bars: bars, lengthBeats: endTick / ppq,
            durationSeconds: tempoMap.seconds(atTick: endTick), initialBPM: tempoMap.initialBPM,
            signature: sig, hasTempoChanges: tempoMap.hasTempoChanges, grid: grid, swingRatio: swing,
            meanGridDeviationMs: deviation, velocityVariety: variety,
            notesPerBar: Double(notes.count) / Double(bars), categoryCounts: counts,
            ghostNoteIDs: ghosts, accentIDs: accents, fillBars: fills, phraseLength: phrase,
            structureSummary: summary, unmappedNotes: unmapped)
    }

    // MARK: Grid

    /// Picks the coarsest grid that explains (nearly) every note.
    static func detectGrid(_ notes: [DrumNote], ppq: Double) -> PatternAnalysis.Grid {
        guard !notes.isEmpty else { return .straight16 }
        let candidates: [(PatternAnalysis.Grid, Double)] = [
            (.straight8, ppq / 2), (.triplet8, ppq / 3), (.straight16, ppq / 4),
            (.triplet16, ppq / 6), (.straight32, ppq / 8),
        ]
        let tolerance = ppq / 24
        for (grid, step) in candidates {
            var fits = 0
            for n in notes {
                let r = n.tick.truncatingRemainder(dividingBy: step)
                if min(r, step - r) <= tolerance { fits += 1 }
            }
            if Double(fits) / Double(notes.count) >= 0.97 { return grid }
        }
        // Swung 16ths/8ths often fit no straight grid: call it mixed.
        return .mixed
    }

    static func gridStep(_ grid: PatternAnalysis.Grid, ppq: Double) -> Double {
        switch grid {
        case .straight8: return ppq / 2
        case .straight16, .mixed: return ppq / 4
        case .straight32: return ppq / 8
        case .triplet8: return ppq / 3
        case .triplet16: return ppq / 6
        }
    }

    static func meanDeviationMs(_ notes: [DrumNote], grid: PatternAnalysis.Grid, ppq: Double, tempoMap: TempoMap) -> Double {
        guard !notes.isEmpty else { return 0 }
        let straight = ppq / 4
        let triplet = ppq / 6
        var total = 0.0
        for n in notes {
            let a = n.tick.truncatingRemainder(dividingBy: straight)
            let b = n.tick.truncatingRemainder(dividingBy: triplet)
            let d = min(min(a, straight - a), min(b, triplet - b))
            let msPerTick = 60_000.0 / (tempoMap.bpm(atTick: Int(n.tick)) * ppq)
            total += d * msPerTick
        }
        return total / Double(notes.count)
    }

    /// Swing ratio from the position of off-beat 8th notes inside each beat.
    static func detectSwing(_ notes: [DrumNote], ppq: Double) -> Double {
        var ratios: [Double] = []
        for n in notes {
            let inBeat = n.tick.truncatingRemainder(dividingBy: ppq) / ppq
            // Off-beat region between a straight 8th (0.5) and a heavy shuffle (0.75).
            if inBeat > 0.45 && inBeat < 0.78 { ratios.append(inBeat) }
        }
        guard ratios.count >= 4 else { return 0.5 }
        ratios.sort()
        return ratios[ratios.count / 2]
    }

    static func velocityVariety(_ notes: [DrumNote], map: DrumMap) -> Double {
        var byPitch: [Int: [Double]] = [:]
        for n in notes { byPitch[n.pitch, default: []].append(Double(n.velocity)) }
        var spreads: [Double] = []
        for (_, v) in byPitch where v.count >= 4 {
            let mean = v.reduce(0, +) / Double(v.count)
            let variance = v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count)
            spreads.append(variance.squareRoot())
        }
        guard !spreads.isEmpty else { return 0 }
        let avg = spreads.reduce(0, +) / Double(spreads.count)
        return min(1, avg / 25.0)
    }

    /// Ghost notes: snare hits well below the snare's typical level, off the main beats.
    static func detectGhosts(_ notes: [DrumNote], map: DrumMap, ppq: Double) -> Set<Int> {
        let snares = notes.filter { map.category(for: $0.pitch).family == .snare }
        guard snares.count >= 3 else { return [] }
        let sorted = snares.map(\.velocity).sorted()
        let upper = Double(sorted[(sorted.count * 3) / 4])
        var ids = Set<Int>()
        for n in snares {
            let v = Double(n.velocity)
            let onBeat = n.tick.truncatingRemainder(dividingBy: ppq) < ppq / 24
            if v <= min(60, upper * 0.6) && !(onBeat && v > 45) { ids.insert(n.id) }
        }
        return ids
    }

    static func detectAccents(_ notes: [DrumNote], map: DrumMap, ghosts: Set<Int>) -> Set<Int> {
        var byPitch: [Int: [Int]] = [:]
        for n in notes { byPitch[n.pitch, default: []].append(n.velocity) }
        var threshold: [Int: Int] = [:]
        for (p, list) in byPitch {
            let s = list.sorted()
            let median = s[s.count / 2]
            let top = s[s.count - 1]
            // Only call something an accent when the part actually varies.
            threshold[p] = top - median >= 10 ? median + (top - median) / 2 : 999
        }
        var ids = Set<Int>()
        for n in notes where !ghosts.contains(n.id) {
            if let t = threshold[n.pitch], n.velocity >= t { ids.insert(n.id) }
        }
        return ids
    }

    /// Bars with toms, or with clearly more activity than a normal bar.
    static func detectFills(_ notes: [DrumNote], map: DrumMap, tempoMap: TempoMap, bars: Int) -> Set<Int> {
        var perBar = [Int](repeating: 0, count: bars)
        var tomsPerBar = [Int](repeating: 0, count: bars)
        for n in notes {
            let bar = tempoMap.position(atTick: n.tick).bar
            guard bar >= 0 && bar < bars else { continue }
            perBar[bar] += 1
            if map.category(for: n.pitch).family == .tom { tomsPerBar[bar] += 1 }
        }
        let sorted = perBar.sorted()
        let median = Double(sorted[sorted.count / 2])
        var fills = Set<Int>()
        for b in 0 ..< bars {
            if tomsPerBar[b] >= 3 { fills.insert(b); continue }
            if median > 0 && Double(perBar[b]) > median * 1.45 && bars > 1 { fills.insert(b) }
        }
        return fills
    }

    /// Phrase length from where fills fall (every 4 or 8 bars) or bar repetition.
    static func detectPhraseLength(_ notes: [DrumNote], tempoMap: TempoMap, bars: Int, fills: Set<Int>) -> Int {
        if !fills.isEmpty {
            for length in [8, 4, 2] {
                let onBoundary = fills.filter { ($0 + 1) % length == 0 }.count
                if Double(onBoundary) / Double(fills.count) >= 0.75 && bars >= length { return length }
            }
        }
        if bars >= 8 { return 4 }
        return max(1, min(4, bars))
    }

    static func structureSummary(bars: Int, phrase: Int, fills: Set<Int>) -> String {
        var parts: [String] = []
        parts.append("\(bars) bar\(bars == 1 ? "" : "s")")
        if bars >= phrase * 2 { parts.append("\(phrase)-bar phrases") }
        if !fills.isEmpty {
            let list = fills.sorted().prefix(6).map { String($0 + 1) }.joined(separator: ", ")
            parts.append("fills in bar\(fills.count == 1 ? "" : "s") \(list)\(fills.count > 6 ? "…" : "")")
        }
        return parts.joined(separator: " · ")
    }
}
