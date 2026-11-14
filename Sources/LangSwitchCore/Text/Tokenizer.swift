import Foundation

/// A piece of text: either a word or the punctuation, digits and spaces between words.
package struct TextToken: Sendable, Equatable {
    package enum Kind: Sendable, Equatable {
        case word(Language)
        case other
    }

    package var text: String
    package let kind: Kind

    package var isWord: Bool { if case .word = kind { true } else { false } }
    package var language: Language? { if case .word(let language) = kind { language } else { nil } }
}

package enum Tokenizer {
    private static func script(of character: Character) -> Language? {
        if Language.english.isLetter(character) { return .english }
        if Language.russian.isLetter(character) { return .russian }
        return nil
    }

    private static func isJoiner(_ character: Character) -> Bool {
        character == "'" || character == "’" || character == "-"
    }

    /// Splits text into words (runs of one script, with inner apostrophes and hyphens) and the rest.
    /// Joining all token texts gives the original string back.
    package static func tokens(in text: String) -> [TextToken] {
        var tokens: [TextToken] = []
        let characters = Array(text)
        var position = 0
        while position < characters.count {
            if let language = script(of: characters[position]) {
                var end = position + 1
                while end < characters.count {
                    if script(of: characters[end]) == language {
                        end += 1
                    } else if isJoiner(characters[end]), end + 1 < characters.count,
                        script(of: characters[end + 1]) == language
                    {
                        end += 2
                    } else {
                        break
                    }
                }
                tokens.append(TextToken(text: String(characters[position..<end]), kind: .word(language)))
                position = end
            } else {
                var end = position + 1
                while end < characters.count, script(of: characters[end]) == nil { end += 1 }
                tokens.append(TextToken(text: String(characters[position..<end]), kind: .other))
                position = end
            }
        }
        return tokens
    }

    /// Words of `language` only.
    package static func words(in text: String, language: Language) -> [String] {
        tokens(in: text).compactMap { $0.language == language ? $0.text : nil }
    }
}

/// Recognises text that must never be rewritten: links, addresses, paths, identifiers.
package enum TextProtection {
    package static func isProtected(_ chunk: String) -> Bool {
        if chunk.contains("://") { return true }
        let lower = chunk.lowercased()
        let characters = Array(chunk)
        guard characters.count >= 2 else { return false }
        let atSigns = characters.indices.filter { characters[$0] == "@" }
        // An e-mail address: "@" inside the chunk followed by a dotted host.
        if let at = atSigns.first(where: { $0 > 0 && $0 < characters.count - 1 }),
            let dot = characters[at...].lastIndex(of: "."), dot + 1 < characters.count,
            characters[dot + 1].isASCIILetter
        {
            return true
        }
        // A mention; "@word@" is a quoted Russian word typed on the Latin layout, not a mention.
        if characters[0] == "@" && atSigns.count == 1 { return true }
        if lower.hasPrefix("www.") || lower.hasPrefix("#") || lower.hasPrefix("$") || lower.hasPrefix("--")
            || lower.hasPrefix("~/") || lower.hasPrefix("./")
        {
            return true
        }
        for index in 1..<characters.count {
            let previous = characters[index - 1]
            let current = characters[index]
            // snake_case, paths and assignments between Latin letters.
            if index + 1 < characters.count, "_/=".contains(current), previous.isASCIILetter,
                characters[index + 1].isASCIILetter
            {
                return true
            }
            // Identifiers such as "h264" or "v2".
            if previous.isASCIILetter && current.isNumber || previous.isNumber && current.isASCIILetter {
                return true
            }
            // camelCase.
            if previous.isASCIILetter && previous.isLowercase && current.isASCIILetter && current.isUppercase
            {
                return true
            }
        }
        return false
    }
}

extension Character {
    package var isASCIILetter: Bool { isASCII && isLetter }
}
