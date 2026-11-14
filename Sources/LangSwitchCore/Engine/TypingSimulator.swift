import Foundation

/// Drives a `TypingSession` with physical key presses and keeps the resulting document text.
///
/// It stands in for a real text field: tests and the in-app self-check type "ghbdtn" on the keys of one
/// layout while another is active and look at what ends up in the document.
package struct TypingSimulator {
    package private(set) var session: TypingSession
    package private(set) var document = ""
    package private(set) var current: KeyboardLayout
    package private(set) var replacements: [Replacement] = []
    private let available: [KeyboardLayout]
    private let engine: CorrectionEngine

    package init(
        engine: CorrectionEngine, active: KeyboardLayout = .abc,
        available: [KeyboardLayout] = [.abc, .russian],
        options: CorrectionOptions = CorrectionOptions()
    ) {
        self.engine = engine
        self.available = available
        self.current = active
        self.session = TypingSession(layouts: Self.layouts(active, available))
        self.session.options = options
    }

    private static func layouts(_ current: KeyboardLayout, _ available: [KeyboardLayout])
        -> TypingSession.Layouts
    {
        TypingSession.Layouts(
            current: current, alternative: available.first { $0.language != current.language })
    }

    private mutating func apply(_ output: SessionOutput) -> Bool {
        guard case .replace(let replacement, let swallowKey) = output else { return false }
        document.removeLast(min(replacement.deleteCount, document.count))
        document += replacement.insert
        replacements.append(replacement)
        if let id = replacement.switchLayoutTo, let layout = available.first(where: { $0.id == id }) {
            current = layout
            session.layoutsChanged(Self.layouts(layout, available), byUser: false)
        }
        return swallowKey
    }

    /// Presses the keys that type `text` on `layout`, whatever layout is active at the moment.
    package mutating func press(keysFor text: String, on layout: KeyboardLayout) {
        for character in text {
            switch character {
            case " ": boundary(.space)
            case "\n": boundary(.newline)
            case "\t": boundary(.tab)
            default:
                guard let stroke = layout.stroke(for: character),
                    let produced = current.character(for: stroke)
                else {
                    continue
                }
                session.character(stroke, produced: produced)
                document.append(produced)
                convertEarlyIfNeeded()
            }
        }
    }

    /// Types `text` on the active layout.
    package mutating func type(_ text: String) {
        for character in text {
            if character == " " || character == "\n" || character == "\t" {
                press(keysFor: String(character), on: current)
            } else if let stroke = current.stroke(for: character) {
                session.character(stroke, produced: character)
                document.append(character)
                convertEarlyIfNeeded()
            }
        }
    }

    private mutating func convertEarlyIfNeeded() {
        guard let replacement = session.earlyConversion(engine: engine) else { return }
        _ = apply(.replace(replacement, swallowKey: true))
    }

    package mutating func boundary(_ boundary: Boundary) {
        let (output, _) = session.boundary(boundary, engine: engine)
        _ = apply(output)
        document.append(boundary.character)
    }

    package mutating func backspace() {
        if !apply(session.backspace()), !document.isEmpty { document.removeLast() }
    }

    package mutating func convertManually() {
        guard let replacement = session.convertManually() else { return }
        _ = apply(.replace(replacement, swallowKey: true))
    }

    /// The system layout changes without the session being told (a lost or late notification).
    package mutating func switchLayoutSilently(to layout: KeyboardLayout) {
        current = layout
    }

    /// The user switches the layout by hand.
    package mutating func switchLayout(to layout: KeyboardLayout) {
        current = layout
        session.layoutsChanged(Self.layouts(layout, available), byUser: true)
    }
}
