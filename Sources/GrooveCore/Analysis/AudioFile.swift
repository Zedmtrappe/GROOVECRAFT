import Foundation

/// Decoded audio: mono samples for analysis plus the original channel count and rate.
public struct AudioBuffer: Sendable {
    public var mono: [Float]
    public var sampleRate: Double
    public var channels: Int
    public var duration: Double { Double(mono.count) / max(1, sampleRate) }

    public init(mono: [Float], sampleRate: Double, channels: Int = 1) {
        self.mono = mono
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// Box-filtered decimation to roughly `targetRate` (integer factor), for analysis.
    public func downsampled(toAbout targetRate: Double) -> AudioBuffer {
        let factor = max(1, Int((sampleRate / targetRate).rounded(.down)))
        guard factor > 1 else { return self }
        var out = [Float](repeating: 0, count: mono.count / factor)
        mono.withUnsafeBufferPointer { src in
            for i in 0 ..< out.count {
                var sum: Float = 0
                let base = i * factor
                for k in 0 ..< factor { sum += src[base + k] }
                out[i] = sum / Float(factor)
            }
        }
        return AudioBuffer(mono: out, sampleRate: sampleRate / Double(factor), channels: channels)
    }
}

public enum AudioFileError: Error, LocalizedError, Equatable, Sendable {
    case unreadable
    case unsupported(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "The audio file couldn't be read."
        case .unsupported(let w): return "This audio format isn't supported (\(w))."
        case .empty: return "The audio file contains no audio."
        }
    }
}

/// A small, dependency-free PCM reader for WAV (RIFF/RF64-less) and AIFF/AIFF-C files.
/// The macOS app decodes through AVFoundation (which also handles MP3, FLAC, AAC and ALAC);
/// this reader is the fallback and lets the analysis engine be tested anywhere.
public enum PCMFileReader {
    public static func read(_ url: URL) throws -> AudioBuffer {
        guard let data = try? Data(contentsOf: url) else { throw AudioFileError.unreadable }
        return try read(data)
    }

    public static func read(_ data: Data) throws -> AudioBuffer {
        let b = [UInt8](data)
        guard b.count >= 12 else { throw AudioFileError.unreadable }
        let id = String(decoding: b[0 ..< 4], as: UTF8.self)
        if id == "RIFF" { return try readWAV(b) }
        if id == "FORM" { return try readAIFF(b) }
        throw AudioFileError.unsupported("not WAV or AIFF")
    }

