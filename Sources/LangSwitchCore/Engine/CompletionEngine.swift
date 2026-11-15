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

    /// The words of one language in alphabetical order, each with its rank in the frequency list.
    private struct Index: Sendable {
        var words: [String] = []
        var ranks: [Int32] = []

        /// The run of words that begin with `prefix`.
        func range(ofPrefix prefix: String) -> Range<Int> {
            func firstIndex(where reached: (String) -> Bool) -> Int {
                var low = 0
                var high = words.count
                while low < high {
                    let middle = (low + high) / 2
                    if reached(words[middle]) { high = middle } else { low = middle + 1 }
                }
                return low
            }
            let start = firstIndex { $0 >= prefix }
            let end = firstIndex { $0 >= prefix && !$0.hasPrefix(prefix) }
            return start..<max(start, end)
        }
    }

    private let index: [Language: Index]
    private let frequency: [Language: FrequencyList]
    private let context: [Language: ContextModel]
    /// Words that must never be offered: the list holds them only so that they are not "corrected".
    private let unsuitable: [Language: Set<String>]

    /// How sure the engine must be before it shows anything: the share of the offered word among all
    /// words that could be meant by what is typed so far.
    package static let confidence: Float = 0.5
    /// A word typed by the user counts as this many sightings in the corpus.
    private static let personalWeight: Float = 40
    /// How many corpus sightings the general frequency of a word is worth next to what was seen after
    /// the previous word.
    private static let priorWeight: Float = 30

    /// - Parameters:
    ///   - context: how often words follow each other in real text.
    ///   - unsuitable: listed words that are not to be suggested (names, rough words).
    package init(
        frequency: [Language: FrequencyList], terms: TermLexicon = TermLexicon(),
        context: [Language: ContextModel] = [:], unsuitable: [Language: Set<String>] = [:]
    ) {
        self.frequency = frequency
        self.context = context
        self.unsuitable = unsuitable
        var index: [Language: Index] = [:]
        for (language, list) in frequency {
            let order = list.words.indices.sorted { list.words[$0] < list.words[$1] }
            var entry = Index()
            entry.words = order.map { list.words[$0] }
            entry.ranks = order.map { Int32($0) }
            if language == .english {
                // Terms complete like words, as the rarest of them.
                let known = Set(entry.words)
                let extra = terms.all.map { $0.canonical.lowercased() }
                    .filter { $0.count >= 4 && $0.allSatisfy(\.isLetter) && !known.contains($0) }
                if !extra.isEmpty {
                    let merged = zip(entry.words, entry.ranks) + extra.map { ($0, Int32(list.count)) }
                    let sorted = merged.sorted { $0.0 < $1.0 }
                    entry.words = sorted.map(\.0)
                    entry.ranks = sorted.map(\.1)
                }
            }
            index[language] = entry
        }
        self.index = index
    }

    /// The most likely completion of `prefix`, or nil when nothing stands out.
    ///
    /// Every word that begins with the prefix gets a weight: how often it follows the previous word in
    /// real text and in the user's own typing, plus its general frequency. A word is offered when its
    /// weight is at least `confidence` of the total — when it is more likely than everything else
    /// together, the shorter words the prefix may already be included.
    package func complete(
        prefix: String, language: Language, previous: String? = nil, learning: LearningData = LearningData(),
        minimumPrefix: Int = 3, confidence: Float = CompletionEngine.confidence
    ) -> Suggestion? {
        guard prefix.count >= minimumPrefix, prefix.count <= 24, prefix.allSatisfy({ language.isLetter($0) }),
            let index = index[language], let list = frequency[language]
        else { return nil }
        let lower = prefix.lowercased()
        let range = index.range(ofPrefix: lower)
        // Thousands of words fit: nothing can stand out.
        guard range.count <= 8000 else { return nil }

        let model = context[language]
        let previousWord = previous?.lowercased()
        let previousID = previousWord.flatMap { list.rank(of: $0.replacingOccurrences(of: "ё", with: "е")) }
        let personalFollowers = previousWord.flatMap { learning.bigrams[$0] } ?? [:]
        let everything = Float(max(model?.grandTotal ?? 0, 1))
        let listSize = Float(max(list.count, 1))

        /// General frequency of a listed word, as a share of the corpus.
        func prior(rank: Int) -> Float {
            if let model {
                // Half a sighting for words the corpus has never seen opening a pair.
                return (Float(model.total(after: rank)) + 0.5) / everything
            }
            // Without a corpus the place in the list has to do: Zipf's law.
            return 1 / (Float(rank) + 3) / log(listSize + 3)
        }
        func weight(_ word: String, rank: Int?) -> Float {
            var seen = Self.personalWeight * Float(personalFollowers[word] ?? 0)
            if let model, let previousID, let rank { seen += Float(model.count(previousID, rank)) }
            let personal = Self.personalWeight * Float(learning.wordCounts[word] ?? 0) / everything
            return seen + Self.priorWeight * ((rank.map(prior) ?? 0) + personal)
        }

        var total: Float = 0
        var best: (word: String, weight: Float)?
        let banned = unsuitable[language] ?? []
        func consider(_ word: String, _ weight: Float) {
            total += weight
            guard word.count >= lower.count + 2, weight > (best?.weight ?? 0),
                // A name or a rough word is offered only to the user who made it their own.
                !banned.contains(word) || learning.vocabulary.knows(word) != nil
            else { return }
            best = (word, weight)
        }
        var listed: Set<String> = []
        for position in range {
            let word = index.words[position]
            let rank = Int(index.ranks[position])
            consider(
                word, weight(word, rank: rank < list.count ? rank : nil) + (rank < list.count ? 0 : 0.01))
            if !learning.wordCounts.isEmpty { listed.insert(word) }
        }
        // The user's own words that no list has.
        for (word, count) in learning.wordCounts
        where count >= 2 && word.hasPrefix(lower) && !listed.contains(word)
            && Language.dominant(in: word) == language
        {
            consider(word, weight(word, rank: nil))
        }

        guard let best, total > 0, best.weight / total >= confidence else { return nil }
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

    /// The word that is likely to come next: the one that most often follows `previous` in the user's
    /// own typing, or, failing that, in real text — when it follows it at least `minimumShare` of the
    /// time.
    package func nextWord(
        after previous: String, learning: LearningData, language: Language? = nil,
        minimumShare: Float = CompletionEngine.nextWordShare
    ) -> String? {
        let key = previous.lowercased()
        if let followers = learning.bigrams[key] {
            let total = followers.values.reduce(0, +)
            if let top = followers.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }),
                top.value >= 3, Float(top.value) / Float(total) >= 0.5
            {
                return top.key
            }
        }
        guard let language, let model = context[language], let list = frequency[language],
            let rank = list.rank(of: key.replacingOccurrences(of: "ё", with: "е"))
        else { return nil }
        let total = model.total(after: rank)
        // A handful of sightings says nothing about what usually follows.
        guard total >= 40, let top = model.followers(of: rank, limit: 1).first,
            Float(top.count) / Float(total) >= minimumShare
        else { return nil }
        let word = list.words[top.word]
        return unsuitable[language]?.contains(word) == true ? nil : word
    }

    /// How often a word must follow the previous one to be offered before a single letter is typed.
    package static let nextWordShare: Float = 0.5
}
