import Foundation

/// A humanised take of the drum part. The original pattern is never modified: a performance
/// is a separate list of notes whose `id`s point back at the original notes.
public struct Performance: Codable, Equatable, Sendable {
    public var notes: [DrumNote]
    public var seed: UInt64
    public var stats: Stats

    public struct Stats: Codable, Equatable, Sendable {
        public var meanTimingShiftMs: Double = 0
        public var maxTimingShiftMs: Double = 0
        public var meanVelocityChange: Double = 0
        public var addedNotes: Int = 0
        public var changedNotes: Int = 0
        public init() {}
    }

    public init(notes: [DrumNote], seed: UInt64, stats: Stats = Stats()) {
        self.notes = notes
        self.seed = seed
        self.stats = stats
    }
}

/// The humanisation engine. Pure and deterministic: the same pattern, settings, seed and
/// context always produce the same performance.
///
/// Processing runs in stages, each musically motivated:
///  1. Musical context for every note (beat position, phrase, fills, ghost notes, limb…)
///  2. Timing: swing → groove template → feel (push/pull, per-drum position, personality)
///     → correlated per-limb variation and kit-wide drift → phrase and velocity influence
///     → backing-track lock (kick ↔ bass, groove match, energy)
///  3. Velocity: metric accents, backbeat, hi-hat hand patterns, groove weights, phrase
///     dynamics, section and energy response, random variation, range/curve, ghost protection
///  4. Articulation (optional, all marked as added): ghost notes, flams, drags, rolls,
///     hi-hat openings, lengths and chokes
///  5. Constraints: per-limb order, no same-drum overlaps, maximum deviation, valid ranges
public enum HumanisationEngine {
    public struct Input: Sendable {
        public var pattern: DrumPattern
        public var tempoMap: TempoMap
        public var map: DrumMap
        public var analysis: PatternAnalysis
        public var settings: HumaniseSettings
        public var context: PerformanceContext
        /// Only bars in this range are changed (nil = all).
        public var bars: ClosedRange<Int>?

        public init(pattern: DrumPattern, tempoMap: TempoMap, map: DrumMap, analysis: PatternAnalysis,
                    settings: HumaniseSettings, context: PerformanceContext = .empty, bars: ClosedRange<Int>? = nil) {
            self.pattern = pattern
            self.tempoMap = tempoMap
            self.map = map
            self.analysis = analysis
            self.settings = settings
            self.context = context
            self.bars = bars
        }
    }

    /// Per-note musical context.
    struct NoteContext {
        var category: DrumCategory
        var family: DrumFamily
        var limb: Limb
        var bar: Int
        var beat: Int
        var beatsInBar: Int
        var ticksPerBeat: Double
        var barFraction: Double
        /// 16th-step within the bar (straight grid) or nil when the note is off the straight grid.
        var step16: Int?
        /// Sub-position inside the beat: 0 = on the beat, 2 = off-beat 8th, 1/3 = 16ths.
        var subIndex: Int?
        var isTriplet: Bool
        var metricWeight: Double
        var isBackbeat: Bool
        var gridDeviationTicks: Double
        var isGhost: Bool
        var isAccent: Bool
        var isFillBar: Bool
        var isPhraseEndBar: Bool
        var isAfterFill: Bool
        var phraseIndex: Int
        var msPerTick: Double
        var seconds: Double
        var inRange: Bool
    }

    public static func humanise(_ input: Input) -> Performance {
        let s = input.settings
        let random = KeyedRandom(seed: s.seed)
        let original = input.pattern.notes
        guard !original.isEmpty else { return Performance(notes: [], seed: s.seed) }

        let contexts = original.map { makeContext($0, input: input) }
        let familyMeans = meanVelocities(original, contexts: contexts)

        // ---- Timing ----
        var shiftsMs = timingShifts(original, contexts: contexts, input: input, random: random, familyMeans: familyMeans)

        // ---- Velocity ----
        var velocities = velocityValues(original, contexts: contexts, input: input, random: random, familyMeans: familyMeans)

        // Notes outside the processed bars stay exactly as they were.
        for i in original.indices where !contexts[i].inRange {
            shiftsMs[i] = 0
            velocities[i] = original[i].velocity
        }

        var notes: [DrumNote] = []
        notes.reserveCapacity(original.count + 32)
        for (i, n) in original.enumerated() {
            var out = n
            out.tick = n.tick + shiftsMs[i] / contexts[i].msPerTick
            out.velocity = velocities[i]
            notes.append(out)
        }

        // ---- Articulation ----
        notes = applyLengths(notes, original: original, contexts: contexts, input: input, random: random)
        if s.articulation.allowAddedNotes {
            notes = addArticulations(notes, original: original, contexts: contexts, input: input, random: random, familyMeans: familyMeans)
        }
        if s.articulation.hihatOpenings > 0 && s.articulation.allowAddedNotes {
            notes = applyHihatOpenings(notes, contexts: contexts, original: original, input: input, random: random)
        }

        // ---- Constraints ----
        notes = enforceConstraints(notes, original: original, input: input)

        return Performance(notes: notes, seed: s.seed, stats: computeStats(notes, original: original, tempoMap: input.tempoMap))
    }

