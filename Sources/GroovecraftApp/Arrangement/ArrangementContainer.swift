import SwiftUI
import AppKit
import GrooveCore

/// SwiftUI wrapper: an NSScrollView holding the arrangement view.
struct ArrangementContainer: NSViewRepresentable {
    @ObservedObject var app: AppState
    @ObservedObject var transport: TransportController

    func makeCoordinator() -> Coordinator { Coordinator(app: app) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = GC.NS.background
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .allowed
        let view = ArrangementView(frame: NSRect(x: 0, y: 0, width: 1200, height: 400))
        view.delegate = context.coordinator
        scroll.documentView = view
        context.coordinator.view = view
        context.coordinator.scrollView = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.boundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ArrangementView else { return }
        context.coordinator.app = app
        // Rebuild the drawing model only when something it shows has changed (the playhead
        // alone updates 60 times a second).
        let key = ModelKey(revision: app.revision, selection: app.selection, pixelsPerBeat: app.pixelsPerBeat,
                           ghosts: app.prefs.showOriginalGhosts, snap: app.prefs.snapToGrid,
                           loop: transport.loopRange, loopEnabled: transport.loopEnabled)
        if context.coordinator.lastKey != key {
            context.coordinator.lastKey = key
            let model = ArrangementModel.make(document: app.document, selection: app.selection, pixelsPerBeat: app.pixelsPerBeat,
                                              showGhosts: app.prefs.showOriginalGhosts, snap: app.prefs.snapToGrid,
                                              loop: transport.loopRange, loopEnabled: transport.loopEnabled)
            view.model = model
        }
        let model = view.model
        let width = max(scroll.contentSize.width, model.contentWidth)
        let height = max(scroll.contentSize.height, model.totalHeight)
        if view.frame.size != NSSize(width: width, height: height) {
            view.setFrameSize(NSSize(width: width, height: height))
        }
        view.isPlaying = transport.isPlaying
        view.playheadSong = transport.position
        // Follow the playhead while playing.
        if transport.isPlaying {
            let x = model.x(forTick: model.tick(forSong: transport.position))
            let visible = scroll.contentView.bounds
            if x > visible.maxX - 60 || x < visible.minX + ArrangementModel.headerWidth {
                let target = max(0, x - ArrangementModel.headerWidth - 40)
                scroll.contentView.scroll(to: NSPoint(x: target, y: visible.minY))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        if let pending = context.coordinator.pendingScrollX {
            context.coordinator.pendingScrollX = nil
            scroll.contentView.scroll(to: NSPoint(x: max(0, pending), y: scroll.contentView.bounds.minY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    struct ModelKey: Equatable {
        var revision: Int
        var selection: Set<Int>
        var pixelsPerBeat: Double
        var ghosts: Bool
        var snap: Bool
        var loop: ClosedRange<Double>
        var loopEnabled: Bool
    }

    @MainActor
    final class Coordinator: NSObject, ArrangementDelegate {
        var app: AppState
        var lastKey: ModelKey?
        weak var view: ArrangementView?
        weak var scrollView: NSScrollView?
        var pendingScrollX: CGFloat?
        private var alignmentEditing = false

        init(app: AppState) { self.app = app }

        @objc func boundsChanged() { view?.needsDisplay = true }

        func arrangementSelect(_ ids: Set<Int>) { app.selection = ids }

        func arrangementSeek(toSong seconds: Double) { app.transport.seek(to: seconds) }

        func arrangementSetLoop(bars: ClosedRange<Int>) { app.transport.setLoop(bars: bars) }

        func arrangementBeginEdit() {}

        func arrangementMove(ids: Set<Int>, deltaTicks: Double, toPitch: Int?) {
            app.mutate { doc in
                if abs(deltaTicks) > 0.001 { doc.edit(.move(ids: ids, deltaTicks: deltaTicks), name: "Move Notes") }
                if let p = toPitch { doc.edit(.setPitch(ids: ids, pitch: p), name: "Change Drum") }
            }
        }

        func arrangementSetVelocity(ids: Set<Int>, delta: Int) {
            app.mutate { $0.edit(.velocity(ids: ids, delta: delta), name: "Change Velocity") }
        }

        func arrangementSetLength(ids: Set<Int>, factor: Double) {
            guard !ids.isEmpty else { return }
            app.mutate { $0.edit(.length(ids: ids, factor: factor), name: "Change Length") }
        }

        func arrangementAddNote(pitch: Int, tick: Double) {
            guard let doc = app.document else { return }
            let template = doc.pattern.notes.first { $0.pitch == pitch } ?? doc.pattern.notes.first
            let note = DrumNote(id: 0, track: template?.track ?? (doc.pattern.drumTracks.first ?? 0),
                                channel: template?.channel ?? 9, pitch: pitch, tick: tick,
                                length: Double(doc.pattern.ppq) / 8, velocity: 96)
            app.mutate { $0.edit(.add(note), name: "Add Note") }
            if let added = app.document?.selectedNotes.first(where: { $0.pitch == pitch && abs($0.tick - tick) < 0.01 }) {
                app.selection = [added.id]
            }
            app.audition(pitch: pitch)
        }

        func arrangementDelete(ids: Set<Int>) {
            guard !ids.isEmpty else { return }
            app.mutate { $0.edit(.delete(ids: ids), name: "Delete Notes") }
            app.selection = []
        }

        func arrangementSetAlignment(offset: Double, commit: Bool) {
            guard let doc = app.document else { return }
            if !alignmentEditing {
                alignmentEditing = true
                doc.beginContinuousChange("Adjust Alignment")
            }
            app.mutate { d in d.changeWithoutUndo { s in s.alignment.offsetSeconds = (offset * 1000).rounded() / 1000; s.alignment.isAutomatic = false } }
            if commit {
                alignmentEditing = false
                app.transport.restartFromCurrentPosition()
            }
        }

        func arrangementAddSection(bar: Int) {
            let menu = NSMenu(title: "Add Section")
            menu.addItem(NSMenuItem.sectionHeader(title: "Add marker at bar \(bar + 1)"))
            for kind in SectionKind.allCases where kind != .unknown {
                let item = NSMenuItem(title: kind.displayName, action: #selector(addSectionItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [bar, SectionKind.allCases.firstIndex(of: kind) ?? 0]
                menu.addItem(item)
            }
            if let v = view, let event = NSApp.currentEvent {
                NSMenu.popUpContextMenu(menu, with: event, for: v)
            }
        }

        @objc func addSectionItem(_ sender: NSMenuItem) {
            guard let info = sender.representedObject as? [Int], info.count == 2 else { return }
            let kind = SectionKind.allCases[info[1]]
            app.mutate { $0.addSection(SectionMarker(bar: info[0], kind: kind)) }
        }

        func arrangementSectionMenu(_ marker: SectionMarker, at point: NSPoint, in view: NSView) {
            let menu = NSMenu(title: marker.label)
            menu.addItem(NSMenuItem.sectionHeader(title: "\(marker.label) · bar \(marker.bar + 1)\(marker.isEstimate ? " (estimated)" : "")"))
            for kind in SectionKind.allCases where kind != .unknown {
                let item = NSMenuItem(title: "Make it \(kind.displayName)", action: #selector(relabelSection(_:)), keyEquivalent: "")
                item.target = self
                item.state = kind == marker.kind ? .on : .off
                item.representedObject = [marker.id.uuidString, kind.rawValue]
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let rename = NSMenuItem(title: "Rename…", action: #selector(renameSection(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = marker.id.uuidString
            menu.addItem(rename)
            let loop = NSMenuItem(title: "Loop This Section", action: #selector(loopSection(_:)), keyEquivalent: "")
            loop.target = self
            loop.representedObject = marker.id.uuidString
            menu.addItem(loop)
            let process = NSMenuItem(title: "Humanise Only This Section", action: #selector(processSection(_:)), keyEquivalent: "")
            process.target = self
            process.representedObject = marker.id.uuidString
            menu.addItem(process)
            menu.addItem(.separator())
            let delete = NSMenuItem(title: "Delete Marker", action: #selector(deleteSection(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = marker.id.uuidString
            menu.addItem(delete)
            menu.popUp(positioning: nil, at: point, in: view)
        }

        private func marker(_ sender: NSMenuItem) -> SectionMarker? {
            let idString = (sender.representedObject as? String) ?? (sender.representedObject as? [String])?.first
            guard let s = idString, let id = UUID(uuidString: s) else { return nil }
            return app.document?.state.sections.first { $0.id == id }
        }

        private func sectionBars(_ m: SectionMarker) -> ClosedRange<Int> {
            guard let doc = app.document else { return m.bar ... m.bar }
            let sorted = doc.state.sections.sorted { $0.bar < $1.bar }
            let next = sorted.first { $0.bar > m.bar }?.bar ?? doc.analysis.bars
            return m.bar ... max(m.bar, next - 1)
        }

        @objc func relabelSection(_ sender: NSMenuItem) {
            guard var m = marker(sender), let info = sender.representedObject as? [String], info.count == 2,
                  let kind = SectionKind(rawValue: info[1]) else { return }
            let keepLabel = m.label != m.kind.displayName
            m.kind = kind
            if !keepLabel { m.label = kind.displayName }
            app.mutate { $0.updateSection(m) }
        }

        @objc func renameSection(_ sender: NSMenuItem) {
            guard var m = marker(sender) else { return }
            let alert = NSAlert()
            alert.messageText = "Rename section"
            let field = NSTextField(string: m.label)
            field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: "Rename")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                let name = field.stringValue.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { m.label = name; app.mutate { $0.updateSection(m) } }
            }
        }

        @objc func loopSection(_ sender: NSMenuItem) {
            guard let m = marker(sender) else { return }
            app.transport.setLoop(bars: sectionBars(m))
        }

        @objc func processSection(_ sender: NSMenuItem) {
            guard let m = marker(sender) else { return }
            let bars = sectionBars(m)
            app.mutate { $0.change("Process Section") { s in s.processBars = bars } }
        }

        @objc func deleteSection(_ sender: NSMenuItem) {
            guard let m = marker(sender) else { return }
            app.mutate { $0.removeSection(m.id) }
        }

        func arrangementMoveSection(_ marker: SectionMarker, toBar bar: Int) {
            var m = marker
            m.bar = bar
            app.mutate { $0.updateSection(m) }
        }

        func arrangementProcessBars(_ bars: ClosedRange<Int>?) {
            app.mutate { $0.change(bars == nil ? "Process All Bars" : "Process Bars") { s in s.processBars = bars } }
        }

        func arrangementZoom(by factor: Double, anchorTick: Double, viewX: CGFloat) {
            let old = app.pixelsPerBeat
            let new = min(400, max(6, old * factor))
            guard abs(new - old) > 0.01, let doc = app.document else { return }
            app.pixelsPerBeat = new
            // Keep the beat under the pointer still.
            let ppt = new / Double(doc.pattern.ppq)
            let x = ArrangementModel.headerWidth + CGFloat(anchorTick * ppt)
            pendingScrollX = x - viewX
        }

        func arrangementAudition(pitch: Int) { app.audition(pitch: pitch) }
    }
}

extension AppState {
    /// Plays one drum through the current output (external and/or preview kit).
    func audition(pitch: Int) {
        let map = document?.state.drumMap ?? .generalMIDI
        let out = prefs.output.noteMap.output(for: pitch)
        if prefs.externalEnabled { midi.sendTestNote(channel: prefs.output.channel ?? 9, note: out, velocity: 100) }
        if prefs.previewKitEnabled {
            audio.startEngine()
            audio.renderer.synth.trigger(category: map.category(for: pitch), note: pitch, velocity: 100)
        }
        flashActivity()
    }
}
