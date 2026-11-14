import Foundation

/// One physical key press that produces text: the virtual key code plus the modifiers that matter.
package struct KeyStroke: Sendable, Hashable, Codable {
    package let keyCode: UInt16
    package let shift: Bool
    package let capsLock: Bool

    package init(keyCode: UInt16, shift: Bool = false, capsLock: Bool = false) {
        self.keyCode = keyCode
        self.shift = shift
        self.capsLock = capsLock
    }
}

/// A snapshot of a keyboard layout: what every text key produces with and without Shift.
///
/// The application builds these from the layouts enabled in macOS (`UCKeyTranslate`); the static
/// layouts below describe the stock Apple layouts and are used for string conversion and tests.
package struct KeyboardLayout: Sendable, Equatable {
    package let id: String
    package let name: String
    package let language: Language
    private let base: [UInt16: Character]
    private let shifted: [UInt16: Character]
    private let reverse: [Character: KeyStroke]

    package init(
        id: String, name: String, language: Language, base: [UInt16: Character],
        shifted: [UInt16: Character]
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.base = base
        self.shifted = shifted
        var reverse: [Character: KeyStroke] = [:]
        for (key, character) in shifted where reverse[character] == nil {
            reverse[character] = KeyStroke(keyCode: key, shift: true)
        }
        // Unshifted positions win when a character is reachable both ways.
        for (key, character) in base { reverse[character] = KeyStroke(keyCode: key) }
        self.reverse = reverse
    }

    /// The character a key produces, honouring Caps Lock for letters only (as macOS does).
    package func character(for stroke: KeyStroke) -> Character? {
        guard let plain = base[stroke.keyCode] else { return nil }
        let upper = shifted[stroke.keyCode] ?? plain
        if stroke.capsLock && plain.isLetter {
            return stroke.shift ? plain : upper
        }
        return stroke.shift ? upper : plain
    }

    package func stroke(for character: Character) -> KeyStroke? { reverse[character] }

    package func render(_ strokes: [KeyStroke]) -> String {
        var result = ""
        result.reserveCapacity(strokes.count)
        for stroke in strokes {
            if let character = character(for: stroke) { result.append(character) }
        }
        return result
    }

    /// Key strokes that type `text` on this layout, or nil when a character is not on the layout.
    package func strokes(for text: String) -> [KeyStroke]? {
        var result: [KeyStroke] = []
        result.reserveCapacity(text.count)
        for character in text {
            guard let stroke = reverse[character] else { return nil }
            result.append(stroke)
        }
        return result
    }

    /// True when the key types a letter of this layout's language.
    package func producesLetter(_ keyCode: UInt16) -> Bool {
        guard let character = base[keyCode] else { return false }
        return language.isLetter(character)
    }

    /// Re-types `text`, entered on this layout, as if the same keys had been pressed on `target`.
    /// Characters that are not on this layout are kept as they are.
    package func convert(_ text: String, to target: KeyboardLayout) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            if let stroke = reverse[character], let converted = target.character(for: stroke) {
                result.append(converted)
            } else {
                result.append(character)
            }
        }
        return result
    }
}

extension KeyboardLayout {
    /// ANSI virtual key codes in the order of the rows below.
    private static let digitKeys: [UInt16] = [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24]
    private static let topKeys: [UInt16] = [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42]
    private static let homeKeys: [UInt16] = [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39]
    private static let bottomKeys: [UInt16] = [6, 7, 8, 9, 11, 45, 46, 43, 47, 44]

    private static func make(
        id: String, name: String, language: Language, base rows: [String], shifted shiftedRows: [String]
    ) -> KeyboardLayout {
        let keys = [digitKeys, topKeys, homeKeys, bottomKeys]
        var base: [UInt16: Character] = [:]
        var shifted: [UInt16: Character] = [:]
        for (row, rowKeys) in keys.enumerated() {
            let plain = Array(rows[row])
            let upper = Array(shiftedRows[row])
            precondition(plain.count == rowKeys.count && upper.count == rowKeys.count, "layout row size")
            for (index, key) in rowKeys.enumerated() {
                base[key] = plain[index]
                shifted[key] = upper[index]
            }
        }
        return KeyboardLayout(id: id, name: name, language: language, base: base, shifted: shifted)
    }

    /// Apple "ABC" / "U.S.".
    package static let abc = make(
        id: "com.apple.keylayout.ABC", name: "ABC", language: .english,
        base: ["`1234567890-=", "qwertyuiop[]\\", "asdfghjkl;'", "zxcvbnm,./"],
        shifted: ["~!@#$%^&*()_+", "QWERTYUIOP{}|", "ASDFGHJKL:\"", "ZXCVBNM<>?"]
    )

    /// Apple "Russian".
    package static let russian = make(
        id: "com.apple.keylayout.Russian", name: "Русская", language: .russian,
        base: ["]1234567890-=", "йцукенгшщзхъё", "фывапролджэ", "ячсмитьбю/"],
        shifted: ["[!\"№%:,.;()_+", "ЙЦУКЕНГШЩЗХЪЁ", "ФЫВАПРОЛДЖЭ", "ЯЧСМИТЬБЮ?"]
    )

    /// Apple "Russian – PC".
    package static let russianPC = make(
        id: "com.apple.keylayout.RussianWin", name: "Русская — ПК", language: .russian,
        base: ["ё1234567890-=", "йцукенгшщзхъ\\", "фывапролджэ", "ячсмитьбю."],
        shifted: ["Ё!\"№;%:?*()_+", "ЙЦУКЕНГШЩЗХЪ/", "ФЫВАПРОЛДЖЭ", "ЯЧСМИТЬБЮ,"]
    )

    package static let builtIn: [KeyboardLayout] = [.abc, .russian, .russianPC]
}

/// Virtual key codes the engine cares about beyond text keys.
package enum KeyCode {
    package static let returnKey: UInt16 = 36
    package static let tab: UInt16 = 48
    package static let space: UInt16 = 49
    package static let delete: UInt16 = 51
    package static let escape: UInt16 = 53
    package static let keypadEnter: UInt16 = 76
    package static let forwardDelete: UInt16 = 117
    package static let leftArrow: UInt16 = 123
    package static let rightArrow: UInt16 = 124
    package static let downArrow: UInt16 = 125
    package static let upArrow: UInt16 = 126
    package static let home: UInt16 = 115
    package static let end: UInt16 = 119
    package static let pageUp: UInt16 = 116
    package static let pageDown: UInt16 = 121

    package static let navigation: Set<UInt16> = [
        leftArrow, rightArrow, downArrow, upArrow, home, end, pageUp, pageDown, forwardDelete, escape,
    ]
}
