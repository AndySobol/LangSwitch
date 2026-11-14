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
                #expect(score.fixedShare >= (language == .russian ? 0.58 : 0.68))
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
            #expect(share <= 0.012, "\(changed.prefix(60))")
        }
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
        var rows: [String] = ["corpus\tword\tright\tplausibility\tauto\tcandidates"]
        func row(_ corpus: String, _ word: String, _ right: String, _ language: Language) {
            let found = runtime.engine.speller.candidates(for: word, language: language)
            let auto = runtime.engine.speller.autoCorrection(for: word, language: language) ?? ""
            let own = runtime.engine.decider.models[language]?.plausibility(of: word) ?? 0
            let listed = found.prefix(5).map { candidate -> String in
                let parts = candidate.word.components(separatedBy: " ")
                let form = parts.map { runtime.vocabulary.rank(of: $0, language: language) ?? -1 }
                let lemma = parts.map { runtime.vocabulary.commonness(of: $0, language: language) ?? -1 }
                return [
                    candidate.word, "\(candidate.edit)", "\(candidate.score)",
                    "\(form.contains(-1) ? -1 : form.max() ?? -1)",
                    "\(lemma.contains(-1) ? -1 : lemma.max() ?? -1)",
                ].joined(separator: ":")
            }.joined(separator: "|")
            rows.append("\(corpus)\t\(word)\t\(right)\t\(own)\t\(auto)\t\(found.count);\(listed)")
        }
        for language in Language.allCases {
            for pair in CorpusTests.typoPairs(language) {
                row("typo-\(language.rawValue)", pair.wrong.lowercased(), pair.right.lowercased(), language)
            }
        }
        for word in CorpusTests.fixture("colloquial-ru.txt") where word.count >= 3 {
            row("colloquial", word, word, .russian)
        }
        try rows.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// What the engine thinks about particular words: LANGSWITCH_PROBE="попапе,dont" swift test --filter probe
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LANGSWITCH_PROBE"] != nil))
    func probe() {
        let runtime = LanguageRuntime()
        for item in (ProcessInfo.processInfo.environment["LANGSWITCH_PROBE"] ?? "").split(separator: ",") {
            let word = String(item)
            let language = Language.dominant(in: word) ?? .english
            let found = runtime.engine.speller.candidates(for: word, language: language).prefix(6)
                .map { "\($0.word) \($0.edit) \($0.score)" }.joined(separator: "; ")
            let auto = runtime.engine.speller.autoCorrection(for: word, language: language) ?? "—"
            let known = runtime.vocabulary.knowledge(of: word, language: language)
            print(
                "probe [\(word)] known=\(known.isKnown) rank=\(known.rank.map(String.init) ?? "—") auto=\(auto)"
            )
            print("  candidates: \(found)")
        }
    }
}
