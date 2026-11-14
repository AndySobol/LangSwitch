import LangSwitchCore
import Testing

@testable import LangSwitchLexicon

@Suite struct LayoutSwitchingTests {
    @Test func dictionariesLoad() {
        withRuntime { runtime in
            #expect(runtime.hasFullDictionaries)
            #expect(runtime.vocabulary.isKnown("привет", language: .russian))
            #expect(runtime.vocabulary.isKnown("работаю", language: .russian))
            #expect(runtime.vocabulary.isKnown("hello", language: .english))
            #expect(!runtime.vocabulary.isKnown("ghbdtn", language: .english))
            #expect(!runtime.vocabulary.isKnown("руддщ", language: .russian))
        }
    }

    @Test func greetingTypedOnLatinLayout() {
        // A whole Russian sentence typed without switching from ABC.
        let result = typeBlind("Привет, меня зовут Анна и я дизайнер в Москве! ", active: .abc)
        #expect(result == "Привет, меня зовут Анна и я дизайнер в Москве! ")
    }

    @Test func productNameSurvivesInsideRussianSentence() {
        // "Z hf,jnf. d figma e;t 12 ktn": every key pressed on ABC.
        let typed = withRuntime { runtime -> String in
            var simulator = TypingSimulator(engine: runtime.engine, active: .abc)
            simulator.press(keysFor: "Z hf,jnf. d figma e;t 12 ktn ", on: .abc)
            return simulator.document
        }
        #expect(typed == "Я работаю в Figma уже 12 лет ")
    }

