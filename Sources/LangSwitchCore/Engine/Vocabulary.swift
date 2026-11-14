import Foundation

/// A spelling dictionary. Implementations follow Hunspell semantics: a lower-case entry also accepts
/// its capitalised and upper-case spellings, while a proper noun is accepted only when capitalised.
package protocol SpellingDictionary {
    func contains(_ word: String, language: Language) -> Bool
}

/// A dictionary backed by plain word sets. Used by tests and as a fallback when Hunspell is missing.
package struct WordSetDictionary: SpellingDictionary {
    private var lowercase: [Language: Set<String>] = [:]
    private var proper: [Language: Set<String>] = [:]

    package init(english: some Sequence<String> = [], russian: some Sequence<String> = []) {
        insert(english, language: .english)
        insert(russian, language: .russian)
    }

    package mutating func insert(_ words: some Sequence<String>, language: Language) {
        for word in words {
            if word == word.lowercased() {
                lowercase[language, default: []].insert(word)
            } else {
                proper[language, default: []].insert(word)
            }
        }
    }

    package func contains(_ word: String, language: Language) -> Bool {
        // Like Hunspell: "word", "Word" and "WORD" match a lower-case entry, "WOrd" does not.
        let regularCase = word.isAllLowercase || word.isCapitalized || word.isAllUppercase
        if regularCase, lowercase[language]?.contains(word.lowercased()) == true { return true }
        guard let names = proper[language] else { return false }
        return names.contains(word)
            || (word.isAllUppercase && names.contains(word.lowercased().capitalizedFirst))
    }
}

/// A product, brand, command or abbreviation that is always a valid Latin-script token.
package struct Term: Sendable, Equatable {
    package let canonical: String
    /// Restore the canonical capitalisation when the user typed the term in lower case.
    package let restoresCase: Bool
}

