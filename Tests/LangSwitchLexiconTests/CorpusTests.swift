import Foundation
import LangSwitchCore
import Testing

@testable import LangSwitchLexicon

/// The engine measured on corpora it was not written against.
///
/// `Fixtures/typos-*.tsv` hold a few thousand `wrong<TAB>right` pairs, `Fixtures/colloquial-ru.txt`
/// modern colloquial word forms. They used to be shipped as tables of exceptions; now nothing in the
/// application reads them, and they only tell us how well the model generalises.
@Suite struct CorpusTests {
    struct Score {
        var total = 0
        var fixed = 0
        var wrong: [String] = []
        var fixedShare: Double { Double(fixed) / Double(max(total, 1)) }
        var wrongShare: Double { Double(wrong.count) / Double(max(total, 1)) }
    }

    static func fixture(_ name: String) -> [String] {
        guard let url = Bundle.module.resourceURL?.appendingPathComponent("Fixtures/" + name),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    static func typoPairs(_ language: Language) -> [(wrong: String, right: String)] {
        fixture("typos-\(language.rawValue).tsv").compactMap { line in
            let fields = line.split(separator: "\t").map(String.init)
            return fields.count == 2 ? (fields[0], fields[1]) : nil
        }
    }

    /// Runs every pair through the corrector the way typing would: lower case, middle of a sentence.
    static func score(_ pairs: [(wrong: String, right: String)], language: Language, runtime: LanguageRuntime)
        -> Score
    {
        var score = Score()
        for pair in pairs {
            let input = ChunkInput(typed: pair.wrong, typedLanguage: language)
            let result = runtime.engine.process(
                input,
                options: CorrectionOptions(
                    layout: false, spelling: true, punctuation: false, capitalization: true)
            ).text
            score.total += 1
            if result.lowercased() == pair.right.lowercased() {
                score.fixed += 1
            } else if result != pair.wrong {
                score.wrong.append("\(pair.wrong)→\(result) (\(pair.right))")
            }
        }
        return score
    }

    @Test func typoCorpus() {
        withRuntime { runtime in
            for language in Language.allCases {
                let pairs = Self.typoPairs(language)
                #expect(pairs.count > 1000)
                let score = Self.score(pairs, language: language, runtime: runtime)
                print(
                    "corpus \(language): \(score.total) typos, fixed \(score.fixedShare), wrong \(score.wrongShare) "
                        + "\(score.wrong.prefix(15))")
                // Leaving a typo alone is acceptable; changing it into the wrong word is the failure.
                #expect(score.wrongShare <= 0.01, "\(score.wrong.prefix(40))")
                #expect(score.fixedShare >= 0.76)
            }
        }
    }

    /// Words of modern usage that old dictionaries lack must survive untouched.
    @Test func colloquialWordsAreNotCorrected() {
        withRuntime { runtime in
            // Every fourth form keeps the unoptimised test run short.
            let words = Self.fixture("colloquial-ru.txt").filter { $0.count >= 3 }.enumerated()
                .filter { $0.offset % 4 == 0 }.map(\.element)
            #expect(words.count > 1500)
            var changed: [String] = []
            for word in words {
                let input = ChunkInput(typed: word, typedLanguage: .russian)
                let result = runtime.engine.process(input, options: CorrectionOptions(layout: false)).text
                if result != word { changed.append("\(word)→\(result)") }
            }
            let share = Double(changed.count) / Double(words.count)
            print("colloquial: \(words.count) forms, changed \(share) \(changed.prefix(40))")
            #expect(share <= 0.016, "\(changed.prefix(60))")
        }
    }
}

/// Whole sentences typed key by key, the way the application sees them.
@Suite struct SentenceTests {
    private static let layouts: [(Language, KeyboardLayout)] = [(.russian, .russian), (.english, .abc)]

    /// The generated data is tied to the frequency lists by a signature; a list edited without
    /// rebuilding the data would silently lose the context model.
    @Test func generatedDataIsInPlace() {
        withRuntime { runtime in
            #expect(runtime.resources.policy != nil)
            for language in Language.allCases {
                #expect(runtime.resources.context[language] != nil, "run LangSwitchData: see docs/DATA.md")
                #expect((runtime.resources.frequency[language]?.count ?? 0) > 40_000)
            }
        }
    }

    /// Correct text written by people must come out as it went in.
    @Test func realSentencesAreLeftAlone() {
        withRuntime { runtime in
            for (language, layout) in Self.layouts {
                let sentences = SentenceCorpus.sentences(language)
                #expect(sentences.count >= 1000)
                var changed: [String] = []
                for sentence in sentences {
                    var simulator = TypingSimulator(engine: runtime.engine, active: layout)
                    simulator.type(sentence + " ")
                    if simulator.document != sentence + " " {
                        changed.append("\(sentence) → \(simulator.document)")
                    }
                }
                let share = Double(changed.count) / Double(sentences.count)
                print(
                    "sentences \(language): \(sentences.count) typed, changed \(share) \(changed.prefix(25))")
                #expect(share <= 0.004, "\(changed.prefix(40))")
            }
        }
    }

