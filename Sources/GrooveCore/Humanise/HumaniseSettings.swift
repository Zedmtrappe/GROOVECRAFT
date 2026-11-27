import Foundation

/// Every control of the humanisation engine. Quick mode drives these through macros;
/// Advanced mode exposes them directly. Values are plain numbers so presets are portable.
public struct HumaniseSettings: Codable, Equatable, Hashable, Sendable {
    public var formatVersion: Int = 1

    // MARK: Randomisation
    /// Overall amount of human variation (0…1.5). Scales timing and velocity randomness.
    public var intensity: Double = 1.0
    public var seed: UInt64 = 1
    /// How differently the individual drums behave from one another (0…1).
    public var perDrumVariation: Double = 0.5
    /// Smoothness of variation: 0 = every hit independent, 1 = a drummer's slowly wandering feel.
    public var correlation: Double = 0.55
    /// How much variation changes from phrase to phrase (0…1).
    public var phraseVariation: Double = 0.4

    // MARK: Timing
    public var timing = TimingSettings()
    // MARK: Velocity
    public var velocity = VelocitySettings()
    // MARK: Groove
    public var groove = GrooveSettings()
    // MARK: Articulation
    public var articulation = ArticulationSettings()
    // MARK: Per drum
    public var drums: [String: DrumSettings] = HumaniseSettings.defaultDrums
    // MARK: Track-aware
    public var trackAware = TrackAwareSettings()

    public init() {}

    public func drum(_ family: DrumFamily) -> DrumSettings {
        drums[family.rawValue] ?? DrumSettings()
    }

    public mutating func setDrum(_ family: DrumFamily, _ value: DrumSettings) {
        drums[family.rawValue] = value
    }

    public static let defaultDrums: [String: DrumSettings] = {
        var d: [String: DrumSettings] = [:]
        d[DrumFamily.kick.rawValue] = DrumSettings(timing: 0.8, velocity: 0.7, tightness: 0.6, accent: 0.4, offsetMs: 0, special: 0.5)
        d[DrumFamily.snare.rawValue] = DrumSettings(timing: 1.0, velocity: 0.9, tightness: 0.5, accent: 0.6, offsetMs: 1.5, special: 0.5)
        d[DrumFamily.hihat.rawValue] = DrumSettings(timing: 1.1, velocity: 1.1, tightness: 0.4, accent: 0.7, offsetMs: 0, special: 0.5)
        d[DrumFamily.cymbal.rawValue] = DrumSettings(timing: 1.0, velocity: 0.8, tightness: 0.4, accent: 0.6, offsetMs: 0, special: 0.5)
        d[DrumFamily.tom.rawValue] = DrumSettings(timing: 1.1, velocity: 0.9, tightness: 0.4, accent: 0.5, offsetMs: 0, special: 0.5)
        d[DrumFamily.percussion.rawValue] = DrumSettings(timing: 1.2, velocity: 1.0, tightness: 0.3, accent: 0.5, offsetMs: 0, special: 0.5)
        d[DrumFamily.other.rawValue] = DrumSettings(timing: 1.0, velocity: 1.0, tightness: 0.5, accent: 0.5, offsetMs: 0, special: 0.5)
        return d
    }()
}

public struct TimingSettings: Codable, Equatable, Hashable, Sendable {
    /// Random timing variation (0…1.5). 1 ≈ a good session drummer (about ±8 ms spread).
    public var variation: Double = 0.6
    /// Hard ceiling on how far any hit may move from where it was, ms.
    public var maxDeviationMs: Double = 22
    /// Whole-kit bias: negative = ahead of the beat, positive = behind (ms).
    public var biasMs: Double = 0
    /// 0 = loose, 1 = tight. Reduces random spread, most on the main beats.
    public var tightness: Double = 0.5
    /// Each drum's "personality" offset (kick a hair early, snare a hair late…) 0…1.
    public var microtiming: Double = 0.5
    /// Keep the timing already present in a file that was played in (0…1).
    public var preserveExisting: Double = 0.7
    /// Main beats are steadier than off-beats (0…1).
    public var beatPositionInfluence: Double = 0.6
    /// Louder hits land slightly earlier, quieter ones relaxed (0…1).
    public var velocityInfluence: Double = 0.3
    /// Fills push forward a little and land back on the downbeat (0…1).
    public var phraseInfluence: Double = 0.4
    /// Slow tempo drift across bars (0…1).
    public var drift: Double = 0.35

