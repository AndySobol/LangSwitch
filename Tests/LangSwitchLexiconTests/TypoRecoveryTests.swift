import LangSwitchCore
import Testing

@testable import LangSwitchLexicon

/// Measures typo repair on words the rules have not seen: every frequent word is damaged in the three
/// ways a fast typist damages it (a dropped letter, two swapped letters, a doubled letter) and typed.
@Suite struct TypoRecoveryTests {
    private struct Tally {
        var total = 0
        var fixed = 0
        var wrong: [String] = []
        var fixedShare: Double { Double(fixed) / Double(max(total, 1)) }
        var wrongShare: Double { Double(wrong.count) / Double(max(total, 1)) }
    }

    private func damage(_ word: String, kind: Int, seed: Int) -> String? {
        var letters = Array(word)
        // An inner position chosen deterministically from the word itself.
        let position = 1 + (seed % max(letters.count - 2, 1))
        switch kind {
        case 0: letters.remove(at: position)
        case 1:
            guard letters[position] != letters[position - 1] else { return nil }
            letters.swapAt(position, position - 1)
        default: letters.insert(letters[position], at: position)
        }
        let result = String(letters)
        return result == word ? nil : result
    }

    @Test func frequentWordsWithTyposAreRepaired() {
        withRuntime { runtime in
            let names = ["dropped letter", "swapped letters", "doubled letter"]
            for (language, layout) in [
                (Language.russian, KeyboardLayout.russian), (Language.english, KeyboardLayout.abc),
            ] {
                let words = (runtime.resources.frequency[language]?.words ?? []).prefix(1300)
                    .filter { $0.count >= 6 && $0.allSatisfy { language.isLetter($0) } }
                var tallies = [Tally](repeating: Tally(), count: 3)
                for (index, word) in words.enumerated() {
                    for kind in 0..<3 {
                        guard let typo = damage(word, kind: kind, seed: index * 7 + kind),
                            !runtime.vocabulary.isKnown(typo, language: language)
                        else { continue }
                        var simulator = TypingSimulator(engine: runtime.engine, active: layout)
                        // A lower-case word in the middle of a sentence.
                        simulator.type((language == .russian ? "и " : "a ") + typo + " ")
                        let result = String(simulator.document.dropFirst(2).dropLast())
                        tallies[kind].total += 1
                        // "monday" coming back as "Monday" is a repair, not a miss.
                        if result.lowercased() == word {
                            tallies[kind].fixed += 1
                        } else if result != typo {
                            tallies[kind].wrong.append("\(typo)→\(result) (\(word))")
                        }
                    }
                }
                for kind in 0..<3 {
                    let tally = tallies[kind]
                    print(
                        "typos \(language) \(names[kind]): \(tally.total) cases, fixed \(tally.fixedShare), "
                            + "wrong \(tally.wrongShare) \(tally.wrong.prefix(12))")
                    #expect(tally.fixedShare >= (kind == 0 ? 0.78 : 0.95), "\(names[kind])")
                    // What remains "wrong" is a different valid reading of an ambiguous typo
                    // («твоми» → «твоим» rather than «твоими»), not damage.
                    #expect(tally.wrongShare <= 0.07, "\(tally.wrong.prefix(30))")
                }
            }
        }
    }

    @Test func sentenceOpeningTypoIsRepaired() {
        let result = withRuntime { runtime -> String in
            var simulator = TypingSimulator(engine: runtime.engine, active: .russian)
            simulator.type("Исравляем ли мы ошибки? ")
            return simulator.document
        }
        #expect(result == "Исправляем ли мы ошибки? ")
    }
}
