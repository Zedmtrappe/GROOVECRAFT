import SwiftUI
import UniformTypeIdentifiers
import GrooveCore

struct MainWindow: View {
    @ObservedObject var app: AppState
    @ObservedObject var transport: TransportController

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(app: app, transport: transport)
            Group {
                if app.hasDocument {
                    HStack(spacing: 0) {
                        Sidebar(app: app)
                            .frame(width: GC.Size.sidebarWidth)
                            .hairline(.trailing)
                        VStack(spacing: 0) {
                            TransportBar(app: app, transport: transport)
                            ArrangementContainer(app: app, transport: transport)
                                .accessibilityLabel("Arrangement and drum grid")
                        }
                        .frame(minWidth: 480)
                        Inspector(app: app)
                            .frame(width: GC.Size.inspectorWidth)
                            .hairline(.leading)
                    }
                    .transition(.opacity)
                } else {
                    EmptyStateView(app: app)
                        .transition(.opacity)
                }
            }
            .animation(MotionPreference.animation(GC.Motion.panel), value: app.hasDocument)
        }
        .background(GC.Palette.background)
        .foregroundStyle(GC.Palette.textPrimary)
        .overlay(alignment: .bottom) { ToastView(toast: app.toast).padding(.bottom, 22) }
        .overlay { if app.isAnalysing { AnalysisOverlay(app: app) } }
        .overlay {
            if app.isDropTargeted {
                RoundedRectangle(cornerRadius: GC.Radius.xl)
                    .stroke(GC.Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(GC.Palette.accent.opacity(0.05))
                    .padding(10)
                    .overlay(Text("Drop MIDI, audio or a Groovecraft project").font(GC.Font.title).foregroundStyle(GC.Palette.accent))
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $app.isDropTargeted) { providers in app.handleDrop(providers) }
        .sheet(isPresented: $app.showLogicGuide) { LogicGuideView(app: app) }
        .alert(item: $app.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
        .navigationTitle(app.windowTitle)
        .preferredColorScheme(.dark)
    }
}

struct ToastView: View {
    let toast: Toast?
    var body: some View {
        if let t = toast {
            HStack(spacing: 8) {
                Image(systemName: t.symbol)
                    .foregroundStyle(t.isError ? GC.Palette.danger : GC.Palette.accent)
                Text(t.text)
                    .font(GC.Font.control)
                    .foregroundStyle(GC.Palette.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Capsule().fill(GC.Palette.surfaceRaised))
            .overlay(Capsule().stroke(GC.Palette.hairlineStrong, lineWidth: 1))
            .shadow(color: GC.Shadow.panel, radius: 14, y: 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(t.id)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

struct AnalysisOverlay: View {
    @ObservedObject var app: AppState
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(app.analysisStatus).font(GC.Font.title)
                }
                ProgressView(value: app.analysisProgress)
                    .progressViewStyle(.linear)
                    .tint(GC.Palette.accent)
                    .frame(width: 320)
                Text("Finding tempo, beats, bass attacks, energy and sections. Everything runs on this Mac.")
                    .font(GC.Font.caption)
                    .foregroundStyle(GC.Palette.textSecondary)
                    .frame(width: 320, alignment: .leading)
            }
            .padding(22)
            .background(RoundedRectangle(cornerRadius: GC.Radius.xl).fill(GC.Palette.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: GC.Radius.xl).stroke(GC.Palette.hairlineStrong, lineWidth: 1))
            .shadow(color: GC.Shadow.panel, radius: 30, y: 10)
        }
        .transition(.opacity)
    }
}
