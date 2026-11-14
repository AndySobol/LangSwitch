import Foundation

/// A writing language supported by the correction engine.
package enum Language: String, Sendable, Codable, CaseIterable, Hashable {
    case english = "en"
    case russian = "ru"

    package var other: Language { self == .english ? .russian : .english }

    /// Short upper-case badge shown in the interface.
    package var badge: String { self == .english ? "EN" : "RU" }

    package func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch self {
        case .english:
            return (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
        case .russian:
            return (0x410...0x44F).contains(scalar.value) || scalar.value == 0x401 || scalar.value == 0x451
        }
    }

    package func isLetter(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return false }
        return isLetter(scalar)
    }

    /// Lower-case alphabet used for candidate generation.
    package var alphabet: [Character] {
        switch self {
        case .english: return Array("abcdefghijklmnopqrstuvwxyz")
        case .russian: return Array("абвгдежзийклмнопрстуфхцчшщъыьэюяё")
        }
    }

    /// The language whose letters dominate `text`, or nil when there are no letters of either script.
    package static func dominant(in text: String) -> Language? {
        var english = 0
        var russian = 0
        for scalar in text.unicodeScalars {
            if Language.english.isLetter(scalar) {
                english += 1
            } else if Language.russian.isLetter(scalar) {
                russian += 1
            }
        }
        if english == 0 && russian == 0 { return nil }
        return english >= russian ? .english : .russian
    }
}

extension String {
    /// First character upper-cased, the rest untouched.
    package var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }

    package var isAllLowercase: Bool { self == lowercased() }

    /// True for "Word" shaped strings: an upper-case first letter followed only by lower-case ones.
    package var isCapitalized: Bool {
        guard let first, first.isUppercase else { return false }
        return dropFirst().allSatisfy { !$0.isUppercase }
    }

    /// True for "WORD" shaped strings with at least two letters.
    package var isAllUppercase: Bool {
        count >= 2 && self == uppercased() && self != lowercased()
    }
}

/// Reapplies the letter case pattern of `source` onto `target`.
package func matchCase(of source: String, to target: String) -> String {
    if source.isAllUppercase { return target.uppercased() }
    if let first = source.first, first.isUppercase { return target.capitalizedFirst }
    return target
}
