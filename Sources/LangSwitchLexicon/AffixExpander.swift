import Foundation
import LangSwitchCore

/// Generates the inflected forms of a dictionary stem from the Hunspell suffix rules.
///
/// Hunspell itself only checks forms; listing them ("what are the cases of this noun?") needs the rules
/// applied forwards, which this type does for the single-character flags used by both bundled dictionaries.
package struct AffixExpander {
    private struct Rule {
        let strip: String
        let add: String
        let condition: [Set<Character>?]  // nil matches any character
        let negated: [Bool]

        func matches(_ stem: [Character]) -> Bool {
            guard stem.count >= condition.count else { return false }
            let offset = stem.count - condition.count
            for (index, allowed) in condition.enumerated() {
                guard let allowed else { continue }
                if allowed.contains(stem[offset + index]) == negated[index] { return false }
            }
            return true
        }
    }

    private let rules: [Character: [Rule]]
    private let words: Data

    package init?(affix: URL, dictionary: URL) {
        guard let text = try? String(contentsOf: affix, encoding: .utf8),
            let words = try? Data(contentsOf: dictionary, options: .mappedIfSafe)
        else { return nil }
        self.words = words
        var rules: [Character: [Rule]] = [:]
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("SFX ") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            // Rule lines have five fields; the header ("SFX A Y 12") has four.
            guard fields.count >= 5, let flag = fields[1].first, fields[1].count == 1 else { continue }
            let strip = fields[2] == "0" ? "" : String(fields[2])
            var add = String(fields[3].split(separator: "/").first ?? "")
            if add == "0" { add = "" }
            guard let (condition, negated) = Self.parseCondition(String(fields[4])) else { continue }
            rules[flag, default: []].append(
                Rule(strip: strip, add: add, condition: condition, negated: negated))
        }
        self.rules = rules
    }

    private static func parseCondition(_ text: String) -> ([Set<Character>?], [Bool])? {
        var sets: [Set<Character>?] = []
        var negated: [Bool] = []
        var characters = Array(text)[...]
        while let character = characters.popFirst() {
            if character == "." {
                sets.append(nil)
                negated.append(false)
            } else if character == "[" {
                guard let close = characters.firstIndex(of: "]") else { return nil }
                var members = characters[..<close]
                let isNegated = members.first == "^"
                if isNegated { members = members.dropFirst() }
                sets.append(Set(members))
                negated.append(isNegated)
                characters = characters[(close + 1)...]
            } else {
                sets.append([character])
                negated.append(false)
            }
        }
        return (sets, negated)
    }

    /// Flags of an exact dictionary entry, or nil when the stem is not listed.
    private func flags(of stem: String) -> String? {
        let needle = Data(("\n" + stem).utf8)
        var searchRange = words.startIndex..<words.endIndex
        while let found = words.range(of: needle, in: searchRange) {
            var end = found.upperBound
            guard end < words.endIndex else { return "" }
            let next = words[end]
            if next == UInt8(ascii: "\n") || next == UInt8(ascii: "\r") || next == UInt8(ascii: "\t") {
                return ""
            }
            if next == UInt8(ascii: "/") {
                end += 1
                var flagEnd = end
                while flagEnd < words.endIndex, words[flagEnd] != UInt8(ascii: "\n"),
                    words[flagEnd] != UInt8(ascii: "\r"),
                    words[flagEnd] != UInt8(ascii: " "), words[flagEnd] != UInt8(ascii: "\t")
                {
                    flagEnd += 1
                }
                return String(decoding: words[end..<flagEnd], as: UTF8.self)
            }
            searchRange = found.upperBound..<words.endIndex
        }
        return nil
    }

    /// The stem and every form its suffix rules produce.
    package func forms(of stem: String) -> [String] {
        guard let flags = flags(of: stem) ?? flags(of: stem.capitalizedFirst) else { return [] }
        let characters = Array(stem)
        var result: [String] = [stem]
        var seen: Set<String> = [stem]
        for flag in flags {
            for rule in rules[flag] ?? [] where stem.hasSuffix(rule.strip) && rule.matches(characters) {
                let form = String(characters.dropLast(rule.strip.count)) + rule.add
                if seen.insert(form).inserted { result.append(form) }
            }
        }
        return result
    }

    /// Lower-case stems of the dictionary, for training the letter model.
    package func stems(language: Language, visit: (String) -> Void) {
        words.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var lineStart = 0
            var isFirstLine = true
            let count = buffer.count
            var index = 0
            while index <= count {
                if index == count || buffer[index] == UInt8(ascii: "\n") {
                    if !isFirstLine, index > lineStart {
                        var end = lineStart
                        while end < index, buffer[end] != UInt8(ascii: "/"),
                            buffer[end] != UInt8(ascii: "\t"),
                            buffer[end] != UInt8(ascii: "\r")
                        {
                            end += 1
                        }
                        let stem = String(
                            decoding: UnsafeRawBufferPointer(rebasing: buffer[lineStart..<end]), as: UTF8.self
                        )
                        if stem.count >= 2, stem.allSatisfy({ language.isLetter($0) }) {
                            visit(stem.lowercased())
                        }
                    }
                    isFirstLine = false
                    lineStart = index + 1
                }
                index += 1
            }
        }
    }
}