    // MARK: - Context

    static func makeContext(_ n: DrumNote, input: Input) -> NoteContext {
        let map = input.map
        let category = map.category(for: n.pitch)
        let pos = input.tempoMap.position(atTick: n.tick)
        let tpb = pos.ticksPerBeat
        let inBar = n.tick - pos.barStartTick
        let ticksPerBar = tpb * Double(pos.beatsInBar)

        // Nearest straight 16th and nearest triplet 8th/16th.
        let step16Ticks = tpb / 4
        let stepTripTicks = tpb / 6
        let n16 = (inBar / step16Ticks).rounded()
        let d16 = inBar - n16 * step16Ticks
        let nT = (inBar / stepTripTicks).rounded()
        let dT = inBar - nT * stepTripTicks
        // A note is "triplet" when it sits nearer a triplet position that isn't also straight.
        let triplet = Int(nT) % 3 != 0 && abs(dT) < abs(d16)
        var step16: Int? = nil
        var subIndex: Int? = nil
        var weight = 0.2
        let deviation: Double
        if triplet {
            deviation = dT
            let sub = ((Int(nT) % 6) + 6) % 6
            weight = sub == 3 ? 0.4 : 0.3
        } else {
            deviation = d16
            let s16 = Int(n16)
            step16 = s16
            let sub = ((s16 % 4) + 4) % 4
            subIndex = sub
            switch sub {
            case 0: weight = 0.75
            case 2: weight = 0.45
            default: weight = 0.25
            }
        }
        let onBeat = subIndex == 0
        let beatIndex = Int((inBar / tpb).rounded(.down))
        if onBeat {
            let roundedBeat = Int(((inBar - deviation) / tpb).rounded()) % max(1, pos.beatsInBar)
            if roundedBeat == 0 { weight = 1.0 } else if pos.beatsInBar == 4 && roundedBeat == 2 { weight = 0.85 }
        }
        let backbeat = onBeat && isBackbeat(beat: Int(((inBar - deviation) / tpb).rounded()) % max(1, pos.beatsInBar),
                                            numerator: pos.beatsInBar,
                                            denominator: input.tempoMap.signature(atTick: n.tick).denominator)

        let fills = input.analysis.fillBars
        let phrase = max(1, input.analysis.phraseLength)
        let phraseEnd = (pos.bar + 1) % phrase == 0
        let afterFill = fills.contains(pos.bar - 1) && inBar < tpb * 0.5
        let msPerTick = 60_000.0 / (input.tempoMap.bpm(atTick: Int(n.tick)) * Double(input.tempoMap.ppq))
        var inRange = true
        if let r = input.bars { inRange = r.contains(pos.bar) }

        return NoteContext(
            category: category, family: category.family, limb: category.limb, bar: pos.bar, beat: beatIndex,
            beatsInBar: pos.beatsInBar, ticksPerBeat: tpb, barFraction: clamp(inBar / ticksPerBar, 0, 1),
            step16: step16, subIndex: subIndex, isTriplet: step16 == nil, metricWeight: weight,
            isBackbeat: backbeat, gridDeviationTicks: deviation,
            isGhost: input.analysis.ghostNoteIDs.contains(n.id), isAccent: input.analysis.accentIDs.contains(n.id),
            isFillBar: fills.contains(pos.bar), isPhraseEndBar: phraseEnd, isAfterFill: afterFill,
            phraseIndex: pos.bar / phrase, msPerTick: msPerTick, seconds: input.tempoMap.seconds(atTick: n.tick),
            inRange: inRange)
    }

    static func isBackbeat(beat: Int, numerator: Int, denominator: Int) -> Bool {
        if denominator == 8 && numerator % 3 == 0 {
            // Compound meters: the second dotted-quarter pulse of each pair (6/8 beat 4, 12/8 beats 4 and 10).
            return beat % 6 == 3
        }
        switch numerator {
        case 2: return beat == 1
        case 4: return beat == 1 || beat == 3
        case 3: return false
        default: return beat % 2 == 1
        }
    }

    static func meanVelocities(_ notes: [DrumNote], contexts: [NoteContext]) -> [Int: Double] {
        var sum: [Int: Double] = [:]
        var count: [Int: Double] = [:]
        for (i, n) in notes.enumerated() where !contexts[i].isGhost {
            sum[n.pitch, default: 0] += Double(n.velocity)
            count[n.pitch, default: 0] += 1
        }
        var out: [Int: Double] = [:]
        for (p, s) in sum { out[p] = s / max(1, count[p] ?? 1) }
        return out
    }

    // MARK: - Timing

    static func familyFeelMs(_ family: DrumFamily) -> Double {
        switch family {
        case .snare: return 12
        case .hihat: return 6
        case .kick: return 4
        case .cymbal: return 6
        case .tom: return 8
        case .percussion: return 8
        case .other: return 5
        }
    }

