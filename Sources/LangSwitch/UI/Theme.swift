import LangSwitchCore
import SwiftUI

/// Colours and shared styling. The palette is a cool indigo-to-violet range with a warm accent for
/// rewards, so the interface reads as one family in light and dark appearance.
enum Theme {
    static let indigo = Color(red: 0.36, green: 0.36, blue: 0.96)
    static let violet = Color(red: 0.62, green: 0.36, blue: 0.98)
    static let pink = Color(red: 0.98, green: 0.36, blue: 0.62)
    static let mint = Color(red: 0.20, green: 0.82, blue: 0.66)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.22)
    static let coral = Color(red: 1.0, green: 0.42, blue: 0.38)

    static let brand = LinearGradient(
        colors: [indigo, violet, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let calm = LinearGradient(colors: [indigo, violet], startPoint: .leading, endPoint: .trailing)

    static func color(for kinds: CorrectionKinds) -> Color {
        if kinds.contains(.layout) { return indigo }
        if kinds.contains(.spelling) { return mint }
        return amber
    }

    static func symbol(for kinds: CorrectionKinds) -> String {
        if kinds.contains(.layout) { return "arrow.left.arrow.right" }
        if kinds.contains(.spelling) { return "textformat.abc.dottedunderline" }
        if kinds.contains(.punctuation) { return "ellipsis.bubble" }
        return "textformat"
    }
}

/// A content surface: Liquid Glass on macOS 26 and later, a soft material before that.
struct CardModifier: ViewModifier {
    var radius: CGFloat = 18
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *) {
            content.padding(padding).glassEffect(.regular, in: shape)
        } else {
            content.padding(padding)
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.06)))
        }
    }
}

extension View {
    func card(radius: CGFloat = 18, padding: CGFloat = 18) -> some View {
        modifier(CardModifier(radius: radius, padding: padding))
    }
}

/// A keyboard key drawn as a small cap, used for shortcut hints.
struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.primary.opacity(0.12)))
    }
}

struct LanguageBadge: View {
    let language: Language?
    var body: some View {
        Text(language?.badge ?? "—")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                language == .russian
                    ? AnyShapeStyle(Theme.pink.gradient) : AnyShapeStyle(Theme.indigo.gradient), in: Capsule()
            )
    }
}
