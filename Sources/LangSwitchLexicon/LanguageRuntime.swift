import Foundation
import LangSwitchCore
import NaturalLanguage

/// The assembled language stack: dictionaries, letter models and the engines built on them.
///
/// One instance lives on the input executor. Building it reads the bundled dictionaries (tens of
/// milliseconds), so it is created once at start-up, off the main thread.
package final class LanguageRuntime {
    package let resources: CoreResources
    package let vocabulary: Vocabulary
    package let engine: CorrectionEngine
    package let fixer: TextFixer
    package let suggestions: SuggestionEngine
    package let completion: CompletionEngine
    /// False when Hunspell could not be loaded and only the frequency lists are available.
    package let hasFullDictionaries: Bool

    private let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])

    package init(personal: PersonalVocabulary = PersonalVocabulary(), dictionaryFolder: URL? = nil) {
        let resources = CoreResources.load()
        self.resources = resources

        let folder = dictionaryFolder ?? HunspellDictionary.bundledFolder
        let hunspell = try? HunspellDictionary(folder: folder)
        var expanders: [Language: AffixExpander] = [:]
        if let folder {
            for language in Language.allCases {
                expanders[language] = AffixExpander(
                    affix: HunspellDictionary.url(language, extension: "aff", in: folder),
                    dictionary: HunspellDictionary.url(language, extension: "dic", in: folder))
            }
        }

        let dictionary: any SpellingDictionary
        if let hunspell {
            dictionary = hunspell
            hasFullDictionaries = true
        } else {
            dictionary = WordSetDictionary(
                english: resources.frequency[.english]?.words ?? [],
                russian: resources.frequency[.russian]?.words ?? [])
            hasFullDictionaries = false
        }
        let vocabulary = Vocabulary(
            dictionary: dictionary, terms: resources.terms,
            frequency: resources.frequency,
            personal: personal)
        self.vocabulary = vocabulary
        if let hunspell {
            vocabulary.lemmatizer = { word, language in hunspell.stems(of: word, language: language) }
        }

        var models: [Language: NGramModel] = [:]
        for language in Language.allCases {
            var builder = NGramModel.Builder(language: language)
            expanders[language]?.stems(language: language) { builder.add($0) }
            // Everyday word forms carry the endings the stems lack, so they weigh more.
            let frequent = resources.frequency[language]?.words ?? []
            for (index, word) in frequent.enumerated() { builder.add(word, weight: index < 500 ? 40 : 12) }
            models[language] = builder.build()
        }

        let engine = CorrectionEngine(
            vocabulary: vocabulary, models: models, abbreviations: resources.abbreviations)
        self.engine = engine
        self.fixer = TextFixer(engine: engine)
        self.completion = CompletionEngine(frequency: resources.frequency, terms: resources.terms)

        let tagger = self.tagger
        let morphology = Morphology(
            lemmas: { word, language in
                var lemmas = hunspell?.stems(of: word, language: language) ?? []
                if lemmas.isEmpty,
                    let lemma = Self.tag(word, scheme: .lemma, language: language, tagger: tagger)
                {
                    lemmas.append(lemma)
                }
                return lemmas
            },
            forms: { lemma, language in expanders[language]?.forms(of: lemma) ?? [] },
            partOfSpeech: { word, language in
                switch Self.tag(word, scheme: .lexicalClass, language: language, tagger: tagger) {
                case NLTag.noun.rawValue: return .noun
                case NLTag.verb.rawValue: return .verb
                case NLTag.adjective.rawValue: return .adjective
                case NLTag.adverb.rawValue: return .adverb
                case .some: return .other
                case .none: return nil
                }
            })
        self.suggestions = SuggestionEngine(
            engine: engine, thesaurus: resources.thesaurus, morphology: morphology)
    }

    private static func tag(_ word: String, scheme: NLTagScheme, language: Language, tagger: NLTagger)
        -> String?
    {
        tagger.string = word
        tagger.setLanguage(language == .russian ? .russian : .english, range: word.startIndex..<word.endIndex)
        return tagger.tag(at: word.startIndex, unit: .word, scheme: scheme).0?.rawValue
    }
}
