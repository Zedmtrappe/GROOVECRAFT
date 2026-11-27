import Foundation

/// What the engine knows about the song around the drums: section markers (from analysis or
/// the user) and, optionally, the analysed backing track lined up with the MIDI.
public struct PerformanceContext: Sendable {
    public var sections: [SectionMarker]
    public var audio: AudioContext?

    public init(sections: [SectionMarker] = [], audio: AudioContext? = nil) {
        self.sections = sections.sorted { $0.bar < $1.bar }
        self.audio = audio
    }

    public static let empty = PerformanceContext()

    /// The section a bar belongs to, the bar's index inside it, and the section's length.
    public func section(atBar bar: Int, totalBars: Int) -> (marker: SectionMarker, index: Int, barIndex: Int, length: Int)? {
        guard !sections.isEmpty else { return nil }
        var found: Int? = nil
        for (i, s) in sections.enumerated() where s.bar <= bar { found = i }
        guard let i = found else { return nil }
        let start = sections[i].bar
        let end = i + 1 < sections.count ? sections[i + 1].bar : max(totalBars, start + 1)
        return (sections[i], i, bar - start, max(1, end - start))
    }

    /// True when `bar` is the last bar before a new section starts.
    public func isBarBeforeBoundary(_ bar: Int) -> Bool {
        sections.contains { $0.bar == bar + 1 && $0.bar > 0 }
    }

    public func isSectionStart(_ bar: Int) -> Bool {
        sections.contains { $0.bar == bar && $0.bar > 0 }
    }
}

/// The analysed backing track as seen from the MIDI timeline.
public struct AudioContext: Sendable {
    public var analysis: BackingAnalysis
    public var alignment: Alignment
    private let energyMean: Double
    private let densityMean: Double
    private let bassTimes: [Double]

    public init(analysis: BackingAnalysis, alignment: Alignment) {
        self.analysis = analysis
        self.alignment = alignment
        self.energyMean = BackingAnalysis.mean(analysis.energy)
        self.densityMean = BackingAnalysis.mean(analysis.density)
        self.bassTimes = analysis.bassOnsets.map(\.time).sorted()
    }

    /// Energy around the note, centred: −1 (much quieter than usual) … +1 (much louder).
    public func energy(midiSeconds: Double) -> Double {
        let t = alignment.audioTime(midiSeconds: midiSeconds)
        guard t >= 0, t <= analysis.duration else { return 0 }
        let v = analysis.curveValue(analysis.energy, at: t)
        return clamp((v - energyMean) * 2.2, -1, 1)
    }

    /// Arrangement density, centred −1 (sparse) … +1 (busy).
    public func density(midiSeconds: Double) -> Double {
        let t = alignment.audioTime(midiSeconds: midiSeconds)
        guard t >= 0, t <= analysis.duration else { return 0 }
        let v = analysis.curveValue(analysis.density, at: t)
        return clamp((v - densityMean) * 2.2, -1, 1)
    }

    /// Vocal activity estimate 0…1.
    public func vocal(midiSeconds: Double) -> Double {
        let t = alignment.audioTime(midiSeconds: midiSeconds)
        guard t >= 0, t <= analysis.duration else { return 0 }
        return clamp(analysis.curveValue(analysis.vocalActivity, at: t), 0, 1)
    }

    /// The bass attack nearest to a MIDI time, if one is within `window` seconds.
    /// Returned as a MIDI time (seconds).
    public func nearestBassOnset(midiSeconds: Double, window: Double) -> Double? {
        guard !bassTimes.isEmpty else { return nil }
        let t = alignment.audioTime(midiSeconds: midiSeconds)
        var lo = 0
        var hi = bassTimes.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if bassTimes[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        var best: Double? = nil
        var bestDistance = window
        for i in [lo - 1, lo, lo + 1] where i >= 0 && i < bassTimes.count {
            let d = abs(bassTimes[i] - t)
            if d <= bestDistance {
                bestDistance = d
                best = bassTimes[i]
            }
        }
        guard let audioTime = best else { return nil }
        return alignment.midiSeconds(audioTime: audioTime)
    }

    /// The backing track's own groove offset for a 16th step (fraction of a 16th).
    public func grooveOffset(step16: Int) -> Double {
        let g = analysis.grooveOffsets
        guard g.count == 4 else { return 0 }
        return g[((step16 % 4) + 4) % 4] * analysis.grooveConfidence
    }
}