    static func le16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    static func le32(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
    static func be16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
    static func be32(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }

    static func readWAV(_ b: [UInt8]) throws -> AudioBuffer {
        var pos = 12
        var format = 0, channels = 0, rate = 0, bits = 0
        var dataStart = -1, dataLength = 0
        while pos + 8 <= b.count {
            let cid = String(decoding: b[pos ..< pos + 4], as: UTF8.self)
            let len = le32(b, pos + 4)
            let body = pos + 8
            if cid == "fmt " && body + 16 <= b.count {
                format = le16(b, body)
                channels = le16(b, body + 2)
                rate = le32(b, body + 4)
                bits = le16(b, body + 14)
                if format == 0xFFFE && body + 26 <= b.count { format = le16(b, body + 24) } // extensible
            } else if cid == "data" {
                dataStart = body
                dataLength = min(len, b.count - body)
                break
            }
            pos = body + len + (len & 1)
        }
        guard dataStart >= 0, channels > 0, rate > 0 else { throw AudioFileError.unreadable }
        let isFloat = format == 3
        guard format == 1 || isFloat else { throw AudioFileError.unsupported("WAV format \(format)") }
        return try decode(b, start: dataStart, length: dataLength, channels: channels, bits: bits, float: isFloat,
                          bigEndian: false, rate: Double(rate))
    }

    static func readAIFF(_ b: [UInt8]) throws -> AudioBuffer {
        let form = String(decoding: b[8 ..< 12], as: UTF8.self)
        guard form == "AIFF" || form == "AIFC" else { throw AudioFileError.unsupported(form) }
        var pos = 12
        var channels = 0, bits = 0
        var rate = 0.0
        var compression = "NONE"
        var dataStart = -1, dataLength = 0
        while pos + 8 <= b.count {
            let cid = String(decoding: b[pos ..< pos + 4], as: UTF8.self)
            let len = be32(b, pos + 4)
            let body = pos + 8
            if cid == "COMM" && body + 18 <= b.count {
                channels = be16(b, body)
                bits = be16(b, body + 6)
                rate = extended80(Array(b[body + 8 ..< body + 18]))
                if form == "AIFC" && body + 22 <= b.count {
                    compression = String(decoding: b[body + 18 ..< body + 22], as: UTF8.self)
                }
            } else if cid == "SSND" && body + 8 <= b.count {
                let offset = be32(b, body)
                dataStart = body + 8 + offset
                dataLength = min(len - 8 - offset, b.count - dataStart)
            }
            pos = body + len + (len & 1)
        }
        guard dataStart >= 0, channels > 0, rate > 0 else { throw AudioFileError.unreadable }
        switch compression {
        case "NONE", "twos":
            return try decode(b, start: dataStart, length: dataLength, channels: channels, bits: bits, float: false, bigEndian: true, rate: rate)
        case "sowt":
            return try decode(b, start: dataStart, length: dataLength, channels: channels, bits: bits, float: false, bigEndian: false, rate: rate)
        case "fl32", "FL32":
            return try decode(b, start: dataStart, length: dataLength, channels: channels, bits: 32, float: true, bigEndian: true, rate: rate)
        default:
            throw AudioFileError.unsupported("AIFF-C \(compression)")
        }
    }

    /// IEEE 754 80-bit extended (AIFF sample rate).
    static func extended80(_ b: [UInt8]) -> Double {
        let exponent = ((Int(b[0]) & 0x7F) << 8) | Int(b[1])
        var mantissa: UInt64 = 0
        for i in 0 ..< 8 { mantissa = (mantissa << 8) | UInt64(b[2 + i]) }
        if exponent == 0 && mantissa == 0 { return 0 }
        let value = Double(mantissa) * pow(2.0, Double(exponent - 16383 - 63))
        return (b[0] & 0x80) != 0 ? -value : value
    }

    static func decode(_ b: [UInt8], start: Int, length: Int, channels: Int, bits: Int, float: Bool,
                       bigEndian: Bool, rate: Double) throws -> AudioBuffer {
        let bytesPerSample = (bits + 7) / 8
        guard [1, 2, 3, 4, 8].contains(bytesPerSample) else { throw AudioFileError.unsupported("\(bits)-bit") }
        let frameBytes = bytesPerSample * channels
        let frames = max(0, length / frameBytes)
        guard frames > 0 else { throw AudioFileError.empty }
        var mono = [Float](repeating: 0, count: frames)
        for f in 0 ..< frames {
            var sum = 0.0
            for c in 0 ..< channels {
                let i = start + f * frameBytes + c * bytesPerSample
                sum += sample(b, i, bytesPerSample, float, bigEndian)
            }
            mono[f] = Float(sum / Double(channels))
        }
        return AudioBuffer(mono: mono, sampleRate: rate, channels: channels)
    }

    @inline(__always)
    static func sample(_ b: [UInt8], _ i: Int, _ n: Int, _ float: Bool, _ big: Bool) -> Double {
        var raw: UInt64 = 0
        for k in 0 ..< n {
            let byte = UInt64(big ? b[i + k] : b[i + n - 1 - k])
            raw = (raw << 8) | byte
        }
        if float {
            if n == 4 { return Double(Float(bitPattern: UInt32(raw))) }
            if n == 8 { return Double(bitPattern: raw) }
            return 0
        }
        if n == 1 { return (Double(raw) - 128) / 128 }   // 8-bit WAV is unsigned
        let bitsTotal = n * 8
        let signBit: UInt64 = 1 << UInt64(bitsTotal - 1)
        let value = (raw & signBit) != 0 ? Int64(bitPattern: raw | ~((signBit << 1) - 1)) : Int64(raw)
        return Double(value) / Double(signBit)
    }

    /// Writes 16-bit PCM WAV (used by tests and for rendering previews).
    public static func wavData(_ samples: [Float], sampleRate: Int, channels: Int = 1) -> Data {
        var out: [UInt8] = []
        func u32(_ v: Int) { out += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        func u16(_ v: Int) { out += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        let dataBytes = samples.count * 2
        out += Array("RIFF".utf8); u32(36 + dataBytes); out += Array("WAVE".utf8)
        out += Array("fmt ".utf8); u32(16); u16(1); u16(channels); u32(sampleRate)
        u32(sampleRate * channels * 2); u16(channels * 2); u16(16)
        out += Array("data".utf8); u32(dataBytes)
        for s in samples {
            let v = Int((max(-1, min(1, s)) * 32767).rounded())
            u16(v & 0xFFFF)
        }
        return Data(out)
    }
}
