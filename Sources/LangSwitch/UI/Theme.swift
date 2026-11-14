import AppKit
import LangSwitchCore
import SwiftUI

/// The visual language: black glass, white ink, one quiet red for mistakes.
///
/// The interface is dark by design, like a console dashboard: surfaces are translucent layers over a
/// blurred backdrop, text and icons are white at a few fixed opacities, and the only filled accent is a
/// white capsule. Colour is reserved for things that went wrong.
enum Theme {
    static let ink = Color.white
    /// Text and glyphs drawn on top of a white fill.
    static let onInk = Color.black
    static let muted = Color.white.opacity(0.56)
    static let faint = Color.white.opacity(0.34)
    static let surface = Color.white.opacity(0.055)
    static let surfaceStrong = Color.white.opacity(0.11)
    static let hairline = Color.white.opacity(0.10)
    static let danger = Color(red: 1.0, green: 0.45, blue: 0.42)

    static func symbol(for kinds: CorrectionKinds) -> String {
        if kinds.contains(.layout) { return "arrow.left.arrow.right" }
        if kinds.contains(.spelling) { return "textformat.abc.dottedunderline" }
        if kinds.contains(.punctuation) { return "ellipsis.bubble" }
        return "textformat"
    }
}

/// Behind-window blur: the desktop shows through the window, softly.
struct GlassBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// A glass panel: a translucent layer with a hairline edge.
struct CardModifier: ViewModifier {
    var radius: CGFloat = 18
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.padding(padding)
            .background(Theme.surface, in: shape)
            .overlay(shape.strokeBorder(Theme.hairline))
    }
}

extension View {
    func card(radius: CGFloat = 18, padding: CGFloat = 18) -> some View {
        modifier(CardModifier(radius: radius, padding: padding))
    }

    /// A small square holder for a glyph.
    func glyphTile(size: CGFloat = 30, radius: CGFloat = 8) -> some View {
        frame(width: size, height: size)
            .background(Theme.surfaceStrong, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// The primary action: a white capsule.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let large = controlSize == .large
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .semibold))
            .foregroundStyle(Theme.onInk)
            .padding(.horizontal, large ? 22 : 15)
            .padding(.vertical, large ? 9 : 6)
            .background(Theme.ink.opacity(configuration.isPressed ? 0.78 : 1), in: Capsule())
            .opacity(isEnabled ? 1 : 0.3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Everything else: a quiet glass capsule.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let large = controlSize == .large
        let small = controlSize == .small
        configuration.label
            .font(.system(size: large ? 14 : small ? 12 : 13, weight: .medium))
            .foregroundStyle(configuration.role == .destructive ? Theme.danger : Theme.ink)
            .padding(.horizontal, large ? 20 : small ? 11 : 14)
            .padding(.vertical, large ? 9 : small ? 4 : 6)
            .background(
                configuration.isPressed ? Theme.surfaceStrong.opacity(1.6) : Theme.surfaceStrong,
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

/// A switch without colour: white when on.
struct MonoToggleStyle: ToggleStyle {
    /// Push the switch to the trailing edge (for "label … switch" rows).
    var fillsWidth = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let small = controlSize == .small
        let width: CGFloat = small ? 32 : 40
        let height: CGFloat = small ? 19 : 23
        HStack(spacing: 10) {
            configuration.label
            if fillsWidth { Spacer(minLength: 0) }
            Capsule()
                .fill(configuration.isOn ? Theme.ink : Theme.surfaceStrong)
                .overlay(Capsule().strokeBorder(configuration.isOn ? .clear : Theme.hairline))
                .frame(width: width, height: height)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? Theme.onInk : Theme.muted)
                        .padding(3)
                }
                .animation(.spring(response: 0.24, dampingFraction: 0.8), value: configuration.isOn)
                .contentShape(Capsule())
                .onTapGesture { configuration.isOn.toggle() }
                .accessibilityAddTraits(.isButton)
        }
        .opacity(isEnabled ? 1 : 0.4)
    }
}

extension ToggleStyle where Self == MonoToggleStyle {
    static var mono: MonoToggleStyle { MonoToggleStyle() }
    static var monoRow: MonoToggleStyle { MonoToggleStyle(fillsWidth: true) }
}

/// A segmented choice drawn as capsules; the system control would bring the accent colour back.
struct CapsulePicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                segment(value: options[index].0, title: options[index].1)
            }
        }
        .padding(3)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }

    private func segment(value: Value, title: String) -> some View {
        let selected = value == selection
        return Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(selected ? Theme.onInk : Theme.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background {
                if selected {
                    Capsule().fill(Theme.ink).matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { selection = value }
            }
    }
}

/// A keyboard key drawn as a small cap, used for shortcut hints.
struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct LanguageBadge: View {
    let language: Language?
    var body: some View {
        Text(language?.badge ?? "—")
            .font(.system(size: 10.5, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.surfaceStrong, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
    }
}
