import Foundation
import AVFoundation
import GrooveCore

/// Audio output for the built-in preview: the backing track and the synthesised kit, both
/// rendered by `PreviewRenderer` in one source node. Its timing is derived from the same
/// host-time anchor as the MIDI thread, so the backing track, the preview kit and external
/// MIDI all play from one clock.
final class AudioEngine {
    let engine: AVAudioEngine
    let renderer: PreviewRenderer
    private var source: AVAudioSourceNode?
    private(set) var isRunning = false
    private(set) var lastError: String?

    // Shared with the render thread. Written before `playing` is set.
    private var anchor: UInt64 = 0
    private var playing = false
    private var framesSinceStart: Int64 = 0

    init() {
        let e = AVAudioEngine()
        let rate = e.outputNode.outputFormat(forBus: 0).sampleRate
        engine = e
        renderer = PreviewRenderer(sampleRate: rate > 0 ? rate : 48_000)
        build()
    }

    private func build() {
        let rate = renderer.sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let node = AVAudioSourceNode(format: format) { [unowned self] _, timestamp, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let frames = Int(frameCount)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            var transport = -1.0
            if self.playing {
                let ts = timestamp.pointee
                if ts.mFlags.contains(.hostTimeValid) && ts.mHostTime > 0 {
                    transport = HostClock.interval(from: self.anchor, to: ts.mHostTime)
                } else {
                    transport = Double(self.framesSinceStart) / rate
                }
                self.framesSinceStart += Int64(frames)
            }
            self.renderer.render(transportTime: transport, frames: frames, left: l, right: r)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
    }

    func startEngine() {
        guard !engine.isRunning else { isRunning = true; return }
        do {
            engine.prepare()
            try engine.start()
            isRunning = true
            lastError = nil
        } catch {
            isRunning = false
            lastError = "Audio output couldn't start: \(error.localizedDescription)"
        }
    }

    func play(anchor host: UInt64, mapper: LoopMapper) {
        startEngine()
        anchor = host
        framesSinceStart = 0
        renderer.start(mapper: mapper)
        playing = true
    }

    func stop() {
        playing = false
        renderer.stop()
    }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }
}

/// Decodes audio files with AVFoundation (WAV, AIFF, CAF, MP3, AAC/M4A, ALAC, FLAC) into
/// floating-point buffers. The file itself is only read.
enum AudioFileLoader {
    struct Loaded {
        var left: [Float]
        var right: [Float]
        var sampleRate: Double
        var channels: Int
        var duration: Double
        var formatDescription: String
        var analysisBuffer: AudioBuffer {
            var mono = [Float](repeating: 0, count: left.count)
            for i in 0 ..< left.count { mono[i] = (left[i] + right[i]) * 0.5 }
            return AudioBuffer(mono: mono, sampleRate: sampleRate, channels: channels)
        }
    }

    enum LoadError: LocalizedError {
        case unreadable(String)
        case tooLong
        var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "The audio file couldn't be opened: \(why)"
            case .tooLong: return "This audio file is longer than 30 minutes. Please use a shorter mix-down."
            }
        }
    }

    static func load(_ url: URL) throws -> Loaded {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            // AVFoundation can't read it: try the built-in WAV/AIFF reader.
            if let buffer = try? PCMFileReader.read(url) {
                return Loaded(left: buffer.mono, right: buffer.mono, sampleRate: buffer.sampleRate, channels: buffer.channels,
                              duration: buffer.duration, formatDescription: "PCM")
            }
            throw LoadError.unreadable(error.localizedDescription)
        }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else { throw LoadError.unreadable("it contains no audio") }
        guard Double(frames) / format.sampleRate <= 30 * 60 else { throw LoadError.tooLong }
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw LoadError.unreadable("not enough memory")
        }
        do { try file.read(into: pcm) } catch { throw LoadError.unreadable(error.localizedDescription) }
        guard let data = pcm.floatChannelData else { throw LoadError.unreadable("unsupported sample format") }
        let count = Int(pcm.frameLength)
        let channels = Int(format.channelCount)
        let left = Array(UnsafeBufferPointer(start: data[0], count: count))
        let right = channels > 1 ? Array(UnsafeBufferPointer(start: data[1], count: count)) : left
        let ext = url.pathExtension.uppercased()
        let desc = "\(ext.isEmpty ? "Audio" : ext) · \(Int(format.sampleRate)) Hz · \(channels == 1 ? "mono" : "\(channels) ch")"
        return Loaded(left: left, right: right, sampleRate: format.sampleRate, channels: channels,
                      duration: Double(count) / format.sampleRate, formatDescription: desc)
    }

    static let supportedExtensions = ["wav", "wave", "aif", "aiff", "aifc", "caf", "mp3", "m4a", "aac", "flac", "alac"]
}
