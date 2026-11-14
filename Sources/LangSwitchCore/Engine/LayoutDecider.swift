import Foundation

/// Decides whether a chunk of typed text was meant for the other keyboard layout.
///
/// A chunk is everything typed between two whitespace boundaries. It is read twice: as typed, and as the
/// same keys would have produced on the alternative layout. The reading that makes sense as language wins;
/// when both or neither do, the text stays as typed.
package struct LayoutDecider {
    package struct Context: Sendable, Equatable {
        /// Language of the previous word in the same run of typing, when it was recognised.
        package var previousLanguage: Language?
        /// How many recognised words in a row were written in `previousLanguage`.
        package var streak = 0
        /// The other language also appeared in the current sentence (a mixed sentence).
        package var sawOtherLanguage = false
        /// The user switched the layout by hand shortly before typing this chunk.
        package var manualSwitch = false

        package init(previousLanguage: Language? = nil, streak: Int = 1, manualSwitch: Bool = false) {
            self.previousLanguage = previousLanguage
            self.streak = previousLanguage == nil ? 0 : streak
            self.manualSwitch = manualSwitch
        }

        /// The surrounding text clearly is in `language`: ambiguous chunks should stay as typed.
        package func confirms(_ language: Language) -> Bool {
            previousLanguage == language && (streak >= 2 || streak == 1 && !sawOtherLanguage)
        }

        /// Records the language of a finished, recognised word.
        package mutating func note(_ language: Language) {
            if previousLanguage == language {
                streak += 1
            } else {
                if previousLanguage != nil { sawOtherLanguage = true }
                previousLanguage = language
                streak = 1
            }
        }

        /// A sentence ended: what follows may well be in the other language.
        package mutating func endSentence() {
            streak = 0
            sawOtherLanguage = false
        }
    }

    package enum Verdict: Sendable, Equatable {
        case keep
        case convert
    }

    /// Facts about one reading of a chunk.
    package struct Reading: Sendable {
        package var words: [String] = []
        package var letters = 0
        package var knownWords = 0
        package var knownLetters = 0
        /// Rank of the least common word, nil when some word is not in the frequency list.
        package var worstRank: Int?
        package var everyWordRanked = true
        /// Length-weighted n-gram plausibility of words with three or more letters.
        package var plausibility: Float?
        package var longestWord = 0
        package var hasPersonal = false
        package var hasTerm = false

        package var allKnown: Bool { !words.isEmpty && knownWords == words.count }
    }

    private let vocabulary: Vocabulary
    private let models: [Language: NGramModel]

    package init(vocabulary: Vocabulary, models: [Language: NGramModel]) {
        self.vocabulary = vocabulary
        self.models = models
    }

    package func reading(of text: String, language: Language) -> Reading {
        var reading = Reading()
        var weighted: Float = 0
        var weight: Float = 0
        for word in Tokenizer.words(in: text, language: language) {
            reading.words.append(word)
            reading.letters += word.count
            reading.longestWord = max(reading.longestWord, word.count)
            let knowledge = vocabulary.knowledge(of: word, language: language)
            if knowledge.isKnown {
                reading.knownWords += 1
                reading.knownLetters += word.count
            }
            if knowledge.isTerm { reading.hasTerm = true }
            if knowledge.isPersonal { reading.hasPersonal = true }
            if let rank = knowledge.rank {
                reading.worstRank = max(reading.worstRank ?? 0, rank)
            } else {
                reading.everyWordRanked = false
            }
            if word.count >= 3, let model = models[language] {
                weighted += model.plausibility(of: word) * Float(word.count)
                weight += Float(word.count)
            }
        }
        if !reading.everyWordRanked { reading.worstRank = nil }
        if weight > 0 { reading.plausibility = weighted / weight }
        return reading
    }

    package func decide(
        typed: String, typedLanguage: Language, alternative: String, context: Context = Context()
    ) -> Verdict {
        let alternativeLanguage = typedLanguage.other
        let key = typed.lowercased()
        if vocabulary.personal.keepAsTyped.contains(key) { return .keep }
        if vocabulary.personal.alwaysConvert.contains(key) { return .convert }
        if typed == alternative { return .keep }

        let other = reading(of: alternative, language: alternativeLanguage)
        guard other.letters > 0 else { return .keep }
        // The other reading must itself look like writing: "rf;lt" for a mistyped «кажде» does not.
        if Self.hasMisplacedPunctuation(
            typed: alternative, alternative: typed, typedLanguage: alternativeLanguage)
        {
            return .keep
        }

        // A whole-chunk term such as "node.js" or "c++".
        let trimmed = typed.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?:;()\"'"))
        if typedLanguage == .english, vocabulary.terms.term(for: trimmed) != nil { return .keep }
        if typedLanguage == .english, TextProtection.isProtected(typed) { return .keep }

        let own = reading(of: typed, language: typedLanguage)

        // Only punctuation was typed, yet the same keys spell a word on the other layout (",fpf" → "база").
        if own.letters == 0 {
            return other.allKnown && other.letters >= 2 && !context.confirms(typedLanguage) ? .convert : .keep
        }

        if own.allKnown {
            guard other.allKnown, !context.manualSwitch, !own.hasPersonal else { return .keep }
            // ";bk" or "jib,rf": the typed words exist, but punctuation sits where no writer puts it,
            // and those very keys are letters of a real word on the other layout ("жил", "ошибка").
            if Self.hasMisplacedPunctuation(
                typed: typed, alternative: alternative, typedLanguage: typedLanguage)
            {
                return .convert
            }
            // Both readings are real words ("tot" / "еще"). Convert only when the alternative is an
            // everyday word, the typed one is not, and nothing says the typed language is in use.
            guard let otherRank = other.worstRank, own.worstRank == nil else { return .keep }
            if context.confirms(typedLanguage) { return .keep }
            // Short technical tokens ("vs", "kb") lose only to the most common words ("мы", "ли").
            if own.hasTerm { return otherRank < 400 && own.letters <= 3 ? .convert : .keep }
            return otherRank < 1500 ? .convert : .keep
        }

        if other.allKnown {
            // Single letters: "z" → "я". Trust context when the typed language is clearly in use.
            if other.letters == 1 {
                guard other.worstRank != nil, own.knownWords == 0 else { return .keep }
                return context.confirms(typedLanguage) ? .keep : .convert
            }
            // The typed text may still be an unlisted but real word (a surname, new slang) whose keys
            // happen to spell a rare word on the other layout.
            var ownScore: Float = 0
            if let plausibility = own.plausibility, own.longestWord >= 4 {
                ownScore = min(max((plausibility + 2.0) / 2.0, 0), 1.6)
            }
            ownScore += Float(own.knownLetters) / Float(max(own.letters, 1))
            var otherScore: Float = 1.6
            if other.worstRank != nil { otherScore += 0.6 }
            if other.letters >= 4 { otherScore += 0.3 }
            if context.previousLanguage == alternativeLanguage { otherScore += 0.3 }
            if context.previousLanguage == typedLanguage { otherScore -= 0.3 }
            if context.manualSwitch { otherScore -= 0.5 }
            return otherScore - ownScore >= 0.8 ? .convert : .keep
        }

        // Neither reading is fully in the dictionaries: compare how word-like they are.
        guard own.knownWords == 0, !context.manualSwitch, other.letters >= 4 else { return .keep }
        guard let otherPlausibility = other.plausibility else { return .keep }
        let ownPlausibility = own.plausibility ?? -6
        let knownShare = Float(other.knownLetters) / Float(other.letters)
        let required: Float = knownShare >= 0.5 ? 1.5 : 2.5
        if otherPlausibility >= -1.2 && otherPlausibility - ownPlausibility >= required
            && ownPlausibility < -1.5
        {
            return .convert
        }
        return .keep
    }

    /// Decides, while a word is still being typed, that it is clearly meant for the other layout.
    ///
    /// Far stricter than the decision at a word boundary, because there is less to go on: the keys must
    /// spell the beginning of an everyday word on the other layout, and lead nowhere on the current one.
    package func shouldConvertEarly(
        typed: String, typedLanguage: Language, alternative: String, context: Context
    ) -> Bool {
        let otherLanguage = typedLanguage.other
        guard typed.count >= 4, typed.count == alternative.count, !context.manualSwitch,
            !context.confirms(typedLanguage), alternative.allSatisfy({ otherLanguage.isLetter($0) })
        else { return false }
        let own = typed.lowercased()
        let other = alternative.lowercased()
        if vocabulary.personal.keepAsTyped.contains(where: { $0.hasPrefix(own) }) { return false }
        if TextProtection.isProtected(typed) { return false }
        guard vocabulary.frequency[otherLanguage]?.hasWord(withPrefix: other) == true else { return false }

        // Keys that are punctuation here and letters there ("hf,j" → «рабо») settle it.
        guard own.allSatisfy({ typedLanguage.isLetter($0) }) else { return true }
        // Letters only: make sure this is not the start of a real word, a term or a plausible new one.
        if vocabulary.frequency[typedLanguage]?.hasWord(withPrefix: own) == true { return false }
        if typedLanguage == .english, vocabulary.terms.hasTerm(withPrefix: own) { return false }
        if vocabulary.personal.words.contains(where: { $0.lowercased().hasPrefix(own) }) { return false }
        if vocabulary.isKnown(typed, language: typedLanguage) { return false }
        guard let model = models[typedLanguage] else { return false }
        return model.prefixPlausibility(of: own) < -2.5
    }

    /// True when `typed` has punctuation in an unnatural place that is a letter on the other layout.
    ///
    /// Natural places are the end of the chunk ("word," "word.") and, between letters, an apostrophe or a
    /// dot ("don't", "example.org"). Anything else — a leading semicolon, a comma inside a word — is the
    /// footprint of the Russian letters ж, э, б, ю, х, ъ, ё typed on a Latin layout.
    static func hasMisplacedPunctuation(typed: String, alternative: String, typedLanguage: Language) -> Bool {
        let own = Array(typed)
        let other = Array(alternative)
        guard own.count == other.count else { return false }
        let otherLanguage = typedLanguage.other
        guard let lastLetter = own.lastIndex(where: { typedLanguage.isLetter($0) }),
            let firstLetter = own.firstIndex(where: { typedLanguage.isLetter($0) })
        else { return false }
        for index in own.indices {
            let character = own[index]
            guard !typedLanguage.isLetter(character), otherLanguage.isLetter(other[index]) else { continue }
            if index > lastLetter && ".,;:!?\"'".contains(character) { continue }
            // An opening quote: "a user" starts with one.
            if index < firstLetter && "\"'".contains(character) { continue }
            let betweenLetters =
                index > 0 && index < lastLetter && typedLanguage.isLetter(own[index - 1])
                && typedLanguage.isLetter(own[index + 1])
            if betweenLetters && (character == "'" || character == ".") { continue }
            return true
        }
        return false
    }
}
