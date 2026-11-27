import Foundation

/// Deterministic random numbers. The same seed always gives the same performance.
///
/// The engine draws numbers through `KeyedRandom`, which derives an independent stream from
/// (seed, note, purpose). Changing one control therefore doesn't reshuffle every other
/// random decision: moving the velocity slider leaves the timing the same.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Uniform in [-1, 1).
    public mutating func signedUnit() -> Double { unit() * 2 - 1 }

    /// Standard normal (Box–Muller).
    public mutating func gaussian() -> Double {
        let u1 = max(unit(), 1e-12)
        let u2 = unit()
        return (-2.0 * log(u1)).squareRoot() * cos(2.0 * Double.pi * u2)
    }

    public mutating func chance(_ probability: Double) -> Bool { unit() < probability }
}

public enum RandomPurpose: UInt64, Sendable {
    case timing = 1, velocity, microtiming, drift, articulation, ghost, flam, drag, roll
    case length, personality, sectionFlavour, hihatOpen, dynamics, accent, variationPick
}

public struct KeyedRandom: Sendable {
    public let seed: UInt64

    public init(seed: UInt64) { self.seed = seed }

    public func stream(_ purpose: RandomPurpose, _ key: Int = 0, _ sub: Int = 0) -> SeededRandom {
        var h = seed ^ (purpose.rawValue &* 0x100_0000_01B3)
        h = mix(h ^ UInt64(bitPattern: Int64(key)))
        h = mix(h ^ (UInt64(bitPattern: Int64(sub)) &* 0xC2B2_AE3D_27D4_EB4F))
        return SeededRandom(seed: h)
    }

    public func gaussian(_ purpose: RandomPurpose, _ key: Int, _ sub: Int = 0) -> Double {
        var s = stream(purpose, key, sub)
        return s.gaussian()
    }

    public func unit(_ purpose: RandomPurpose, _ key: Int, _ sub: Int = 0) -> Double {
        var s = stream(purpose, key, sub)
        return s.unit()
    }

    public func signedUnit(_ purpose: RandomPurpose, _ key: Int, _ sub: Int = 0) -> Double {
        var s = stream(purpose, key, sub)
        return s.signedUnit()
    }

    private func mix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Smooth random curve over time (value noise with cosine interpolation), used for slow
/// tempo drift and phrase-level dynamics. `at(x)` for x in "knots" returns about -1…1.
public struct SmoothNoise: Sendable {
    let random: KeyedRandom
    let purpose: RandomPurpose
    let key: Int

    public init(random: KeyedRandom, purpose: RandomPurpose, key: Int) {
        self.random = random
        self.purpose = purpose
        self.key = key
    }

    public func at(_ x: Double) -> Double {
        let i = Int(x.rounded(.down))
        let f = x - Double(i)
        let a = random.signedUnit(purpose, key, i)
        let b = random.signedUnit(purpose, key, i + 1)
        let t = (1 - cos(f * Double.pi)) / 2
        return a + (b - a) * t
    }
}

/// Soft limit: behaves linearly for small values and approaches ±limit smoothly, so variation
/// never hits an audible "wall" at the maximum deviation.
@inline(__always)
func softLimit(_ value: Double, _ limit: Double) -> Double {
    guard limit > 0 else { return 0 }
    return limit * tanh(value / limit)
}

@inline(__always)
func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }
