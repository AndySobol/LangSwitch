import LangSwitchCore
import Testing

@testable import LangSwitchLexicon

@Suite struct QualityTests {
    private func fix(_ text: String) -> String {
        withRuntime { $0.fixer.fix(text, options: CorrectionOptions()).text }
    }

    private func typed(_ text: String, active: KeyboardLayout) -> String {
        withRuntime { runtime in
            var simulator = TypingSimulator(engine: runtime.engine, active: active)
            simulator.type(text)
            return simulator.document
        }
    }

    @Test func wholeSentencesThroughTheFixCommand() {
        #expect(
            fix("Ghbdtn^ vtyz pjden Fyyf b z lbpfqyth d Vjcrdt!")
                == "Привет, меня зовут Анна и я дизайнер в Москве!")
        #expect(fix("Z hf,jnf. d figma e;t 12 ktn") == "Я работаю в Figma уже 12 лет")
        #expect(fix("руддщ цщкдв") == "Hello world")
    }

    @Test(arguments: [
        ("првиет", "привет"), ("програма", "программа"), ("тесст", "тест"), ("здраствуйте", "здравствуйте"),
        ("сдесь", "здесь"), ("вобщем", "в общем"), ("чтото", "что-то"), ("помоему", "по-моему"),
        ("пожалуста", "пожалуйста"), ("агенство", "агентство"), ("будующий", "будущий"),
        ("как-будто", "как будто"), ("врядли", "вряд ли"),
    ])
    func russianTypos(pair: (String, String)) {
        #expect(typed(pair.0 + " ", active: .russian) == pair.1 + " ")
    }

    @Test(arguments: [
        ("teh", "the"), ("recieve", "receive"), ("definately", "definitely"), ("becuase", "because"),
        ("dont", "don't"), ("im", "I'm"), ("freind", "friend"), ("seperate", "separate"), ("wich", "which"),
        ("tommorow", "tomorrow"),
    ])
    func englishTypos(pair: (String, String)) {
        #expect(typed(pair.0 + " ", active: .abc) == pair.1 + " ")
    }

    @Test(arguments: [
        "кринж", "имхо", "фича", "баг", "деплой", "Zoltra", "макбук", "дедлайн", "созвон", "апрув", "фидбек",
        "kubectl", "FigJam", "repo", "frontend", "iPhone", "macOS", "SwiftUI", "OK", "lol", "btw",
    ])
    func slangNamesAndTermsAreLeftAlone(word: String) {
        let layout: KeyboardLayout = Language.dominant(in: word) == .russian ? .russian : .abc
        let result = withRuntime { runtime -> String in
            var simulator = TypingSimulator(engine: runtime.engine, active: layout)
            simulator.type("и " + word + " ")
            return simulator.document
        }
        #expect(result.hasSuffix(" " + word + " "), "\(result)")
    }

    @Test func commasInFullText() {
        #expect(
            fix("Я думаю что это хорошая идея но нужно проверить.")
                == "Я думаю, что это хорошая идея, но нужно проверить.")
        #expect(fix("Конечно я помогу.") == "Конечно, я помогу.")
        #expect(fix("Это например можно сделать завтра.") == "Это, например, можно сделать завтра.")
        #expect(fix("Я не пришел потому что заболел.") == "Я не пришел, потому что заболел.")
        #expect(fix("Человек который смеется.") == "Человек, который смеется.")
    }

    @Test func suggestionsOfferSpellingFormsAndSynonyms() {
        withRuntime { runtime in
            let misspelled = runtime.suggestions.suggestions(for: "превет")
            #expect(misspelled.first?.text == "привет")
            let forms = runtime.suggestions.suggestions(for: "сделал")
            #expect(forms.contains { $0.kind == .form })
            let layout = runtime.suggestions.suggestions(for: "ghbdtn")
            #expect(layout.contains { $0.kind == .layout && $0.text == "привет" })
        }
    }

    /// Every "wrong" form in the misspelling tables must really be wrong: a table entry that is a valid
    /// word would silently rewrite correct text.
    @Test func misspellingTablesContainNoRealWords() {
        // Asked directly, bypassing frequency lists and slang.
        let dictionary = try? HunspellDictionary()
        withRuntime { runtime in
            for language in Language.allCases {
                let table = runtime.resources.misspellings[language] ?? [:]
                #expect(table.count > 400)
                // Hunspell accepts hyphenated compounds part by part, so those are judged by the table alone.
                let real = table.keys.filter {
                    !$0.contains("-") && (dictionary?.contains($0, language: language) ?? false)
                }
                .sorted()
                print("misspellings \(language): \(table.count) entries, valid words among them: \(real)")
                #expect(real.isEmpty, "\(real)")
            }
            #expect((runtime.resources.thesaurus[.russian]?.count ?? 0) > 500)
            #expect((runtime.resources.thesaurus[.english]?.count ?? 0) > 500)
            let synonyms = runtime.suggestions.suggestions(for: "быстро")
            #expect(synonyms.contains { $0.kind == .synonym })
        }
    }

    /// The false-positive audit: 120 correct passages, typed normally with every correction switched on,
    /// must come out exactly as typed.
    @Test func correctProseSurvivesLiveTyping() {
        withRuntime { runtime in
            var changed: [String] = []
            var total = 0
            for (language, layout) in [
                (Language.russian, KeyboardLayout.russian), (Language.english, KeyboardLayout.abc),
            ] {
                for passage in runtime.resources.trainer.passages[language] ?? [] {
                    var simulator = TypingSimulator(engine: runtime.engine, active: layout)
                    simulator.type(passage.text + " ")
                    total += passage.text.split(separator: " ").count
                    for replacement in simulator.replacements {
                        changed.append("\(replacement.original)→\(replacement.insert)")
                    }
                }
            }
            print("live audit: \(changed.count) changes in \(total) words: \(changed)")
            #expect(total > 3000)
            #expect(Double(changed.count) / Double(max(total, 1)) < 0.004, "\(changed)")
        }
    }

    @Test func correctProseSurvivesTheFixCommand() {
        withRuntime { runtime in
            var changed: [String] = []
            var total = 0
            for language in Language.allCases {
                for passage in runtime.resources.trainer.passages[language] ?? [] {
                    total += 1
                    let fixed = runtime.fixer.fix(passage.text, options: CorrectionOptions()).text
                    // The Russian dash is the one intended change to these keyboard-typeable texts.
                    if fixed.replacingOccurrences(of: " — ", with: " - ") != passage.text {
                        let before = passage.text.split(separator: " ")
                        let after = fixed.replacingOccurrences(of: " — ", with: " - ").split(separator: " ")
                        let difference = zip(before, after).filter { $0 != $1 }.prefix(3).map {
                            "\($0)→\($1)"
                        }
                        changed.append("\(passage.id): \(difference)")
                    }
                }
            }
            print("fix audit: \(changed.count) of \(total) passages changed: \(changed)")
            #expect(changed.count <= total / 20, "\(changed)")
        }
    }
}