    /// One slip of the hand per sentence: most are repaired, few are turned into another word.
    @Test func slipsInRealSentencesAreRepaired() {
        withRuntime { runtime in
            for (language, layout) in Self.layouts {
                let cases = SentenceCorpus.slips(language, runtime: runtime)
                var fixed = 0
                var untouched = 0
                var wrong: [String] = []
                for item in cases {
                    var simulator = TypingSimulator(engine: runtime.engine, active: layout)
                    simulator.type(item.mistyped + " ")
                    if simulator.document == item.sentence + " " {
                        fixed += 1
                    } else if simulator.document == item.mistyped + " " {
                        untouched += 1
                    } else {
                        wrong.append("\(item.mistyped) → \(simulator.document)")
                    }
                }
                let total = Double(max(cases.count, 1))
                print(
                    "slips \(language): \(cases.count) sentences, fixed \(Double(fixed) / total), untouched "
                        + "\(Double(untouched) / total), wrong \(Double(wrong.count) / total) \(wrong.prefix(25))"
                )
                #expect(Double(fixed) / total >= 0.7)
                #expect(Double(wrong.count) / total <= 0.03, "\(wrong.prefix(40))")
            }
        }
    }
}

/// Real sentences held out of the context model, and slips of the hand made in them on purpose.
enum SentenceCorpus {
    /// A deterministic random source: the measurements must not change from run to run.
    struct Random: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    struct Word {
        /// As written in the sentence, without the punctuation around it.
        var text: String
        /// The word before it in the same clause, lower case.
        var previous: String?
        var opensSentence: Bool
        /// Which space-separated piece of the sentence holds it.
        var chunk = 0
    }

    static func sentences(_ language: Language) -> [String] {
        CorpusTests.fixture("sentences-\(language.rawValue).txt")
    }

    static func words(of sentence: String, language: Language) -> [Word] {
        var result: [Word] = []
        var previous: String?
        for (index, chunk) in sentence.split(separator: " ").enumerated() {
            let word = chunk.trimmingCharacters(in: CharacterSet(charactersIn: ",.!?"))
            let closes = chunk.last.map { ",.!?".contains($0) } ?? false
            if word.isEmpty || !word.allSatisfy({ language.isLetter($0) || $0 == "-" }) {
                previous = nil
                continue
            }
            result.append(Word(text: word, previous: previous, opensSentence: index == 0, chunk: index))
            previous = closes ? nil : word.lowercased()
        }
        return result
    }

    private static let rows: [Language: [[Character]]] = [
        .english: ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map(Array.init),
        .russian: ["йцукенгшщзхъ", "фывапролджэ", "ячсмитьбю"].map(Array.init),
    ]

    private static func neighbour(of letter: Character, language: Language, using random: inout Random)
        -> Character?
    {
        for row in rows[language] ?? [] {
            guard let index = row.firstIndex(of: letter) else { continue }
            let options = [index - 1, index + 1].filter { row.indices.contains($0) }.map { row[$0] }
            return options.randomElement(using: &random)
        }
        return nil
    }

    /// One slip of a fast typist: a dropped letter, two letters swapped, a letter doubled, the next key
    /// hit instead of the right one, or together with it.
    static func slip(_ word: String, language: Language, using random: inout Random) -> String {
        var letters = Array(word)
        let position = Int.random(in: 0..<letters.count, using: &random)
        switch Int.random(in: 0..<100, using: &random) {
        case 0..<35:
            letters.remove(at: position)
        case 35..<65:
            let first = min(position, letters.count - 2)
            letters.swapAt(first, first + 1)
        case 65..<75:
            letters.insert(letters[position], at: position)
        case 75..<90:
            if let other = neighbour(of: letters[position], language: language, using: &random) {
                letters[position] = other
            }
        default:
            if let other = neighbour(of: letters[position], language: language, using: &random) {
                letters.insert(other, at: position)
            }
        }
        return String(letters)
    }

    struct Case {
        var typed: String
        var intended: String
        var previous: String?
        /// The sentence as written and as mistyped, when the case comes from one.
        var sentence = ""
        var mistyped = ""
    }

