import LangSwitchCore
import SwiftUI

/// An on-screen keyboard that lights up the next key, coloured by the finger that should press it.
/// Looking at it instead of the real keyboard is how touch typing is learned.
struct KeyboardHint: View {
    let layout: KeyboardLayout
    let expected: Character?

    private static let rows: [[UInt16]] = [
        [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24],
        [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30],
        [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39],
        [6, 7, 8, 9, 11, 45, 46, 43, 47, 44],
    ]
    private static let indents: [CGFloat] = [0, 1.5, 1.85, 2.4]
    /// Finger for each column of a row, left pinky (0) to right pinky (7).
    private static func finger(row: Int, column: Int) -> Int {
        let shifted = row == 0 ? column - 1 : column
        switch shifted {
        case ...0: return 0
        case 1: return 1
        case 2: return 2
        case 3, 4: return 3
        case 5, 6: return 4
        case 7: return 5
        case 8: return 6
        default: return 7
        }
    }
    private static let fingerColors: [Color] = [
        Theme.pink, Theme.amber, Theme.mint, Theme.indigo, Theme.indigo, Theme.mint, Theme.amber, Theme.pink,
    ]

    var body: some View {
        let target = expected.flatMap { layout.stroke(for: $0) }
        let unit: CGFloat = 34
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Self.rows.indices, id: \.self) { row in
                HStack(spacing: 5) {
                    if row == 3 {
                        key(
                            label: "⇧", width: unit * 2.35, color: Theme.violet, active: target?.shift == true
                        )
                    } else {
                        Spacer().frame(width: Self.indents[row] * unit * 0.62)
                    }
                    ForEach(Array(Self.rows[row].enumerated()), id: \.element) { column, keyCode in
                        let character = layout.character(for: KeyStroke(keyCode: keyCode)) ?? " "
                        key(
                            label: String(character).uppercased(), width: unit,
                            color: Self.fingerColors[Self.finger(row: row, column: column)],
                            active: target?.keyCode == keyCode,
                            isHome: keyCode == 3 || keyCode == 38)
                    }
                    if row == 3 {
                        key(
                            label: "⇧", width: unit * 2.35, color: Theme.violet, active: target?.shift == true
                        )
                    }
                }
            }
            HStack {
                Spacer()
                key(label: "", width: unit * 6.4, color: Theme.violet, active: expected == " ")
                Spacer()
            }
        }
        .animation(.easeOut(duration: 0.12), value: expected)
    }

    private func key(label: String, width: CGFloat, color: Color, active: Bool, isHome: Bool = false)
        -> some View
    {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(active ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(0.10)))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(
                        color.opacity(active ? 0 : 0.22))
                )
                .shadow(color: active ? color.opacity(0.6) : .clear, radius: 8)
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(active ? .white : .primary.opacity(0.65))
                .frame(maxHeight: .infinity)
            if isHome {
                Capsule().fill(active ? .white.opacity(0.8) : .primary.opacity(0.3)).frame(
                    width: 9, height: 2
                ).padding(.bottom, 4)
            }
        }
        .frame(width: width, height: 34)
        .scaleEffect(active ? 1.08 : 1)
    }
}