    public init() {}
}

public enum VelocityCurve: String, Codable, CaseIterable, Sendable {
    case linear, soft, hard, compressed, expanded
    public var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .soft: return "Soft"
        case .hard: return "Hard"
        case .compressed: return "Compressed"
        case .expanded: return "Expanded"
        }
    }
}

public struct VelocitySettings: Codable, Equatable, Hashable, Sendable {
    /// Random velocity variation (0…1.5). 1 ≈ ±7 velocity spread.
    public var variation: Double = 0.6
    /// Scales dynamic range around each drum's average (0.5…1.6).
    public var range: Double = 1.0
    public var minimum: Int = 8
    public var maximum: Int = 127
    /// Overall level shift (−30…+30).
    public var bias: Double = 0
    /// Strength of accents on strong beats (0…1).
    public var accentIntensity: Double = 0.5
    /// Ghost notes: 0 = keep exactly, otherwise level relative to their original (0.5…1.5).
    public var ghostLevel: Double = 1.0
    /// Never let ghost notes rise above their range or drop to inaudible (true by default).
    public var protectGhosts: Bool = true
    /// Strong beats louder, weak beats softer (0…1).
    public var beatPositionVariation: Double = 0.5
    /// Phrase-level swells and fall-backs (0…1).
    public var phraseDynamics: Double = 0.4
    /// Repeated hits (hi-hat 8ths/16ths) alternate like real hands (0…1).
    public var repetitionVariation: Double = 0.6
    public var curve: VelocityCurve = .linear
    /// Largest change from a note's original velocity.
    public var maxChange: Int = 30

    public init() {}
}

public enum SwingSubdivision: String, Codable, CaseIterable, Sendable {
    case eighth, sixteenth
    public var displayName: String { self == .eighth ? "8ths" : "16ths" }
}

public struct GrooveSettings: Codable, Equatable, Hashable, Sendable {
    /// Swing amount 0…1 → 50% (straight) … 75% (hard shuffle).
    public var swing: Double = 0
    public var swingSubdivision: SwingSubdivision = .sixteenth
    public var templateID: String? = nil
    /// Inline template (imported, extracted or user-made); overrides `templateID` when set.
    public var customTemplate: GrooveTemplate? = nil
    /// Strength of the groove template (0…1).
    public var intensity: Double = 0.6
    /// Keep the pattern's own swing/groove when it already has one (0…1).
    public var preserveExisting: Double = 0.8
    /// Feel: −1 = on top / ahead, +1 = laid back / behind (≈ ±12 ms on the backbeat).
    public var pushPull: Double = 0
    /// Extra weight on downbeats/beats (0…1).
    public var beatEmphasis: Double = 0.4
    /// Extra weight on off-beats (0…1, e.g. disco hats).
    public var offbeatEmphasis: Double = 0.1

    public init() {}

    public var swingRatio: Double { 0.5 + clamp(swing, 0, 1) * 0.25 }

    public var template: GrooveTemplate? {
        customTemplate ?? GrooveTemplate.factory(id: templateID)
    }
}