package struct TermLexicon: Sendable {
    private let terms: [String: Term]
    private let sortedKeys: [String]

    package init(_ terms: [Term] = []) {
        self.terms = Dictionary(
            terms.map { ($0.canonical.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        sortedKeys = self.terms.keys.sorted()
    }

    /// True when some term starts with `prefix` (lower case).
    package func hasTerm(withPrefix prefix: String) -> Bool {
        SortedPrefixSearch.contains(prefix: prefix, in: sortedKeys)
    }

    /// Parses `canonical<TAB>cap|keep` lines.
    package init(tsv: String) {
        var parsed: [Term] = []
        for line in tsv.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let name = fields.first, !name.isEmpty else { continue }
            parsed.append(Term(canonical: String(name), restoresCase: fields.count > 1 && fields[1] == "cap"))
        }
        self.init(parsed)
    }

    package func term(for word: String) -> Term? { terms[word.lowercased()] }
    package var count: Int { terms.count }
    package var all: [Term] { Array(terms.values) }
}

/// Word frequency ranks: 0 is the most frequent word of the language.
/// Binary search for "is any element prefixed by this string" in a sorted array.
enum SortedPrefixSearch {
    static func contains(prefix: String, in sorted: [String]) -> Bool {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < prefix { low = middle + 1 } else { high = middle }
        }
        return low < sorted.count && sorted[low].hasPrefix(prefix)
    }
}

package struct FrequencyList: Sendable {
    /// Every word, most frequent first: the core list, then the extension.
    package let words: [String]
    /// The curated head of the list: the commonest everyday forms, which the letter model is trained
    /// on and which the "one of the commonest words" rules refer to.
    package let coreCount: Int
    private let ranks: [String: Int]
    private let sorted: [String]

    /// - Parameter extended: words beyond the core, ordered by how often they occur in a large corpus.
    package init(words: [String] = [], extended: [String] = []) {
        var all = words
        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(words.count + extended.count)
        for (index, word) in words.enumerated() where ranks[word] == nil { ranks[word] = index }
        for word in extended where ranks[word] == nil {
            ranks[word] = all.count
            all.append(word)
        }
        self.words = all
        self.coreCount = words.count
        self.ranks = ranks
        self.sorted = all.sorted()
    }

    package var core: ArraySlice<String> { words.prefix(coreCount) }

    /// Identifies the exact list: data built against it (the context model) is tied to this value.
    package var signature: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for word in words {
            for byte in word.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            hash ^= 0x0A
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// True when some listed word starts with `prefix` (lower case).
    package func hasWord(withPrefix prefix: String) -> Bool {
        SortedPrefixSearch.contains(prefix: prefix, in: sorted)
    }

    package init(text: String) {
        self.init(words: text.split(whereSeparator: \.isNewline).map { $0.lowercased() })
    }

    package func rank(of word: String) -> Int? { ranks[word.lowercased()] }
    package var count: Int { words.count }
}

/// What the engine knows about one word of one language.
package struct WordKnowledge: Sendable, Equatable {
    package var isKnown = false
    /// Frequency rank, lower is more common; nil when the word is not in the frequency list.
    package var rank: Int?
    /// Canonical spelling when the typed case should be fixed ("figma" → "Figma", "андрей" → "Андрей").
    package var canonical: String?
    package var isTerm = false
    package var isPersonal = false
}

/// Words the user taught the application, kept separately from the bundled data.
package struct PersonalVocabulary: Sendable, Codable, Equatable {
    /// Words accepted as correct, stored in their canonical case.
    package var words: Set<String> = []
    /// Typed strings (lower-case, as produced by the wrong layout) that must never be converted.
    package var keepAsTyped: Set<String> = []
    /// Typed strings (lower-case) that must always be converted to the other layout.
    package var alwaysConvert: Set<String> = []

    package init() {}

    package func knows(_ word: String) -> String? {
        if words.contains(word) { return word }
        let lower = word.lowercased()
        if words.contains(lower) { return lower }
        let capitalised = lower.capitalizedFirst
        if words.contains(capitalised) { return capitalised }
        return words.first { $0.lowercased() == lower }
    }
}

/// Everything the engine can look a word up in. Owned by one executor; lookups are cached.
package final class Vocabulary {
    private let dictionary: any SpellingDictionary
    package let terms: TermLexicon
    package let frequency: [Language: FrequencyList]
    package let context: [Language: ContextModel]
    package var personal: PersonalVocabulary {
        didSet { if personal != oldValue { cache.removeAll(keepingCapacity: true) } }
    }

    private struct CacheKey: Hashable {
        let word: String
        let language: Language
    }
    private var cache: [CacheKey: WordKnowledge] = [:]
    private let cacheLimit = 8192

    package init(
        dictionary: any SpellingDictionary, terms: TermLexicon = TermLexicon(),
        frequency: [Language: FrequencyList] = [:], context: [Language: ContextModel] = [:],
        personal: PersonalVocabulary = PersonalVocabulary()
    ) {
        self.context = context
        self.dictionary = dictionary
        self.terms = terms
        self.frequency = frequency
        self.personal = personal
    }

    package func rank(of word: String, language: Language) -> Int? {
        frequency[language]?.rank(of: word)
    }

    /// How many times `word` follows `previous` in everyday text. Nil when the pair cannot be judged:
    /// there is no model, or one of the words is outside its vocabulary.
    package func pairCount(_ previous: String, _ word: String, language: Language) -> Int? {
        guard let model = context[language], let list = frequency[language],
            let first = list.rank(of: Self.folded(previous)), let second = list.rank(of: Self.folded(word))
        else { return nil }
        return model.count(first, second)
    }

    /// How many pairs in the corpus begin with `previous`; 0 when it is unknown to the model.
    package func pairTotal(after previous: String, language: Language) -> Int {
        guard let model = context[language], let first = frequency[language]?.rank(of: Self.folded(previous))
        else { return 0 }
        return model.total(after: first)
    }

    /// The words that most often follow `previous`, most frequent first.
    package func followers(of previous: String, language: Language, limit: Int) -> [(
        word: String, count: Int
    )] {
        guard let model = context[language], let list = frequency[language],
            let first = list.rank(of: Self.folded(previous))
        else { return [] }
        return model.followers(of: first, limit: limit).map { (list.words[$0.word], $0.count) }
    }

    /// The corpus is counted without «ё», as most people type.
    private static func folded(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    /// Dictionary forms of a word; plugged in by the dictionary provider.
    package var lemmatizer: ((_ word: String, _ language: Language) -> [String])?

    /// How common a word is, judged by the form itself or, failing that, by its dictionary form:
    /// «исправляем» is an everyday word because «исправлять» is, although the form itself is unlisted.
    package func commonness(of word: String, language: Language) -> Int? {
        if let rank = rank(of: word, language: language) { return rank }
        if let cached = commonnessCache[CacheKey(word: word, language: language)] { return cached.rank }
        let lemmaRank = lemmatizer?(word, language).compactMap { rank(of: $0, language: language) }.min()
        if commonnessCache.count >= cacheLimit { commonnessCache.removeAll(keepingCapacity: true) }
        commonnessCache[CacheKey(word: word, language: language)] = CachedRank(rank: lemmaRank)
        return lemmaRank
    }

    private struct CachedRank {
        let rank: Int?
    }
    private var commonnessCache: [CacheKey: CachedRank] = [:]

    /// Looks a word up exactly as typed (case matters for proper nouns).
    package func knowledge(of word: String, language: Language) -> WordKnowledge {
        let key = CacheKey(word: word, language: language)
        if let cached = cache[key] { return cached }
        let value = compute(word, language: language)
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = value
        return value
    }

    package func isKnown(_ word: String, language: Language) -> Bool {
        knowledge(of: word, language: language).isKnown
    }

    private func compute(_ word: String, language: Language) -> WordKnowledge {
        var result = WordKnowledge()
        guard !word.isEmpty, word.count <= 48 else { return result }
        let lower = word.lowercased()
        result.rank = frequency[language]?.rank(of: lower)

        if let personalSpelling = personal.knows(word), Language.dominant(in: personalSpelling) == language {
            result.isKnown = true
            result.isPersonal = true
            if personalSpelling != word, word.isAllLowercase, personalSpelling != lower {
                result.canonical = personalSpelling
            }
            return result
        }
        if language == .english, let term = terms.term(for: word) {
            result.isKnown = true
            result.isTerm = true
            if term.restoresCase, word.isAllLowercase, term.canonical != word {
                result.canonical = term.canonical
            }
            return result
        }
        if language == .english, lower == "i" {
            result.isKnown = true
            if word == "i" { result.canonical = "I" }
            return result
        }
        // Single letters are words only when the frequency list says so ("я", "в", "a").
        if word.count == 1 {
            result.isKnown = result.rank != nil
            return result
        }
        if dictionary.contains(word, language: language) {
            result.isKnown = true
            return result
        }
        // A proper noun typed in lower case: "андрей" → "Андрей", "monday" → "Monday". Very short
        // words collide with chat abbreviations («оки» is not the river) and are left alone.
        if word.isAllLowercase, word.count >= 4 {
            let capitalised = word.capitalizedFirst
            if dictionary.contains(capitalised, language: language) {
                result.isKnown = true
                result.canonical = capitalised
                return result
            }
        }
        // Frequent everyday forms missing from the dictionary (contractions, chat words).
        if result.rank != nil, word.isAllLowercase || word.isCapitalized || word.isAllUppercase {
            result.isKnown = true
            return result
        }
        // "ё" is routinely typed as "е"; accept the word when the dictionary knows it either way.
        if language == .russian, lower.contains("ё") {
            let plain = word.replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "Ё", with: "Е")
            if dictionary.contains(plain, language: language) { result.isKnown = true }
        }
        return result
    }
}
