import Foundation

/// Everything the application learns about its user. Stored locally; never leaves the Mac.
package struct LearningData: Sendable, Codable, Equatable {
    package var vocabulary = PersonalVocabulary()
    /// Words the application added on its own after seeing them typed repeatedly.
    package var autoLearned: Set<String> = []
    /// How often each word was typed (lower-case); drives personal completions.
    package var wordCounts: [String: Int] = [:]
    /// Unknown words left as typed; repeated ones are promoted to the vocabulary.
    package var unknownCounts: [String: Int] = [:]
    /// previous word → next word → count; drives next-word suggestions.
    package var bigrams: [String: [String: Int]] = [:]
    /// Typed chunk (lower-case) → how many times its conversion was undone.
    package var rejections: [String: Int] = [:]
    /// Typed chunk (lower-case) → how many times it was converted by hand.
    package var manualConversions: [String: Int] = [:]
    /// Correct spelling → how many times the user mistyped it; feeds the "weak words" drill.
    package var typoCounts: [String: Int] = [:]

    package init() {}

    package static let promotionThreshold = 3
    private static let wordLimit = 6000
    private static let bigramLimit = 2500

    private enum CodingKeys: String, CodingKey {
        case vocabulary, autoLearned, wordCounts, unknownCounts, bigrams, rejections, manualConversions,
            typoCounts
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vocabulary =
            try container.decodeIfPresent(PersonalVocabulary.self, forKey: .vocabulary)
            ?? PersonalVocabulary()
        autoLearned = try container.decodeIfPresent(Set<String>.self, forKey: .autoLearned) ?? []
        wordCounts = try container.decodeIfPresent([String: Int].self, forKey: .wordCounts) ?? [:]
        unknownCounts = try container.decodeIfPresent([String: Int].self, forKey: .unknownCounts) ?? [:]
        bigrams = try container.decodeIfPresent([String: [String: Int]].self, forKey: .bigrams) ?? [:]
        rejections = try container.decodeIfPresent([String: Int].self, forKey: .rejections) ?? [:]
        manualConversions =
            try container.decodeIfPresent([String: Int].self, forKey: .manualConversions) ?? [:]
        typoCounts = try container.decodeIfPresent([String: Int].self, forKey: .typoCounts) ?? [:]
    }

    /// A word must look like a word to be remembered: letters, at least three, no digits.
    package static func isLearnable(_ word: String) -> Bool {
        word.count >= 3 && word.count <= 32
            && word.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" }
            && word.first?.isLetter == true && word.last?.isLetter == true
    }

    /// Records a finished word. Returns the word when it has just been promoted to the vocabulary.
    @discardableResult
    package mutating func recordWord(_ word: String, previous: String?, known: Bool) -> String? {
        guard Self.isLearnable(word) else { return nil }
        let lower = word.lowercased()
        wordCounts[lower, default: 0] += 1
        if let previous, Self.isLearnable(previous) {
            bigrams[previous.lowercased(), default: [:]][lower, default: 0] += 1
        }
        var promoted: String?
        if !known, vocabulary.knows(word) == nil {
            let count = unknownCounts[lower, default: 0] + 1
            unknownCounts[lower] = count
            if count >= Self.promotionThreshold {
                // Keep the spelling the user actually uses, including its capitalisation.
                vocabulary.words.insert(word)
                autoLearned.insert(word)
                unknownCounts[lower] = nil
                promoted = word
            }
        }
        pruneIfNeeded()
        return promoted
    }

    /// The user undid a conversion. After two undos the chunk is never converted again.
    @discardableResult
    package mutating func recordRejection(typed: String) -> Bool {
        let key = typed.lowercased()
        let count = rejections[key, default: 0] + 1
        rejections[key] = count
        vocabulary.alwaysConvert.remove(key)
        if count >= 2 {
            vocabulary.keepAsTyped.insert(key)
            return true
        }
        return false
    }

    /// The user converted a chunk by hand. After two times it is converted automatically.
    @discardableResult
    package mutating func recordManualConversion(typed: String) -> Bool {
        let key = typed.lowercased()
        let count = manualConversions[key, default: 0] + 1
        manualConversions[key] = count
        vocabulary.keepAsTyped.remove(key)
        if count >= 2 {
            vocabulary.alwaysConvert.insert(key)
            return true
        }
        return false
    }

    package mutating func recordTypo(corrected: String) {
        guard Self.isLearnable(corrected) else { return }
        typoCounts[corrected.lowercased(), default: 0] += 1
        if typoCounts.count > 800 { typoCounts = Self.trimmed(typoCounts, to: 600) }
    }

    package mutating func addWord(_ word: String) {
        vocabulary.words.insert(word)
        unknownCounts[word.lowercased()] = nil
    }

    package mutating func removeWord(_ word: String) {
        vocabulary.words.remove(word)
        autoLearned.remove(word)
    }

    /// Words mistyped most often, best candidates for practice first.
    package func weakWords(limit: Int) -> [String] {
        typoCounts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit).map(
            \.key)
    }

    private static func trimmed(_ counts: [String: Int], to limit: Int) -> [String: Int] {
        let kept = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(
            limit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    private mutating func pruneIfNeeded() {
        if wordCounts.count > Self.wordLimit {
            wordCounts = Self.trimmed(wordCounts, to: Self.wordLimit * 3 / 4)
        }
        if unknownCounts.count > 1500 { unknownCounts = Self.trimmed(unknownCounts, to: 1000) }
        if bigrams.count > Self.bigramLimit {
            var totals: [String: Int] = [:]
            for (key, followers) in bigrams { totals[key] = followers.values.reduce(0, +) }
            let keep = Set(Self.trimmed(totals, to: Self.bigramLimit * 3 / 4).keys)
            bigrams = bigrams.filter { keep.contains($0.key) }
        }
        for (key, followers) in bigrams where followers.count > 12 {
            bigrams[key] = Self.trimmed(followers, to: 8)
        }
    }
}
