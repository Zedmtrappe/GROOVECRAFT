import SwiftUI

// MARK: - Panel sections

/// A titled group inside a panel: small expanded caps title, optional trailing accessory.
struct PanelSection<Content: View, Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GC.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: GC.Space.s) {
                Text(title.uppercased())
                    .font(GC.Font.section)
                    .foregroundStyle(GC.Palette.textTertiary)
                    .tracking(0.6)
                if let subtitle {
                    Text(subtitle)
                        .font(GC.Font.caption)
                        .foregroundStyle(GC.Palette.textTertiary)
                }
                Spacer(minLength: 0)
                trailing()
            }
            content()
        }
        .padding(.horizontal, GC.Space.l)
        .padding(.vertical, GC.Space.m)
    }
}

extension PanelSection where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}

/// A collapsible section for Advanced mode.
struct DisclosureSection<Content: View>: View {
    let title: String
    let symbol: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(MotionPreference.animation(GC.Motion.standard)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: GC.Space.s) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isExpanded ? GC.Palette.accent : GC.Palette.textTertiary)
                        .frame(width: 16)
                    Text(title)
                        .font(GC.Font.heading)
                        .foregroundStyle(GC.Palette.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(GC.Palette.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, GC.Space.l)
                .padding(.vertical, GC.Space.m - 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(alignment: .leading, spacing: GC.Space.m) {
                    content()
                }
                .padding(.horizontal, GC.Space.l)
                .padding(.bottom, GC.Space.m)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Rectangle().fill(GC.Palette.hairline).frame(height: 1)
        }
    }
}

// MARK: - Slider

/// A precise horizontal slider with label, value read-out, double-click reset and full
/// keyboard / VoiceOver support. Bipolar ranges fill from zero.
struct GCSlider: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0 ... 1
    var defaultValue: Double? = nil
    var step: Double = 0
    var format: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }
    var help: String? = nil
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}

    @State private var isDragging = false
    @State private var isHovering = false

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    private var zeroFraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0, range.lowerBound < 0, range.upperBound > 0 else { return 0 }
        return -range.lowerBound / span
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: GC.Space.s) {
                Text(label)
                    .font(GC.Font.control)
                    .foregroundStyle(GC.Palette.textSecondary)
                Spacer(minLength: 4)
                Text(format(value))
                    .font(GC.Font.value)
                    .foregroundStyle(isDragging ? GC.Palette.accentBright : GC.Palette.textPrimary)
                    .contentTransition(.numericText())
            }
            GeometryReader { geo in
                let width = geo.size.width
                let thumbX = width * CGFloat(fraction)
                let zeroX = width * CGFloat(zeroFraction)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(GC.Palette.control)
                        .frame(height: 4)
                    Capsule()
                        .fill(LinearGradient(colors: [GC.Palette.accentDeep, GC.Palette.accent], startPoint: .leading, endPoint: .trailing))
                        .frame(width: abs(thumbX - zeroX), height: 4)
                        .offset(x: min(thumbX, zeroX))
                    Circle()
                        .fill(isDragging ? GC.Palette.accentBright : GC.Palette.textPrimary)
                        .frame(width: 12, height: 12)
                        .shadow(color: isDragging || isHovering ? GC.Palette.accentGlow : GC.Shadow.control, radius: isDragging ? 6 : 3)
                        .offset(x: thumbX - 6)
                }
                .frame(height: 14)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            if !isDragging { isDragging = true; onBegin() }
                            let precise = NSEvent.modifierFlags.contains(.option)
                            var f = Double(drag.location.x / max(1, width))
                            if precise {
                                // ⌥ drag: fine adjustment around the start point.
                                let start = Double(drag.startLocation.x / max(1, width))
                                f = start + (f - start) * 0.15
                            }
                            set(fraction: f)
                        }
                        .onEnded { _ in isDragging = false; onEnd() }
                )
                .onTapGesture(count: 2) {
                    if let d = defaultValue { onBegin(); value = d; onEnd() }
                }
            }
            .frame(height: 14)
        }
        .onHover { isHovering = $0 }
        .help(help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            let span = range.upperBound - range.lowerBound
            let delta = step > 0 ? step : span / 50
            onBegin()
            switch direction {
            case .increment: value = min(range.upperBound, value + delta)
            case .decrement: value = max(range.lowerBound, value - delta)
            @unknown default: break
            }
            onEnd()
        }
    }

    private func set(fraction f: Double) {
        let clamped = min(1, max(0, f))
        var v = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
        if step > 0 { v = (v / step).rounded() * step }
        value = min(range.upperBound, max(range.lowerBound, v))
    }
}

// MARK: - Knob

