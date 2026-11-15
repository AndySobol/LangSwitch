import Foundation
import LangSwitchCore
import Testing

@testable import LangSwitchLexicon

/// The grey completion measured on real sentences: how often what it shows is the word being typed,
/// and how many key presses it saves when accepted.
@Suite struct CompletionTests {
    struct Score {
        var shown = 0
        var right = 0
        var words = 0
        var helped = 0
        var keys = 0
        var saved = 0
        var precision: Double { Double(right) / Double(max(shown, 1)) }
        var helpedShare: Double { Double(helped) / Double(max(words, 1)) }
        var savedShare: Double { Double(saved) / Double(max(keys, 1)) }
    }

    static func score(
        _ language: Language, runtime: LanguageRuntime, usesContext: Bool,
        confidence: Float = CompletionEngine.confidence
    ) -> Score {
        var score = Score()
        for sentence in SentenceCorpus.sentences(language) {
            for word in SentenceCorpus.words(of: sentence, language: language) where !word.text.contains("-")
            {
                let letters = Array(word.text)
                score.words += 1
                // The word and the space after it.
                score.keys += letters.count + 1
                var accepted = false
                guard letters.count >= 5 else { continue }
                for length in 3...(letters.count - 2) {
                    let prefix = String(letters[..<length])
                    guard
                        let suggestion = runtime.completion.complete(
                            prefix: prefix, language: language, previous: usesContext ? word.previous : nil,
                            confidence: confidence)
                    else { continue }
                    score.shown += 1
                    guard suggestion.word.lowercased() == word.text.lowercased() else { continue }
                    score.right += 1
                    if !accepted {
                        accepted = true
                        score.helped += 1
                        // One press of Tab stands for the rest of the word.
                        score.saved += letters.count - length - 1
                    }
                }
            }
        }
        return score
    }

    @Test func completionOnRealSentences() {
        withRuntime { runtime in
            for language in Language.allCases {
                let plain = Self.score(language, runtime: runtime, usesContext: false)
                let score = Self.score(language, runtime: runtime, usesContext: true)
                print(
                    "completion \(language): shown \(score.shown), right \(score.precision), words helped "
                        + "\(score.helpedShare), keys saved \(score.savedShare) "
                        + "(without the previous word: right \(plain.precision), saved \(plain.savedShare))")
                // What is shown is the word being typed three times out of four, and the word before
                // it is what makes it so.
                #expect(score.precision >= 0.75)
                #expect(score.savedShare >= 0.08)
                #expect(score.savedShare > plain.savedShare * 1.5)
                if ProcessInfo.processInfo.environment["LANGSWITCH_SWEEP"] != nil {
                    for share in [Float(0.2), 0.3, 0.4, 0.5, 0.6] {
                        var shown = 0
                        var right = 0
                        var positions = 0
                        for sentence in SentenceCorpus.sentences(language) {
                            for word in SentenceCorpus.words(of: sentence, language: language) {
                                guard let previous = word.previous else { continue }
                                positions += 1
                                guard
                                    let next = runtime.completion.nextWord(
                                        after: previous, learning: LearningData(), language: language,
                                        minimumShare: share)
                                else { continue }
                                shown += 1
                                if next == word.text.lowercased() { right += 1 }
                            }
                        }
                        print(
                            "  next word, share \(share): shown \(shown) of \(positions), right "
                                + "\(Double(right) / Double(max(shown, 1)))")
                    }
                    for confidence in [Float(0.3), 0.4, 0.5, 0.6, 0.7] {
                        let sweep = Self.score(
                            language, runtime: runtime, usesContext: true, confidence: confidence)
                        print(
                            "  confidence \(confidence): shown \(sweep.shown), right \(sweep.precision), helped "
                                + "\(sweep.helpedShare), saved \(sweep.savedShare)")
                    }
                }
            }
        }
    }
}
