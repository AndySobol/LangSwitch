import Foundation

/// Suggests how the word being typed ends, and which word is likely to come next.
///
/// Sources, in order of weight: the user's own typing history, the frequency lists and the term list.
/// Nothing is generated: a suggestion is always a word that exists.
package struct CompletionEngine: Sendable {
    package struct Suggestion: Sendable, Equatable {
        /// The complete word, in the letter case of what was typed.
        package let word: String
        /// What still has to be typed to finish it.
        package let remainder: String

        package init(word: String, remainder: String) {
            self.word = word
            self.remainder = remainder
        }
    }

    private let sorted: [Language: [String]]
    private let frequency: [Language: FrequencyList]

    package init(frequency: [Language: FrequencyList], terms: TermLexicon = TermLexicon()) {
        self.frequency = frequency
        var sorted: [Language: [String]] = [:]
        for (language, list) in frequency {
            var words = Set(list.words.filter { $0.count >= 4 })
            if language == .english {
                for term in terms.all where term.canonical.count >= 4 && term.canonical.allSatisfy(\.isLetter)
                {
                    words.insert(term.canonical.lowercased())
                }
            }
            sorted[language] = words.sorted()
        }
        self.sorted = sorted
    }

    private func matches(prefix: String, language: Language) -> ArraySlice<String> {
        guard let words = sorted[language] else { return [] }
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if words[middle] < prefix { low = middle + 1 } else { high = middle }
        }
        var end = low
        while end < words.count, words[end].hasPrefix(prefix), end - low < 400 { end += 1 }
        return words[low..<end]
    }

    /// The most likely completion of `prefix`, or nil when nothing stands out.
    package func complete(
        prefix: String, language: Language, previous: String? = nil, learning: LearningData = LearningData(),
        minimumPrefix: Int = 3
    ) -> Suggestion? {
        guard prefix.count >= minimumPrefix, prefix.count <= 24, prefix.allSatisfy({ language.isLetter($0) })
        else {
            return nil
        }
        let lower = prefix.lowercased()
        let followers = previous.flatMap { learning.bigrams[$0.lowercased()] } ?? [:]
        let total = Float(max(frequency[language]?.count ?? 1, 1))
        var best: (word: String, score: Float)?

        func consider(_ word: String) {
            guard word.count >= lower.count + 2, word.hasPrefix(lower) else { return }
            var score: Float = 0
            if let rank = frequency[language]?.rank(of: word) { score += 1 - Float(rank) / total }
            if let count = learning.wordCounts[word] { score += min(Float(count) / 6, 1.5) }
            if let count = followers[word] { score += min(Float(count) / 2, 2) }
            // Shorter completions are more often right; avoid jumping to long rare words.
            score -= Float(word.count - lower.count) * 0.02
            if score > (best?.score ?? 0.15) { best = (word, score) }
        }

        for word in matches(prefix: lower, language: language) { consider(word) }
        for (word, count) in learning.wordCounts where count >= 2 && word.hasPrefix(lower) {
            if Language.dominant(in: word) == language { consider(word) }
        }
        for word in followers.keys where Language.dominant(in: word) == language { consider(word) }

        guard let best else { return nil }
        var word = best.word
        if let personal = learning.vocabulary.knows(best.word), personal.lowercased() == best.word {
            word = personal
        }
        let cased: String
        if prefix.isAllUppercase {
            cased = word.uppercased()
        } else if prefix.first?.isUppercase == true {
            cased = word.capitalizedFirst
        } else {
            cased = word
        }
        // The typed prefix must survive verbatim, otherwise the ghost text would not line up.
        guard cased.hasPrefix(prefix) else {
            let remainder = String(word.dropFirst(prefix.count))
            return Suggestion(word: prefix + remainder, remainder: remainder)
        }
        return Suggestion(word: cased, remainder: String(cased.dropFirst(prefix.count)))
    }

    /// The word that most often follows `previous` in the user's own typing.
    package func nextWord(after previous: String, learning: LearningData) -> String? {
        guard let followers = learning.bigrams[previous.lowercased()] else { return nil }
        let total = followers.values.reduce(0, +)
        guard let top = followers.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }),
            top.value >= 3, Float(top.value) / Float(total) >= 0.5
        else { return nil }
        return top.key
    }
}
