import Foundation

/// The result of analysing a backing track. Everything is in audio seconds.
/// Values marked "estimate" are heuristics; the UI labels them as such.
public struct BackingAnalysis: Codable, Equatable, Sendable {
    public struct Onset: Codable, Equatable, Sendable {
        public var time: Double
        public var strength: Double
        public init(time: Double, strength: Double) { self.time = time; self.strength = strength }
    }

    public struct TempoEstimate: Codable, Equatable, Sendable {
        public var bpm: Double
        /// 0…1. Below about 0.35 the estimate shouldn't be trusted without checking.
        public var confidence: Double
        /// Other plausible tempos (half/double time and close contenders), most likely first.
        public var alternatives: [Double]
        public init(bpm: Double, confidence: Double, alternatives: [Double]) {
            self.bpm = bpm
            self.confidence = confidence
            self.alternatives = alternatives
        }
        public var isReliable: Bool { confidence >= 0.35 }
    }

    public struct ChordEvent: Codable, Equatable, Sendable {
        public var time: Double
        public var name: String
        public var confidence: Double
    }

    public var duration: Double
    public var tempo: TempoEstimate
    /// Beat times from the beat tracker.
    public var beats: [Double]
    /// Index in `beats` of the first downbeat (bar phase estimate).
    public var downbeatPhase: Int
    public var beatsPerBar: Int
    public var onsets: [Onset]
    public var bassOnsets: [Onset]
    /// Curves sampled at `curveRate` Hz, each normalised to 0…1 over the song.
    public var curveRate: Double
    public var energy: [Double]
    public var lowEnergy: [Double]
    public var density: [Double]
    /// Estimate: likelihood of vocals (mid-band, harmonic, sustained activity).
    public var vocalActivity: [Double]
    /// Estimated sections in audio time (labels are guesses; users can edit them).
    public var sections: [EstimatedSection]
    /// Estimate: harmonic changes from chroma template matching.
    public var chordChanges: [ChordEvent]
    /// The backing track's own micro-timing: mean offset of onsets per 16th step of the beat
    /// (fraction of a 16th, + = late), and how consistent it was (0…1).
    public var grooveOffsets: [Double]
    public var grooveConfidence: Double
    public var swingRatio: Double
    /// Waveform overview: peak values (0…1) for drawing, `overviewRate` points per second.
    public var overview: [Float]
    public var overviewRate: Double

    public init(duration: Double, tempo: TempoEstimate, beats: [Double], downbeatPhase: Int, beatsPerBar: Int,
                onsets: [Onset], bassOnsets: [Onset], curveRate: Double, energy: [Double], lowEnergy: [Double],
                density: [Double], vocalActivity: [Double], sections: [EstimatedSection], chordChanges: [ChordEvent],
                grooveOffsets: [Double], grooveConfidence: Double, swingRatio: Double, overview: [Float], overviewRate: Double) {
        self.duration = duration
        self.tempo = tempo
        self.beats = beats
        self.downbeatPhase = downbeatPhase
        self.beatsPerBar = beatsPerBar
        self.onsets = onsets
        self.bassOnsets = bassOnsets
        self.curveRate = curveRate
        self.energy = energy
        self.lowEnergy = lowEnergy
        self.density = density
        self.vocalActivity = vocalActivity
        self.sections = sections
        self.chordChanges = chordChanges
        self.grooveOffsets = grooveOffsets
        self.grooveConfidence = grooveConfidence
        self.swingRatio = swingRatio
        self.overview = overview
        self.overviewRate = overviewRate
    }

    public func curveValue(_ curve: [Double], at seconds: Double) -> Double {
        guard !curve.isEmpty else { return 0 }
        let x = seconds * curveRate
        let i = Int(x.rounded(.down))
        if i < 0 { return curve[0] }
        if i >= curve.count - 1 { return curve[curve.count - 1] }
        let f = x - Double(i)
        return curve[i] * (1 - f) + curve[i + 1] * f
    }

    /// Mean of a curve (used to centre energy and density around zero).
    public static func mean(_ curve: [Double]) -> Double {
        curve.isEmpty ? 0 : curve.reduce(0, +) / Double(curve.count)
    }

