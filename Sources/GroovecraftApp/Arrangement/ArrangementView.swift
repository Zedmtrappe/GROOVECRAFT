import AppKit
import GrooveCore

/// What the arrangement view asks the app to do.
@MainActor
protocol ArrangementDelegate: AnyObject {
    func arrangementSelect(_ ids: Set<Int>)
    func arrangementSeek(toSong seconds: Double)
    func arrangementSetLoop(bars: ClosedRange<Int>)
    func arrangementBeginEdit()
    func arrangementMove(ids: Set<Int>, deltaTicks: Double, toPitch: Int?)
    func arrangementSetVelocity(ids: Set<Int>, delta: Int)
    func arrangementSetLength(ids: Set<Int>, factor: Double)
    func arrangementAddNote(pitch: Int, tick: Double)
    func arrangementDelete(ids: Set<Int>)
    func arrangementSetAlignment(offset: Double, commit: Bool)
    func arrangementAddSection(bar: Int)
    func arrangementSectionMenu(_ marker: SectionMarker, at point: NSPoint, in view: NSView)
    func arrangementMoveSection(_ marker: SectionMarker, toBar bar: Int)
    func arrangementProcessBars(_ bars: ClosedRange<Int>?)
    func arrangementZoom(by factor: Double, anchorTick: Double, viewX: CGFloat)
    func arrangementAudition(pitch: Int)
}

/// The timeline + drum grid. One flipped NSView inside an NSScrollView: the ruler and lane
/// headers are drawn pinned to the visible edges, and only the visible rectangle is drawn.
final class ArrangementView: NSView {
    weak var delegate: ArrangementDelegate?
    var model = ArrangementModel() {
        didSet { needsDisplay = true }
    }
    var playheadSong: Double = 0 {
        didSet {
            guard oldValue != playheadSong else { return }
            let oldX = model.x(forTick: model.tick(forSong: oldValue))
            let newX = model.x(forTick: model.tick(forSong: playheadSong))
            setNeedsDisplay(NSRect(x: oldX - 8, y: visibleRect.minY, width: 16, height: visibleRect.height))
            setNeedsDisplay(NSRect(x: newX - 8, y: visibleRect.minY, width: 16, height: visibleRect.height))
            setNeedsDisplay(NSRect(x: visibleRect.minX, y: visibleRect.minY, width: ArrangementModel.headerWidth, height: ArrangementModel.rulerHeight))
        }
    }
    var isPlaying = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    // Drag state
    private enum Drag {
        case none
        case seek
        case loop(startTick: Double)
        case alignment(startX: CGFloat, startOffset: Double)
        case notes(startPoint: NSPoint, ids: Set<Int>, began: Bool)
        case velocity(startY: CGFloat, ids: Set<Int>, applied: Int)
        case rubberBand(start: NSPoint)
        case section(SectionMarker)
    }
    private var drag: Drag = .none
    private var dragCurrent: NSPoint = .zero
    private var dragPreviewDelta: Double = 0
    private var dragPreviewLane: Int? = nil
    private var dragPreviewVelocity: Int = 0
    private var rubberBand: NSRect? = nil
    private var hoverPoint: NSPoint? = nil
    private var trackingArea: NSTrackingArea?

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        GC.NS.background.setFill()
        dirtyRect.fill()
        let m = model
        if m.isEmpty { return }
        let visible = visibleRect

