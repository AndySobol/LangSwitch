import Foundation

/// Finds the intended word behind a typo.
///
/// Candidates are generated with the edits a fast typist actually makes — swapped neighbours, a dropped
/// letter, a doubled letter, a slip to the next key — and each is checked against the vocabulary.
package struct SpellingCorrector {
    package struct Candidate: Sendable, Equatable {
        package let word: String
        /// Lower is better: edit cost minus a bonus for frequent words.
        package let score: Float
    }

    private let vocabulary: Vocabulary
    private let adjacency: [Language: [Character: [Character]]]
    private let misspellings: [Language: [String: String]]

    /// Vowel pairs confused in unstressed positions; a cheap stand-in for real orthographic rules.
    private static let confusable: [Language: [Character: [Character]]] = [
        .russian: ["о": ["а"], "а": ["о"], "е": ["и", "э"], "и": ["е", "ы"], "ы": ["и"], "э": ["е"]],
        .english: ["a": ["e"], "e": ["a", "i"], "i": ["e", "y"], "y": ["i"]],
    ]

    /// Fast typists drop letters and swap neighbours; a stray extra letter is rare unless it is a doubled
    /// one. So "the typo has a letter too many" costs more than the automatic threshold: such readings
    /// are offered in the list of alternatives but never applied on their own.
    private static let strayLetterCost: Float = 1.75

    package init(vocabulary: Vocabulary, misspellings: [Language: [String: String]] = [:]) {
        self.vocabulary = vocabulary
        self.misspellings = misspellings
        self.adjacency = [
            .english: Self.adjacency(for: .abc),
            .russian: Self.adjacency(for: .russian),
        ]
    }

    /// Parses `wrong<TAB>right` lines.
    package static func parseMisspellings(_ tsv: String) -> [String: String] {
        var table: [String: String] = [:]
        for line in tsv.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty else { continue }
            table[fields[0].lowercased()] = String(fields[1])
        }
        return table
    }

    private static func adjacency(for layout: KeyboardLayout) -> [Character: [Character]] {
        let rows: [[UInt16]] = [
            [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30],
            [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39],
            [6, 7, 8, 9, 11, 45, 46, 43, 47, 44],
        ]
        func letter(_ row: Int, _ column: Int) -> Character? {
            guard rows.indices.contains(row), rows[row].indices.contains(column),
                let character = layout.character(for: KeyStroke(keyCode: rows[row][column])),
                layout.language.isLetter(character)
            else { return nil }
            return character
        }
        var result: [Character: [Character]] = [:]
        for row in rows.indices {
            for column in rows[row].indices {
                guard let key = letter(row, column) else { continue }
                // Rows are staggered: the key above sits half a key to the left.
                let neighbours = [
                    letter(row, column - 1), letter(row, column + 1),
                    letter(row - 1, column), letter(row - 1, column + 1),
                    letter(row + 1, column - 1), letter(row + 1, column),
                ]
                result[key] = neighbours.compactMap { $0 }
            }
        }
        return result
    }

    private func bonus(_ rank: Int?) -> Float {
        guard let rank else { return 0 }
        if rank < 300 { return 0.5 }
        if rank < 1500 { return 0.35 }
        return 0.2
    }

    /// Single-edit strings with their cost; not yet checked against the vocabulary.
    private func edits(of word: [Character], language: Language, allowInsertions: Bool) -> [(String, Float)] {
        var result: [(String, Float)] = []
        let count = word.count
        for index in 0..<max(count - 1, 0) where word[index] != word[index + 1] {
            var copy = word
            copy.swapAt(index, index + 1)
            result.append((String(copy), 1.0))
        }
        for index in 0..<count {
            var copy = word
            copy.remove(at: index)
            let doubled =
                index > 0 && word[index] == word[index - 1]
                || index + 1 < count && word[index] == word[index + 1]
            result.append((String(copy), doubled ? 1.0 : Self.strayLetterCost))
        }
        for index in 0..<count {
            for replacement in adjacency[language]?[word[index]] ?? [] {
                var copy = word
                copy[index] = replacement
                result.append((String(copy), 1.5))
            }
            for replacement in Self.confusable[language]?[word[index]] ?? [] {
                var copy = word
                copy[index] = replacement
                result.append((String(copy), 1.45))
            }
        }
        if allowInsertions {
            for index in 0...count {
                for letter in language.alphabet where letter != "ё" {
                    var copy = word
                    copy.insert(letter, at: index)
                    let doubling =
                        index > 0 && word[index - 1] == letter || index < count && word[index] == letter
                    result.append((String(copy), doubling ? 1.1 : 1.4))
                }
            }
        }
        return result
    }

    /// Known words one edit away from `word`, best first.
    package func candidates(for word: String, language: Language, deep: Bool = false) -> [Candidate] {
        let lower = Array(word.lowercased())
        guard lower.count >= 2, lower.count <= 32, lower.allSatisfy({ language.isLetter($0) }) else {
            return []
        }
        var best: [String: Float] = [:]
        func consider(_ text: String, _ cost: Float) {
            guard text != String(lower) else { return }
            let knowledge = vocabulary.knowledge(of: text, language: language)
            guard knowledge.isKnown else { return }
            // Lower-case spellings that exist only as proper nouns are offered capitalised.
            let spelling = knowledge.canonical ?? text
            let score = cost - bonus(knowledge.rank) + (knowledge.canonical != nil ? 0.4 : 0)
            if let existing = best[spelling], existing <= score { return }
            best[spelling] = score
        }
        let first = edits(of: lower, language: language, allowInsertions: true)
        for (text, cost) in first { consider(text, cost) }
        if deep && best.count < 5 {
            let seeds = edits(of: lower, language: language, allowInsertions: false)
            for (seed, seedCost) in seeds.prefix(160) {
                for (text, cost) in edits(
                    of: Array(seed), language: language, allowInsertions: lower.count <= 10)
                {
                    consider(text, seedCost + cost)
                }
            }
        }
        return best.map { Candidate(word: $0.key, score: $0.value) }
            .sorted { $0.score == $1.score ? $0.word < $1.word : $0.score < $1.score }
    }

    /// The correction from the table of common misspellings, or nil. The table lists only forms that
    /// are never valid, so it applies even where the dictionary is lenient ("как-будто").
    package func knownMisspelling(_ word: String, language: Language) -> String? {
        guard let fixed = misspellings[language]?[word.lowercased()] else { return nil }
        // The table stores "I'm"-style capitalisation; otherwise follow the typed case.
        return fixed == fixed.lowercased() ? matchCase(of: word, to: fixed) : fixed
    }

    /// A replacement that is safe to apply without asking, or nil.
    ///
    /// - Parameter capitalIsOrdinary: the word opens a sentence, so its capital letter does not suggest
    ///   a proper name.
    package func autoCorrection(for word: String, language: Language, capitalIsOrdinary: Bool = false)
        -> String?
    {
        if let fixed = knownMisspelling(word, language: language) { return fixed }
        guard word.count >= 3, word.count <= 24 else { return nil }
        // Mixed case such as "iPhone" or "SwiftUI" is deliberate.
        guard word.isAllLowercase || word.isCapitalized || word.isAllUppercase else { return nil }
        let found = candidates(for: word, language: language)
        guard let best = found.first else { return nil }

        // The longer the word, the less likely a single edit lands on another word by accident, so
        // longer words may use costlier edits (a dropped letter, a slip to the next key).
        var threshold: Float
        switch word.count {
        case 3: threshold = 0.55
        case 4: threshold = 1.0
        case 5: threshold = 1.25
        // Enough for a dropped letter; replacing a letter needs a frequent target on top of that.
        default: threshold = 1.42
        }
        // A capital inside a sentence usually marks a name: only the cheapest edits to frequent words.
        if !word.isAllLowercase, !(capitalIsOrdinary && word.isCapitalized) {
            threshold = min(threshold, 0.9)
        }
        guard best.score <= threshold else { return nil }
        // Two equally good readings ("слове" / "свое") are a question for the user, not a guess.
        if let runnerUp = found.dropFirst().first {
            // An everyday word beats an obscure one almost on its own.
            let bestIsCommon = vocabulary.rank(of: best.word, language: language) != nil
            let runnerUpIsCommon = vocabulary.rank(of: runnerUp.word, language: language) != nil
            let required: Float = bestIsCommon && !runnerUpIsCommon ? 0.05 : 0.15
            if runnerUp.score - best.score < required { return nil }
        }
        return matchCase(of: word, to: best.word)
    }
}