public struct ArticulationSettings: Codable, Equatable, Hashable, Sendable {
    /// Master switch for adding notes. Added notes are always marked and can be removed.
    public var allowAddedNotes: Bool = false
    /// Probability of adding snare ghost notes in grooves (0…1).
    public var addGhostNotes: Double = 0
    /// Probability of a flam on accented snare hits in fills and phrase ends (0…1).
    public var flams: Double = 0
    /// Probability of a drag (two grace notes) before snare accents in fills (0…1).
    public var drags: Double = 0
    /// Probability of filling consecutive snare 16ths in fills with 32nd-note rolls (0…1).
    public var rolls: Double = 0
    /// Occasional hi-hat openings on the last off-beat of a phrase (0…1).
    public var hihatOpenings: Double = 0
    /// Note length variation (0…1). Matters for hi-hat and cymbal chokes in some instruments.
    public var lengthVariation: Double = 0.3
    /// Fills build in energy towards the end (0…1).
    public var fillBuild: Double = 0.5
    /// Accent the downbeat that ends a fill (0…1).
    public var phraseEndAccent: Double = 0.4
    /// Hi-hat accent pattern strength (quarter-note lift) 0…1.
    public var hihatAccents: Double = 0.5

    public init() {}
}

/// Per-drum controls. `special` is the drum's own extra behaviour:
/// kick = bass interaction, snare = backbeat emphasis, hi-hats = open/closed transitions,
/// cymbals = phrase variation, toms = fill behaviour, percussion = groove follow.
public struct DrumSettings: Codable, Equatable, Hashable, Sendable {
    public var timing: Double = 1
    public var velocity: Double = 1
    public var tightness: Double = 0.5
    public var accent: Double = 0.5
    /// Groove position: this drum's constant offset (− ahead / + behind), ms.
    public var offsetMs: Double = 0
    public var special: Double = 0.5
    /// Ghost-note handling (snare): how far ghosts may vary relative to main hits (0…1).
    public var ghostHandling: Double = 0.5

    public init(timing: Double = 1, velocity: Double = 1, tightness: Double = 0.5, accent: Double = 0.5,
                offsetMs: Double = 0, special: Double = 0.5, ghostHandling: Double = 0.5) {
        self.timing = timing
        self.velocity = velocity
        self.tightness = tightness
        self.accent = accent
        self.offsetMs = offsetMs
        self.special = special
        self.ghostHandling = ghostHandling
    }
}

public struct TrackAwareSettings: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool = false
    /// Macro: scales all the backing-track influences below (0…1).
    public var bandInteraction: Double = 0.7
    /// 0 = loose, 0.5 = natural, 1 = tight lock of kick to bass attacks.
    public var kickBassLock: Double = 0.5
    /// Borrow the backing track's own micro-timing feel (0…1).
    public var grooveMatch: Double = 0.4
    /// Loud passages → stronger hits and cymbals; quiet → softer (0…1).
    public var energyResponse: Double = 0.5
    /// Verse/chorus/breakdown each get their own dynamics (0…1).
    public var sectionAwareness: Double = 0.5
    /// Busy arrangement → simpler, tighter drums; sparse → more nuance (0…1).
    public var arrangementSensitivity: Double = 0.4
    /// Build into and accent phrase boundaries found in the audio (0…1).
    public var phraseAwareness: Double = 0.5
    /// Hold back added notes and cymbals where vocals are busy (0…1).
    public var vocalSpace: Double = 0.4

    public init() {}

    func scaled(_ v: Double) -> Double { enabled ? v * bandInteraction : 0 }
}

// MARK: - Tolerant decoding

/// Decodes JSON written by older (or newer) versions: missing keys take their default values,
/// unknown keys are ignored. Used for presets, settings and project files.
public enum TolerantJSON {
    public static func decode<T: Codable>(_ type: T.Type, from data: Data, defaults: T) throws -> T {
        let encoder = JSONEncoder()
        let defaultData = try encoder.encode(defaults)
        let base = try JSONSerialization.jsonObject(with: defaultData)
        let incoming = try JSONSerialization.jsonObject(with: data)
        let merged = merge(base, incoming)
        let mergedData = try JSONSerialization.data(withJSONObject: merged)
        return try JSONDecoder().decode(T.self, from: mergedData)
    }

    static func merge(_ base: Any, _ over: Any) -> Any {
        guard let b = base as? [String: Any], let o = over as? [String: Any] else { return over }
        var out = b
        for (k, v) in o {
            if let existing = b[k] { out[k] = merge(existing, v) } else { out[k] = v }
        }
        return out
    }
}