    /// One mistyped word per sentence; the result is never a real word.
    static func slips(_ language: Language, runtime: LanguageRuntime) -> [Case] {
        var random = Random(state: 20_261_114)
        var cases: [Case] = []
        for sentence in sentences(language) {
            let candidates = words(of: sentence, language: language).filter { word in
                word.text.count >= 3 && !word.text.contains("-")
                    && (word.text == word.text.lowercased() || word.opensSentence)
                    && runtime.vocabulary.isKnown(word.text.lowercased(), language: language)
            }
            guard let word = candidates.randomElement(using: &random) else { continue }
            let intended = word.text.lowercased()
            for _ in 0..<6 {
                var typed = slip(intended, language: language, using: &random)
                // Long words now and then collect two slips.
                if intended.count >= 8, Int.random(in: 0..<100, using: &random) < 20 {
                    typed = slip(typed, language: language, using: &random)
                }
                if typed != intended, typed.count >= 2, !runtime.vocabulary.isKnown(typed, language: language)
                {
                    var chunks = sentence.split(separator: " ").map(String.init)
                    chunks[word.chunk] = chunks[word.chunk].replacingOccurrences(
                        of: word.text, with: word.opensSentence ? typed.capitalizedFirst : typed)
                    cases.append(
                        Case(
                            typed: typed, intended: intended, previous: word.previous, sentence: sentence,
                            mistyped: chunks.joined(separator: " ")))
                    break
                }
            }
        }
        return cases
    }

    /// One slip in each of the commonest words, typed with nothing before them.
    static func slipsInFrequentWords(_ language: Language, runtime: LanguageRuntime) -> [Case] {
        var random = Random(state: 7_061_995)
        var cases: [Case] = []
        for word in (runtime.resources.frequency[language]?.core ?? []).prefix(2500)
        where word.count >= 3 && word.allSatisfy({ language.isLetter($0) }) {
            let typed = slip(word, language: language, using: &random)
            if typed != word, typed.count >= 2, !runtime.vocabulary.isKnown(typed, language: language) {
                cases.append(Case(typed: typed, intended: word, previous: nil))
            }
            // Long words also with two slips at once.
            guard word.count >= 8 else { continue }
            let twice = slip(
                slip(word, language: language, using: &random), language: language, using: &random)
            if twice != word, twice != typed, !runtime.vocabulary.isKnown(twice, language: language) {
                cases.append(Case(typed: twice, intended: word, previous: nil))
            }
        }
        return cases
    }

    /// Spelling mistakes from the typo corpus put where their words stand in real sentences, so that
    /// they are judged with the words around them as in real typing.
    static func mistakesInContext(_ language: Language) -> [Case] {
        var mistakes: [String: [String]] = [:]
        for pair in CorpusTests.typoPairs(language) where !pair.right.contains(" ") {
            mistakes[pair.right.lowercased(), default: []].append(pair.wrong.lowercased())
        }
        var used: [String: Int] = [:]
        var cases: [Case] = []
        for sentence in sentences(language) {
            for word in words(of: sentence, language: language) {
                let intended = word.text.lowercased()
                guard let options = mistakes[intended], used[intended, default: 0] < 3 else { continue }
                cases.append(
                    Case(
                        typed: options[used[intended, default: 0] % options.count], intended: intended,
                        previous: word.previous))
                used[intended, default: 0] += 1
            }
        }
        return cases
    }

