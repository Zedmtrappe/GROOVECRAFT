import Foundation

/// A named set of humanisation settings.
public struct Preset: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var category: String
    public var summary: String
    public var settings: HumaniseSettings
    public var isFactory: Bool
    public var isFavourite: Bool
    public var formatVersion: Int

    public init(id: String = "user.\(UUID().uuidString)", name: String, category: String, summary: String = "",
                settings: HumaniseSettings, isFactory: Bool = false, isFavourite: Bool = false) {
        self.id = id
        self.name = name
        self.category = category
        self.summary = summary
        self.settings = settings
        self.isFactory = isFactory
        self.isFavourite = isFavourite
        self.formatVersion = 1
    }
}

public enum FactoryPresets {
    public static let all: [Preset] = [
        tightStudio, naturalDrummer, laidBack, driving, vintageSoul, funkPocket, hipHopPocket, jazzFeel,
        rockPerformance, looseLive, electronicTight, shuffle,
    ]

    public static func preset(id: String) -> Preset? { all.first { $0.id == id } }

    static func make(_ id: String, _ name: String, _ category: String, _ summary: String,
                     _ edit: (inout HumaniseSettings) -> Void) -> Preset {
        var s = HumaniseSettings()
        edit(&s)
        return Preset(id: "factory.\(id)", name: name, category: category, summary: summary, settings: s, isFactory: true)
    }

    public static let tightStudio = make("tight-studio", "Tight Studio", "Studio",
        "A session drummer playing to a click: precise, controlled dynamics.") { s in
        s.intensity = 0.7
        s.correlation = 0.6
        s.timing.variation = 0.35
        s.timing.tightness = 0.8
        s.timing.maxDeviationMs = 12
        s.timing.drift = 0.15
        s.velocity.variation = 0.45
        s.velocity.range = 0.95
        s.velocity.accentIntensity = 0.45
        s.groove.beatEmphasis = 0.35
    }

    public static let naturalDrummer = make("natural", "Natural Drummer", "Studio",
        "A balanced, believable player: small timing wander, real hand patterns.") { s in
        s.intensity = 1.0
        s.timing.variation = 0.65
        s.timing.tightness = 0.5
        s.velocity.variation = 0.65
        s.velocity.repetitionVariation = 0.7
        s.articulation.lengthVariation = 0.3
    }

    public static let laidBack = make("laid-back", "Laid Back", "Feel",
        "Behind the beat: the snare drags, hats relax, nothing rushes.") { s in
        s.timing.variation = 0.6
        s.timing.biasMs = 3
        s.groove.pushPull = 0.75
        s.timing.tightness = 0.4
        s.velocity.range = 0.9
        s.velocity.curve = .soft
        var snare = s.drum(.snare); snare.offsetMs = 6; s.setDrum(.snare, snare)
    }

    public static let driving = make("driving", "Driving", "Feel",
        "On top of the beat with a strong pulse: urgent, forward-leaning.") { s in
        s.timing.variation = 0.55
        s.timing.biasMs = -3
        s.groove.pushPull = -0.6
        s.groove.templateID = "groove.rockdrive"
        s.groove.intensity = 0.6
        s.groove.beatEmphasis = 0.7
        s.velocity.accentIntensity = 0.7
        s.velocity.curve = .hard
        s.velocity.bias = 4
    }

    public static let vintageSoul = make("vintage-soul", "Vintage Soul", "Genre",
        "Sixties/seventies soul: soft 16ths, gentle backbeat drag, warm dynamics.") { s in
        s.groove.templateID = "groove.motown"
        s.groove.intensity = 0.75
        s.groove.swing = 0.12
        s.timing.variation = 0.8
        s.timing.drift = 0.55
        s.timing.tightness = 0.35
        s.velocity.variation = 0.8
        s.velocity.curve = .compressed
        s.velocity.phraseDynamics = 0.6
        s.articulation.allowAddedNotes = true
        s.articulation.addGhostNotes = 0.25
    }

    public static let funkPocket = make("funk-pocket", "Funk Pocket", "Genre",
        "Tight kick, lazy 16ths, ghost notes that breathe around the backbeat.") { s in
        s.groove.templateID = "groove.funkpocket"
        s.groove.intensity = 0.85
        s.groove.swing = 0.16
        s.timing.variation = 0.55
        s.timing.tightness = 0.6
        s.velocity.variation = 0.7
        s.velocity.accentIntensity = 0.75
        s.velocity.repetitionVariation = 0.85
        s.velocity.range = 1.15
        s.articulation.allowAddedNotes = true
        s.articulation.addGhostNotes = 0.45
        s.articulation.hihatAccents = 0.7
        var kick = s.drum(.kick); kick.tightness = 0.8; s.setDrum(.kick, kick)
    }