    /// Short technical words typed without leaving the Russian layout, in the middle of Russian text.
    @Test func shortTermsInsideRussianTextAreConverted() {
        let sentence = "Ты можешь сразу выпустить dmg файл и запушить в git "
        #expect(typeBlind(sentence, active: .russian) == sentence)
        #expect(
            typeBlind("Надо обновить css и проверить api ", active: .russian)
                == "Надо обновить css и проверить api ")
    }

    /// Two letters are enough when they spell an everyday word of the other language.
    @Test func shortEverydayWordsAreConvertedInsideOtherText() {
        #expect(typeBlind("Надо составить to do список ", active: .russian) == "Надо составить to do список ")
        #expect(typeBlind("I think не надо ", active: .abc) == "I think не надо ")
    }

    /// Short Russian abbreviations and slang stay Russian: their keys do not spell an everyday English
    /// word or a known term of three letters, or the Russian word is common enough itself («ща» / "of").
    @Test(arguments: ["мск", "спс", "ки", "вк", "ща", "кек", "че"])
    func shortRussianTokensStay(word: String) {
        for lead in ["привет мир как дела ", ""] {
            let result = withRuntime { runtime -> String in
                var simulator = TypingSimulator(engine: runtime.engine, active: .russian)
                simulator.type(lead + word + " ")
                return simulator.document
            }
            #expect(!result.contains(where: { Language.english.isLetter($0) }), "\(result)")
        }
    }

    @Test func englishTypedOnRussianLayout() {
        #expect(typeBlind("hello world ", active: .russian) == "hello world ")
        #expect(typeBlind("please check the design ", active: .russian) == "please check the design ")
    }

    @Test(arguments: [
        "a.sobolev", "git", "GitLab", "Codex", "gmail", "figma.com", "https://example.org/figma",
        "getUserName", "user_name", "npm", "kubectl", "README.md", "v2", "h264", "@andy", "#design",
    ])
    func latinTokensAreNotConverted(token: String) {
        let result = withRuntime { runtime -> String in
            var simulator = TypingSimulator(
                engine: runtime.engine, active: .abc,
                options: CorrectionOptions(
                    layout: true, spelling: false, punctuation: false, capitalization: false))
            simulator.press(keysFor: token + " ", on: .abc)
            return simulator.document
        }
        #expect(result == token + " ")
    }

    @Test(arguments: [
        "The quick brown fox jumps over the lazy dog.",
        "Please review the pull request and let me know what you think.",
        "I will send the updated design tomorrow morning, thanks!",
        "We need to fix this bug before the release.",
    ])
    func correctEnglishIsLeftAlone(sentence: String) {
        #expect(typeBlind(sentence + " ", active: .abc) == sentence + " ")
    }

    @Test(arguments: [
        "Сегодня хорошая погода, пойдем гулять в парк.",
        "Я отправил макет на проверку, жду обратную связь.",
        "Давай созвонимся завтра и обсудим детали проекта.",
        "Мне нужно доделать задачу до конца недели.",
    ])
    func correctRussianIsLeftAlone(sentence: String) {
        #expect(typeBlind(sentence + " ", active: .russian) == sentence + " ")
    }

    @Test func mixedSentenceSwitchesBackAndForth() {
        let result = typeBlind("Открой Figma и проверь макет ", active: .russian)
        #expect(result == "Открой Figma и проверь макет ")
    }

    @Test func backspaceRightAfterConversionRestoresTypedText() {
        let result = withRuntime { runtime -> String in
            var simulator = TypingSimulator(engine: runtime.engine, active: .abc)
            simulator.backspaceUndoes = true
            simulator.press(keysFor: "ghbdtn ", on: .abc)
            #expect(simulator.document == "привет ")
            simulator.backspace()
            return simulator.document
        }
        #expect(result == "ghbdtn ")
    }

    @Test func obviousWordsAreConvertedBeforeTheSpace() {
        withRuntime { runtime in
            var simulator = TypingSimulator(engine: runtime.engine, active: .abc)
            simulator.press(keysFor: "прив", on: .russian)
            #expect(simulator.document == "прив")
            #expect(simulator.current.language == .russian)
            simulator.press(keysFor: "ет как дела ", on: .russian)
            #expect(simulator.document == "привет как дела ")
            #expect(simulator.replacements.count == 1)

            // English on the Russian layout, and a word with a "punctuation" letter.
            simulator = TypingSimulator(engine: runtime.engine, active: .russian)
            simulator.press(keysFor: "plea", on: .abc)
            #expect(simulator.document == "plea")
            simulator = TypingSimulator(engine: runtime.engine, active: .abc)
            simulator.press(keysFor: "рабо", on: .russian)
            #expect(simulator.document == "рабо")
        }
    }

    @Test(arguments: ["ghost", "rhythm", "html", "kubectl", "nginx", "sobolev", "xcode", "figma", "strength"])
    func latinWordsAreNotConvertedEarly(word: String) {
        withRuntime { runtime in
            var simulator = TypingSimulator(engine: runtime.engine, active: .abc)
            simulator.press(keysFor: word, on: .abc)
            #expect(simulator.document == word)
        }
    }

    @Test func manualConversionTogglesTheLastWord() {
        withRuntime { runtime in
            var simulator = TypingSimulator(engine: runtime.engine, active: .abc)
            simulator.press(keysFor: "sobolev", on: .abc)
            simulator.convertManually()
            #expect(simulator.document == "ыщищдум")
            #expect(simulator.current.language == .russian)
            simulator.convertManually()
            #expect(simulator.document == "sobolev")
        }
    }

    /// Coverage and safety on words the rules have never seen: every frequent word of one language,
    /// typed blind on the other layout, must come out right; typed on its own layout it must not change.
    @Test func frequentWordsRoundTrip() {
        withRuntime { runtime in
            let options = CorrectionOptions(
                layout: true, spelling: false, punctuation: false, capitalization: false)
            for (language, own, wrong) in [
                (Language.russian, KeyboardLayout.russian, KeyboardLayout.abc),
                (Language.english, KeyboardLayout.abc, KeyboardLayout.russian),
            ] {
                let words = (runtime.resources.frequency[language]?.words ?? []).prefix(2500)
                    .filter { $0.count >= 2 && $0.allSatisfy { language.isLetter($0) } }
                guard words.count > 500 else {
                    Issue.record("frequency list for \(language) is missing")
                    continue
                }
                var missed: [String] = []
                var damaged: [String] = []
                for word in words {
                    var blind = TypingSimulator(engine: runtime.engine, active: wrong, options: options)
                    blind.press(keysFor: word + " ", on: own)
                    if blind.document != word + " " { missed.append(word) }
                    var normal = TypingSimulator(engine: runtime.engine, active: own, options: options)
                    normal.press(keysFor: word + " ", on: own)
                    if normal.document != word + " " { damaged.append("\(word)→\(normal.document)") }
                }
                let coverage = 1 - Double(missed.count) / Double(words.count)
                print(
                    "\(language): coverage \(coverage), missed \(missed.prefix(40)), damaged \(damaged.prefix(40))"
                )
                #expect(coverage >= 0.97, "missed: \(missed.prefix(60))")
                #expect(
                    Double(damaged.count) / Double(words.count) <= 0.002, "damaged: \(damaged.prefix(60))")
            }
        }
    }
}