    /// Words of the real sentences that the dictionaries do not know: nothing here is a typo.
    static func unknownWords(_ language: Language, runtime: LanguageRuntime) -> [Case] {
        var cases: [Case] = []
        for sentence in sentences(language) {
            // A capitalised first word may be a name, and nothing tells it from an ordinary word.
            for word in words(of: sentence, language: language) where word.text == word.text.lowercased() {
                let lower = word.text.lowercased()
                if !runtime.vocabulary.isKnown(lower, language: language) {
                    cases.append(Case(typed: lower, intended: lower, previous: word.previous))
                }
            }
        }
        return cases
    }
}

/// Dumps, for every corpus item, what the edit model proposes and what is known about each proposal.
/// The automatic-correction policy is chosen from these distributions, not from single words:
/// LANGSWITCH_ANALYSIS=<file> swift test -c release -Xswiftc -enable-testing --filter corpusAnalysis
@Suite struct CorpusAnalysis {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LANGSWITCH_ANALYSIS"] != nil))
    func corpusAnalysis() throws {
        let path = ProcessInfo.processInfo.environment["LANGSWITCH_ANALYSIS"] ?? ""
        let runtime = LanguageRuntime()
        var rows: [String] = ["corpus\tword\tright\tprevious\tauto\tplausibility\tcandidates"]
        func row(
            _ corpus: String, _ word: String, _ right: String, _ language: Language, previous: String? = nil
        ) {
            let speller = runtime.engine.speller
            let found = speller.candidates(for: word, language: language, after: previous)
            let auto = speller.autoCorrection(for: word, language: language, after: previous) ?? ""
            let listed = found.prefix(6).map { candidate -> String in
                let parts = candidate.word.components(separatedBy: " ")
                let form = parts.map { runtime.vocabulary.rank(of: $0, language: language) ?? -1 }
                let lemma = parts.map { runtime.vocabulary.commonness(of: $0, language: language) ?? -1 }
                return [
                    candidate.word, "\(candidate.edit)", "\(candidate.score)",
                    "\(form.contains(-1) ? -1 : form.max() ?? -1)",
                    "\(lemma.contains(-1) ? -1 : lemma.max() ?? -1)",
                    "\(candidate.followsPrevious)", "\(candidate.innerPair)",
                ].joined(separator: ":")
            }.joined(separator: "|")
            let own = runtime.engine.decider.models[language]?.plausibility(of: word) ?? 0
            rows.append(
                "\(corpus)\t\(word)\t\(right)\t\(previous ?? "")\t\(auto)\t\(own)\t\(found.count);\(listed)")
        }
        let leads = [
            "и", "в", "не", "на", "это", "я", "ты", "мы", "он", "у", "с", "а", "но", "как", "так", "вот",
        ]
        for language in Language.allCases {
            let code = language.rawValue
            for pair in CorpusTests.typoPairs(language) {
                row("typo-\(code)", pair.wrong.lowercased(), pair.right.lowercased(), language)
            }
            for item in SentenceCorpus.slips(language, runtime: runtime) {
                row("slip-\(code)", item.typed, item.intended, language, previous: item.previous)
            }
            for item in SentenceCorpus.slipsInFrequentWords(language, runtime: runtime) {
                row("frequent-\(code)", item.typed, item.intended, language)
            }
            for item in SentenceCorpus.mistakesInContext(language) {
                row("mistake-\(code)", item.typed, item.intended, language, previous: item.previous)
            }
            for item in SentenceCorpus.unknownWords(language, runtime: runtime) {
                row("clean-\(code)", item.typed, item.intended, language, previous: item.previous)
            }
            let common = Array(runtime.resources.frequency[language]?.words.prefix(40) ?? [])
            for (index, word) in CorpusTests.fixture("unlisted-\(code).txt").enumerated() {
                row(
                    "unlisted-\(code)", word, word, language,
                    previous: index % 2 == 0 ? nil : common[index % common.count])
            }
        }
        for (index, word) in CorpusTests.fixture("colloquial-ru.txt").enumerated() where word.count >= 2 {
            row("colloquial", word, word, .russian)
            if index % 3 == 0 {
                row("colloquial-after", word, word, .russian, previous: leads[index / 3 % leads.count])
            }
        }
        try rows.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// What the engine thinks about particular words; a word may be given with the one before it:
    /// LANGSWITCH_PROBE="попапе,включить ео,dont" swift test --filter probe
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LANGSWITCH_PROBE"] != nil))
    func probe() {
        let runtime = LanguageRuntime()
        for item in (ProcessInfo.processInfo.environment["LANGSWITCH_PROBE"] ?? "").split(separator: ",") {
            let fields = item.split(separator: " ").map(String.init)
            guard let word = fields.last else { continue }
            if let language = Language.dominant(in: word) {
                // The same keys on the other layout, and what the layout decision makes of them.
                let (from, to): (KeyboardLayout, KeyboardLayout) =
                    language == .russian ? (.russian, .abc) : (.abc, .russian)
                let other = from.convert(word, to: to)
                let decider = runtime.engine.decider
                let decision = decider.decide(
                    typed: word, typedLanguage: language, alternative: other, context: LayoutDecider.Context()
                )
                print(
                    "layout [\(word)] / [\(other)]: \(decision); typed \(decider.reading(of: word, language: language)); "
                        + "other \(decider.reading(of: other, language: language.other))")
            }
            let previous = fields.count > 1 ? fields[fields.count - 2] : nil
            let language = Language.dominant(in: word) ?? .english
            let speller = runtime.engine.speller
            let found = speller.candidates(for: word, language: language, after: previous).prefix(6)
                .map { "\($0.word) \($0.edit) \($0.score) ×\($0.followsPrevious)/\($0.innerPair)" }
                .joined(separator: "; ")
            let auto = speller.autoCorrection(for: word, language: language, after: previous) ?? "—"
            let known = runtime.vocabulary.knowledge(of: word, language: language)
            let confidence =
                speller.assessment(of: word, language: language, after: previous)?.confidence ?? 0
            print(
                "probe [\(item)] known=\(known.isKnown) rank=\(known.rank.map(String.init) ?? "—") auto=\(auto) "
                    + "confidence=\(confidence)")
            print("  candidates: \(found)")
        }
    }
}
