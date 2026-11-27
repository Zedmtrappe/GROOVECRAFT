import Foundation

/// The drum element a MIDI note plays.
public enum DrumCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case kick, snare, sideStick, closedHat, openHat, pedalHat
    case ride, rideBell, crash, splash, china
    case highTom, midTom, lowTom, floorTom
    case percussion, other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .kick: return "Kick"
        case .snare: return "Snare"
        case .sideStick: return "Side Stick"
        case .closedHat: return "Closed Hi-Hat"
        case .openHat: return "Open Hi-Hat"
        case .pedalHat: return "Pedal Hi-Hat"
        case .ride: return "Ride"
        case .rideBell: return "Ride Bell"
        case .crash: return "Crash"
        case .splash: return "Splash"
        case .china: return "China"
        case .highTom: return "High Tom"
        case .midTom: return "Mid Tom"
        case .lowTom: return "Low Tom"
        case .floorTom: return "Floor Tom"
        case .percussion: return "Percussion"
        case .other: return "Other"
        }
    }

    public var family: DrumFamily {
        switch self {
        case .kick: return .kick
        case .snare, .sideStick: return .snare
        case .closedHat, .openHat, .pedalHat: return .hihat
        case .ride, .rideBell, .crash, .splash, .china: return .cymbal
        case .highTom, .midTom, .lowTom, .floorTom: return .tom
        case .percussion: return .percussion
        case .other: return .other
        }
    }

    /// The limb a drummer would normally play this with (used for correlated timing and
    /// collision rules). Toms and crashes are "hands" shared between both arms.
    public var limb: Limb {
        switch self {
        case .kick: return .rightFoot
        case .pedalHat: return .leftFoot
        case .snare, .sideStick: return .leftHand
        case .closedHat, .openHat, .ride, .rideBell: return .rightHand
        case .crash, .splash, .china, .highTom, .midTom, .lowTom, .floorTom: return .hands
        case .percussion, .other: return .auxiliary
        }
    }

    /// Lane order in the drum grid (top to bottom).
    public var laneOrder: Int {
        switch self {
        case .crash: return 0
        case .china: return 1
        case .splash: return 2
        case .ride: return 3
        case .rideBell: return 4
        case .openHat: return 5
        case .closedHat: return 6
        case .pedalHat: return 7
        case .highTom: return 8
        case .midTom: return 9
        case .lowTom: return 10
        case .floorTom: return 11
        case .snare: return 12
        case .sideStick: return 13
        case .kick: return 14
        case .percussion: return 15
        case .other: return 16
        }
    }
}

/// Groups of drum elements that share controls in Advanced mode.
public enum DrumFamily: String, Codable, CaseIterable, Sendable, Identifiable {
    case kick, snare, hihat, cymbal, tom, percussion, other
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .kick: return "Kick"
        case .snare: return "Snare"
        case .hihat: return "Hi-Hats"
        case .cymbal: return "Cymbals"
        case .tom: return "Toms"
        case .percussion: return "Percussion"
        case .other: return "Other"
        }
    }
}

public enum Limb: String, Codable, CaseIterable, Sendable {
    case rightFoot, leftFoot, rightHand, leftHand, hands, auxiliary
}

/// One entry in a drum map: what a note number is called and which element it plays.
public struct DrumMapEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var note: Int
    public var name: String
    public var category: DrumCategory
    public var id: Int { note }

    public init(note: Int, name: String, category: DrumCategory) {
        self.note = note
        self.name = name
        self.category = category
    }
}