    static func familyIndex(_ family: DrumFamily) -> Int {
        DrumFamily.allCases.firstIndex(of: family) ?? 0
    }

    static func timingShifts(_ notes: [DrumNote], contexts: [NoteContext], input: Input, random: KeyedRandom,
                             familyMeans: [Int: Double]) -> [Double] {
        let s = input.settings
        let t = s.timing
        let g = s.groove
        let ta = s.trackAware
        let ppq = Double(input.pattern.ppq)
        let analysis = input.analysis
        let template = g.template
        let alreadyPlayed = !analysis.isQuantised
        let drift = SmoothNoise(random: random, purpose: .drift, key: 0)
        let phraseLen = max(1, analysis.phraseLength)

        // Correlated per-limb noise state.
        var limbState: [Limb: (value: Double, tick: Double)] = [:]
        var shifts = [Double](repeating: 0, count: notes.count)

        // Swing already in the part is not doubled.
        let existingSwing = analysis.swingRatio > 0.53 || analysis.grid == .mixed
        let swingScale = existingSwing ? (1 - g.preserveExisting) : 1.0
        let swingRatio = g.swingRatio
        let grooveScale = alreadyPlayed ? (1 - 0.7 * g.preserveExisting) : 1.0

        for (i, n) in notes.enumerated() {
            let c = contexts[i]
            let drum = s.drum(c.family)
            let tpb = c.ticksPerBeat
            var deliberateTicks = 0.0   // swing and groove: not limited by the maximum deviation
            var feelMs = 0.0
            var randomMs = 0.0

            // 1. Swing (only for notes sitting on the straight grid).
            if let sub = c.subIndex, swingRatio > 0.5005, abs(c.gridDeviationTicks) < tpb / 32 {
                var amount = 0.0
                switch g.swingSubdivision {
                case .eighth:
                    if sub == 2 { amount = (swingRatio - 0.5) * tpb }
                    else if sub == 1 || sub == 3 { amount = (swingRatio - 0.5) * tpb * 0.5 }
                case .sixteenth:
                    if sub == 1 || sub == 3 { amount = (swingRatio - 0.5) * tpb * 0.5 }
                }
                let familySwing = c.family == .hihat ? (0.7 + 0.6 * drum.special) : 1.0
                deliberateTicks += amount * swingScale * min(1.2, familySwing)
            }

            // 2. Groove template.
            if let tpl = template, g.intensity > 0 {
                let stepTicks = tpb / Double(tpl.stepsPerBeat)
                let inBar = c.barFraction * tpb * Double(c.beatsInBar)
                let stepValue = inBar / stepTicks
                let nearest = stepValue.rounded()
                if abs(stepValue - nearest) < 0.2 {
                    let off = tpl.timing(atStep: Int(nearest))
                    deliberateTicks += g.intensity * grooveScale * off * stepTicks
                }
                feelMs += g.intensity * tpl.familyOffset(c.family)
            }

            // 3. Feel: push/pull, kit bias, per-drum groove position and drummer personality.
            let pp = g.pushPull * familyFeelMs(c.family) * (c.isBackbeat ? 1.0 : 0.7)
            feelMs += pp + t.biasMs + drum.offsetMs
            let personality = random.gaussian(.personality, familyIndex(c.family))
            feelMs += t.microtiming * 3.5 * personality * (0.4 + s.perDrumVariation)

            // 4. Random variation: correlated per limb + kit-wide drift.
            let tight = clamp(t.tightness * 0.6 + drum.tightness * 0.4, 0, 1)
            let tightFactor = 1 - 0.7 * tight
            let posFactor = 1 + t.beatPositionInfluence * (0.35 - 0.6 * c.metricWeight)
            var sigma = 6.0 * t.variation * s.intensity * drum.timing * tightFactor * max(0.3, posFactor)
            if alreadyPlayed { sigma *= (1 - t.preserveExisting * 0.8) }
            if c.isAfterFill { sigma *= 0.6 }    // land the downbeat after a fill

            // Track-aware: busy arrangements get tighter drums.
            var energy = 0.0
            if let audio = input.context.audio, ta.enabled {
                let d = audio.density(midiSeconds: c.seconds)
                if d > 0 { sigma *= 1 - 0.3 * ta.scaled(ta.arrangementSensitivity) * d }
                energy = audio.energy(midiSeconds: c.seconds)
            }

            let rho = clamp(s.correlation, 0, 0.98) * 0.88
            let previous = limbState[c.limb]
            let gapBeats = previous.map { max(0, (n.tick - $0.tick) / ppq) } ?? 4
            let rhoEff = pow(rho, max(0.25, gapBeats * 2))
            let fresh = random.gaussian(.timing, n.id)
            let value = (previous?.value ?? 0) * rhoEff + (1 - rhoEff * rhoEff).squareRoot() * fresh
            limbState[c.limb] = (value, n.tick)
            randomMs += sigma * value

            // Slow drift of the whole kit, a knot every two bars, varying by phrase.
            let barPosition = Double(c.bar) + c.barFraction
            let phraseAmp = 1 + s.phraseVariation * 0.5 * random.signedUnit(.drift, 7, c.bar / phraseLen)
            randomMs += t.drift * 5.0 * s.intensity * phraseAmp * drift.at(barPosition / 2)

            // 5. Louder hits slightly earlier.
            if let mean = familyMeans[n.pitch] {
                randomMs -= t.velocityInfluence * 2.5 * (Double(n.velocity) - mean) / 40
            }

            // 6. Fills push forward towards their end.
            if c.isFillBar {
                randomMs -= t.phraseInfluence * 5 * s.intensity * c.barFraction * c.barFraction
            }

            // 7. Track-aware energy: energetic passages sit a touch on top.
            if ta.enabled && input.context.audio != nil {
                feelMs -= ta.scaled(ta.energyResponse) * 1.5 * energy
            }

            let limited = softLimit(feelMs + randomMs, t.maxDeviationMs)
            var total = deliberateTicks * c.msPerTick + limited

            // 8. Track-aware timing: kick ↔ bass lock and groove match.
            if let audio = input.context.audio, ta.enabled {
                if ta.grooveMatch > 0, let step = c.step16 {
                    let off = audio.grooveOffset(step16: step)
                    total += ta.scaled(ta.grooveMatch) * off * (tpb / 4) * c.msPerTick
                }
                if c.family == .kick, ta.kickBassLock > 0 {
                    let window = 0.045
                    if let bass = audio.nearestBassOnset(midiSeconds: c.seconds, window: window) {
                        let targetMs = (bass - c.seconds) * 1000
                        let lock = ta.scaled(ta.kickBassLock) * (0.5 + drum.special)
                        let w = clamp(lock * 0.9, 0, 0.95)
                        total = total + w * (targetMs - total)
                    }
                }
            }

            // Never move a note further than the deliberate shift + maximum deviation.
            let cap = abs(deliberateTicks * c.msPerTick) + t.maxDeviationMs
            shifts[i] = clamp(total, -cap, cap)
        }
        return shifts
    }

