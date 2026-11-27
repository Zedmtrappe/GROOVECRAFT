import Foundation

/// Maps "transport time" (seconds since Play, always increasing) to "song position" (seconds
/// in the MIDI timeline), including loop wrap-around. Audio rendering and the MIDI scheduler
/// both use this one mapping, which is what keeps them in sync.
public struct LoopMapper: Equatable, Sendable {
    public var startPosition: Double
    public var loop: ClosedRange<Double>?

    public init(startPosition: Double, loop: ClosedRange<Double>? = nil) {
        if let l = loop, l.upperBound - l.lowerBound > 0.05 {
            self.loop = l
            // Starting after the loop's end plays through to it, then wraps from its start.
            self.startPosition = startPosition
        } else {
            self.loop = nil
            self.startPosition = startPosition
        }
    }

    var loopLength: Double { loop.map { $0.upperBound - $0.lowerBound } ?? 0 }

    /// Transport time at which the first wrap happens (nil without a loop).
    var firstWrapTime: Double? {
        guard let l = loop else { return nil }
        if startPosition < l.upperBound { return l.upperBound - startPosition }
        return nil
    }

    /// The first loop wrap strictly after transport time `t` (nil without a loop).
    public func nextWrap(after t: Double) -> Double? {
        guard let wrap = firstWrapTime else { return nil }
        if t < wrap { return wrap }
        let cycles = ((t - wrap) / loopLength).rounded(.down) + 1
        return wrap + cycles * loopLength
    }

    public func position(atTransport t: Double) -> Double {
        guard let l = loop, let wrap = firstWrapTime else { return startPosition + t }
        if t < wrap { return startPosition + t }
        let into = (t - wrap).truncatingRemainder(dividingBy: loopLength)
        return l.lowerBound + into
    }

    /// The song-position segments covered by a transport window, in order. Each segment says
    /// where it starts in transport time, so events can be placed exactly.
    public struct Segment: Equatable, Sendable {
        public var transportStart: Double
        public var from: Double
        public var to: Double
        /// True when this segment ends at the loop end (notes must be released there).
        public var endsAtWrap: Bool
    }

    public func segments(transportFrom a: Double, to b: Double) -> [Segment] {
        guard b > a else { return [] }
        guard let l = loop, let wrap = firstWrapTime else {
            return [Segment(transportStart: a, from: startPosition + a, to: startPosition + b, endsAtWrap: false)]
        }
        var out: [Segment] = []
        var t = a
        while t < b {
            let pos = position(atTransport: t)
            // Next wrap boundary in transport time.
            let nextWrap: Double
            if t < wrap {
                nextWrap = wrap
            } else {
                let cycles = ((t - wrap) / loopLength).rounded(.down) + 1
                nextWrap = wrap + cycles * loopLength
            }
            let end = min(b, nextWrap)
            let endsAtWrap = end == nextWrap
            out.append(Segment(transportStart: t, from: pos, to: pos + (end - t), endsAtWrap: endsAtWrap))
            t = end
            if out.count > 1000 { break }
        }
        _ = l
        return out
    }
}

/// MIDI 1.0 messages as bytes.
public enum MIDIBytes {
    public static func noteOn(_ channel: Int, _ note: Int, _ velocity: Int) -> [UInt8] {
        [0x90 | UInt8(channel & 0x0F), UInt8(clamp(note, 0, 127)), UInt8(clamp(velocity, 1, 127))]
    }
    public static func noteOff(_ channel: Int, _ note: Int) -> [UInt8] {
        [0x80 | UInt8(channel & 0x0F), UInt8(clamp(note, 0, 127)), 0]
    }
    public static func controlChange(_ channel: Int, _ controller: Int, _ value: Int) -> [UInt8] {
        [0xB0 | UInt8(channel & 0x0F), UInt8(clamp(controller, 0, 127)), UInt8(clamp(value, 0, 127))]
    }
    public static let clock: [UInt8] = [0xF8]
    public static let start: [UInt8] = [0xFA]
    public static let `continue`: [UInt8] = [0xFB]
    public static let stop: [UInt8] = [0xFC]
    /// Song Position Pointer in MIDI beats (16th notes).
    public static func songPosition(_ sixteenths: Int) -> [UInt8] {
        let v = clamp(sixteenths, 0, 16383)
        return [0xF2, UInt8(v & 0x7F), UInt8((v >> 7) & 0x7F)]
    }
    /// All Notes Off + Reset Controllers… actually only CC 123 (all notes off) and CC 64 = 0
    /// (sustain up), which every drum instrument understands without side effects.
    public static func panic(_ channel: Int) -> [[UInt8]] {
        [controlChange(channel, 64, 0), controlChange(channel, 123, 0)]
    }
}
