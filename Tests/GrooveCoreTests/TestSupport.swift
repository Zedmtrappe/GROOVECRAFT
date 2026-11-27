import Foundation
@testable import GrooveCore

/// Builds simple drum files for tests.
enum Fixtures {
    /// A quantised 4/4 rock beat: kick on 1 and 3 (+ "and" of 3), snare on 2 and 4, 8th hats.
    static func rockBeat(bars: Int = 8, ppq: Int = 480, bpm: Double = 120, velocity: Int = 100,
                         fills: Bool = true, channel: Int = 9) -> MIDIFile {
        var drums: [MIDIEvent] = [.trackName("Drums")]
        func hit(_ tick: Int, _ note: Int, _ v: Int) {
            drums.append(MIDIEvent(tick: tick, kind: .noteOn(channel: channel, note: note, velocity: v)))
            drums.append(MIDIEvent(tick: tick + ppq / 8, kind: .noteOff(channel: channel, note: note, velocity: 0)))
        }
        for bar in 0 ..< bars {
            let start = bar * ppq * 4
            let fillBar = fills && bar % 4 == 3
            for e in 0 ..< 8 {
                let t = start + e * ppq / 2
                if !(fillBar && e >= 4) { hit(t, 42, velocity) }
            }
            hit(start, 36, velocity)
            hit(start + 2 * ppq, 36, velocity)
            hit(start + 2 * ppq + ppq / 2, 36, velocity)
            hit(start + ppq, 38, velocity)
            if fillBar {
                for s in 0 ..< 8 {
                    let t = start + 2 * ppq + s * ppq / 4
                    hit(t, [38, 38, 48, 48, 45, 45, 41, 41][s], velocity)
                }
            } else {
                hit(start + 3 * ppq, 38, velocity)
            }
        }
        let end = bars * ppq * 4
        drums.append(.endOfTrack(tick: end))
        var drumTrack = MIDITrack(events: drums)
        drumTrack.sortEvents()
        let tempo = MIDITrack(events: [.trackName("Tempo"), .tempo(tick: 0, bpm: bpm),
                                       .timeSignature(tick: 0, numerator: 4, denominator: 4), .endOfTrack(tick: end)])
        return MIDIFile(format: .multiTrack, ppq: ppq, tracks: [tempo, drumTrack])
    }

    static func input(_ file: MIDIFile, settings: HumaniseSettings = HumaniseSettings(),
                      context: PerformanceContext = .empty) -> HumanisationEngine.Input {
        let source = DrumPattern.detectSource(in: file)
        let pattern = DrumPattern.extract(from: file, source: source)
        let map = DrumMap.generalMIDI
        let analysis = PatternAnalyzer.analyze(pattern, tempoMap: file.tempoMap, map: map)
        return HumanisationEngine.Input(pattern: pattern, tempoMap: file.tempoMap, map: map, analysis: analysis,
                                        settings: settings, context: context)
    }
}
