import Foundation

/// A groove template: per-step timing offsets and velocity weights over one bar (or more).
///
/// Templates are plain data (JSON-codable), so new grooves can be added, imported, exported
/// and extracted from MIDI performances ("groove transfer") without code changes.
public struct GrooveTemplate: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var category: String
    /// Steps per quarter note (4 = 16ths, 3 = 8th triplets, 6 = 16th triplets).
    public var stepsPerBeat: Int
    /// Timing offset of each step as a fraction of one step (+ = late). Length = steps in the
    /// template; it repeats through the song.
    public var timing: [Double]
    /// Velocity weight of each step (1 = unchanged).
    public var velocity: [Double]
    /// Optional per-family timing offsets in milliseconds (e.g. snare sits back).
    public var familyOffsetsMs: [String: Double]
    public var notes: String

    public init(id: String, name: String, category: String, stepsPerBeat: Int = 4, timing: [Double],
                velocity: [Double], familyOffsetsMs: [String: Double] = [:], notes: String = "") {
        self.id = id
        self.name = name
        self.category = category
        self.stepsPerBeat = max(1, stepsPerBeat)
        self.timing = timing.isEmpty ? [0] : timing
        let v = velocity.isEmpty ? [1] : velocity
        self.velocity = v
        self.familyOffsetsMs = familyOffsetsMs
        self.notes = notes
    }

    public var stepCount: Int { max(timing.count, velocity.count) }

    public func timing(atStep step: Int) -> Double {
        timing[((step % timing.count) + timing.count) % timing.count]
    }

    public func velocity(atStep step: Int) -> Double {
        velocity[((step % velocity.count) + velocity.count) % velocity.count]
    }

    public func familyOffset(_ family: DrumFamily) -> Double { familyOffsetsMs[family.rawValue] ?? 0 }

    // MARK: Factory grooves

    /// Builds a swing template for 16 steps: off-beat 8ths (step 2 of each beat) or 16ths.
    static func swing16(_ id: String, _ name: String, ratio: Double, category: String = "Swing") -> GrooveTemplate {
        // A 16th-note swing moves the 2nd and 4th 16th of every beat. Ratio 0.5 = straight.
        let shift = (ratio - 0.5) * 2.0   // in steps
        var t: [Double] = []
        for i in 0 ..< 16 { t.append(i % 2 == 1 ? shift : 0) }
        let v: [Double] = (0 ..< 16).map { i in i % 4 == 0 ? 1.0 : (i % 2 == 0 ? 0.94 : 0.86) }
        return GrooveTemplate(id: id, name: name, category: category, timing: t, velocity: v,
                              notes: "16th swing, \(Int((ratio * 100).rounded()))%")
    }

    static func swing8(_ id: String, _ name: String, ratio: Double, category: String = "Swing") -> GrooveTemplate {
        // An 8th swing moves the off-beat 8th (3rd 16th of the beat) by (ratio-0.5) beats.
        let shift = (ratio - 0.5) * 4.0
        var t: [Double] = []
        for i in 0 ..< 16 {
            switch i % 4 {
            case 2: t.append(shift)
            case 3: t.append(shift * 0.66)       // an "a" 16th leans with the shuffle
            case 1: t.append(shift * 0.33)
            default: t.append(0)
            }
        }
        let v: [Double] = (0 ..< 16).map { i in i % 4 == 0 ? 1.0 : (i % 4 == 2 ? 0.9 : 0.8) }
        return GrooveTemplate(id: id, name: name, category: category, timing: t, velocity: v,
                              notes: "8th swing, \(Int((ratio * 100).rounded()))%")
    }

    public static let straight = GrooveTemplate(
        id: "groove.straight", name: "Straight", category: "Basic",
        timing: [Double](repeating: 0, count: 16),
        velocity: (0 ..< 16).map { i in i % 4 == 0 ? 1.0 : (i % 2 == 0 ? 0.95 : 0.9) },
        notes: "No timing groove; gentle metric velocity weighting.")

    public static let factory: [GrooveTemplate] = [
        straight,
        swing16("groove.swing16.54", "16th Swing 54%", ratio: 0.54),
        swing16("groove.swing16.58", "16th Swing 58%", ratio: 0.58),
        swing16("groove.swing16.62", "16th Swing 62%", ratio: 0.62),
        swing8("groove.swing8.60", "8th Swing 60%", ratio: 0.60),
        swing8("groove.shuffle", "Shuffle (triplet)", ratio: 0.667, category: "Shuffle"),
        swing8("groove.hardshuffle", "Hard Shuffle", ratio: 0.71, category: "Shuffle"),
        GrooveTemplate(
            id: "groove.funkpocket", name: "Funk Pocket", category: "Pocket",
            timing: [0, 0.10, 0.04, 0.14, 0.02, 0.12, 0.05, 0.16, 0, 0.10, 0.04, 0.14, 0.03, 0.12, 0.06, 0.18],
            velocity: [1.0, 0.72, 0.9, 0.78, 1.0, 0.72, 0.88, 0.8, 1.0, 0.72, 0.9, 0.78, 1.0, 0.74, 0.88, 0.84],
            familyOffsetsMs: ["snare": 6, "hihat": 2, "kick": -1],
            notes: "Tight downbeats, lazy 'e' and 'a' 16ths, snare sits back."),
        GrooveTemplate(
            id: "groove.hiphoppocket", name: "Hip-Hop Pocket", category: "Pocket",
            timing: [0, 0.16, 0.06, 0.22, 0, 0.18, 0.07, 0.24, 0, 0.16, 0.06, 0.22, 0, 0.18, 0.08, 0.25],
            velocity: [1.0, 0.7, 0.86, 0.74, 1.0, 0.7, 0.86, 0.76, 1.0, 0.7, 0.86, 0.74, 1.0, 0.7, 0.88, 0.78],
            familyOffsetsMs: ["snare": 14, "hihat": 6, "kick": 0],
            notes: "Laid-back, MPC-style lazy 16ths and a late snare."),
        GrooveTemplate(
            id: "groove.rockdrive", name: "Rock Drive", category: "Push",
            timing: [0, -0.02, -0.03, -0.02, 0, -0.02, -0.03, -0.02, 0, -0.02, -0.03, -0.02, 0, -0.02, -0.03, -0.02],
            velocity: [1.0, 0.86, 0.95, 0.86, 1.0, 0.86, 0.95, 0.86, 1.0, 0.86, 0.95, 0.86, 1.0, 0.86, 0.95, 0.86],
            familyOffsetsMs: ["hihat": -3, "snare": 2, "kick": -1],
            notes: "Hi-hat pushes slightly ahead, big quarter-note pulse."),
        GrooveTemplate(
            id: "groove.motown", name: "Vintage Soul", category: "Pocket",
            timing: [0, 0.06, 0.03, 0.08, 0.01, 0.06, 0.03, 0.09, 0, 0.06, 0.03, 0.08, 0.01, 0.07, 0.04, 0.1],
            velocity: [1.0, 0.78, 0.92, 0.8, 0.96, 0.78, 0.9, 0.8, 1.0, 0.78, 0.92, 0.8, 0.96, 0.78, 0.9, 0.82],
            familyOffsetsMs: ["snare": 8, "hihat": 3],
            notes: "Gentle drag on the backbeat and soft 16ths."),
        GrooveTemplate(
            id: "groove.jazzride", name: "Jazz Ride", category: "Swing", stepsPerBeat: 3,
            timing: [0, 0, 0.12, 0, 0, 0.12, 0, 0, 0.12, 0, 0, 0.12],
            velocity: [0.95, 0.7, 0.8, 1.0, 0.7, 0.86, 0.95, 0.7, 0.8, 1.0, 0.7, 0.86],
            familyOffsetsMs: ["cymbal": -2, "kick": 3],
            notes: "Triplet grid, the skip note leans late, accents on 2 and 4."),
        GrooveTemplate(
            id: "groove.halftime", name: "Half-Time Lay-back", category: "Pocket",
            timing: [0, 0.05, 0.08, 0.1, 0, 0.05, 0.08, 0.1, 0, 0.05, 0.08, 0.1, 0, 0.05, 0.08, 0.1],
            velocity: [1.0, 0.78, 0.86, 0.78, 0.96, 0.78, 0.86, 0.78, 1.0, 0.78, 0.86, 0.78, 0.96, 0.78, 0.86, 0.78],
            familyOffsetsMs: ["snare": 10, "hihat": 4],
            notes: "Everything falls back a touch, heavy backbeat."),
    ]

    public static func factory(id: String?) -> GrooveTemplate? {
        guard let id else { return nil }
        return factory.first { $0.id == id }
    }

    // MARK: Groove transfer

    /// Extracts a groove from a performed drum part: the average timing offset and relative
    /// velocity of each 16th-note step across the part.
    public static func extract(from pattern: DrumPattern, name: String, stepsPerBeat: Int = 4, beatsPerBar: Int = 4) -> GrooveTemplate? {
        let ppq = Double(pattern.ppq)
        let step = ppq / Double(stepsPerBeat)
        let steps = stepsPerBeat * beatsPerBar
        var offsetSum = [Double](repeating: 0, count: steps)
        var velSum = [Double](repeating: 0, count: steps)
        var count = [Double](repeating: 0, count: steps)
        for n in pattern.notes {
            let nearest = (n.tick / step).rounded()
            let offset = n.tick / step - nearest
            guard abs(offset) < 0.45 else { continue }
            let index = ((Int(nearest) % steps) + steps) % steps
            offsetSum[index] += offset
            velSum[index] += Double(n.velocity)
            count[index] += 1
        }
        guard count.reduce(0, +) >= 8 else { return nil }
        let meanVel = velSum.reduce(0, +) / max(1, count.reduce(0, +))
        var timing: [Double] = []
        var velocity: [Double] = []
        for i in 0 ..< steps {
            if count[i] > 0 {
                timing.append(offsetSum[i] / count[i])
                velocity.append(clamp((velSum[i] / count[i]) / max(1, meanVel), 0.5, 1.5))
            } else {
                timing.append(0)
                velocity.append(1)
            }
        }
        return GrooveTemplate(id: "user.\(UUID().uuidString)", name: name, category: "Extracted",
                              stepsPerBeat: stepsPerBeat, timing: timing, velocity: velocity,
                              notes: "Extracted from a MIDI performance.")
    }
}