/// A rotary macro control. Drag up/down (⌥ for fine), scroll, or double-click to reset.
struct GCKnob: View {
    let label: String
    @Binding var value: Double
    var defaultValue: Double = 0.5
    var size: CGFloat = GC.Size.knob
    var help: String? = nil
    var format: (Double) -> String = { String(format: "%.0f", $0 * 100) }
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}

    @State private var dragStart: Double? = nil
    @State private var isHovering = false

    private let startAngle = 135.0
    private let sweep = 270.0

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [GC.Palette.controlHover, GC.Palette.control], center: .topLeading,
                                         startRadius: 2, endRadius: size))
                    .shadow(color: GC.Shadow.control, radius: 4, y: 2)
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(GC.Palette.background.opacity(0.9), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(startAngle))
                    .padding(-5)
                Circle()
                    .trim(from: 0, to: 0.75 * CGFloat(min(1, max(0, value))))
                    .stroke(LinearGradient(colors: [GC.Palette.accentDeep, GC.Palette.accentBright], startPoint: .bottomLeading, endPoint: .topTrailing),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(startAngle))
                    .padding(-5)
                    .shadow(color: dragStart != nil || isHovering ? GC.Palette.accentGlow : .clear, radius: 6)
                Capsule()
                    .fill(GC.Palette.textPrimary)
                    .frame(width: 2.5, height: size * 0.28)
                    .offset(y: -size * 0.22)
                    .rotationEffect(.degrees(startAngle + 90 + sweep * min(1, max(0, value))))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragStart == nil { dragStart = value; onBegin() }
                        let fine = NSEvent.modifierFlags.contains(.option) ? 0.2 : 1
                        let delta = Double(-g.translation.height + g.translation.width * 0.3) / 180 * fine
                        value = min(1, max(0, (dragStart ?? value) + delta))
                    }
                    .onEnded { _ in dragStart = nil; onEnd() }
            )
            .onTapGesture(count: 2) { onBegin(); value = defaultValue; onEnd() }
            .onHover { isHovering = $0 }

            VStack(spacing: 1) {
                Text(label)
                    .font(GC.Font.control)
                    .foregroundStyle(GC.Palette.textPrimary)
                Text(format(value))
                    .font(GC.Font.value)
                    .foregroundStyle(dragStart != nil ? GC.Palette.accentBright : GC.Palette.textTertiary)
                    .contentTransition(.numericText())
            }
        }
        .help(help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            onBegin()
            switch direction {
            case .increment: value = min(1, value + 0.05)
            case .decrement: value = max(0, value - 0.05)
            @unknown default: break
            }
            onEnd()
        }
    }
}

// MARK: - Segmented control

struct GCSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var compact = false
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let isOn = option.value == selection
                Button {
                    withAnimation(MotionPreference.animation(GC.Motion.panel)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(compact ? GC.Font.micro : GC.Font.control)
                        .foregroundStyle(isOn ? GC.Palette.textPrimary : GC.Palette.textSecondary)
                        .padding(.horizontal, compact ? 8 : 10)
                        .frame(maxWidth: .infinity)
                        .frame(height: compact ? 20 : 24)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: GC.Radius.s)
                                    .fill(GC.Palette.controlPressed)
                                    .shadow(color: GC.Shadow.control, radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: GC.Radius.m).fill(GC.Palette.background.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: GC.Radius.m).stroke(GC.Palette.hairline, lineWidth: 1))
    }
}

// MARK: - Buttons

struct GCButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }
    var kind: Kind = .secondary
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        GCButtonBody(configuration: configuration, kind: kind, large: large)
    }
}

private struct GCButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: GCButtonStyle.Kind
    let large: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(large ? .system(size: 13, weight: .semibold) : GC.Font.control)
            .foregroundStyle(foreground)
            .padding(.horizontal, large ? 16 : 10)
            .frame(height: large ? GC.Size.largeControlHeight : GC.Size.controlHeight)
            .background(background)
            .overlay(RoundedRectangle(cornerRadius: GC.Radius.m).stroke(border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: GC.Radius.m))
            .shadow(color: kind == .primary && isEnabled ? GC.Palette.accentGlow.opacity(hovering ? 1 : 0.5) : .clear, radius: hovering ? 10 : 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(MotionPreference.animation(GC.Motion.quick), value: configuration.isPressed)
            .animation(MotionPreference.animation(GC.Motion.quick), value: hovering)
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Color(hex: 0x1B1308)
        case .danger: return GC.Palette.danger
        default: return GC.Palette.textPrimary
        }
    }

    @ViewBuilder private var background: some View {
        switch kind {
        case .primary:
            LinearGradient(colors: configuration.isPressed ? [GC.Palette.accentDeep, GC.Palette.accent]
                                                            : [GC.Palette.accentBright, GC.Palette.accent],
                           startPoint: .top, endPoint: .bottom)
        case .secondary:
            (configuration.isPressed ? GC.Palette.controlPressed : (hovering ? GC.Palette.controlHover : GC.Palette.control))
        case .ghost:
            (hovering || configuration.isPressed ? GC.Palette.control : Color.clear)
        case .danger:
            (hovering ? GC.Palette.danger.opacity(0.18) : GC.Palette.control)
        }
    }

    private var border: Color {
        switch kind {
        case .primary: return GC.Palette.accentBright.opacity(0.6)
        case .ghost: return .clear
        default: return GC.Palette.hairlineStrong.opacity(hovering ? 1 : 0.6)
        }
    }
}

