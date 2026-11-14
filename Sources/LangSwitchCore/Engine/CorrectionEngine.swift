import Foundation

/// Which kinds of fixes are allowed. Every switch maps to a setting in the interface.
package struct CorrectionOptions: Sendable, Equatable, Codable {
    package var layout = true
    package var spelling = true
    package var punctuation = true
    package var capitalization = true

    package init(
        layout: Bool = true, spelling: Bool = true, punctuation: Bool = true, capitalization: Bool = true
    ) {
        self.layout = layout
        self.spelling = spelling
        self.punctuation = punctuation
        self.capitalization = capitalization
    }

    package static let none = CorrectionOptions(
        layout: false, spelling: false, punctuation: false, capitalization: false)
    package var isEmpty: Bool { !layout && !spelling && !punctuation && !capitalization }
}

package struct CorrectionKinds: OptionSet, Sendable, Hashable, Codable {
    package let rawValue: Int
    package init(rawValue: Int) { self.rawValue = rawValue }

    package static let layout = CorrectionKinds(rawValue: 1 << 0)
    package static let spelling = CorrectionKinds(rawValue: 1 << 1)
    package static let punctuation = CorrectionKinds(rawValue: 1 << 2)
    package static let capitalization = CorrectionKinds(rawValue: 1 << 3)
}

/// One chunk of typing — the text between two whitespace boundaries — with what is known around it.
package struct ChunkInput: Sendable {
    package var typed: String
    package var typedLanguage: Language
    /// The same key presses rendered on the other layout; nil when there is no second layout.
    package var alternative: String?
    package var context = LayoutDecider.Context()
    /// The chunk opens a sentence.
    package var sentenceStart = false
    /// Lower-case words typed before this chunk in the same clause, nearest last.
    package var previousWords: [String] = []
    /// The chunk may open a sentence (it is the first one typed after the caret was placed), so a
    /// capital letter on its first word does not mark a proper name.
    package var mayOpenSentence = false

    package init(typed: String, typedLanguage: Language, alternative: String? = nil) {
        self.typed = typed
        self.typedLanguage = typedLanguage
        self.alternative = alternative
    }
}

package struct ChunkResult: Sendable, Equatable {
    package var text: String
    /// Language of the words in the final text, nil for chunks without letters.
    package var language: Language?
    package var kinds: CorrectionKinds = []
    /// A comma must be inserted right after the previous word (before the separating space).
    package var commaBefore = false
    /// The final text contains at least one recognised word.
    package var hasKnownWord = false

    package var converted: Bool { kinds.contains(.layout) }
}