        drawLaneBackgrounds(ctx, dirtyRect, m)
        drawGrid(ctx, dirtyRect, m)
        drawProcessRange(dirtyRect, m)
        if m.hasAudio { drawAudio(ctx, dirtyRect, m) }
        drawNotes(ctx, dirtyRect, m)
        drawVelocityLane(ctx, dirtyRect, m)
        drawLoopOverlay(dirtyRect, m)
        drawPlayhead(ctx, dirtyRect, m)
        if let r = rubberBand {
            GC.NS.accent.withAlphaComponent(0.12).setFill()
            r.fill()
            GC.NS.accent.withAlphaComponent(0.7).setStroke()
            NSBezierPath(rect: r).stroke()
        }
        // Pinned chrome last: ruler and sections at the top edge, headers at the left edge.
        drawRuler(ctx, visible, m)
        drawSections(ctx, visible, m)
        drawHeaders(ctx, visible, m)
    }

    private func drawLaneBackgrounds(_ ctx: CGContext, _ rect: NSRect, _ m: ArrangementModel) {
        for i in 0 ..< m.lanes.count {
            let y = m.lanesTop + CGFloat(i) * ArrangementModel.laneHeight
            let r = NSRect(x: rect.minX, y: y, width: rect.width, height: ArrangementModel.laneHeight)
            guard r.intersects(rect) else { continue }
            (i % 2 == 0 ? GC.NS.laneA : GC.NS.laneB).setFill()
            r.fill()
        }
        // Fill bars get a faint tint so phrase structure is visible.
        for bar in m.fillBars {
            let x0 = m.x(forTick: m.tempoMap.tick(atBar: bar))
            let x1 = m.x(forTick: m.tempoMap.tick(atBar: bar + 1))
            let r = NSRect(x: x0, y: m.lanesTop, width: x1 - x0, height: CGFloat(m.lanes.count) * ArrangementModel.laneHeight)
            if r.intersects(rect) {
                GC.NS.accent.withAlphaComponent(0.025).setFill()
                r.fill()
            }
        }
        GC.NS.surface.setFill()
        NSRect(x: rect.minX, y: m.velocityTop, width: rect.width, height: ArrangementModel.velocityHeight).intersection(rect).fill()
        if m.hasAudio {
            NSColor(hex: 0x101215).setFill()
            NSRect(x: rect.minX, y: m.audioTop, width: rect.width, height: ArrangementModel.audioHeight).intersection(rect).fill()
        }
    }

    private func drawGrid(_ ctx: CGContext, _ rect: NSRect, _ m: ArrangementModel) {
        let startTick = max(0, m.tick(forX: rect.minX))
        let endTick = m.tick(forX: rect.maxX)
        let top = m.audioTop
        let bottom = m.totalHeight
        let pos = m.tempoMap.position(atTick: startTick)
        var bar = pos.bar
        var guardCount = 0
        while guardCount < 5000 {
            guardCount += 1
            let barTick = m.tempoMap.tick(atBar: bar)
            if barTick > endTick { break }
            let p = m.tempoMap.position(atTick: barTick + 1)
            let beats = p.beatsInBar
            let tpb = p.ticksPerBeat
            for beat in 0 ..< beats {
                let bt = barTick + Double(beat) * tpb
                // Subdivisions when zoomed in enough.
                let subdivisions = m.pixelsPerBeat >= 40 ? 4 : (m.pixelsPerBeat >= 20 ? 2 : 1)
                for s in 0 ..< subdivisions {
                    let t = bt + Double(s) * tpb / Double(subdivisions)
                    let x = round(m.x(forTick: t)) + 0.5
                    guard x >= rect.minX - 1 && x <= rect.maxX + 1 else { continue }
                    let color: NSColor = (beat == 0 && s == 0) ? GC.NS.barLine : (s == 0 ? GC.NS.beatLine : GC.NS.subLine)
                    color.setStroke()
                    let path = NSBezierPath()
                    path.move(to: NSPoint(x: x, y: top))
                    path.line(to: NSPoint(x: x, y: bottom))
                    path.lineWidth = 1
                    path.stroke()
                }
            }
            bar += 1
        }
        // Lane separators.
        GC.NS.hairline.withAlphaComponent(0.5).setFill()
        NSRect(x: rect.minX, y: m.velocityTop, width: rect.width, height: 1).fill()
        if m.hasAudio { NSRect(x: rect.minX, y: m.lanesTop, width: rect.width, height: 1).fill() }
    }

    private func drawProcessRange(_ rect: NSRect, _ m: ArrangementModel) {
        guard let bars = m.processBars else { return }
        let x0 = m.x(forTick: m.tempoMap.tick(atBar: bars.lowerBound))
        let x1 = m.x(forTick: m.tempoMap.tick(atBar: bars.upperBound + 1))
        // Dim everything outside the processed bars.
        NSColor.black.withAlphaComponent(0.35).setFill()
        let h = m.velocityTop - m.lanesTop
        NSRect(x: ArrangementModel.headerWidth, y: m.lanesTop, width: max(0, x0 - ArrangementModel.headerWidth), height: h).intersection(rect).fill()
        NSRect(x: x1, y: m.lanesTop, width: max(0, rect.maxX - x1), height: h).intersection(rect).fill()
    }

    private func drawAudio(_ ctx: CGContext, _ rect: NSRect, _ m: ArrangementModel) {
        guard let b = m.backing else { return }
        let top = m.audioTop
        let height = ArrangementModel.audioHeight
        let mid = top + height * 0.5
        let x0 = max(rect.minX, ArrangementModel.headerWidth)
        let x1 = rect.maxX
        guard x1 > x0 else { return }
        // Waveform (mirrored peaks).
        let path = CGMutablePath()
        var first = true
        var x = x0
        var upper: [CGPoint] = []
        while x <= x1 {
            let song = m.song(forTick: m.tick(forX: x))
            let audioT = m.alignment.offsetSeconds + song
            var peak: CGFloat = 0
            if audioT >= 0 && audioT < b.duration && !b.overview.isEmpty {
                let i = min(b.overview.count - 1, Int(audioT * b.overviewRate))
                let span = max(1, Int(Double(1.5) / m.pixelsPerTick / Double(m.ppq) * b.overviewRate * 0.5))
                var p: Float = 0
                for k in max(0, i - span) ... min(b.overview.count - 1, i + span) where k >= 0 { p = max(p, b.overview[k]) }
                peak = CGFloat(p)
            }
            upper.append(CGPoint(x: x, y: mid - peak * height * 0.42))
            x += 1.5
        }
        for p in upper {
            if first { path.move(to: p); first = false } else { path.addLine(to: p) }
        }
        for p in upper.reversed() { path.addLine(to: CGPoint(x: p.x, y: mid + (mid - p.y))) }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(GC.NS.waveform.withAlphaComponent(0.7).cgColor)
        ctx.fillPath()

        // Energy curve.
        let energy = CGMutablePath()
        first = true
        x = x0
        while x <= x1 {
            let audioT = m.alignment.offsetSeconds + m.song(forTick: m.tick(forX: x))
            let e = audioT >= 0 && audioT <= b.duration ? CGFloat(b.curveValue(b.energy, at: audioT)) : 0
            let p = CGPoint(x: x, y: top + height - 4 - e * (height - 10))
            if first { energy.move(to: p); first = false } else { energy.addLine(to: p) }
            x += 3
        }
        ctx.addPath(energy)
        ctx.setStrokeColor(GC.NS.energy.cgColor)
        ctx.setLineWidth(1.4)
        ctx.strokePath()

        // Bass attacks as small ticks along the bottom.
        let tickStart = m.tick(forX: x0)
        let tickEnd = m.tick(forX: x1)
        ctx.setFillColor(GC.NS.bass.withAlphaComponent(0.85).cgColor)
        for o in b.bassOnsets {
            let songT = o.time - m.alignment.offsetSeconds
            let t = m.tick(forSong: songT)
            guard t >= tickStart && t <= tickEnd else { continue }
            let px = m.x(forTick: t)
            ctx.fill(CGRect(x: px - 0.75, y: top + height - 9, width: 1.5, height: 7))
        }
        // Beat grid from the audio (thin, to check alignment).
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.09).cgColor)
        for beat in b.beats {
            let t = m.tick(forSong: beat - m.alignment.offsetSeconds)
            guard t >= tickStart && t <= tickEnd else { continue }
            ctx.fill(CGRect(x: m.x(forTick: t) - 0.5, y: top + 2, width: 1, height: 6))
        }
        // Offset label.
        let label = String(format: "Audio offset %+.3f s%@", m.alignment.offsetSeconds,
                           abs(m.alignment.stretch - 1) > 0.0001 ? String(format: " · tempo ×%.3f", m.alignment.stretch) : "")
        drawText(label, at: NSPoint(x: visibleRect.minX + ArrangementModel.headerWidth + 8, y: top + 4), size: 10, color: GC.NS.textTertiary)
    }

    private func noteColor(_ velocity: Int, added: Bool) -> NSColor {
        let v = CGFloat(velocity) / 127
        let base = added ? NSColor(hex: 0xFFD38A) : GC.NS.accent
        return base.withAlphaComponent(0.35 + 0.65 * v)
    }

    private func noteWidth(_ m: ArrangementModel) -> CGFloat {
        let sixteenth = CGFloat(Double(m.ppq) / 4 * m.pixelsPerTick)
        return max(5, min(12, sixteenth * 0.55))
    }

    private func drawNotes(_ ctx: CGContext, _ rect: NSRect, _ m: ArrangementModel) {
        let w = noteWidth(m)
        let margin = Double(w + 40) / m.pixelsPerTick
        let startTick = m.tick(forX: rect.minX) - margin
        let endTick = m.tick(forX: rect.maxX) + margin
        let laneH = ArrangementModel.laneHeight

        // Original positions as hollow steel outlines (only when looking at a take).
        if !m.showingOriginal && m.showOriginalGhosts {
            var i = ArrangementModel.firstIndex(m.original, atOrAfter: startTick)
            while i < m.original.count && m.original[i].tick <= endTick {
                let n = m.original[i]
                if let lane = m.laneIndex[n.pitch] {
                    let x = m.x(forTick: n.tick)
                    let y = m.lanesTop + CGFloat(lane) * laneH
                    let h = (laneH - 6) * (0.4 + 0.6 * CGFloat(n.velocity) / 127)
                    let r = NSRect(x: x - w / 2, y: y + (laneH - h) / 2, width: w, height: h)
                    GC.NS.referenceDim.setStroke()
                    let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
                    p.lineWidth = 1
                    p.stroke()
                }
                i += 1
            }
        }

        // The selected performance.
        var i = ArrangementModel.firstIndex(m.current, atOrAfter: startTick)
        while i < m.current.count && m.current[i].tick <= endTick {
            let n = m.current[i]
            i += 1
            let isSelected = m.selection.contains(n.id)
            var tick = n.tick
            var laneIdx = m.laneIndex[n.pitch]
            if isSelected, case .notes(_, _, true) = drag {
                tick += dragPreviewDelta
                if let target = dragPreviewLane, let src = laneIdx {
                    let anyLane = m.selection.compactMap { id in m.current.first { $0.id == id }.flatMap { m.laneIndex[$0.pitch] } }.min() ?? src
                    laneIdx = max(0, min(m.lanes.count - 1, src + target - anyLane))
                }
            }
            guard let lane = laneIdx else { continue }
            let x = m.x(forTick: tick)
            let y = m.lanesTop + CGFloat(lane) * laneH
            var velocity = n.velocity
            if isSelected, case .velocity = drag { velocity = max(1, min(127, velocity + dragPreviewVelocity)) }
            let h = (laneH - 6) * (0.4 + 0.6 * CGFloat(velocity) / 127)
            let r = NSRect(x: x - w / 2, y: y + (laneH - h) / 2, width: w, height: h)

            // Deviation line from the original position.
            if !m.showingOriginal, m.showOriginalGhosts, let o = m.originalByID[n.id] {
                let ox = m.x(forTick: o.tick)
                if abs(ox - x) > 1.5 {
                    GC.NS.accent.withAlphaComponent(0.35).setStroke()
                    let line = NSBezierPath()
                    line.move(to: NSPoint(x: ox, y: y + laneH / 2))
                    line.line(to: NSPoint(x: x, y: y + laneH / 2))
                    line.lineWidth = 1
                    line.stroke()
                }
            }
            let color = m.showingOriginal ? GC.NS.reference.withAlphaComponent(0.4 + 0.6 * CGFloat(velocity) / 127)
                                          : noteColor(velocity, added: n.origin.isAdded)
            color.setFill()
            let shape = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
            shape.fill()
            if n.origin.isAdded {
                NSColor.black.withAlphaComponent(0.55).setFill()
                NSBezierPath(ovalIn: NSRect(x: x - 1.5, y: r.midY - 1.5, width: 3, height: 3)).fill()
            }
            if isSelected {
                NSColor.white.setStroke()
                shape.lineWidth = 1.5
                shape.stroke()
            }
        }
    }

    private func drawVelocityLane(_ ctx: CGContext, _ rect: NSRect, _ m: ArrangementModel) {
        let top = m.velocityTop + 8
        let height = ArrangementModel.velocityHeight - 14
        let laneRect = NSRect(x: rect.minX, y: m.velocityTop, width: rect.width, height: ArrangementModel.velocityHeight)
        guard laneRect.intersects(rect) else { return }
        // Guide lines at 32 / 64 / 96 / 127.
        for v in [32, 64, 96, 127] {
            let y = top + height * (1 - CGFloat(v) / 127)
            GC.NS.subLine.setFill()
            NSRect(x: rect.minX, y: y, width: rect.width, height: 1).fill()
        }
        let startTick = m.tick(forX: rect.minX) - 50
        let endTick = m.tick(forX: rect.maxX) + 50
        var i = ArrangementModel.firstIndex(m.current, atOrAfter: startTick)
        while i < m.current.count && m.current[i].tick <= endTick {
            let n = m.current[i]
            i += 1
            let isSelected = m.selection.contains(n.id)
            var v = n.velocity
            if isSelected, case .velocity = drag { v = max(1, min(127, v + dragPreviewVelocity)) }
            var tick = n.tick
            if isSelected, case .notes(_, _, true) = drag { tick += dragPreviewDelta }
            let x = m.x(forTick: tick)
            let h = height * CGFloat(v) / 127
            let color: NSColor = isSelected ? NSColor.white : (m.showingOriginal ? GC.NS.reference : noteColor(v, added: n.origin.isAdded))
            color.withAlphaComponent(isSelected ? 0.95 : 0.8).setFill()
            NSRect(x: x - 1, y: top + height - h, width: 2, height: h).fill()
            NSBezierPath(ovalIn: NSRect(x: x - 2.5, y: top + height - h - 2.5, width: 5, height: 5)).fill()
            // Original velocity marker.
            if !m.showingOriginal, m.showOriginalGhosts, let o = m.originalByID[n.id], o.velocity != v {
                let oy = top + height - height * CGFloat(o.velocity) / 127
                GC.NS.reference.withAlphaComponent(0.8).setFill()
                NSRect(x: x - 3, y: oy, width: 6, height: 1).fill()
            }
        }
    }

    private func drawLoopOverlay(_ rect: NSRect, _ m: ArrangementModel) {
        guard let loop = m.loop, m.loopEnabled else { return }
        let x0 = m.x(forTick: m.tick(forSong: loop.lowerBound))
        let x1 = m.x(forTick: m.tick(forSong: loop.upperBound))
        let r = NSRect(x: x0, y: ArrangementModel.rulerHeight, width: x1 - x0, height: m.totalHeight)
        GC.NS.accent.withAlphaComponent(0.04).setFill()
        r.intersection(rect).fill()
        GC.NS.accent.withAlphaComponent(0.4).setFill()
        NSRect(x: x0, y: ArrangementModel.rulerHeight, width: 1, height: m.totalHeight).intersection(rect).fill()
        NSRect(x: x1 - 1, y: ArrangementModel.rulerHeight, width: 1, height: m.totalHeight).intersection(rect).fill()
    }

    private func drawPlayhead(_ ctx: CGContext, _ rect: NSRect, _ m: ArrangementModel) {
        let x = m.x(forTick: m.tick(forSong: playheadSong))
        guard x >= rect.minX - 8 && x <= rect.maxX + 8 else { return }
        (isPlaying ? GC.NS.accentBright : GC.NS.textSecondary).setFill()
        NSRect(x: round(x) - 0.5, y: ArrangementModel.rulerHeight, width: 1.5, height: m.totalHeight).fill()
    }

    private func drawRuler(_ ctx: CGContext, _ visible: NSRect, _ m: ArrangementModel) {
        let r = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: ArrangementModel.rulerHeight)
        GC.NS.surfaceRaised.setFill()
        r.fill()
        // Loop region in the ruler.
        if let loop = m.loop {
            let x0 = m.x(forTick: m.tick(forSong: loop.lowerBound))
            let x1 = m.x(forTick: m.tick(forSong: loop.upperBound))
            let lr = NSRect(x: x0, y: r.minY + 3, width: max(2, x1 - x0), height: 7)
            (m.loopEnabled ? GC.NS.accent.withAlphaComponent(0.75) : GC.NS.textTertiary.withAlphaComponent(0.35)).setFill()
            NSBezierPath(roundedRect: lr, xRadius: 2, yRadius: 2).fill()
        }
        let startTick = max(0, m.tick(forX: visible.minX))
        let endTick = m.tick(forX: visible.maxX)
        var bar = m.tempoMap.position(atTick: startTick).bar
        let barPixels = CGFloat(m.tempoMap.ticksPerBar(atTick: startTick) * m.pixelsPerTick)
        let every = barPixels < 24 ? 4 : (barPixels < 48 ? 2 : 1)
        var count = 0
        while count < 4000 {
            count += 1
            let t = m.tempoMap.tick(atBar: bar)
            if t > endTick { break }
            let x = m.x(forTick: t)
            if bar % every == 0 {
                GC.NS.barLine.setFill()
                NSRect(x: x, y: r.minY + 12, width: 1, height: r.height - 12).fill()
                drawText("\(bar + 1)", at: NSPoint(x: x + 4, y: r.minY + 12), size: 10.5, color: GC.NS.textSecondary, mono: true)
            }
            bar += 1
        }
        GC.NS.hairline.setFill()
        NSRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1).fill()
        // Playhead cap.
        let px = m.x(forTick: m.tick(forSong: playheadSong))
        if px >= visible.minX + ArrangementModel.headerWidth {
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: px - 5, y: r.maxY - 9))
            tri.line(to: NSPoint(x: px + 5, y: r.maxY - 9))
            tri.line(to: NSPoint(x: px, y: r.maxY - 1))
            tri.close()
            (isPlaying ? GC.NS.accentBright : GC.NS.textPrimary).setFill()
            tri.fill()
        }
    }

    private func drawSections(_ ctx: CGContext, _ visible: NSRect, _ m: ArrangementModel) {
        let top = visible.minY + ArrangementModel.rulerHeight
        let r = NSRect(x: visible.minX, y: top, width: visible.width, height: ArrangementModel.sectionHeight)
        GC.NS.surface.setFill()
        r.fill()
        for (i, s) in m.sections.enumerated() {
            let x0 = m.x(forTick: m.tempoMap.tick(atBar: s.bar))
            let nextBar = i + 1 < m.sections.count ? m.sections[i + 1].bar : m.bars
            let x1 = m.x(forTick: m.tempoMap.tick(atBar: max(nextBar, s.bar + 1)))
            guard x1 >= visible.minX && x0 <= visible.maxX else { continue }
            let chip = NSRect(x: x0 + 1, y: top + 3, width: max(8, x1 - x0 - 2), height: ArrangementModel.sectionHeight - 6)
            let color = sectionColor(s.kind)
            color.withAlphaComponent(s.isEstimate ? 0.16 : 0.28).setFill()
            NSBezierPath(roundedRect: chip, xRadius: 3, yRadius: 3).fill()
            color.withAlphaComponent(0.9).setFill()
            NSRect(x: chip.minX, y: chip.minY, width: 2, height: chip.height).fill()
            let label = s.label + (s.isEstimate ? " ?" : "")
            drawText(label, at: NSPoint(x: max(chip.minX + 6, visible.minX + ArrangementModel.headerWidth + 4), y: chip.minY + 1.5),
                     size: 10, color: GC.NS.textPrimary.withAlphaComponent(0.9), weight: .semibold, maxWidth: chip.width - 8)
        }
        GC.NS.hairline.setFill()
        NSRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1).fill()
    }

    func sectionColor(_ kind: SectionKind) -> NSColor {
        switch kind {
        case .intro, .outro: return NSColor(hex: 0x7C95B3)
        case .verse: return NSColor(hex: 0x6FB1A0)
        case .preChorus: return NSColor(hex: 0xC9A55C)
        case .chorus: return NSColor(hex: 0xF4A940)
        case .bridge, .solo: return NSColor(hex: 0xA48AD4)
        case .breakdown: return NSColor(hex: 0x5B7FA6)
        case .transition: return NSColor(hex: 0xE5615B)
        case .unknown: return NSColor(hex: 0x8A939C)
        }
    }

    private func drawHeaders(_ ctx: CGContext, _ visible: NSRect, _ m: ArrangementModel) {
        let w = ArrangementModel.headerWidth
        let x = visible.minX
        // Corner (ruler + sections).
        GC.NS.surfaceRaised.setFill()
        NSRect(x: x, y: visible.minY, width: w, height: ArrangementModel.rulerHeight + ArrangementModel.sectionHeight).fill()
        drawText("BAR", at: NSPoint(x: x + 10, y: visible.minY + 9), size: 9.5, color: GC.NS.textTertiary, weight: .semibold)
        drawText("SECTIONS", at: NSPoint(x: x + 10, y: visible.minY + ArrangementModel.rulerHeight + 5), size: 9.5, color: GC.NS.textTertiary, weight: .semibold)

        GC.NS.surface.setFill()
        let bodyTop = max(m.audioTop, visible.minY + ArrangementModel.rulerHeight + ArrangementModel.sectionHeight)
        NSRect(x: x, y: bodyTop, width: w, height: max(0, visible.maxY - bodyTop)).fill()
        if m.hasAudio {
            let y = m.audioTop
            if y + ArrangementModel.audioHeight > bodyTop {
                drawText("BACKING", at: NSPoint(x: x + 10, y: max(bodyTop, y) + 8), size: 9.5, color: GC.NS.textTertiary, weight: .semibold)
                drawText("energy · bass", at: NSPoint(x: x + 10, y: max(bodyTop, y) + 22), size: 9.5, color: GC.NS.textTertiary)
            }
        }
        for (i, lane) in m.lanes.enumerated() {
            let y = m.lanesTop + CGFloat(i) * ArrangementModel.laneHeight
            guard y + ArrangementModel.laneHeight > bodyTop && y < visible.maxY else { continue }
            let color = familyColor(lane.category.family)
            color.setFill()
            NSRect(x: x + 8, y: y + 7, width: 3, height: ArrangementModel.laneHeight - 14).fill()
            drawText(lane.name, at: NSPoint(x: x + 16, y: y + 4), size: 11, color: lane.isMapped ? GC.NS.textPrimary : GC.NS.danger, maxWidth: w - 52)
            drawText("\(lane.pitch)", at: NSPoint(x: x + w - 30, y: y + 5), size: 9.5, color: GC.NS.textTertiary, mono: true)
        }
        let vy = m.velocityTop
        if vy + ArrangementModel.velocityHeight > bodyTop {
            drawText("VELOCITY", at: NSPoint(x: x + 10, y: max(bodyTop, vy) + 8), size: 9.5, color: GC.NS.textTertiary, weight: .semibold)
        }
        GC.NS.hairline.setFill()
        NSRect(x: x + w - 1, y: visible.minY, width: 1, height: visible.height).fill()
    }

    func familyColor(_ family: DrumFamily) -> NSColor {
        switch family {
        case .kick: return NSColor(hex: 0xF4A940)
        case .snare: return NSColor(hex: 0xE5845B)
        case .hihat: return NSColor(hex: 0x6FB1A0)
        case .cymbal: return NSColor(hex: 0x8FB7E0)
        case .tom: return NSColor(hex: 0xA48AD4)
        case .percussion: return NSColor(hex: 0xC9A55C)
        case .other: return NSColor(hex: 0x6C747E)
        }
    }

    private func drawText(_ s: String, at p: NSPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular,
                          mono: Bool = false, maxWidth: CGFloat? = nil) {
        let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        let str = NSAttributedString(string: s, attributes: attrs)
        if let mw = maxWidth {
            str.draw(with: NSRect(x: p.x, y: p.y, width: max(0, mw), height: size + 4), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        } else {
            str.draw(at: p)
        }
    }

    // MARK: Hit testing

    private func lane(atY y: CGFloat) -> Int? {
        let m = model
        guard y >= m.lanesTop && y < m.velocityTop else { return nil }
        let i = Int((y - m.lanesTop) / ArrangementModel.laneHeight)
        return i >= 0 && i < m.lanes.count ? i : nil
    }

    private func note(at p: NSPoint) -> DrumNote? {
        let m = model
        guard let laneIdx = lane(atY: p.y) else { return nil }
        let pitch = m.lanes[laneIdx].pitch
        let tolerance = Double(noteWidth(m) / 2 + 3) / m.pixelsPerTick
        let tick = m.tick(forX: p.x)
        var best: DrumNote? = nil
        var bestD = tolerance
        var i = ArrangementModel.firstIndex(m.current, atOrAfter: tick - tolerance)
        while i < m.current.count && m.current[i].tick <= tick + tolerance {
            let n = m.current[i]
            if n.pitch == pitch {
                let d = abs(n.tick - tick)
                if d <= bestD { bestD = d; best = n }
            }
            i += 1
        }
        return best
    }

    private func velocityNote(at p: NSPoint) -> DrumNote? {
        let m = model
        let tolerance = 5.0 / m.pixelsPerTick
        let tick = m.tick(forX: p.x)
        var best: DrumNote? = nil
        var bestD = tolerance
        var i = ArrangementModel.firstIndex(m.current, atOrAfter: tick - tolerance)
        while i < m.current.count && m.current[i].tick <= tick + tolerance {
            let d = abs(m.current[i].tick - tick)
            // Prefer selected notes, then the loudest at the same spot.
            if d < bestD || (d == bestD && m.selection.contains(m.current[i].id)) { bestD = d; best = m.current[i] }
            i += 1
        }
        return best
    }

    private func snappedTick(_ tick: Double, force: Bool = false) -> Double {
        let m = model
        guard m.snap || force else { return tick }
        let step = Double(m.ppq) / 4
        return (tick / step).rounded() * step
    }

    private func bar(atX x: CGFloat) -> Int {
        let t = max(0, model.tick(forX: x))
        return model.tempoMap.position(atTick: t).bar
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverPoint = p
        updateCursor(p)
    }

    private func updateCursor(_ p: NSPoint) {
        let m = model
        if p.x < visibleRect.minX + ArrangementModel.headerWidth { NSCursor.arrow.set(); return }
        if m.hasAudio && p.y >= m.audioTop && p.y < m.audioTop + ArrangementModel.audioHeight { NSCursor.resizeLeftRight.set(); return }
        if p.y >= m.velocityTop { NSCursor.resizeUpDown.set(); return }
        if note(at: p) != nil { NSCursor.openHand.set(); return }
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let m = model
        guard !m.isEmpty else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragCurrent = p
        let visible = visibleRect
        let inHeader = p.x < visible.minX + ArrangementModel.headerWidth
        let rulerBottom = visible.minY + ArrangementModel.rulerHeight
        let sectionsBottom = rulerBottom + ArrangementModel.sectionHeight

        if inHeader {
            if let laneIdx = lane(atY: p.y) {
                let pitch = m.lanes[laneIdx].pitch
                if event.clickCount >= 2 || event.modifierFlags.contains(.command) {
                    // Select every note in this lane.
                    delegate?.arrangementSelect(Set(m.current.filter { $0.pitch == pitch }.map(\.id)))
                } else {
                    delegate?.arrangementAudition(pitch: pitch)
                }
            }
            return
        }
        if p.y < rulerBottom {
            drag = .seek
            delegate?.arrangementSeek(toSong: m.song(forTick: max(0, m.tick(forX: p.x))))
            return
        }
        if p.y < sectionsBottom {
            let bar = self.bar(atX: p.x)
            if let marker = m.sections.last(where: { $0.bar <= bar }), event.clickCount < 2 {
                let x0 = m.x(forTick: m.tempoMap.tick(atBar: marker.bar))
                if event.modifierFlags.contains(.control) || event.buttonNumber == 1 {
                    delegate?.arrangementSectionMenu(marker, at: p, in: self)
                } else if abs(p.x - x0) < 12 {
                    drag = .section(marker)
                } else {
                    delegate?.arrangementSectionMenu(marker, at: p, in: self)
                }
            } else if event.clickCount >= 2 || m.sections.isEmpty {
                delegate?.arrangementAddSection(bar: bar)
            }
            return
        }
        if m.hasAudio && p.y >= m.audioTop && p.y < m.audioTop + ArrangementModel.audioHeight {
            drag = .alignment(startX: p.x, startOffset: m.alignment.offsetSeconds)
            return
        }
        if p.y >= m.velocityTop {
            if let n = velocityNote(at: p) {
                var ids = m.selection
                if !ids.contains(n.id) { ids = [n.id]; delegate?.arrangementSelect(ids) }
                drag = .velocity(startY: p.y, ids: ids, applied: 0)
                dragPreviewVelocity = 0
            }
            return
        }
        // Drum lanes.
        if let n = note(at: p) {
            var ids = m.selection
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command) {
                if ids.contains(n.id) { ids.remove(n.id) } else { ids.insert(n.id) }
                delegate?.arrangementSelect(ids)
                return
            }
            if !ids.contains(n.id) { ids = [n.id]; delegate?.arrangementSelect(ids) }
            drag = .notes(startPoint: p, ids: ids, began: false)
            dragPreviewDelta = 0
            dragPreviewLane = nil
            NSCursor.closedHand.set()
            return
        }
        if event.clickCount >= 2, let laneIdx = lane(atY: p.y) {
            delegate?.arrangementAddNote(pitch: m.lanes[laneIdx].pitch, tick: snappedTick(max(0, m.tick(forX: p.x)), force: true))
            return
        }
        if !event.modifierFlags.contains(.shift) { delegate?.arrangementSelect([]) }
        drag = .rubberBand(start: p)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragCurrent = p
        let m = model
        switch drag {
        case .none:
            break
        case .seek:
            let distance = abs(p.x - m.x(forTick: m.tick(forSong: playheadSong)))
            if distance > 6 {
                drag = .loop(startTick: m.tick(forX: p.x))
            }
        case .loop(let startTick):
            let a = min(startTick, m.tick(forX: p.x))
            let b = max(startTick, m.tick(forX: p.x))
            let barA = m.tempoMap.position(atTick: max(0, a)).bar
            let barB = m.tempoMap.position(atTick: max(0, b)).bar
            delegate?.arrangementSetLoop(bars: barA ... max(barA, barB))
        case .alignment(let startX, let startOffset):
            // Dragging the audio right makes it play later relative to the MIDI.
            let dx = p.x - startX
            let seconds = m.song(forTick: Double(dx) / m.pixelsPerTick) - m.song(forTick: 0)
            delegate?.arrangementSetAlignment(offset: startOffset - seconds, commit: false)
        case .notes(let start, let ids, let began):
            if !began && hypot(p.x - start.x, p.y - start.y) < 3 { return }
            if !began { delegate?.arrangementBeginEdit() }
            drag = .notes(startPoint: start, ids: ids, began: true)
            var delta = Double(p.x - start.x) / m.pixelsPerTick
            if m.snap || event.modifierFlags.contains(.command) {
                let step = Double(m.ppq) / 4
                delta = (delta / step).rounded() * step
            }
            if event.modifierFlags.contains(.option) { delta *= 0.2 }
            dragPreviewDelta = delta
            if let startLane = lane(atY: start.y), let nowLane = lane(atY: p.y), nowLane != startLane {
                dragPreviewLane = nowLane - startLane + (m.selection.compactMap { id in m.current.first { $0.id == id }.flatMap { m.laneIndex[$0.pitch] } }.min() ?? 0)
            } else {
                dragPreviewLane = nil
            }
            needsDisplay = true
        case .velocity(let startY, let ids, let applied):
            let delta = Int((startY - p.y) * 1.2)
            dragPreviewVelocity = delta
            drag = .velocity(startY: startY, ids: ids, applied: applied)
            needsDisplay = true
        case .rubberBand(let start):
            let r = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            rubberBand = r
            var ids = Set<Int>()
            let t0 = m.tick(forX: r.minX), t1 = m.tick(forX: r.maxX)
            for n in m.current where n.tick >= t0 && n.tick <= t1 {
                guard let laneIdx = m.laneIndex[n.pitch] else { continue }
                let y = m.lanesTop + CGFloat(laneIdx) * ArrangementModel.laneHeight + ArrangementModel.laneHeight / 2
                if y >= r.minY && y <= r.maxY { ids.insert(n.id) }
            }
            if event.modifierFlags.contains(.shift) { ids.formUnion(model.selection) }
            delegate?.arrangementSelect(ids)
            needsDisplay = true
        case .section(let marker):
            let bar = self.bar(atX: p.x + 4)
            if bar != marker.bar && bar >= 0 {
                delegate?.arrangementMoveSection(marker, toBar: bar)
                var moved = marker
                moved.bar = bar
                drag = .section(moved)
            }
        }
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let m = model
        switch drag {
        case .notes(_, let ids, true):
            var toPitch: Int? = nil
            if let target = dragPreviewLane, target >= 0, target < m.lanes.count, ids.count == 1 { toPitch = m.lanes[target].pitch }
            if abs(dragPreviewDelta) > 0.01 || toPitch != nil {
                delegate?.arrangementMove(ids: ids, deltaTicks: dragPreviewDelta, toPitch: toPitch)
            }
        case .velocity(_, let ids, _):
            if dragPreviewVelocity != 0 {
                delegate?.arrangementBeginEdit()
                delegate?.arrangementSetVelocity(ids: ids, delta: dragPreviewVelocity)
            }
        case .alignment:
            delegate?.arrangementSetAlignment(offset: m.alignment.offsetSeconds, commit: true)
        default:
            break
        }
        drag = .none
        dragPreviewDelta = 0
        dragPreviewLane = nil
        dragPreviewVelocity = 0
        rubberBand = nil
        needsDisplay = true
        updateCursor(convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let m = model
        if p.y >= visibleRect.minY + ArrangementModel.rulerHeight && p.y < visibleRect.minY + ArrangementModel.rulerHeight + ArrangementModel.sectionHeight {
            let bar = self.bar(atX: p.x)
            if let marker = m.sections.last(where: { $0.bar <= bar }) {
                delegate?.arrangementSectionMenu(marker, at: p, in: self)
            } else {
                delegate?.arrangementAddSection(bar: bar)
            }
            return
        }
        if let n = note(at: p), !m.selection.contains(n.id) { delegate?.arrangementSelect([n.id]) }
        let menu = NSMenu()
        let bar = self.bar(atX: p.x)
        clickBar = bar
        if !model.selection.isEmpty || note(at: p) != nil {
            menu.addItem(withTitle: "Delete Selected Notes", action: #selector(menuDelete), keyEquivalent: "")
            menu.addItem(withTitle: "Louder (+8)", action: #selector(menuLouder), keyEquivalent: "")
            menu.addItem(withTitle: "Softer (−8)", action: #selector(menuSofter), keyEquivalent: "")
            menu.addItem(withTitle: "Longer Notes", action: #selector(menuLonger), keyEquivalent: "")
            menu.addItem(withTitle: "Shorter Notes", action: #selector(menuShorter), keyEquivalent: "")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Loop Bar \(bar + 1)", action: #selector(menuLoopBar), keyEquivalent: "")
        menu.addItem(withTitle: "Humanise Only Bars Around Here (\(max(1, bar - 1)) – \(bar + 3))", action: #selector(menuProcessHere), keyEquivalent: "")
        menu.addItem(withTitle: "Humanise All Bars", action: #selector(menuProcessAll), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Add Section Marker at Bar \(bar + 1)", action: #selector(menuAddSection), keyEquivalent: "")
        for item in menu.items { item.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private var clickBar = 0
    @objc private func menuDelete() { delegate?.arrangementDelete(ids: model.selection) }
    @objc private func menuLouder() { delegate?.arrangementBeginEdit(); delegate?.arrangementSetVelocity(ids: model.selection, delta: 8) }
    @objc private func menuSofter() { delegate?.arrangementBeginEdit(); delegate?.arrangementSetVelocity(ids: model.selection, delta: -8) }
    @objc private func menuLonger() { delegate?.arrangementSetLength(ids: model.selection, factor: 1.5) }
    @objc private func menuShorter() { delegate?.arrangementSetLength(ids: model.selection, factor: 0.66) }
    @objc private func menuLoopBar() { delegate?.arrangementSetLoop(bars: clickBar ... clickBar) }
    @objc private func menuProcessHere() { delegate?.arrangementProcessBars(max(0, clickBar - 2) ... (clickBar + 2)) }
    @objc private func menuProcessAll() { delegate?.arrangementProcessBars(nil) }
    @objc private func menuAddSection() { delegate?.arrangementAddSection(bar: clickBar) }

    // MARK: Keyboard, zoom

    override func keyDown(with event: NSEvent) {
        let m = model
        let sel = m.selection
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            if !sel.isEmpty { delegate?.arrangementDelete(ids: sel) }
        case 123, 124: // left / right: nudge 1/64 beat (⌥ = 1/256)
            guard !sel.isEmpty else { return }
            let step = Double(m.ppq) / (event.modifierFlags.contains(.option) ? 256 : 64)
            delegate?.arrangementBeginEdit()
            delegate?.arrangementMove(ids: sel, deltaTicks: event.keyCode == 123 ? -step : step, toPitch: nil)
        case 125, 126: // down / up: velocity
            guard !sel.isEmpty else { return }
            let step = event.modifierFlags.contains(.shift) ? 10 : 3
            delegate?.arrangementBeginEdit()
            delegate?.arrangementSetVelocity(ids: sel, delta: event.keyCode == 126 ? step : -step)
        default:
            if event.charactersIgnoringModifiers == "a" && event.modifierFlags.contains(.command) {
                delegate?.arrangementSelect(Set(m.current.map(\.id)))
            } else if event.keyCode == 53 {
                delegate?.arrangementSelect([])
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let p = convert(event.locationInWindow, from: nil)
            let factor = pow(1.01, Double(event.scrollingDeltaY))
            delegate?.arrangementZoom(by: factor, anchorTick: model.tick(forX: p.x), viewX: p.x - visibleRect.minX)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        delegate?.arrangementZoom(by: 1 + Double(event.magnification), anchorTick: model.tick(forX: p.x), viewX: p.x - visibleRect.minX)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        let m = model
        return "Drum grid. \(m.lanes.count) drum lanes, \(m.current.count) notes, \(m.selection.count) selected. Arrow keys nudge timing and velocity of the selection; Delete removes it."
    }
}
