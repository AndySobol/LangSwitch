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
        vocabulary: Vocabulary, models: [Language: NGramModel],
        misspellings: [Language: [String: String]] = [:], abbreviations: Set<String> = []
    ) {
        self.vocabulary = vocabulary
        self.decider = LayoutDecider(vocabulary: vocabulary, models: models)
        self.speller = SpellingCorrector(vocabulary: vocabulary, misspellings: misspellings)
        self.abbreviations = abbreviations
    }

    /// True when a chunk ends a sentence, so the next word starts with a capital letter.
    package func endsSentence(_ chunk: String) -> Bool {
        guard let last = chunk.last, ".!?…".contains(last) else { return false }
        let lower = chunk.lowercased()
        if abbreviations.contains(lower) { return false }
        // Initials and single letters: "А." or "e."
        let letters = lower.filter(\.isLetter)
        if last == "." && letters.count <= 1 { return false }
        // Dotted tokens such as "т.е." or "e.g." that the list does not mention.
        if last == "." && lower.dropLast().contains(".") && letters.count <= 4 { return false }
        return true
    }

    package func process(_ input: ChunkInput, options: CorrectionOptions) -> ChunkResult {
        var text = input.typed
        var language = input.typedLanguage
        var kinds: CorrectionKinds = []

        if options.layout, let alternative = input.alternative,
            decider.decide(
                typed: input.typed, typedLanguage: input.typedLanguage, alternative: alternative,
                context: input.context) == .convert
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
                if options.spelling, let fixed = speller.knownMisspelling(word, language: language) {
                    tokens[index].text = fixed
                    kinds.insert(.spelling)
                    hasKnownWord = true
                    if isFirst { firstWordIsPlain = true }
                    continue
                }
                let knowledge = vocabulary.knowledge(of: word, language: language)
                if knowledge.isKnown {
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
                if options.spelling, let fixed = speller.autoCorrection(for: word, language: language) {
                    tokens[index].text = fixed
                    kinds.insert(.spelling)
                    hasKnownWord = true
                    if isFirst { firstWordIsPlain = true }
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