    public static let hipHopPocket = make("hiphop-pocket", "Hip-Hop Pocket", "Genre",
        "Drunk-but-deliberate 16ths and a late snare, MPC style.") { s in
        s.groove.templateID = "groove.hiphoppocket"
        s.groove.intensity = 0.9
        s.groove.swing = 0.3
        s.groove.pushPull = 0.4
        s.timing.variation = 0.45
        s.timing.drift = 0.1
        s.velocity.variation = 0.5
        s.velocity.range = 1.1
        s.velocity.curve = .hard
        var hats = s.drum(.hihat); hats.timing = 1.3; s.setDrum(.hihat, hats)
    }

    public static let jazzFeel = make("jazz", "Jazz Feel", "Genre",
        "Triplet ride feel, feathered kick, wide dynamics and lots of conversation.") { s in
        s.groove.templateID = "groove.jazzride"
        s.groove.swing = 0.65
        s.groove.swingSubdivision = .eighth
        s.groove.intensity = 0.7
        s.timing.variation = 0.85
        s.timing.tightness = 0.3
        s.timing.drift = 0.5
        s.velocity.variation = 0.95
        s.velocity.range = 1.3
        s.velocity.curve = .expanded
        s.velocity.phraseDynamics = 0.75
        s.phraseVariation = 0.7
        var kick = s.drum(.kick); kick.velocity = 1.3; kick.accent = 0.2; s.setDrum(.kick, kick)
        s.articulation.allowAddedNotes = true
        s.articulation.addGhostNotes = 0.3
        s.articulation.drags = 0.2
    }

    public static let rockPerformance = make("rock", "Rock Performance", "Genre",
        "Big backbeat, confident cymbals, fills that build and land hard.") { s in
        s.intensity = 1.05
        s.groove.templateID = "groove.rockdrive"
        s.groove.intensity = 0.45
        s.groove.beatEmphasis = 0.6
        s.timing.variation = 0.6
        s.timing.phraseInfluence = 0.6
        s.velocity.accentIntensity = 0.7
        s.velocity.curve = .hard
        s.velocity.bias = 5
        var snare = s.drum(.snare); snare.special = 0.85; s.setDrum(.snare, snare)
        s.articulation.fillBuild = 0.8
        s.articulation.phraseEndAccent = 0.8
        s.articulation.allowAddedNotes = true
        s.articulation.flams = 0.25
    }

    public static let looseLive = make("loose-live", "Loose Live", "Feel",
        "A live take in a room: more wander, more push in fills, more dynamics.") { s in
        s.intensity = 1.25
        s.correlation = 0.7
        s.timing.variation = 1.0
        s.timing.tightness = 0.2
        s.timing.maxDeviationMs = 30
        s.timing.drift = 0.8
        s.timing.phraseInfluence = 0.8
        s.velocity.variation = 1.0
        s.velocity.range = 1.2
        s.velocity.phraseDynamics = 0.8
        s.phraseVariation = 0.8
        s.articulation.lengthVariation = 0.6
    }

    public static let electronicTight = make("electronic", "Electronic Tight", "Studio",
        "Machine-tight timing with just enough velocity life to stop it sounding static.") { s in
        s.intensity = 0.6
        s.timing.variation = 0.12
        s.timing.tightness = 0.95
        s.timing.maxDeviationMs = 5
        s.timing.microtiming = 0.1
        s.timing.drift = 0
        s.velocity.variation = 0.4
        s.velocity.repetitionVariation = 0.5
        s.velocity.phraseDynamics = 0.2
        s.velocity.curve = .compressed
        s.groove.swing = 0.06
        s.articulation.lengthVariation = 0
    }

    public static let shuffle = make("shuffle", "Shuffle", "Feel",
        "Triplet shuffle on the 8ths with a lifting backbeat.") { s in
        s.groove.templateID = "groove.shuffle"
        s.groove.intensity = 0.9
        s.groove.swing = 0.62
        s.groove.swingSubdivision = .eighth
        s.timing.variation = 0.6
        s.velocity.accentIntensity = 0.6
        s.velocity.repetitionVariation = 0.8
        s.articulation.hihatAccents = 0.75
    }
}

// MARK: - Quick mode