    /// Converts the estimated sections to markers on the drum part's bars.
    public func sectionMarkers(alignment: Alignment, tempoMap: TempoMap, totalBars: Int) -> [SectionMarker] {
        var markers: [SectionMarker] = []
        var before: EstimatedSection? = nil     // the section playing when the drums come in
        for section in sections {
            let midi = alignment.midiSeconds(audioTime: section.start)
            if midi < 0.5 && markers.isEmpty { before = section }
            if midi < -0.5 { continue }
            let tick = tempoMap.tick(atSeconds: max(0, midi))
            let pos = tempoMap.position(atTick: tick)
            // Snap to the nearest bar line.
            let bar = pos.beat >= pos.beatsInBar / 2 ? pos.bar + 1 : pos.bar
            guard bar < totalBars else { continue }
            if markers.contains(where: { $0.bar == bar }) { continue }
            markers.append(SectionMarker(bar: bar, kind: section.kind, isEstimate: true, energy: section.energy))
        }
        if markers.first.map({ $0.bar > 0 }) ?? true, let b = before ?? sections.first {
            markers.insert(SectionMarker(bar: 0, kind: b.kind, isEstimate: true, energy: b.energy), at: 0)
        }
        return markers
    }

    /// Time of the first downbeat according to the beat tracker.
    public var firstDownbeat: Double? {
        guard downbeatPhase < beats.count else { return beats.first }
        return beats[downbeatPhase]
    }
}

public struct EstimatedSection: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var kind: SectionKind
    /// Relative energy 0…1.
    public var energy: Double
    /// Cluster letter (A, B, C…): sections with the same letter sound alike.
    public var group: String
    public init(start: Double, end: Double, kind: SectionKind, energy: Double, group: String) {
        self.start = start
        self.end = end
        self.kind = kind
        self.energy = energy
        self.group = group
    }
}

public enum SectionKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case intro, verse, preChorus, chorus, bridge, breakdown, solo, outro, transition, unknown
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .intro: return "Intro"
        case .verse: return "Verse"
        case .preChorus: return "Pre-Chorus"
        case .chorus: return "Chorus"
        case .bridge: return "Bridge"
        case .breakdown: return "Breakdown"
        case .solo: return "Solo"
        case .outro: return "Outro"
        case .transition: return "Fill / Transition"
        case .unknown: return "Section"
        }
    }
}

/// A section marker. Estimated markers come from analysis; users can add, move, relabel and
/// delete markers. `bar` is in the drum part's bars (zero-based).
public struct SectionMarker: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var bar: Int
    public var kind: SectionKind
    public var label: String
    public var isEstimate: Bool
    /// Relative energy 0…1 (from analysis, or 0.5 for user markers).
    public var energy: Double

    public init(id: UUID = UUID(), bar: Int, kind: SectionKind, label: String? = nil, isEstimate: Bool = false, energy: Double = 0.5) {
        self.id = id
        self.bar = bar
        self.kind = kind
        self.label = label ?? kind.displayName
        self.isEstimate = isEstimate
        self.energy = energy
    }
}

/// How the MIDI part lines up with the backing audio.
/// audioTime = offsetSeconds + midiSeconds × stretch.
public struct Alignment: Codable, Equatable, Hashable, Sendable {
    public var offsetSeconds: Double
    /// 1 = MIDI plays at its own tempo. When the MIDI tempo differs from the audio, "match
    /// tempo" sets stretch = midiBPM / audioBPM so the MIDI follows the recording.
    public var stretch: Double
    public var isAutomatic: Bool

    public init(offsetSeconds: Double = 0, stretch: Double = 1, isAutomatic: Bool = false) {
        self.offsetSeconds = offsetSeconds
        self.stretch = stretch
        self.isAutomatic = isAutomatic
    }

    public func audioTime(midiSeconds: Double) -> Double { offsetSeconds + midiSeconds * stretch }
    public func midiSeconds(audioTime: Double) -> Double { (audioTime - offsetSeconds) / max(0.0001, stretch) }

    public static let none = Alignment()
}
