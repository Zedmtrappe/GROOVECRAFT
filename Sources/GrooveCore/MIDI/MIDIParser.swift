import Foundation

public enum MIDIFileError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case notAMIDIFile
    case truncated(String)
    case unsupportedFormat(Int)
    case invalidData(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "The file is empty."
        case .notAMIDIFile: return "This isn't a Standard MIDI File (no MThd header)."
        case .truncated(let w): return "The MIDI file is cut short (\(w))."
        case .unsupportedFormat(let f): return "MIDI format \(f) isn't supported."
        case .invalidData(let w): return "The MIDI file contains invalid data (\(w))."
        }
    }
}

/// Reads Standard MIDI Files (format 0, 1 and 2), including running status, SysEx, meta
/// events and SMPTE time division (converted to an equivalent PPQ at the file's tempo).
public enum MIDIParser {
    public static func parse(contentsOf url: URL) throws -> MIDIFile {
        let data = try Data(contentsOf: url)
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> MIDIFile {
        let bytes = [UInt8](data)
        if bytes.isEmpty { throw MIDIFileError.empty }
        var reader = ByteReader(bytes: bytes)

        // Some files carry a RIFF "RMID" wrapper.
        if bytes.count >= 12, bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46 {
            if let start = findChunk("MThd", in: bytes) { reader.position = start } else { throw MIDIFileError.notAMIDIFile }
        }

        guard let header = try? reader.readChunkID(), header == "MThd" else { throw MIDIFileError.notAMIDIFile }
        let headerLength = Int(try reader.readUInt32())
        guard headerLength >= 6 else { throw MIDIFileError.invalidData("header length \(headerLength)") }
        let formatValue = Int(try reader.readUInt16())
        let trackCount = Int(try reader.readUInt16())
        let division = try reader.readUInt16()
        if headerLength > 6 { try reader.skip(headerLength - 6) }

        guard let format = MIDIFile.Format(rawValue: formatValue) else {
            throw MIDIFileError.unsupportedFormat(formatValue)
        }

        var ppq: Int
        var smpteTicksPerSecond: Double? = nil
        if division & 0x8000 != 0 {
            // SMPTE: high byte is negative frames per second, low byte ticks per frame.
            let fps = Int(Int8(bitPattern: UInt8(division >> 8)))
            let framesPerSecond = Double(-fps) == 29 ? 29.97 : Double(-fps)
            let ticksPerFrame = Double(division & 0xFF)
            smpteTicksPerSecond = framesPerSecond * ticksPerFrame
            ppq = 480
        } else {
            ppq = Int(division)
            if ppq == 0 { throw MIDIFileError.invalidData("division is zero") }
        }

        var tracks: [MIDITrack] = []
        var index = 0
        while index < trackCount && !reader.atEnd {
            let id: String
            do { id = try reader.readChunkID() } catch { break }
            let length = Int(try reader.readUInt32())
            if id != "MTrk" {
                // Unknown chunk: skip it as the specification requires.
                try reader.skip(min(length, reader.remaining))
                continue
            }
            let available = min(length, reader.remaining)
            let chunk = Array(bytes[reader.position ..< reader.position + available])
            reader.position += available
            tracks.append(try parseTrack(chunk))
            index += 1
        }
        if tracks.isEmpty && trackCount > 0 { throw MIDIFileError.truncated("no track data") }

        var file = MIDIFile(format: format, ppq: ppq, tracks: tracks)
        if let tps = smpteTicksPerSecond {
            // Convert absolute SMPTE ticks to PPQ ticks at 120 BPM, inserting a matching tempo.
            let secondsPerTick = 1.0 / tps
            let ppqTicksPerSecond = Double(ppq) * 2.0
            for t in file.tracks.indices {
                for e in file.tracks[t].events.indices {
                    let seconds = Double(file.tracks[t].events[e].tick) * secondsPerTick
                    file.tracks[t].events[e].tick = Int((seconds * ppqTicksPerSecond).rounded())
                }
                file.tracks[t].events.removeAll { event in
                    if case .meta(let type, _) = event.kind { return type == MIDIMeta.tempo }
                    return false
                }
            }
            if !file.tracks.isEmpty { file.tracks[0].events.insert(.tempo(tick: 0, bpm: 120), at: 0) }
        }
        return file
    }

    static func parseTrack(_ bytes: [UInt8]) throws -> MIDITrack {
        var reader = ByteReader(bytes: bytes)
        var events: [MIDIEvent] = []
        var tick = 0
        var runningStatus: UInt8 = 0

        while !reader.atEnd {
            let delta: Int
            do { delta = try reader.readVLQ() } catch { break } // tolerate trailing padding
            tick += delta
            guard !reader.atEnd else { break }
            var status = try reader.readUInt8()

            if status == 0xFF {
                let type = try reader.readUInt8()
                let length = try reader.readVLQ()
                let data = try reader.readBytes(min(length, reader.remaining))
                events.append(MIDIEvent(tick: tick, kind: .meta(type: type, data: data)))
                if type == MIDIMeta.endOfTrack { break }
                continue
            }
            if status == 0xF0 || status == 0xF7 {
                let length = try reader.readVLQ()
                let data = try reader.readBytes(min(length, reader.remaining))
                let kind: MIDIEvent.Kind = status == 0xF0 ? .sysex(data: data) : .sysexEscape(data: data)
                events.append(MIDIEvent(tick: tick, kind: kind))
                runningStatus = 0
                continue
            }

            var firstData: UInt8
            if status < 0x80 {
                // Running status: this byte is data.
                guard runningStatus != 0 else { throw MIDIFileError.invalidData("data byte without status") }
                firstData = status
                status = runningStatus
            } else {
                runningStatus = status
                firstData = try reader.readUInt8()
            }

            let channel = Int(status & 0x0F)
            let type = status & 0xF0
            let d1 = Int(firstData & 0x7F)
            switch type {
            case 0x80:
                let d2 = Int(try reader.readUInt8() & 0x7F)
                events.append(MIDIEvent(tick: tick, kind: .noteOff(channel: channel, note: d1, velocity: d2)))
            case 0x90:
                let d2 = Int(try reader.readUInt8() & 0x7F)
                events.append(MIDIEvent(tick: tick, kind: .noteOn(channel: channel, note: d1, velocity: d2)))
            case 0xA0:
                let d2 = Int(try reader.readUInt8() & 0x7F)
                events.append(MIDIEvent(tick: tick, kind: .polyPressure(channel: channel, note: d1, pressure: d2)))
            case 0xB0:
                let d2 = Int(try reader.readUInt8() & 0x7F)
                events.append(MIDIEvent(tick: tick, kind: .controlChange(channel: channel, controller: d1, value: d2)))
            case 0xC0:
                events.append(MIDIEvent(tick: tick, kind: .programChange(channel: channel, program: d1)))
            case 0xD0:
                events.append(MIDIEvent(tick: tick, kind: .channelPressure(channel: channel, pressure: d1)))
            case 0xE0:
                let d2 = Int(try reader.readUInt8() & 0x7F)
                events.append(MIDIEvent(tick: tick, kind: .pitchBend(channel: channel, value: d1 | (d2 << 7))))
            default:
                throw MIDIFileError.invalidData(String(format: "status 0x%02X", status))
            }
        }
        // Make sure every track ends with End of Track.
        if events.last.map({ !$0.kind.isEndOfTrack }) ?? true {
            events.append(.endOfTrack(tick: tick))
        }
        return MIDITrack(events: events)
    }

    private static func findChunk(_ id: String, in bytes: [UInt8]) -> Int? {
        let pattern = Array(id.utf8)
        guard bytes.count >= pattern.count else { return nil }
        for i in 0 ... (bytes.count - pattern.count) where Array(bytes[i ..< i + pattern.count]) == pattern {
            return i
        }
        return nil
    }
}

struct ByteReader {
    let bytes: [UInt8]
    var position = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    var atEnd: Bool { position >= bytes.count }
    var remaining: Int { max(0, bytes.count - position) }