public enum Feel: String, Codable, CaseIterable, Sendable, Identifiable {
    case tight, natural, laidBack, ahead, behind, swing, shuffle, loose, aggressive, vintage, modern
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .tight: return "Tight"
        case .natural: return "Natural"
        case .laidBack: return "Laid-back"
        case .ahead: return "Ahead"
        case .behind: return "Behind"
        case .swing: return "Swing"
        case .shuffle: return "Shuffle"
        case .loose: return "Loose"
        case .aggressive: return "Aggressive"
        case .vintage: return "Vintage"
        case .modern: return "Modern"
        }
    }

    public var hint: String {
        switch self {
        case .tight: return "Steady and precise"
        case .natural: return "Like a good session drummer"
        case .laidBack: return "Relaxed, sits back"
        case .ahead: return "On top of the beat"
        case .behind: return "Clearly behind the beat"
        case .swing: return "Swung 16ths"
        case .shuffle: return "Triplet shuffle"
        case .loose: return "Live and wandering"
        case .aggressive: return "Hard, forward, big accents"
        case .vintage: return "Warm, soft, drifting"
        case .modern: return "Clean, punchy, controlled"
        }
    }

    func apply(to s: inout HumaniseSettings) {
        switch self {
        case .tight:
            s.timing.tightness = max(s.timing.tightness, 0.8); s.timing.variation *= 0.6; s.timing.drift *= 0.5
        case .natural:
            break
        case .laidBack:
            s.groove.pushPull = 0.6; s.timing.biasMs += 2
        case .ahead:
            s.groove.pushPull = -0.6; s.timing.biasMs -= 2
        case .behind:
            s.groove.pushPull = 1.0; s.timing.biasMs += 5
        case .swing:
            s.groove.swing = max(s.groove.swing, 0.35); s.groove.swingSubdivision = .sixteenth
        case .shuffle:
            s.groove.swing = max(s.groove.swing, 0.66); s.groove.swingSubdivision = .eighth
        case .loose:
            s.timing.tightness = min(s.timing.tightness, 0.25); s.timing.variation *= 1.4; s.timing.drift = max(s.timing.drift, 0.7)
            s.timing.maxDeviationMs = max(s.timing.maxDeviationMs, 28)
        case .aggressive:
            s.groove.pushPull = -0.4; s.velocity.curve = .hard; s.velocity.bias += 6; s.velocity.accentIntensity = max(0.75, s.velocity.accentIntensity)
        case .vintage:
            s.velocity.curve = .compressed; s.timing.drift = max(0.55, s.timing.drift); s.groove.pushPull = max(0.25, s.groove.pushPull)
            s.velocity.range *= 0.9
        case .modern:
            s.velocity.curve = .hard; s.timing.tightness = max(0.65, s.timing.tightness); s.timing.drift *= 0.4
        }
    }
}

/// The macro controls shown in Quick mode. Each one scales several engine parameters.
public struct QuickControls: Codable, Equatable, Hashable, Sendable {
    /// Overall human feel 0…1 (0.5 = the style's own amount).
    public var humanise: Double = 0.5
    /// Groove influence 0…1.
    public var groove: Double = 0.5
    /// Timing looseness 0…1.
    public var timing: Double = 0.5
    /// Dynamic variation 0…1.
    public var velocity: Double = 0.5
    /// How much the performance changes from phrase to phrase (0…1).
    public var variation: Double = 0.5
    public var feel: Feel = .natural
    /// Factory or user preset id used as the starting point.
    public var styleID: String = FactoryPresets.naturalDrummer.id
    /// Track-aware macro (0 = ignore the backing track).
    public var listen: Double = 0.6

    public init() {}

