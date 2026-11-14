import Foundation

/// A bundled practice passage.
package struct TrainerPassage: Sendable, Codable, Equatable, Identifiable {
    package let id: String
    package let title: String
    package let difficulty: Int
    package let text: String
}

/// Builds exercise texts from the bundled material and from what the application learned.
package struct TrainerContent: Sendable {
    package var passages: [Language: [TrainerPassage]]
    package var words: [Language: [String]]

    package init(passages: [Language: [TrainerPassage]] = [:], words: [Language: [String]] = [:]) {
        self.passages = passages
        self.words = words
    }

    /// Characters an exercise may contain: everything else is not on a plain keyboard.
    package static func isTypeable(_ text: String, language: Language) -> Bool {
        !text.isEmpty
            && text.allSatisfy { character in
                language.isLetter(character) || character.isNumber && character.isASCII
                    || " .,!?:;-()\"'".contains(character)
            }
    }

    /// Replaces typographic characters with their keyboard equivalents.
    package static func normalized(_ text: String) -> String {
        var result = ""
        var lastWasSpace = false
        for character in text {
            var replacement: String
            switch character {
            case "—", "–": replacement = "-"
            case "«", "»", "“", "”", "„": replacement = "\""
            case "’", "‘": replacement = "'"
            case "…": replacement = "..."
            case "\n", "\t", "\u{00A0}": replacement = " "
            default: replacement = String(character)
            }
            if replacement == " " {
                if lastWasSpace { replacement = "" }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }
            result += replacement
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    package func randomWords(
        language: Language, count: Int, using generator: inout some RandomNumberGenerator
    ) -> String {
        guard let pool = words[language], !pool.isEmpty else { return "" }
        var picked: [String] = []
        var last: String?
        while picked.count < count {
            guard let word = pool.randomElement(using: &generator) else { break }
            if word == last && pool.count > 1 { continue }
            picked.append(word)
            last = word
        }
        return picked.joined(separator: " ")
    }

    package func passage(
        language: Language, difficulty: Int?, excluding recent: Set<String> = [],
        using generator: inout some RandomNumberGenerator
    ) -> TrainerPassage? {
        let all = passages[language] ?? []
        let level = all.filter { difficulty == nil || $0.difficulty == difficulty }
        let fresh = level.filter { !recent.contains($0.id) }
        return (fresh.isEmpty ? (level.isEmpty ? all : level) : fresh).randomElement(using: &generator)
    }

    /// A drill built from the user's weak words, each repeated so the correct motion sticks.
    package func weakWordsDrill(
        _ weakWords: [String], language: Language, count: Int,
        using generator: inout some RandomNumberGenerator
    ) -> String {
        let own = weakWords.filter {
            Language.dominant(in: $0) == language && Self.isTypeable($0, language: language)
        }
        guard !own.isEmpty else { return randomWords(language: language, count: count, using: &generator) }
        var picked: [String] = []
        let filler = words[language] ?? []
        while picked.count < count {
            // Two weak words, then one easy word to keep the rhythm.
            if picked.count % 3 == 2, let easy = filler.randomElement(using: &generator) {
                picked.append(easy)
            } else if let weak = own.randomElement(using: &generator) {
                picked.append(weak)
            }
        }
        return picked.joined(separator: " ")
    }
}

/// A phrase the user typed somewhere on the Mac, kept for practice when collection is switched on.
package struct CollectedPhrase: Sendable, Codable, Equatable, Identifiable {
    package var id = UUID()
    package var text: String
    package var language: Language
    package var date: Date
    /// Name of the application it was typed in.
    package var application: String

    package init(text: String, language: Language, date: Date, application: String) {
        self.text = text
        self.language = language
        self.date = date
        self.application = application
    }
}

/// Assembles phrases from finished chunks. Nothing is kept unless it passes `isSafe`.
package struct PhraseCollector: Sendable {
    private var words: [String] = []
    package init() {}

    /// Text that may be stored: ordinary prose, no numbers that could be codes, no addresses.
    package static func isSafe(_ phrase: String) -> Bool {
        let wordCount = phrase.split(separator: " ").count
        guard wordCount >= 4, phrase.count >= 20, phrase.count <= 320 else { return false }
        if phrase.contains("@") || phrase.contains("://") || phrase.contains("www.") { return false }
        var digitRun = 0
        for character in phrase {
            digitRun = character.isNumber ? digitRun + 1 : 0
            if digitRun >= 3 { return false }
        }
        guard let language = Language.dominant(in: phrase) else { return false }
        return TrainerContent.isTypeable(TrainerContent.normalized(phrase), language: language)
    }

    package mutating func reset() { words.removeAll(keepingCapacity: true) }

    /// Adds a finished chunk; returns a phrase when a sentence or line has just been completed.
    package mutating func add(chunk: String, endsSentence: Bool, endsLine: Bool) -> String? {
        if TextProtection.isProtected(chunk) {
            reset()
            return nil
        }
        words.append(chunk)
        guard endsSentence || endsLine || words.count >= 40 else { return nil }
        let phrase = words.joined(separator: " ")
        reset()
        return Self.isSafe(phrase) ? TrainerContent.normalized(phrase) : nil
    }
}

/// The stored phrases with their retention policy.
package struct PhraseLibrary: Sendable, Codable, Equatable {
    package var phrases: [CollectedPhrase] = []
    package init() {}

    package static let limit = 400

    package mutating func add(_ phrase: CollectedPhrase) {
        guard !phrases.contains(where: { $0.text == phrase.text }) else { return }
        phrases.append(phrase)
        if phrases.count > Self.limit { phrases.removeFirst(phrases.count - Self.limit) }
    }

    /// Drops phrases older than `days`.
    package mutating func prune(olderThan days: Int, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        phrases.removeAll { $0.date < cutoff }
    }

    package func exercise(
        language: Language, targetLength: Int, using generator: inout some RandomNumberGenerator
    ) -> String? {
        var pool = phrases.filter { $0.language == language }.map(\.text)
        guard !pool.isEmpty else { return nil }
        pool.shuffle(using: &generator)
        var text = ""
        for phrase in pool {
            if !text.isEmpty { text += " " }
            text += phrase
            if text.count >= targetLength { break }
        }
        return text
    }
}