    // MARK: - Velocity

    struct SectionProfile {
        var velocity: Double
        var cymbals: Double
        var backbeat: Double
        var addedNotes: Double
        var ramp: Double
    }

    static func sectionProfile(_ kind: SectionKind) -> SectionProfile {
        switch kind {
        case .intro: return SectionProfile(velocity: -4, cymbals: -4, backbeat: 0, addedNotes: 0.6, ramp: 0)
        case .verse: return SectionProfile(velocity: -6, cymbals: -6, backbeat: -1, addedNotes: 0.8, ramp: 0)
        case .preChorus: return SectionProfile(velocity: -2, cymbals: 0, backbeat: 1, addedNotes: 0.8, ramp: 10)
        case .chorus: return SectionProfile(velocity: 7, cymbals: 8, backbeat: 5, addedNotes: 1.0, ramp: 0)
        case .bridge: return SectionProfile(velocity: 0, cymbals: 2, backbeat: 0, addedNotes: 1.0, ramp: 0)
        case .breakdown: return SectionProfile(velocity: -11, cymbals: -10, backbeat: -3, addedNotes: 0.4, ramp: 0)
        case .solo: return SectionProfile(velocity: 3, cymbals: 4, backbeat: 2, addedNotes: 1.1, ramp: 0)
        case .outro: return SectionProfile(velocity: -2, cymbals: 0, backbeat: 0, addedNotes: 0.7, ramp: -8)
        case .transition: return SectionProfile(velocity: 2, cymbals: 2, backbeat: 2, addedNotes: 1.2, ramp: 6)
        case .unknown: return SectionProfile(velocity: 0, cymbals: 0, backbeat: 0, addedNotes: 1, ramp: 0)
        }
    }

