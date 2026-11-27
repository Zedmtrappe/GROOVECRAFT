import SwiftUI
import GrooveCore

extension AppState {
    var state: ProjectState { document?.state ?? ProjectState() }

    /// A binding into the project state for continuous controls (sliders, knobs). Call
    /// `beginEdit` when the gesture starts (one undo step) and `endEdit` when it ends
    /// (live-updates the selected take).
    func binding<T: Equatable>(_ keyPath: WritableKeyPath<ProjectState, T>) -> Binding<T> {
        Binding(
            get: { self.state[keyPath: keyPath] },
            set: { value in
                guard self.document?.state[keyPath: keyPath] != value else { return }
                self.mutate { doc in doc.changeWithoutUndo { $0[keyPath: keyPath] = value } }
            }
        )
    }

    /// A binding where every change is its own undo step and refreshes the take (toggles, pickers).
    func undoableBinding<T: Equatable>(_ keyPath: WritableKeyPath<ProjectState, T>, _ name: String, live: Bool = true) -> Binding<T> {
        Binding(
            get: { self.state[keyPath: keyPath] },
            set: { value in
                guard self.document?.state[keyPath: keyPath] != value else { return }
                self.mutate { doc in doc.change(name) { $0[keyPath: keyPath] = value } }
                if live { self.liveUpdate() }
            }
        )
    }

    func beginEdit(_ name: String) {
        document?.beginContinuousChange(name)
    }

    func endEdit() { liveUpdate() }

    /// Re-renders the selected take with the current controls (same seed).
    func liveUpdate() {
        guard UserDefaults.standard.object(forKey: "liveUpdate") as? Bool ?? true else { return }
        guard let doc = document, doc.selectedVariation != nil else { return }
        mutate { $0.refreshSelectedTake() }
    }

    /// Binding to a preference value.
    func pref<T: Equatable>(_ keyPath: WritableKeyPath<AppPreferences, T>) -> Binding<T> {
        Binding(get: { self.prefs[keyPath: keyPath] }, set: { self.prefs[keyPath: keyPath] = $0 })
    }
}

/// Number formatting used across the inspector.
enum Fmt {
    static func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
    static func ms(_ v: Double) -> String { String(format: "%.1f ms", v) }
    static func signedMs(_ v: Double) -> String { String(format: "%+.1f ms", v) }
    static func plain(_ v: Double) -> String { String(format: "%.0f", v) }
    static func signed(_ v: Double) -> String { String(format: "%+.0f", v) }
    static func factor(_ v: Double) -> String { String(format: "×%.2f", v) }
    static func bpm(_ v: Double) -> String { String(format: "%.1f", v) }
    static func lockLabel(_ v: Double) -> String {
        if v < 0.2 { return "Loose" }
        if v < 0.4 { return "Relaxed" }
        if v < 0.62 { return "Natural" }
        if v < 0.82 { return "Firm" }
        return "Tight"
    }
    static func pushPull(_ v: Double) -> String {
        if abs(v) < 0.05 { return "On the beat" }
        return v < 0 ? String(format: "Ahead %.0f%%", -v * 100) : String(format: "Behind %.0f%%", v * 100)
    }
    static func swing(_ v: Double) -> String { String(format: "%.0f%%", (0.5 + v * 0.25) * 100) }
}