    /// Builds full engine settings from the macros on top of a base preset.
    public func settings(base: HumaniseSettings, seed: UInt64, trackAware: Bool) -> HumaniseSettings {
        var s = base
        s.seed = seed
        feel.apply(to: &s)
        let h = 2 * humanise           // 0…2, 1 = as designed
        s.intensity = clamp(s.intensity * (0.15 + 0.85 * h), 0, 1.6)
        s.timing.variation = clamp(s.timing.variation * (0.2 + 1.6 * timing), 0, 1.6)
        s.timing.drift = clamp(s.timing.drift * (0.3 + 1.4 * timing), 0, 1)
        s.velocity.variation = clamp(s.velocity.variation * (0.2 + 1.6 * velocity), 0, 1.6)
        s.velocity.range = clamp(s.velocity.range * (0.8 + 0.4 * velocity), 0.5, 1.6)
        s.velocity.phraseDynamics = clamp(s.velocity.phraseDynamics * (0.4 + 1.2 * velocity), 0, 1)
        s.groove.intensity = clamp(s.groove.intensity * (2 * groove), 0, 1)
        s.groove.swing = clamp(s.groove.swing * (0.3 + 1.4 * groove), 0, 1)
        s.groove.beatEmphasis = clamp(s.groove.beatEmphasis * (0.5 + groove), 0, 1)
        s.phraseVariation = clamp(variation, 0, 1)
        s.perDrumVariation = clamp(0.2 + 0.6 * variation, 0, 1)
        if s.articulation.allowAddedNotes {
            s.articulation.addGhostNotes = clamp(s.articulation.addGhostNotes * (0.4 + 1.2 * variation), 0, 1)
            s.articulation.flams = clamp(s.articulation.flams * (0.4 + 1.2 * variation), 0, 1)
            s.articulation.drags = clamp(s.articulation.drags * (0.4 + 1.2 * variation), 0, 1)
        }
        s.articulation.fillBuild = clamp(s.articulation.fillBuild * (0.6 + 0.8 * humanise), 0, 1)
        s.trackAware.enabled = trackAware && listen > 0.01
        s.trackAware.bandInteraction = clamp(listen, 0, 1)
        s.trackAware.grooveMatch = clamp(0.2 + 0.6 * groove, 0, 1)
        return s
    }
}

// MARK: - Preset storage

/// Stores user presets as one JSON file per preset in a folder. Factory presets live in code.
public final class PresetStore {
    public let folder: URL
    public private(set) var userPresets: [Preset] = []

    public init(folder: URL) {
        self.folder = folder
        reload()
    }

    public var allPresets: [Preset] { FactoryPresets.all + userPresets }

    public func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Preset] = []
        for url in files where url.pathExtension == "gcpreset" {
            if let p = try? PresetStore.read(url) { loaded.append(p) }
        }
        userPresets = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func read(_ url: URL) throws -> Preset {
        let data = try Data(contentsOf: url)
        let defaults = Preset(id: "user.\(UUID().uuidString)", name: url.deletingPathExtension().lastPathComponent,
                              category: "User", settings: HumaniseSettings())
        var p = try TolerantJSON.decode(Preset.self, from: data, defaults: defaults)
        p.isFactory = false
        return p
    }

    public static func encode(_ preset: Preset) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(preset)
    }

    private func url(for preset: Preset) -> URL {
        let safe = preset.id.replacingOccurrences(of: "/", with: "_")
        return folder.appendingPathComponent(safe).appendingPathExtension("gcpreset")
    }

    @discardableResult
    public func save(_ preset: Preset) throws -> Preset {
        var p = preset
        p.isFactory = false
        if p.id.hasPrefix("factory.") { p.id = "user.\(UUID().uuidString)" }
        try PresetStore.encode(p).write(to: url(for: p), options: .atomic)
        reload()
        return p
    }

    public func delete(_ preset: Preset) throws {
        guard !preset.isFactory else { return }
        let u = url(for: preset)
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
        reload()
    }

    public func rename(_ preset: Preset, to name: String) throws {
        var p = preset
        p.name = name
        try save(p)
    }

    public func duplicate(_ preset: Preset) throws -> Preset {
        let copy = Preset(name: preset.name + " Copy", category: preset.isFactory ? "User" : preset.category,
                          summary: preset.summary, settings: preset.settings)
        return try save(copy)
    }

    /// Imports a preset file exported from Groovecraft (gets a fresh id so it never clashes).
    public func importPreset(from file: URL) throws -> Preset {
        var p = try PresetStore.read(file)
        p.id = "user.\(UUID().uuidString)"
        return try save(p)
    }

    public func export(_ preset: Preset, to file: URL) throws {
        try PresetStore.encode(preset).write(to: file, options: .atomic)
    }

    public func search(_ text: String, category: String? = nil, favouritesOnly: Bool = false, favourites: Set<String> = []) -> [Preset] {
        allPresets.filter { p in
            if let c = category, p.category != c { return false }
            if favouritesOnly && !(p.isFavourite || favourites.contains(p.id)) { return false }
            if text.isEmpty { return true }
            return p.name.localizedCaseInsensitiveContains(text) || p.summary.localizedCaseInsensitiveContains(text)
                || p.category.localizedCaseInsensitiveContains(text)
        }
    }
}