    static func velocityValues(_ notes: [DrumNote], contexts: [NoteContext], input: Input, random: KeyedRandom,
                               familyMeans: [Int: Double]) -> [Int] {
        let s = input.settings
        let v = s.velocity
        let g = s.groove
        let a = s.articulation
        let ta = s.trackAware
        let analysis = input.analysis
        let template = g.template
        let shaping = 0.35 + 0.65 * (1 - analysis.velocityVariety)
        let dynamics = SmoothNoise(random: random, purpose: .dynamics, key: 0)
        let phraseLen = Double(max(1, analysis.phraseLength))
        let totalBars = analysis.bars

        // Repetition: count consecutive hits of the same pitch to alternate "hands".
        var lastTickByPitch: [Int: Double] = [:]
        var strokeByPitch: [Int: Int] = [:]
        var previousNoise: [Limb: Double] = [:]
        var out = [Int](repeating: 0, count: notes.count)

        for (i, n) in notes.enumerated() {
            let c = contexts[i]
            let drum = s.drum(c.family)
            let original = Double(n.velocity)
            let mean = familyMeans[n.pitch] ?? original
            var value = original

            if c.isGhost {
                // Ghost notes: scale and vary inside a protected range.
                var ghost = original * v.ghostLevel
                let spread = 2.5 + drum.ghostHandling * 4
                ghost += spread * v.variation * s.intensity * random.gaussian(.velocity, n.id)
                if v.protectGhosts {
                    let floor = max(10, original * 0.6)
                    let ceiling = max(floor + 1, min(original * 1.45, mean - 10))
                    ghost = clamp(ghost, floor, ceiling)
                }
                out[i] = Int(clamp(ghost.rounded(), 1, 127))
                continue
            }

            // Metric accents.
            let metric = v.beatPositionVariation * drum.accent * 0.22 * (c.metricWeight - 0.55)
            value *= 1 + shaping * metric

            // Hi-hat / ride quarter-note accents.
            if c.family == .hihat || c.category == .ride {
                let onQuarter = c.subIndex == 0
                value *= 1 + a.hihatAccents * shaping * 0.16 * (onQuarter ? 1 : -0.4)
            }

            // Groove velocity weights.
            if let tpl = template, g.intensity > 0 {
                let stepTicks = c.ticksPerBeat / Double(tpl.stepsPerBeat)
                let inBar = c.barFraction * c.ticksPerBeat * Double(c.beatsInBar)
                let step = Int((inBar / stepTicks).rounded())
                value *= 1 + g.intensity * (tpl.velocity(atStep: step) - 1) * (0.6 + 0.4 * shaping)
            }

            // Beat / off-beat emphasis.
            if c.subIndex == 0 { value += g.beatEmphasis * 6 * shaping }
            if c.subIndex == 2 { value += g.offbeatEmphasis * 10 }

            // Snare backbeat.
            if c.family == .snare && c.isBackbeat {
                value += (drum.special * 10 - 2) * shaping
            }

            // Existing accents get a little more confidence.
            if c.isAccent { value += v.accentIntensity * 6 }

            // Repetition: alternating hands on fast repeated notes.
            let spacing = n.tick - (lastTickByPitch[n.pitch] ?? -1e9)
            if spacing <= c.ticksPerBeat / 2 + 1 {
                strokeByPitch[n.pitch, default: 0] += 1
            } else {
                strokeByPitch[n.pitch] = 0
            }
            lastTickByPitch[n.pitch] = n.tick
            let stroke = strokeByPitch[n.pitch] ?? 0
            if spacing <= c.ticksPerBeat / 2 + 1 {
                let lead = stroke % 2 == 0 ? 1.0 : -1.0
                let handScale = c.family == .hihat ? (0.6 + drum.special * 0.8) : 0.6
                value *= 1 + v.repetitionVariation * 0.07 * lead * handScale
            }

            // Phrase dynamics and fill builds.
            let bp = Double(c.bar) + c.barFraction
            value *= 1 + v.phraseDynamics * 0.06 * dynamics.at(bp / phraseLen * 2)
            if c.isFillBar {
                let build = c.family == .tom || c.family == .snare ? 1.0 : 0.5
                value *= 1 + a.fillBuild * 0.14 * build * (c.barFraction - 0.35)
            }
            if c.isAfterFill && c.subIndex == 0 && (c.family == .kick || c.family == .cymbal || c.family == .snare) {
                value += a.phraseEndAccent * 10
            }

            // Sections (markers from analysis or the user) and backing-track response.
            if ta.enabled {
                let sectionScale = input.context.audio == nil ? ta.sectionAwareness : ta.scaled(ta.sectionAwareness)
                if sectionScale > 0, let sec = input.context.section(atBar: c.bar, totalBars: totalBars) {
                    let p = sectionProfile(sec.marker.kind)
                    let flavour = 1 + 0.3 * random.signedUnit(.sectionFlavour, sec.index)
                    var delta = p.velocity * flavour
                    if c.family == .cymbal || c.category == .openHat { delta += p.cymbals * flavour }
                    if c.family == .snare && c.isBackbeat { delta += p.backbeat }
                    if p.ramp != 0 {
                        let progress = (Double(sec.barIndex) + c.barFraction) / Double(sec.length)
                        delta += p.ramp * (progress - 0.5)
                    }
                    value += sectionScale * delta
                }
                let phraseScale = input.context.audio == nil ? ta.phraseAwareness : ta.scaled(ta.phraseAwareness)
                if phraseScale > 0 {
                    if input.context.isBarBeforeBoundary(c.bar) { value *= 1 + phraseScale * 0.08 * c.barFraction }
                    if input.context.isSectionStart(c.bar) && c.subIndex == 0 && c.barFraction < 0.01 {
                        value += phraseScale * 8
                    }
                }
                if let audio = input.context.audio {
                    let e = audio.energy(midiSeconds: c.seconds)
                    let cymbalBoost = c.family == .cymbal ? 1.4 : 1.0
                    value += ta.scaled(ta.energyResponse) * 12 * e * cymbalBoost
                    let d = audio.density(midiSeconds: c.seconds)
                    if d < 0 { value += ta.scaled(ta.arrangementSensitivity) * 4 * d }
                    if c.family == .cymbal {
                        value -= ta.scaled(ta.vocalSpace) * 6 * audio.vocal(midiSeconds: c.seconds)
                    }
                }
            }

            // Random variation, slightly correlated per limb.
            let rho = clamp(s.correlation, 0, 0.95) * 0.5
            let fresh = random.gaussian(.velocity, n.id)
            let noise = (previousNoise[c.limb] ?? 0) * rho + (1 - rho * rho).squareRoot() * fresh
            previousNoise[c.limb] = noise
            value += noise * 7 * v.variation * s.intensity * drum.velocity

            // Range, bias and curve.
            value = mean + (value - mean) * v.range
            value += v.bias
            value = applyCurve(value, v.curve)

            // Limits: no huge jumps from the original, inside min/max.
            let maxChange = Double(max(1, v.maxChange))
            value = clamp(value, original - maxChange, original + maxChange)
            value = clamp(value, Double(max(1, v.minimum)), Double(min(127, max(v.minimum, v.maximum))))
            out[i] = Int(value.rounded())
        }
        return out
    }