/// A square icon button for the header and toolbars.
struct IconButton: View {
    let systemName: String
    let help: String
    var isActive = false
    var size: CGFloat = 28
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? GC.Palette.accent : (hovering ? GC.Palette.textPrimary : GC.Palette.textSecondary))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: GC.Radius.m).fill(hovering || isActive ? GC.Palette.control : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Toggle

struct GCSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: GC.Space.s) {
            configuration.label
                .font(GC.Font.control)
                .foregroundStyle(GC.Palette.textSecondary)
            Spacer(minLength: 4)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? GC.Palette.accent : GC.Palette.control)
                    .overlay(Capsule().stroke(GC.Palette.hairlineStrong, lineWidth: configuration.isOn ? 0 : 1))
                    .frame(width: 30, height: 17)
                Circle()
                    .fill(configuration.isOn ? Color(hex: 0x1B1308) : GC.Palette.textSecondary)
                    .frame(width: 13, height: 13)
                    .padding(2)
            }
            .onTapGesture {
                withAnimation(MotionPreference.animation(GC.Motion.quick)) { configuration.isOn.toggle() }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

// MARK: - Chips, badges, LEDs

struct Chip: View {
    let label: String
    var detail: String? = nil
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(GC.Font.control)
                .foregroundStyle(isSelected ? Color(hex: 0x1B1308) : (hovering ? GC.Palette.textPrimary : GC.Palette.textSecondary))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(isSelected ? GC.Palette.accent : (hovering ? GC.Palette.controlHover : GC.Palette.control)))
                .overlay(Capsule().stroke(isSelected ? Color.clear : GC.Palette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(detail ?? label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(MotionPreference.animation(GC.Motion.quick), value: isSelected)
    }
}

struct ValueBadge: View {
    let text: String
    var color: Color = GC.Palette.textSecondary
    var body: some View {
        Text(text)
            .font(GC.Font.micro)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// Small pulsing light (MIDI activity, connection state).
struct ActivityLED: View {
    let isOn: Bool
    var color: Color = GC.Palette.success
    var body: some View {
        Circle()
            .fill(isOn ? color : GC.Palette.textDisabled)
            .frame(width: 7, height: 7)
            .shadow(color: isOn ? color.opacity(0.8) : .clear, radius: isOn ? 4 : 0)
            .animation(MotionPreference.animation(.easeOut(duration: 0.15)), value: isOn)
            .accessibilityHidden(true)
    }
}

/// A "detected / estimated" tag so users know how much to trust analysis values.
struct ConfidenceTag: View {
    let reliable: Bool
    var body: some View {
        ValueBadge(text: reliable ? "Detected" : "Estimate", color: reliable ? GC.Palette.success : GC.Palette.warning)
            .help(reliable ? "Measured with good confidence." : "A best guess from the audio. Check it and correct it if needed.")
    }
}

// MARK: - Brand

/// The Groovecraft mark: a drum head with hits drawn slightly off the grid.
struct LogoMark: View {
    var size: CGFloat = 22
    var body: some View {
        Canvas { ctx, sz in
            let rect = CGRect(origin: .zero, size: sz).insetBy(dx: 1, dy: 1)
            ctx.stroke(Path(ellipseIn: rect), with: .color(GC.Palette.accent), lineWidth: 1.6)
            let centre = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let r = sz.width * 0.30
            let angles: [Double] = [-90, -12, 68, 178]
            let radii: [CGFloat] = [1.0, 0.92, 1.04, 0.96]
            for (i, a) in angles.enumerated() {
                let rad = a * Double.pi / 180
                let p = CGPoint(x: centre.x + CGFloat(cos(rad)) * r * radii[i], y: centre.y + CGFloat(sin(rad)) * r * radii[i])
                let d: CGFloat = i == 0 ? sz.width * 0.2 : sz.width * 0.13
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)),
                         with: .color(i == 0 ? GC.Palette.accentBright : GC.Palette.accent.opacity(0.75)))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct Wordmark: View {
    var body: some View {
        HStack(spacing: 8) {
            LogoMark()
            Text(GC.Brand.wordmark)
                .font(GC.Font.wordmark)
                .foregroundStyle(GC.Palette.textPrimary)
                .tracking(-0.2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GC.Brand.name)
    }
}

// MARK: - Surfaces

extension View {
    /// Standard panel background with a hairline edge.
    func panelSurface(edge: Edge.Set = [], color: Color = GC.Palette.surface) -> some View {
        self.background(color)
    }

    func hairline(_ edge: Alignment) -> some View {
        overlay(alignment: edge) {
            Rectangle().fill(GC.Palette.hairline)
                .frame(width: edge == .leading || edge == .trailing ? 1 : nil,
                       height: edge == .top || edge == .bottom ? 1 : nil)
        }
    }
}