/// A named note → drum element map. Users can edit, save and load these; nothing assumes
/// every file (or drum plug-in) follows General MIDI.
public struct DrumMap: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var entries: [Int: DrumMapEntry]
    public var isFactory: Bool

    public init(id: String = UUID().uuidString, name: String, entries: [DrumMapEntry], isFactory: Bool = false) {
        self.id = id
        self.name = name
        var dict: [Int: DrumMapEntry] = [:]
        for e in entries { dict[e.note] = e }
        self.entries = dict
        self.isFactory = isFactory
    }

    public func entry(for note: Int) -> DrumMapEntry? { entries[note] }

    public func category(for note: Int) -> DrumCategory {
        entries[note]?.category ?? DrumMap.guessCategory(note: note)
    }

    public func name(for note: Int) -> String {
        entries[note]?.name ?? "Note \(note) (\(MIDINoteName.name(note)))"
    }

    public func isMapped(_ note: Int) -> Bool { entries[note] != nil }

    /// The first note mapped to a category (used when adding articulations such as open hats).
    public func note(for category: DrumCategory) -> Int? {
        let keys = entries.keys.sorted()
        for k in keys where entries[k]?.category == category { return k }
        return nil
    }

    public mutating func set(_ entry: DrumMapEntry) { entries[entry.note] = entry }
    public mutating func remove(note: Int) { entries.removeValue(forKey: note) }

    public var sortedEntries: [DrumMapEntry] { entries.values.sorted { $0.note < $1.note } }

    /// Best guess for notes that are not mapped (outside the GM range the guess is "other").
    public static func guessCategory(note: Int) -> DrumCategory {
        DrumMap.generalMIDI.entries[note]?.category ?? .other
    }

    // MARK: Factory maps

    public static let generalMIDI = DrumMap(id: "factory.gm", name: "General MIDI", entries: [
        DrumMapEntry(note: 35, name: "Acoustic Bass Drum", category: .kick),
        DrumMapEntry(note: 36, name: "Bass Drum", category: .kick),
        DrumMapEntry(note: 37, name: "Side Stick", category: .sideStick),
        DrumMapEntry(note: 38, name: "Acoustic Snare", category: .snare),
        DrumMapEntry(note: 39, name: "Hand Clap", category: .percussion),
        DrumMapEntry(note: 40, name: "Electric Snare", category: .snare),
        DrumMapEntry(note: 41, name: "Low Floor Tom", category: .floorTom),
        DrumMapEntry(note: 42, name: "Closed Hi-Hat", category: .closedHat),
        DrumMapEntry(note: 43, name: "High Floor Tom", category: .floorTom),
        DrumMapEntry(note: 44, name: "Pedal Hi-Hat", category: .pedalHat),
        DrumMapEntry(note: 45, name: "Low Tom", category: .lowTom),
        DrumMapEntry(note: 46, name: "Open Hi-Hat", category: .openHat),
        DrumMapEntry(note: 47, name: "Low-Mid Tom", category: .midTom),
        DrumMapEntry(note: 48, name: "Hi-Mid Tom", category: .midTom),
        DrumMapEntry(note: 49, name: "Crash Cymbal 1", category: .crash),
        DrumMapEntry(note: 50, name: "High Tom", category: .highTom),
        DrumMapEntry(note: 51, name: "Ride Cymbal 1", category: .ride),
        DrumMapEntry(note: 52, name: "Chinese Cymbal", category: .china),
        DrumMapEntry(note: 53, name: "Ride Bell", category: .rideBell),
        DrumMapEntry(note: 54, name: "Tambourine", category: .percussion),
        DrumMapEntry(note: 55, name: "Splash Cymbal", category: .splash),
        DrumMapEntry(note: 56, name: "Cowbell", category: .percussion),
        DrumMapEntry(note: 57, name: "Crash Cymbal 2", category: .crash),
        DrumMapEntry(note: 58, name: "Vibraslap", category: .percussion),
        DrumMapEntry(note: 59, name: "Ride Cymbal 2", category: .ride),
        DrumMapEntry(note: 60, name: "Hi Bongo", category: .percussion),
        DrumMapEntry(note: 61, name: "Low Bongo", category: .percussion),
        DrumMapEntry(note: 62, name: "Mute Hi Conga", category: .percussion),
        DrumMapEntry(note: 63, name: "Open Hi Conga", category: .percussion),
        DrumMapEntry(note: 64, name: "Low Conga", category: .percussion),
        DrumMapEntry(note: 65, name: "High Timbale", category: .percussion),
        DrumMapEntry(note: 66, name: "Low Timbale", category: .percussion),
        DrumMapEntry(note: 67, name: "High Agogo", category: .percussion),
        DrumMapEntry(note: 68, name: "Low Agogo", category: .percussion),
        DrumMapEntry(note: 69, name: "Cabasa", category: .percussion),
        DrumMapEntry(note: 70, name: "Maracas", category: .percussion),
        DrumMapEntry(note: 71, name: "Short Whistle", category: .percussion),
        DrumMapEntry(note: 72, name: "Long Whistle", category: .percussion),
        DrumMapEntry(note: 73, name: "Short Guiro", category: .percussion),
        DrumMapEntry(note: 74, name: "Long Guiro", category: .percussion),
        DrumMapEntry(note: 75, name: "Claves", category: .percussion),
        DrumMapEntry(note: 76, name: "Hi Wood Block", category: .percussion),
        DrumMapEntry(note: 77, name: "Low Wood Block", category: .percussion),
        DrumMapEntry(note: 78, name: "Mute Cuica", category: .percussion),
        DrumMapEntry(note: 79, name: "Open Cuica", category: .percussion),
        DrumMapEntry(note: 80, name: "Mute Triangle", category: .percussion),
        DrumMapEntry(note: 81, name: "Open Triangle", category: .percussion),
    ], isFactory: true)

    public static let factoryMaps: [DrumMap] = [generalMIDI]
}

/// Remaps notes on the way out to an external drum instrument whose layout differs from the
/// pattern's. Empty means "send notes unchanged".
public struct OutputNoteMap: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var remap: [Int: Int]

    public init(name: String = "Unchanged", remap: [Int: Int] = [:]) {
        self.name = name
        self.remap = remap
    }

    public func output(for note: Int) -> Int { remap[note] ?? note }

    public static let identity = OutputNoteMap()
}

public enum MIDINoteName {
    static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    /// Name with octave using the C3 = 60 convention that Logic Pro uses.
    public static func name(_ note: Int) -> String {
        let n = max(0, min(127, note))
        return "\(names[n % 12])\(n / 12 - 2)"
    }
}
