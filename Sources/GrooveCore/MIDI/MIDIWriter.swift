import Foundation

/// Writes Standard MIDI Files. Events are written in tick order; note-offs are written as
/// real note-off messages (0x8n) unless the original used note-on velocity 0.
public enum MIDIWriter {
    public static func data(for file: MIDIFile) -> Data {
        var out: [UInt8] = []
        out += Array("MThd".utf8)
        appendUInt32(6, to: &out)
        var format = file.format.rawValue
        if format == 0 && file.tracks.count > 1 { format = 1 }   // format 0 allows one track only
        appendUInt16(UInt16(format), to: &out)
        appendUInt16(UInt16(file.tracks.count), to: &out)
        appendUInt16(UInt16(max(1, min(0x7FFF, file.ppq))), to: &out)

        for track in file.tracks {
            var sortedTrack = track
            sortedTrack.sortEvents()
            let body = trackBytes(sortedTrack)
            out += Array("MTrk".utf8)
            appendUInt32(UInt32(body.count), to: &out)
            out += body
        }
        return Data(out)
    }

    public static func write(_ file: MIDIFile, to url: URL) throws {
        try data(for: file).write(to: url, options: .atomic)
    }

    static func trackBytes(_ track: MIDITrack) -> [UInt8] {
        var out: [UInt8] = []
        var lastTick = 0
        var sawEnd = false
        for event in track.events {
            if sawEnd { break }
            let tick = max(lastTick, event.tick)
            appendVLQ(tick - lastTick, to: &out)
            lastTick = tick
            switch event.kind {
            case .noteOff(let c, let n, let v):
                out += [0x80 | UInt8(c & 0x0F), UInt8(clamp7(n)), UInt8(clamp7(v))]
            case .noteOn(let c, let n, let v):
                out += [0x90 | UInt8(c & 0x0F), UInt8(clamp7(n)), UInt8(clamp7(v))]
            case .polyPressure(let c, let n, let p):
                out += [0xA0 | UInt8(c & 0x0F), UInt8(clamp7(n)), UInt8(clamp7(p))]
            case .controlChange(let c, let cc, let v):
                out += [0xB0 | UInt8(c & 0x0F), UInt8(clamp7(cc)), UInt8(clamp7(v))]
            case .programChange(let c, let p):
                out += [0xC0 | UInt8(c & 0x0F), UInt8(clamp7(p))]
            case .channelPressure(let c, let p):
                out += [0xD0 | UInt8(c & 0x0F), UInt8(clamp7(p))]
            case .pitchBend(let c, let v):
                let value = max(0, min(16383, v))
                out += [0xE0 | UInt8(c & 0x0F), UInt8(value & 0x7F), UInt8((value >> 7) & 0x7F)]
            case .meta(let type, let data):
                out += [0xFF, type]
                appendVLQ(data.count, to: &out)
                out += data
                if type == MIDIMeta.endOfTrack { sawEnd = true }
            case .sysex(let data):
                out.append(0xF0)
                appendVLQ(data.count, to: &out)
                out += data
            case .sysexEscape(let data):
                out.append(0xF7)
                appendVLQ(data.count, to: &out)
                out += data
            }
        }
        if !sawEnd {
            out += [0x00, 0xFF, MIDIMeta.endOfTrack, 0x00]
        }
        return out
    }

    static func clamp7(_ v: Int) -> Int { max(0, min(127, v)) }

    static func appendVLQ(_ value: Int, to out: inout [UInt8]) {
        var v = max(0, min(value, 0x0FFF_FFFF))
        var buffer: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            buffer.insert(UInt8((v & 0x7F) | 0x80), at: 0)
            v >>= 7
        }
        out += buffer
    }

    static func appendUInt16(_ v: UInt16, to out: inout [UInt8]) {
        out += [UInt8(v >> 8), UInt8(v & 0xFF)]
    }

    static func appendUInt32(_ v: UInt32, to out: inout [UInt8]) {
        out += [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
}
