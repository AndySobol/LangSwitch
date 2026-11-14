import Foundation

/// A replacement offered for a word the user selected.
package struct WordSuggestion: Sendable, Equatable, Identifiable {
    package enum Kind: String, Sendable, Equatable {
        case spelling
        case layout
        case form
        case synonym
        case capitalization
    }

    package let text: String
    package let kind: Kind
    package var id: String { kind.rawValue + ":" + text }
}

package enum PartOfSpeech: String, Sendable, Equatable {
    case noun, verb
    case adjective = "adj"
    case adverb = "adv"
    case other
}

/// A small bundled thesaurus: lemma → synonyms grouped by part of speech.
package struct Thesaurus: Sendable {
    package struct Entry: Sendable, Equatable {
        package let partOfSpeech: PartOfSpeech
        package let synonyms: [String]
    }

    private let entries: [String: [Entry]]

    /// Parses `headword<TAB>pos<TAB>synonym, synonym, …` lines.
    package init(tsv: String = "") {
        var entries: [String: [Entry]] = [:]
        for line in tsv.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let synonyms = fields[2].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !synonyms.isEmpty else { continue }
            let part = PartOfSpeech(rawValue: String(fields[1])) ?? .other
            entries[fields[0].lowercased(), default: []].append(Entry(partOfSpeech: part, synonyms: synonyms))
        }
        self.entries = entries
    }

    package func entries(for lemma: String) -> [Entry] { entries[lemma.lowercased()] ?? [] }
    package var count: Int { entries.count }
}

/// Morphology the engine needs but cannot compute itself; the application plugs in Hunspell and
/// NaturalLanguage here.
package struct Morphology {
    /// Dictionary forms (lemmas) of a word, most likely first.
    package var lemmas: (_ word: String, _ language: Language) -> [String]
    /// All inflected forms of a lemma.
    package var forms: (_ lemma: String, _ language: Language) -> [String]
    /// Part of speech of a word, when it can be determined.
    package var partOfSpeech: (_ word: String, _ language: Language) -> PartOfSpeech?

    package init(
        lemmas: @escaping (String, Language) -> [String] = { _, _ in [] },
        forms: @escaping (String, Language) -> [String] = { _, _ in [] },
        partOfSpeech: @escaping (String, Language) -> PartOfSpeech? = { _, _ in nil }
    ) {
        self.lemmas = lemmas
        self.forms = forms
        self.partOfSpeech = partOfSpeech
    }
}

/// Builds the list shown when the user asks "what else could this word be?".
package struct SuggestionEngine {
    private let engine: CorrectionEngine
    private let thesaurus: [Language: Thesaurus]
    private let morphology: Morphology
    private let layouts: [KeyboardLayout]

    package init(
        engine: CorrectionEngine, thesaurus: [Language: Thesaurus] = [:],
        morphology: Morphology = Morphology(),
        layouts: [KeyboardLayout] = KeyboardLayout.builtIn
    ) {
        self.engine = engine
        self.thesaurus = thesaurus
        self.morphology = morphology
        self.layouts = layouts
    }

    private static func commonSuffix(_ left: String, _ right: String) -> Int {
        var count = 0
        for (a, b) in zip(left.reversed(), right.reversed()) {
            guard a == b else { break }
            count += 1
        }
        return count
    }

    /// Picks the form of `lemma` that best mirrors the grammatical form of `model` ("быстрого" → "скорого").
    private func inflect(_ lemma: String, like model: String, modelLemma: String, language: Language)
        -> String
    {
        guard model.lowercased() != modelLemma.lowercased() else { return lemma }
        let target = model.lowercased()
        var best = lemma
        var bestScore = Self.commonSuffix(lemma.lowercased(), target)
        for form in morphology.forms(lemma, language) {
            let score = Self.commonSuffix(form.lowercased(), target)
            if score > bestScore || score == bestScore && score > 0 && form.count < best.count {
                best = form
                bestScore = score
            }
        }
        return best
    }

    package func suggestions(for selection: String, limit: Int = 12) -> [WordSuggestion] {
        let word = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, word.count <= 40, !word.contains(where: \.isWhitespace),
            let language = Language.dominant(in: word)
        else { return [] }
        var result: [WordSuggestion] = []
        var seen: Set<String> = [word]
        func add(_ text: String, _ kind: WordSuggestion.Kind) {
            guard !text.isEmpty, seen.insert(text).inserted else { return }
            result.append(WordSuggestion(text: text, kind: kind))
        }

        let vocabulary = engine.vocabulary
        let knowledge = vocabulary.knowledge(of: word, language: language)
        let lettersOnly = word.allSatisfy { language.isLetter($0) || $0 == "-" || $0 == "'" }

        if let canonical = knowledge.canonical { add(canonical, .capitalization) }

        // The same keys on the other layout, when that spells something.
        if let source = layouts.first(where: { $0.language == language }),
            let target = layouts.first(where: { $0.language == language.other })
        {
            let converted = source.convert(word, to: target)
            let reading = engine.decider.reading(of: converted, language: language.other)
            if converted != word,
                reading.allKnown || !knowledge.isKnown && (reading.plausibility ?? -9) > -1.5
            {
                let fixed = Tokenizer.tokens(in: converted).map { token -> String in
                    guard token.isWord else { return token.text }
                    return vocabulary.knowledge(of: token.text, language: language.other).canonical
                        ?? token.text
                }.joined()
                add(fixed, .layout)
            }
        }

        guard lettersOnly else { return Array(result.prefix(limit)) }

        if !knowledge.isKnown {
            if let fixed = engine.speller.autoCorrection(for: word, language: language) {
                add(fixed, .spelling)
            }
            for candidate in engine.speller.candidates(for: word, language: language, deep: true).prefix(7) {
                add(matchCase(of: word, to: candidate.word), .spelling)
            }
        }

        // Synonyms, inflected like the selected word where the dictionary allows it.
        let lemmas = [word.lowercased()] + morphology.lemmas(word, language).map { $0.lowercased() }
        let part = morphology.partOfSpeech(word, language)
        var synonymCount = 0
        for lemma in lemmas {
            let entries = thesaurus[language]?.entries(for: lemma) ?? []
            // Prefer the entry of the detected part of speech; fall back to all of them.
            let matching = entries.filter { $0.partOfSpeech == part }
            for entry in matching.isEmpty ? entries : matching {
                for synonym in entry.synonyms where synonymCount < 8 {
                    let inflected = inflect(synonym, like: word, modelLemma: lemma, language: language)
                    add(matchCase(of: word, to: inflected), .synonym)
                    synonymCount += 1
                }
            }
        }

        // Other forms of the same word: cases, tenses, number.
        if knowledge.isKnown {
            var formCount = 0
            for lemma in morphology.lemmas(word, language).prefix(2) {
                if lemma.lowercased() != word.lowercased() {
                    add(matchCase(of: word, to: lemma), .form)
                    formCount += 1
                }
                let forms = morphology.forms(lemma, language)
                    .sorted {
                        Self.commonSuffix($0, word) == Self.commonSuffix($1, word)
                            ? $0.count < $1.count : Self.commonSuffix($0, word) > Self.commonSuffix($1, word)
                    }
                for form in forms where formCount < 8 {
                    add(matchCase(of: word, to: form), .form)
                    formCount += 1
                }
            }
        } else if result.isEmpty {
            for candidate in engine.speller.candidates(for: word, language: language, deep: true).prefix(5) {
                add(matchCase(of: word, to: candidate.word), .spelling)
            }
        }
        return Array(result.prefix(limit))
    }
}