    mutating func readUInt8() throws -> UInt8 {
        guard position < bytes.count else { throw MIDIFileError.truncated("byte at \(position)") }
        let b = bytes[position]
        position += 1
        return b
    }

    mutating func readUInt16() throws -> UInt16 {
        let a = UInt16(try readUInt8())
        let b = UInt16(try readUInt8())
        return (a << 8) | b
    }

    mutating func readUInt32() throws -> UInt32 {
        var v: UInt32 = 0
        for _ in 0 ..< 4 { v = (v << 8) | UInt32(try readUInt8()) }
        return v
    }

    mutating func readVLQ() throws -> Int {
        var value = 0
        for _ in 0 ..< 4 {
            let b = try readUInt8()
            value = (value << 7) | Int(b & 0x7F)
            if b & 0x80 == 0 { return value }
        }
        throw MIDIFileError.invalidData("variable-length number too long")
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, position + count <= bytes.count else { throw MIDIFileError.truncated("\(count) bytes") }
        let slice = Array(bytes[position ..< position + count])
        position += count
        return slice
    }

    mutating func readChunkID() throws -> String {
        let b = try readBytes(4)
        return String(decoding: b, as: UTF8.self)
    }

    mutating func skip(_ count: Int) throws {
        guard position + count <= bytes.count else { throw MIDIFileError.truncated("skip") }
        position += count
    }
}