    static func applyCurve(_ value: Double, _ curve: VelocityCurve) -> Double {
        let x = clamp(value / 127.0, 0, 1)
        let y: Double
        switch curve {
        case .linear: y = x
        case .soft: y = pow(x, 1.22)
        case .hard: y = pow(x, 0.82)
        case .compressed: y = 0.55 + (x - 0.55) * 0.7
        case .expanded: y = 0.55 + (x - 0.55) * 1.3
        }
        return clamp(y, 0, 1) * 127.0
    }

    // MARK: - Articulation

    static func applyLengths(_ notes: [DrumNote], original: [DrumNote], contexts: [NoteContext], input: Input,
                             random: KeyedRandom) -> [DrumNote] {
        let amount = input.settings.articulation.lengthVariation
        guard amount > 0 else { return notes }
        var out = notes
        for i in out.indices where contexts[i].inRange {
            let factor = 1 + amount * 0.25 * random.signedUnit(.length, out[i].id)
            out[i].length = max(1, original[i].length * factor)
        }
        return out
    }

    static func addArticulations(_ notes: [DrumNote], original: [DrumNote], contexts: [NoteContext], input: Input,
                                 random: KeyedRandom, familyMeans: [Int: Double]) -> [DrumNote] {
        let s = input.settings
        let a = s.articulation
        let ta = s.trackAware
        let map = input.map
        var out = notes
        var nextID = DrumNote.addedIDBase

        // Main snare note (most used snare pitch).
        var snareCounts: [Int: Int] = [:]
        var snareTemplate: DrumNote? = nil
        for (i, n) in original.enumerated() where contexts[i].category == .snare {
            snareCounts[n.pitch, default: 0] += 1
            if snareTemplate == nil { snareTemplate = n }
        }
        guard let mainSnare = snareCounts.max(by: { $0.value < $1.value })?.key, let template = snareTemplate else { return out }
        let snareMean = familyMeans[mainSnare] ?? 90
        let existingGhosts = original.enumerated().filter { contexts[$0.offset].isGhost }.map { Double($0.element.velocity) }
        let ghostVelocity: Double = existingGhosts.isEmpty
            ? clamp(snareMean * 0.28, 14, 40)
            : existingGhosts.sorted()[existingGhosts.count / 2]

        func occupied(_ tick: Double, limb: Limb, tolerance: Double) -> Bool {
            for n in out where abs(n.tick - tick) < tolerance {
                let cat = map.category(for: n.pitch)
                if cat.limb == limb || cat.family == .tom || cat == .crash { return true }
            }
            return false
        }

        func contextScale(atTick tick: Double, bar: Int) -> Double {
            var scale = 1.0
            if ta.enabled {
                if let sec = input.context.section(atBar: bar, totalBars: input.analysis.bars) {
                    let p = sectionProfile(sec.marker.kind)
                    scale *= 1 + (p.addedNotes - 1) * ta.sectionAwareness
                }
                if let audio = input.context.audio {
                    let sec = input.tempoMap.seconds(atTick: tick)
                    let d = audio.density(midiSeconds: sec)
                    if d > 0 { scale *= 1 - ta.scaled(ta.arrangementSensitivity) * d }
                    scale *= 1 - ta.scaled(ta.vocalSpace) * audio.vocal(midiSeconds: sec)
                }
            }
            return max(0, scale)
        }

        // Ghost notes around backbeats (the "a" before and the "e" after), outside fills.
        if a.addGhostNotes > 0 {
            for (i, n) in original.enumerated() {
                let c = contexts[i]
                guard c.inRange, c.category == .snare, c.isBackbeat, !c.isFillBar, !c.isGhost else { continue }
                let step = c.ticksPerBeat / 4
                let gridTick = n.tick - c.gridDeviationTicks
                for (k, offset) in [-1.0, 1.0, 3.0].enumerated() {
                    let probability = a.addGhostNotes * (k == 2 ? 0.4 : 0.6) * contextScale(atTick: gridTick, bar: c.bar)
                    guard random.unit(.ghost, n.id, k) < probability else { continue }
                    let tick = gridTick + offset * step
                    guard tick > 0, !occupied(tick, limb: .leftHand, tolerance: step * 0.6) else { continue }
                    let vel = ghostVelocity * (1 + 0.15 * random.signedUnit(.ghost, n.id, k + 10))
                    let late = 3.0 * random.gaussian(.ghost, n.id, k + 20) / c.msPerTick
                    out.append(DrumNote(id: nextID, track: template.track, channel: template.channel, pitch: mainSnare,
                                        tick: tick + late, length: step * 0.5, velocity: Int(clamp(vel, 8, 50).rounded()),
                                        origin: .ghost))
                    nextID += 1
                }
            }
        }

        // Flams and drags on accented snare hits in fills and at phrase ends; rolls in fills.
        for (i, n) in original.enumerated() {
            let c = contexts[i]
            guard c.inRange, c.family == .snare, !c.isGhost else { continue }
            let strong = Double(n.velocity) >= snareMean - 4 || c.isAccent
            guard strong, c.isFillBar || c.isPhraseEndBar else { continue }
            let mainTick = out[i].tick
            let scale = contextScale(atTick: mainTick, bar: c.bar)

            if a.flams > 0, random.unit(.flam, n.id) < a.flams * (c.isFillBar ? 0.5 : 0.2) * scale {
                let graceMs = 18 + 12 * random.unit(.flam, n.id, 1)
                let tick = mainTick - graceMs / c.msPerTick
                if tick > 0 && !occupied(tick, limb: .leftHand, tolerance: 12 / c.msPerTick) {
                    let vel = Double(out[i].velocity) * (0.38 + 0.15 * random.unit(.flam, n.id, 2))
                    out.append(DrumNote(id: nextID, track: n.track, channel: n.channel, pitch: n.pitch, tick: tick,
                                        length: max(1, n.length * 0.5), velocity: Int(clamp(vel, 10, 90).rounded()), origin: .flam))
                    nextID += 1
                    continue
                }
            }
            if a.drags > 0, c.isFillBar, c.barFraction > 0.5, random.unit(.drag, n.id) < a.drags * 0.4 * scale {
                let spacingMs = min(32.0, c.ticksPerBeat / 12 * c.msPerTick)
                let first = mainTick - 2 * spacingMs / c.msPerTick
                if first > 0 && !occupied(first, limb: .leftHand, tolerance: spacingMs * 0.6 / c.msPerTick) {
                    for k in 0 ..< 2 {
                        let tick = mainTick - Double(2 - k) * spacingMs / c.msPerTick
                        let vel = Double(out[i].velocity) * (0.3 + 0.06 * Double(k))
                        out.append(DrumNote(id: nextID, track: n.track, channel: n.channel, pitch: n.pitch, tick: tick,
                                            length: max(1, n.length * 0.4), velocity: Int(clamp(vel, 8, 70).rounded()), origin: .drag))
                        nextID += 1
                    }
                }
            }
        }

        if a.rolls > 0 {
            let snareIndexes = original.indices.filter { contexts[$0].family == .snare && contexts[$0].isFillBar && contexts[$0].inRange }
            for (k, idx) in snareIndexes.enumerated() where k + 1 < snareIndexes.count {
                let next = snareIndexes[k + 1]
                let c = contexts[idx]
                let gap = original[next].tick - original[idx].tick
                let sixteenth = c.ticksPerBeat / 4
                guard abs(gap - sixteenth) < sixteenth * 0.1 else { continue }
                guard random.unit(.roll, original[idx].id) < a.rolls * 0.6 * contextScale(atTick: original[idx].tick, bar: c.bar) else { continue }
                let tick = (out[idx].tick + out[next].tick) / 2
                let vel = (Double(out[idx].velocity) + Double(out[next].velocity)) / 2 * 0.72
                out.append(DrumNote(id: nextID, track: original[idx].track, channel: original[idx].channel, pitch: original[idx].pitch,
                                    tick: tick, length: max(1, sixteenth * 0.4), velocity: Int(clamp(vel, 10, 110).rounded()), origin: .roll))
                nextID += 1
            }
        }
        return out
    }