/// The full correction pipeline for one chunk: layout, then words, then capitalisation and punctuation.
package struct CorrectionEngine {
    package let vocabulary: Vocabulary
    package let decider: LayoutDecider
    package let speller: SpellingCorrector
    private let abbreviations: Set<String>

    package init(
        vocabulary: Vocabulary, models: [Language: NGramModel], abbreviations: Set<String> = [],
        policy: CorrectionPolicy? = nil
    ) {
        self.vocabulary = vocabulary
        self.decider = LayoutDecider(vocabulary: vocabulary, models: models)
        self.speller = SpellingCorrector(vocabulary: vocabulary, models: models, policy: policy)
        self.abbreviations = abbreviations
    }

    /// Whether an unknown word may be remembered as part of the user's own vocabulary.
    ///
    /// Learning must never turn a missed correction into a rule. A word typed on the wrong layout that
    /// was left alone once is still a mistake, not vocabulary: "ghbdtn" reads as «привет» on the other
    /// layout and is keyboard noise on its own, so it is refused on both counts.
    package func mayLearn(_ word: String, language: Language, layouts: [KeyboardLayout]) -> Bool {
        guard LearningData.isLearnable(word) else { return false }
        let own = decider.reading(of: word, language: language)
        let plausibility = own.plausibility ?? -9
        // Measured: unusual names score around -2.4 ("Bambu", "Zoltra"), wrong-layout text below -4.
        if plausibility < -3.3 { return false }
        guard let layout = layouts.first(where: { $0.language == language }),
            let otherLayout = layouts.first(where: { $0.language != language })
        else { return true }
        let other = decider.reading(of: layout.convert(word, to: otherLayout), language: language.other)
        if other.allKnown { return false }
        if other.letters >= 4, let otherPlausibility = other.plausibility, otherPlausibility > -1.0,
            plausibility < otherPlausibility - 1.5
        {
            return false
        }
        return true
    }

    /// A space that landed one letter early or late: «н ето» for «не то», «та ки» for «так и».
    ///
    /// Looked at only when the second word is not a word at all; both repaired words must be everyday
    /// ones, so that an unusual but valid pair is never rearranged.
    package func spaceSlip(previous: String, current: String, language: Language) -> (String, String)? {
        guard options(for: previous, current, language) else { return nil }
        let left = Array(previous.lowercased())
        let right = Array(current.lowercased())
        var repairs: [(String, String, Int)] = []
        func offer(_ first: [Character], _ second: [Character]) {
            guard !first.isEmpty, !second.isEmpty,
                let firstRank = vocabulary.rank(of: String(first), language: language),
                let secondRank = vocabulary.rank(of: String(second), language: language)
            else { return }
            // With a context model, the two words must have been seen side by side; without one, both
            // must be among the commonest.
            if let pair = vocabulary.pairCount(String(first), String(second), language: language) {
                guard pair > 0 else { return }
            } else {
                guard max(firstRank, secondRank) < 6000 else { return }
            }
            repairs.append((String(first), String(second), max(firstRank, secondRank)))
        }
        // The space came one letter too early …
        offer(left + [right[0]], Array(right.dropFirst()))
        // … or one letter too late.
        if left.count >= 2 { offer(Array(left.dropLast()), [left[left.count - 1]] + right) }
        guard repairs.count == 1, let repair = repairs.first else { return nil }
        return (matchCase(of: previous, to: repair.0), repair.1)
    }

    private func options(for previous: String, _ current: String, _ language: Language) -> Bool {
        guard previous.count >= 1, previous.count <= 12, current.count >= 2, current.count <= 12,
            previous.allSatisfy({ language.isLetter($0) }), current.allSatisfy({ language.isLetter($0) }),
            current.isAllLowercase
        else { return false }
        // The second word must be meaningless as typed, and the first must not be an everyday word that
        // simply stands before a typo.
        if vocabulary.isKnown(current, language: language) { return false }
        return true
    }

    /// True when a chunk ends a sentence, so the next word starts with a capital letter.
    package func endsSentence(_ chunk: String) -> Bool {
        guard let last = chunk.last, ".!?".contains(last) else { return false }
        // An ellipsis trails off; the sentence may well go on.
        if chunk.hasSuffix("..") { return false }
        let lower = chunk.lowercased()
        if abbreviations.contains(lower) { return false }
        // Initials and single letters: "А." or "e."
        let letters = lower.filter(\.isLetter)
        if last == "." && letters.count <= 1 { return false }
        // Dotted tokens such as "т.е." or "e.g." that the list does not mention.
        if last == "." && lower.dropLast().contains(".") && letters.count <= 4 { return false }
        return true
    }

    /// A chunk that the layout decision wants to convert, but which is better explained as a word of
    /// the typed language with a slip in it: «руук» is «руку», not "heer".
    private func isSlipInTypedLanguage(_ input: ChunkInput, alternative: String) -> Bool {
        let language = input.typedLanguage
        let word = input.typed.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?:;()\"'«»"))
        guard word.count >= 3, word.allSatisfy({ language.isLetter($0) }), let threshold = speller.threshold,
            let assessment = speller.assessment(of: word, language: language, after: input.previousWords.last)
        else { return false }
        // Against an everyday word of the other language the slip has to be as certain as any
        // correction; against a rare or unknown one, merely likely.
        let other = decider.reading(of: alternative, language: language.other)
        let otherIsEveryday = other.allKnown && other.worstRank != nil
        return assessment.confidence >= (otherIsEveryday ? threshold : 0.5)
    }

    /// The word right before a token in the same clause: inside the chunk, or the last one typed.
    private func previousWord(before index: Int, in tokens: [TextToken], input: ChunkInput) -> String? {
        if index >= 2, tokens[index - 2].isWord, tokens[index - 1].text.allSatisfy({ $0.isWhitespace }) {
            return tokens[index - 2].text.lowercased()
        }
        return index == 0 ? input.previousWords.last : nil
    }

    package func process(_ input: ChunkInput, options: CorrectionOptions) -> ChunkResult {
        var text = input.typed
        var language = input.typedLanguage
        var kinds: CorrectionKinds = []

        if options.layout, let alternative = input.alternative,
            decider.decide(
                typed: input.typed, typedLanguage: input.typedLanguage, alternative: alternative,
                context: input.context) == .convert,
            !isSlipInTypedLanguage(input, alternative: alternative)
        {
            text = alternative
            language = input.typedLanguage.other
            kinds.insert(.layout)
        }

        let protected = TextProtection.isProtected(text)
        var tokens = Tokenizer.tokens(in: text)
        var hasKnownWord = false
        var firstWordIsPlain = false
        var sawWord = false

        if !protected {
            for index in tokens.indices {
                guard tokens[index].language == language else { continue }
                let word = tokens[index].text
                let isFirst = !sawWord
                sawWord = true
                let knowledge = vocabulary.knowledge(of: word, language: language)
                // The dictionary accepts any pair of words joined by a hyphen («как-будто»), so a compound
                // that is not attested in everyday use is still examined against the hyphenation rules.
                let lenientCompound =
                    knowledge.isKnown && knowledge.rank == nil && !knowledge.isTerm && !knowledge.isPersonal
                    && word.contains("-")
                if knowledge.isKnown && !lenientCompound {
                    hasKnownWord = true
                    if isFirst { firstWordIsPlain = !knowledge.isTerm && !knowledge.isPersonal }
                    if options.capitalization, let canonical = knowledge.canonical {
                        tokens[index].text = canonical
                        kinds.insert(.capitalization)
                        if isFirst { firstWordIsPlain = false }
                    }
                    continue
                }
                // "ПРивет": Shift was held one letter too long.
                if options.capitalization, word.count >= 3 {
                    let characters = Array(word)
                    if characters[0].isUppercase, characters[1].isUppercase,
                        characters[2...].allSatisfy(\.isLowercase)
                    {
                        let repaired = word.lowercased().capitalizedFirst
                        if vocabulary.isKnown(repaired, language: language) {
                            tokens[index].text = repaired
                            kinds.insert(.capitalization)
                            hasKnownWord = true
                            continue
                        }
                    }
                }
                if options.spelling,
                    let fixed = speller.autoCorrection(
                        for: word, language: language,
                        capitalIsOrdinary: isFirst && (input.sentenceStart || input.mayOpenSentence),
                        after: previousWord(before: index, in: tokens, input: input))
                {
                    tokens[index].text = fixed
                    kinds.insert(.spelling)
                    hasKnownWord = true
                    if isFirst { firstWordIsPlain = true }
                } else if lenientCompound {
                    hasKnownWord = true
                }
            }

            // "привет,как" → "привет, как". Dots are left alone: they belong to addresses and file names.
            if options.punctuation, tokens.count >= 3 {
                for index in 1..<(tokens.count - 1)
                where [",", ";", "!", "?"].contains(tokens[index].text)
                    && tokens[index - 1].language == language && tokens[index + 1].language == language
                    && vocabulary.isKnown(tokens[index - 1].text, language: language)
                    && vocabulary.isKnown(tokens[index + 1].text, language: language)
                    && tokens[index + 1].text.count >= 2
                {
                    tokens[index].text += " "
                    kinds.insert(.punctuation)
                }
            }

            if options.capitalization, input.sentenceStart, firstWordIsPlain,
                let index = tokens.firstIndex(where: \.isWord),
                index == 0 || tokens[0].text.allSatisfy({ "\"'(«".contains($0) }),
                let first = tokens[index].text.first, first.isLowercase
            {
                tokens[index].text = tokens[index].text.capitalizedFirst
                kinds.insert(.capitalization)
            }
        }

        var result = ChunkResult(
            text: tokens.map(\.text).joined(), language: sawWord ? language : nil, kinds: kinds)
        result.hasKnownWord = hasKnownWord
        if result.text == input.typed { result.kinds = [] }

        if options.punctuation, !protected, !input.sentenceStart, !input.previousWords.isEmpty,
            tokens.count == 1, let first = tokens.first, first.language == language
        {
            // The word after this one is not typed yet, so only rules that do not need it can fire.
            result.commaBefore = PunctuationRules.needsCommaBefore(
                word: first.text.lowercased(), next: nil, previous: input.previousWords, language: language)
            if result.commaBefore { result.kinds.insert(.punctuation) }
        }
        return result
    }
}
