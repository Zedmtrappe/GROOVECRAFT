import SwiftUI
import AppKit

/// Groovecraft's design system. Every colour, size and timing used by the UI comes from here,
/// so the look can be tuned (or rebranded) in one place.
enum GC {
    // MARK: Brand
    enum Brand {
        static let name = "Groovecraft"
        static let wordmark = "groovecraft"
        static let tagline = "Programmed drums, played."
    }

    // MARK: Colour
    enum Palette {
        // Surfaces: graphite → charcoal, from the window background up to raised controls.
        static let background = Color(hex: 0x0D0E10)
        static let surface = Color(hex: 0x141619)
        static let surfaceRaised = Color(hex: 0x1A1D21)
        static let control = Color(hex: 0x22262B)
        static let controlHover = Color(hex: 0x2A2F35)
        static let controlPressed = Color(hex: 0x30363D)
        static let hairline = Color(hex: 0x2A2E34)
        static let hairlineStrong = Color(hex: 0x3A3F46)

        // Text
        static let textPrimary = Color(hex: 0xECEEF0)
        static let textSecondary = Color(hex: 0xA0A8B1)
        static let textTertiary = Color(hex: 0x6C747E)
        static let textDisabled = Color(hex: 0x4A5058)

        // Accent: one warm amber for "performed" things and primary actions …
        static let accent = Color(hex: 0xF4A940)
        static let accentBright = Color(hex: 0xFFC46B)
        static let accentDeep = Color(hex: 0xC97E1C)
        static let accentGlow = Color(hex: 0xF4A940).opacity(0.35)
        // … and one cool steel for the original / reference material.
        static let reference = Color(hex: 0x7C95B3)
        static let referenceDim = Color(hex: 0x4C5D73)

        // Status
        static let success = Color(hex: 0x5EC28E)
        static let warning = Color(hex: 0xF0C24B)
        static let danger = Color(hex: 0xE5615B)
        static let info = Color(hex: 0x6FA8DC)

        static let focus = Color(hex: 0xF4A940).opacity(0.8)
        static let selection = Color(hex: 0xF4A940).opacity(0.18)
    }

    /// The same colours for AppKit drawing.
    enum NS {
        static let background = NSColor(hex: 0x0D0E10)
        static let surface = NSColor(hex: 0x141619)
        static let surfaceRaised = NSColor(hex: 0x1A1D21)
        static let laneA = NSColor(hex: 0x15181B)
        static let laneB = NSColor(hex: 0x121417)
        static let hairline = NSColor(hex: 0x2A2E34)
        static let barLine = NSColor(hex: 0x3A3F46)
        static let beatLine = NSColor(hex: 0x23272C)
        static let subLine = NSColor(hex: 0x1C1F23)
        static let textPrimary = NSColor(hex: 0xECEEF0)
        static let textSecondary = NSColor(hex: 0xA0A8B1)
        static let textTertiary = NSColor(hex: 0x6C747E)
        static let accent = NSColor(hex: 0xF4A940)
        static let accentBright = NSColor(hex: 0xFFC46B)
        static let reference = NSColor(hex: 0x7C95B3)
        static let referenceDim = NSColor(hex: 0x4C5D73)
        static let success = NSColor(hex: 0x5EC28E)
        static let danger = NSColor(hex: 0xE5615B)
        static let waveform = NSColor(hex: 0x56677C)
        static let energy = NSColor(hex: 0xF4A940).withAlphaComponent(0.55)
        static let bass = NSColor(hex: 0x8F7CF0)
    }

    // MARK: Typography
    enum Font {
        static let wordmark = SwiftUI.Font.system(size: 17, weight: .semibold, design: .rounded)
        static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let heading = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let section = SwiftUI.Font.system(size: 10.5, weight: .semibold).width(.expanded)
        static let control = SwiftUI.Font.system(size: 12, weight: .medium)
        static let body = SwiftUI.Font.system(size: 12)
        static let caption = SwiftUI.Font.system(size: 11)
        static let micro = SwiftUI.Font.system(size: 10, weight: .medium)
        /// Parameter values and musical numbers: monospaced digits so they don't jitter.
        static let value = SwiftUI.Font.system(size: 12, weight: .medium, design: .monospaced)
        static let valueLarge = SwiftUI.Font.system(size: 20, weight: .semibold, design: .monospaced)
        static let musical = SwiftUI.Font.system(size: 13, weight: .semibold, design: .monospaced)
    }

    // MARK: Layout
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let s: CGFloat = 4
        static let m: CGFloat = 6
        static let l: CGFloat = 10
        static let xl: CGFloat = 14
    }

    enum Size {
        static let headerHeight: CGFloat = 52
        static let transportHeight: CGFloat = 44
        static let sidebarWidth: CGFloat = 236
        static let inspectorWidth: CGFloat = 330
        static let controlHeight: CGFloat = 26
        static let largeControlHeight: CGFloat = 32
        static let knob: CGFloat = 52
        static let laneHeight: CGFloat = 22
        static let laneHeaderWidth: CGFloat = 132
    }

    // MARK: Motion
    enum Motion {
        static let quick = Animation.easeOut(duration: 0.12)
        static let standard = Animation.easeInOut(duration: 0.2)
        static let panel = Animation.spring(response: 0.32, dampingFraction: 0.86)
        static let emphasis = Animation.spring(response: 0.45, dampingFraction: 0.7)
    }

    enum Shadow {
        static let panel = Color.black.opacity(0.45)
        static let control = Color.black.opacity(0.35)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}

/// Respect "Reduce motion" (system) and the in-app animation preference.
struct MotionPreference {
    static var enabled: Bool {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return false }
        return UserDefaults.standard.object(forKey: "animations") as? Bool ?? true
    }

    static func animation(_ a: Animation) -> Animation? { enabled ? a : nil }
}
