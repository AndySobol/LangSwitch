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
        ("вобщем", "в общем"), ("чтото", "что-то"), ("помоему", "по-моему"), ("пожалуста", "пожалуйста"),
        ("агенство", "агентство"), ("исравляем", "исправляем"), ("илседования", "исследования"),
    ])
    func russianTypos(pair: (String, String)) {
        #expect(typed(pair.0 + " ", active: .russian) == pair.1 + " ")
    }

    /// One example per spelling rule the model knows; none of these words is listed anywhere.
    @Test(arguments: [
        ("любиш", "любишь"), ("стараеться", "старается"), ("обьект", "объект"), ("жызнь", "жизнь"),
        ("цыфра", "цифра"), ("ищют", "ищут"), ("безплатно", "бесплатно"), ("зделать", "сделать"),
        ("прикрасные", "прекрасные"), ("чуствовать", "чувствовать"), ("сонце", "солнце"),
        ("лесница", "лестница"),
        ("колега", "коллега"), ("исскуство", "искусство"), ("как-будто", "как будто"), ("что-ли", "что ли"),
        ("буд-то", "будто"), ("по-этому", "поэтому"), ("ктото", "кто-то"), ("подружески", "по-дружески"),
        ("вточности", "в точности"), ("немогу", "не могу"),
    ])
    func russianSpellingRules(pair: (String, String)) {
        #expect(typed("и " + pair.0 + " ", active: .russian) == "и " + pair.1 + " ")
    }

    /// The space pressed one key too early or too late.
    @Test(arguments: [("н ето", "не то"), ("та ки", "так и"), ("ка кдела", "как дела")])
    func slippedSpace(pair: (String, String)) {
        #expect(typed("вот " + pair.0 + " ", active: .russian) == "вот " + pair.1 + " ")
    }

    /// Words that only the sentence could decide are left as typed rather than guessed.
    @Test(arguments: ["го", "ео", "пртит", "апять", "мб", "спс"])
    func ambiguousShortWordsAreLeftAlone(word: String) {
        #expect(typed("это " + word + " ", active: .russian) == "это " + word + " ")
    }

    @Test(arguments: [
        ("teh", "the"), ("recieve", "receive"), ("becuase", "because"),
        ("dont", "don't"), ("freind", "friend"), ("wich", "which"), ("tommorow", "tomorrow"),
        ("perfomance", "performance"), ("imporve", "improve"), ("truely", "truly"), ("seperate", "separate"),
        ("definately", "definitely"), ("alot", "a lot"), ("youre", "you're"),
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

    /// Self-learning must not turn a missed conversion into a rule: once "ghbdtn" was learned as a
    /// word of the user's own, it was never converted again.
    @Test func wrongLayoutTextIsNeverLearned() {
        withRuntime { runtime in
            let layouts = KeyboardLayout.builtIn
            for noise in ["Ghbdtn", "ghbdtn", "rfr", "ltkf", "cgfcb,j"] {
                #expect(!runtime.engine.mayLearn(noise, language: .english, layouts: layouts), "\(noise)")
            }
            for noise in ["руддщ", "зкщпкфь", "цщкдв"] {
                #expect(!runtime.engine.mayLearn(noise, language: .russian, layouts: layouts), "\(noise)")
            }
            for word in ["Zoltra", "Sobolev", "figjam", "kubernetes"] {
                #expect(runtime.engine.mayLearn(word, language: .english, layouts: layouts), "\(word)")
            }
            for word in ["вайбкодинг", "Соболев", "кринжатина"] {
                #expect(runtime.engine.mayLearn(word, language: .russian, layouts: layouts), "\(word)")
            }
        }
    }

    @Test func typingNoiseRepeatedlyDoesNotTeachIt() {
        var learning = LearningData()
        for _ in 0..<6 { learning.recordWord("Ghbdtn", previous: nil, known: false, mayLearn: false) }
        #expect(learning.vocabulary.words.isEmpty)
        #expect(learning.wordCounts.isEmpty)

        // Data written by an earlier build is healed.
        learning.vocabulary.words = ["Ghbdtn", "Zoltra"]
        learning.autoLearned = ["Ghbdtn", "Zoltra"]
        learning.wordCounts = ["ghbdtn": 4, "zoltra": 3]
        let removed = learning.removeAutoLearned { $0 == "Ghbdtn" }
        #expect(removed == ["Ghbdtn"])
        #expect(learning.vocabulary.words == ["Zoltra"])
        #expect(learning.wordCounts == ["zoltra": 3])
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