    /// Opens the last off-beat closed hi-hat of a phrase now and then (the next hat chokes it).
    static func applyHihatOpenings(_ notes: [DrumNote], contexts: [NoteContext], original: [DrumNote], input: Input,
                                   random: KeyedRandom) -> [DrumNote] {
        guard let openNote = input.map.note(for: .openHat) else { return notes }
        let probability = input.settings.articulation.hihatOpenings
        var out = notes
        for (i, n) in original.enumerated() {
            let c = contexts[i]
            guard c.inRange, c.category == .closedHat, c.isPhraseEndBar, !c.isFillBar, c.subIndex == 2 else { continue }
            guard c.beat == c.beatsInBar - 1 else { continue }
            guard random.unit(.hihatOpen, n.id) < probability * 0.6 else { continue }
            out[i].pitch = openNote
            out[i].origin = .articulation
            out[i].velocity = min(127, out[i].velocity + 6)
            out[i].length = max(out[i].length, c.ticksPerBeat * 0.5)
        }
        return out
    }

    // MARK: - Constraints

    static func enforceConstraints(_ processed: [DrumNote], original: [DrumNote], input: Input) -> [DrumNote] {
        let map = input.map
        let tempo = input.tempoMap
        var notes = processed

        // 1. Keep each limb's original order and a minimum gap between its strokes.
        let originalTick: [Int: Double] = Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0.tick) })
        var byLimb: [Limb: [Int]] = [:]
        for i in notes.indices { byLimb[map.category(for: notes[i].pitch).limb, default: []].append(i) }
        for (limb, indexes) in byLimb where limb != .auxiliary {
            let ordered = indexes.sorted { a, b in
                let ta = originalTick[notes[a].id] ?? notes[a].tick
                let tb = originalTick[notes[b].id] ?? notes[b].tick
                return ta == tb ? notes[a].id < notes[b].id : ta < tb
            }
            var previous: Int? = nil
            for idx in ordered {
                defer { previous = idx }
                guard let p = previous else { continue }
                let origGap = (originalTick[notes[idx].id] ?? notes[idx].tick) - (originalTick[notes[p].id] ?? notes[p].tick)
                guard origGap > 0 else { continue }
                let msPerTick = 60_000.0 / (tempo.bpm(atTick: Int(notes[idx].tick)) * Double(tempo.ppq))
                let minGap = min(origGap * 0.5, 25 / msPerTick)
                if notes[idx].tick < notes[p].tick + minGap { notes[idx].tick = notes[p].tick + minGap }
            }
        }

        // 2. Ticks can't be negative.
        for i in notes.indices { notes[i].tick = max(0, notes[i].tick) }

        // 3. Remove added notes that collide with a hit on the same drum; trim same-drum overlaps.
        notes.sort(by: DrumPattern.order)
        var keep = [Bool](repeating: true, count: notes.count)
        var lastIndexByPitch: [Int: Int] = [:]
        for i in notes.indices {
            let n = notes[i]
            if let p = lastIndexByPitch[n.pitch] {
                let msPerTick = 60_000.0 / (tempo.bpm(atTick: Int(n.tick)) * Double(tempo.ppq))
                let gapMs = (n.tick - notes[p].tick) * msPerTick
                if gapMs < 10 && (n.origin.isAdded || notes[p].origin.isAdded) {
                    if n.origin.isAdded { keep[i] = false; continue } else { keep[p] = false }
                }
                if keep[p] && notes[p].endTick > n.tick {
                    notes[p].length = max(1, n.tick - notes[p].tick - 1)
                }
            }
            lastIndexByPitch[n.pitch] = i
        }
        notes = notes.enumerated().filter { keep[$0.offset] }.map { $0.element }

        // 4. Open hi-hats are choked by the next closed or pedal hat.
        let hatIndexes = notes.indices.filter { map.category(for: notes[$0].pitch).family == .hihat }
        for (k, i) in hatIndexes.enumerated() where map.category(for: notes[i].pitch) == .openHat {
            if k + 1 < hatIndexes.count {
                let next = notes[hatIndexes[k + 1]]
                if next.tick > notes[i].tick { notes[i].length = min(notes[i].length, max(1, next.tick - notes[i].tick)) }
            }
        }

        // 5. Valid velocities and lengths.
        for i in notes.indices {
            notes[i].velocity = clamp(notes[i].velocity, 1, 127)
            notes[i].length = max(1, notes[i].length)
        }
        return notes
    }

    static func computeStats(_ notes: [DrumNote], original: [DrumNote], tempoMap: TempoMap) -> Performance.Stats {
        var stats = Performance.Stats()
        let byID = Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0) })
        var total = 0.0
        var totalVel = 0.0
        var count = 0.0
        for n in notes {
            guard let o = byID[n.id] else { stats.addedNotes += 1; continue }
            let msPerTick = 60_000.0 / (tempoMap.bpm(atTick: Int(o.tick)) * Double(tempoMap.ppq))
            let shift = abs(n.tick - o.tick) * msPerTick
            total += shift
            stats.maxTimingShiftMs = max(stats.maxTimingShiftMs, shift)
            totalVel += Double(abs(n.velocity - o.velocity))
            if shift > 0.5 || n.velocity != o.velocity || n.pitch != o.pitch { stats.changedNotes += 1 }
            count += 1
        }
        if count > 0 {
            stats.meanTimingShiftMs = total / count
            stats.meanVelocityChange = totalVel / count
        }
        return stats
    }
}
