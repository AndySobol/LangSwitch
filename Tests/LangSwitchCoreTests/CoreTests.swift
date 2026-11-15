import Foundation
import Testing

@testable import LangSwitchCore

/// A small self-contained engine: no bundled dictionaries, so these tests exercise mechanisms only.
private func makeEngine(personal: PersonalVocabulary = PersonalVocabulary()) -> CorrectionEngine {
    let russian = [
        "привет", "мир", "как", "дела", "я", "в", "и", "работаю", "уже", "лет", "слово", "слове", "тест",
        "что",
        "сказал", "он", "придет", "дом", "котором", "живу", "знаю", "хорошо", "но", "поздно", "это", "Андрей",
        "меня",
        "зовут", "программа", "чтобы", "успеть", "встал", "рано", "не", "то", "его",
    ]
    let english = [
        "hello", "world", "the", "design", "a", "is", "and", "you", "figma", "git", "test", "receive",
        "which",
        "apple", "car", "an", "user", "however", "we", "can", "wait", "John", "it", "works", "st",
    ]
    let dictionary = WordSetDictionary(english: english, russian: russian)
    let frequency: [Language: FrequencyList] = [
        .russian: FrequencyList(words: russian.map { $0.lowercased() }),
        .english: FrequencyList(words: english.map { $0.lowercased() }),
    ]
    let terms = TermLexicon([
        Term(canonical: "Figma", restoresCase: true), Term(canonical: "git", restoresCase: false),
        Term(canonical: "Node.js", restoresCase: true), Term(canonical: "rb", restoresCase: false),
    ])
    let vocabulary = Vocabulary(
        dictionary: dictionary, terms: terms, frequency: frequency, personal: personal)
    let models: [Language: NGramModel] = [
        .russian: NGramModel(language: .russian, words: russian.map { ($0.lowercased(), Float(1)) }),
        .english: NGramModel(language: .english, words: english.map { ($0.lowercased(), Float(1)) }),
    ]
    return CorrectionEngine(
        vocabulary: vocabulary, models: models,
        abbreviations: ["т.е.", "e.g."], policy: CoreResources.load(generated: false).policy)
}

/// `#expect` cannot wrap a mutating call, so the call is evaluated first and compared here.
private func check<T: Equatable>(_ value: T, _ expected: T, sourceLocation: SourceLocation = #_sourceLocation)
{
    #expect(value == expected, sourceLocation: sourceLocation)
}

@Suite struct KeyboardLayoutTests {
    @Test func convertsBetweenLayoutsByPhysicalKey() {
        #expect(KeyboardLayout.abc.convert("ghbdtn", to: .russian) == "привет")
        #expect(KeyboardLayout.russian.convert("руддщ", to: .abc) == "hello")
        #expect(KeyboardLayout.abc.convert("Ghbdtn^ vtyz", to: .russian) == "Привет, меня")
        #expect(KeyboardLayout.abc.convert("hf,jnf.", to: .russian) == "работаю")
    }

    @Test func conversionIsReversibleForLetters() {
        for word in ["привет", "Андрей", "съезд", "ёжик", "ЭЮЯ"] {
            let latin = KeyboardLayout.russian.convert(word, to: .abc)
            #expect(KeyboardLayout.abc.convert(latin, to: .russian) == word)
        }
    }

    @Test func pcLayoutDiffersInPunctuation() {
        #expect(KeyboardLayout.abc.convert("?", to: .russianPC) == ",")
        #expect(KeyboardLayout.abc.convert("?", to: .russian) == "?")
    }

    @Test func capsLockAffectsLettersOnly() {
        let layout = KeyboardLayout.abc
        #expect(layout.character(for: KeyStroke(keyCode: 0, capsLock: true)) == "A")
        // On macOS Shift does not cancel Caps Lock.
        #expect(layout.character(for: KeyStroke(keyCode: 0, shift: true, capsLock: true)) == "A")
        #expect(layout.character(for: KeyStroke(keyCode: 18, capsLock: true)) == "1")
    }
}

@Suite struct TokenizerTests {
    @Test func tokensJoinBackToTheOriginal() {
        for text in ["Привет, мир!", "don't stop-me", "что-то 12 лет", "mixed слово text", ""] {
            #expect(Tokenizer.tokens(in: text).map(\.text).joined() == text)
        }
    }

    @Test func wordsKeepInnerHyphensAndApostrophes() {
        #expect(
            Tokenizer.words(in: "don't кто-то well-known", language: .english) == ["don't", "well-known"])
        #expect(Tokenizer.words(in: "don't кто-то", language: .russian) == ["кто-то"])
    }

    @Test(arguments: [
        "https://example.org", "a.sobolev@example.com", "user_name", "getUserName", "h264", "./build.sh",
        "#tag", "@andy",
        "path/to/file", "--flag",
    ])
    func protectedText(chunk: String) {
        #expect(TextProtection.isProtected(chunk))
    }

    @Test(arguments: ["hello", "привет,", "@ghbdtn@", "x\\v", "don't", "e;t"])
    func ordinaryText(chunk: String) {
        #expect(!TextProtection.isProtected(chunk))
    }
}

@Suite struct TypingSessionTests {
    @Test func convertsAndSwitchesLayout() {
        var simulator = TypingSimulator(engine: makeEngine())
        simulator.press(keysFor: "привет мир ", on: .russian)
        #expect(simulator.document == "привет мир ")
        #expect(simulator.current.language == .russian)
        #expect(simulator.replacements.count == 1)
    }

    @Test func backspaceUndoRestoresTextAndLayout() {
        var simulator = TypingSimulator(engine: makeEngine())
        simulator.backspaceUndoes = true
        simulator.press(keysFor: "привет ", on: .russian)
        simulator.backspace()
        #expect(simulator.document == "ghbdtn ")
        #expect(simulator.current.language == .english)
        // After the undo, Backspace is an ordinary Backspace again.
        simulator.backspace()
        #expect(simulator.document == "ghbdtn")
    }

    @Test func editingInsideAChunkWithBackspace() {
        var simulator = TypingSimulator(engine: makeEngine(), active: .russian)
        simulator.type("привее")
        simulator.backspace()
        simulator.type("т ")
        #expect(simulator.document == "привет ")
        #expect(simulator.replacements.isEmpty)
    }

    @Test func retypingAfterErasingEverythingStillConverts() {
        // Type, erase further back than the session saw, type again: the layout must still be fixed.
        var simulator = TypingSimulator(engine: makeEngine())
        simulator.backspace()
        simulator.backspace()
        simulator.press(keysFor: "привет ", on: .russian)
        #expect(simulator.document == "привет ")

        // Spelling is not guessed for a chunk that may be the tail of an existing word …
        simulator = TypingSimulator(engine: makeEngine(), active: .russian)
        simulator.backspace()
        simulator.type("тесст ")
        #expect(simulator.document == "тесст ")
        // … but the next word is a whole word again.
        simulator.type("тесст ")
        #expect(simulator.document == "тесст тест ")
    }

    @Test func sessionFollowsTheKeyboardWhenALayoutNoticeIsLost() {
        // The system is on ABC but nobody told the session, which still believes Russian.
        var simulator = TypingSimulator(engine: makeEngine(), active: .russian)
        simulator.switchLayoutSilently(to: .abc)
        simulator.press(keysFor: "привет мир ", on: .russian)
        #expect(simulator.document == "привет мир ")
        #expect(simulator.current.language == .russian)

        // And the other way round: the session believes ABC, the system is on Russian.
        simulator = TypingSimulator(engine: makeEngine(), active: .abc)
        simulator.switchLayoutSilently(to: .russian)
        simulator.press(keysFor: "hello ", on: .abc)
        #expect(simulator.document == "hello ")
    }

    @Test func spaceThatSlippedByOneLetterIsRepaired() {
        var simulator = TypingSimulator(engine: makeEngine(), active: .russian)
        simulator.type("это н ето что ")
        #expect(simulator.document == "это не то что ")
        // Backspace right after it restores what was typed.
        // Double Shift right after it restores what was typed.
        simulator = TypingSimulator(engine: makeEngine(), active: .russian)
        simulator.type("н ето ")
        simulator.convertManually()
        #expect(simulator.document == "н ето ")
    }

    @Test func technicalTokenDoesNotSwallowAFragment() {
        // «ки» typed in Russian text must not become the Ruby extension "rb".
        var simulator = TypingSimulator(
            engine: makeEngine(), active: .russian, options: CorrectionOptions(spelling: false))
        simulator.type("привет мир ки ")
        #expect(simulator.document == "привет мир ки ")
    }

    @Test func backspaceAfterACorrectionIsJustBackspace() {
        // Deleting the space after a converted word must not turn the word back into gibberish.
        var simulator = TypingSimulator(engine: makeEngine())
        simulator.press(keysFor: "привет ", on: .russian)
        simulator.backspace()
        #expect(simulator.document == "привет")
        simulator.press(keysFor: " мир ", on: .russian)
        #expect(simulator.document == "привет мир ")
    }

    @Test func doubleShiftUndoesTheLastCorrection() {
        var simulator = TypingSimulator(engine: makeEngine(), active: .russian)
        simulator.type("тесст ")
        #expect(simulator.document == "тест ")
        simulator.convertManually()
        #expect(simulator.document == "тесст ")

        simulator = TypingSimulator(engine: makeEngine())
        simulator.press(keysFor: "привет ", on: .russian)
        simulator.convertManually()
        #expect(simulator.document == "ghbdtn ")
        #expect(simulator.current.language == .english)
    }

    @Test func extraSpacesDoNotConfuseTheCount() {
        // "мир␣␣⌫": one space is still there; the next word must be handled on its own.
        var simulator = TypingSimulator(engine: makeEngine(), active: .russian)
        simulator.type("мир  ")
        simulator.backspace()
        simulator.switchLayoutSilently(to: .abc)
        simulator.press(keysFor: "привет ", on: .russian)
        #expect(simulator.document == "мир привет ")
    }

    @Test func erasedEarlyConversionLeavesNoTrace() {
        // Convert early, erase the word, type another: nothing of the first decision may linger.
        var simulator = TypingSimulator(engine: makeEngine())
        simulator.backspaceUndoes = true
        simulator.press(keysFor: "прив", on: .russian)
        for _ in 0..<4 { simulator.backspace() }
        simulator.type("мир ")
        simulator.backspace()
        #expect(simulator.document == "мир")
        #expect(simulator.current.language == .russian)
    }

    @Test func shortWordIsConvertedOnceTheNextWordProvesTheLayout() {
        // «и» typed as "b" after English words is ambiguous alone; «привет» after it settles both.
        var simulator = TypingSimulator(engine: makeEngine())
        simulator.type("hello world ")
        simulator.press(keysFor: "и привет ", on: .russian)
        #expect(simulator.document == "hello world и привет ")
    }

    @Test func shortRussianWordsInRussianTextStay() {
        // «ки» reads as the Ruby extension "rb"; inside Russian text it is not Ruby.
        // Spelling is off: the handful of words in this test vocabulary would make «ки» a typo of «и».
        var simulator = TypingSimulator(
            engine: makeEngine(), active: .russian, options: CorrectionOptions(spelling: false))
        simulator.type("привет мир как дела ки ")
        #expect(simulator.document == "привет мир как дела ки ")
        #expect(simulator.current.language == .russian)
    }

    @Test func tailTypedAfterAClickIsNotTreatedAsAWord() {
        // The caret was placed after «красн»; the typed «ые» is a tail, not the English "st".
        var simulator = TypingSimulator(engine: makeEngine(), active: .russian)
        simulator.click()
        simulator.type("ые ")
        #expect(simulator.document == "ые ")
        // A whole wrong-layout word after a click is still converted.
        simulator = TypingSimulator(engine: makeEngine())
        simulator.click()
        simulator.press(keysFor: "привет ", on: .russian)
        #expect(simulator.document == "привет ")
    }

    @Test func manualLayoutSwitchInsideAWordDisablesCorrection() {
        var simulator = TypingSimulator(engine: makeEngine())
        simulator.press(keysFor: "при", on: .russian)
        simulator.switchLayout(to: .russian)
        simulator.type("вет ")
        #expect(simulator.document == "ghbвет ")
    }

    @Test func nothingHappensWhenEverythingIsDisabled() {
        var simulator = TypingSimulator(engine: makeEngine(), options: .none)
        simulator.press(keysFor: "привет ", on: .russian)
        #expect(simulator.document == "ghbdtn ")
    }

    @Test func personalRulesOverrideTheDecision() {
        var personal = PersonalVocabulary()
        personal.keepAsTyped.insert("ghbdtn")
        var simulator = TypingSimulator(engine: makeEngine(personal: personal))
        simulator.press(keysFor: "привет ", on: .russian)
        #expect(simulator.document == "ghbdtn ")
    }

    @Test func commaIsInsertedBeforeTheConjunction() {
        var simulator = TypingSimulator(engine: makeEngine(), active: .russian)
        simulator.type("он сказал что придет ")
        #expect(simulator.document == "он сказал, что придет ")
        simulator = TypingSimulator(engine: makeEngine(), active: .russian)
        simulator.type("хорошо но поздно ")
        #expect(simulator.document == "хорошо, но поздно ")
    }

    @Test func commaInsertionCanBeUndone() {
        var simulator = TypingSimulator(engine: makeEngine(), active: .russian)
        simulator.backspaceUndoes = true
        simulator.type("он сказал что ")
        #expect(simulator.document == "он сказал, что ")
        simulator.backspace()
        #expect(simulator.document == "он сказал что ")
    }

    @Test func sentencesStartWithACapitalLetter() {
        var simulator = TypingSimulator(engine: makeEngine(), active: .russian)
        simulator.type("привет. как дела ")
        #expect(simulator.document == "привет. Как дела ")
    }

    @Test func abbreviationsDoNotEndASentence() {
        let engine = makeEngine()
        #expect(!engine.endsSentence("т.е."))
        #expect(!engine.endsSentence("e.g."))
        #expect(!engine.endsSentence("А."))
        #expect(engine.endsSentence("привет."))
        #expect(engine.endsSentence("really?"))
    }

    @Test func termsAndProperNounsGetTheirCase() {
        var simulator = TypingSimulator(engine: makeEngine())
        simulator.type("figma and john ")
        #expect(simulator.document == "Figma and John ")
    }

    @Test func typosAreFixed() {
        var simulator = TypingSimulator(engine: makeEngine(), active: .russian)
        simulator.type("прогармма тесст ")
        #expect(simulator.document == "программа тест ")
        simulator = TypingSimulator(engine: makeEngine())
        simulator.type("teh desgin ")
        #expect(simulator.document == "the design ")
    }

    @Test func doubledCapitalIsRepaired() {
        var simulator = TypingSimulator(engine: makeEngine(), active: .russian)
        simulator.type("ПРивет ")
        #expect(simulator.document == "Привет ")
    }

    @Test func manualConversionOfTheFinishedWord() {
        var simulator = TypingSimulator(engine: makeEngine())
        simulator.type("zoltra ")
        simulator.convertManually()
        #expect(simulator.document == "ящдекф ")
        simulator.convertManually()
        #expect(simulator.document == "zoltra ")
    }
}

@Suite struct PunctuationTests {
    @Test func spacingIsNormalised() {
        #expect(TextFixer.fixSpacing("Привет ,  мир !") == "Привет, мир!")
        #expect(TextFixer.fixSpacing("это - тест") == "это — тест")
        #expect(TextFixer.fixSpacing("  indented   line") == "  indented line")
        #expect(TextFixer.fixSpacing("ok :) fine") == "ok :) fine")
        #expect(TextFixer.fixSpacing("open .gitignore now") == "open .gitignore now")
    }

    @Test func fullTextFixAddsCommasAndCapitals() {
        let fixer = TextFixer(engine: makeEngine())
        #expect(
            fixer.fix("я знаю что он придет", options: CorrectionOptions()).text == "Я знаю, что он придет")
        #expect(
            fixer.fix("дом в котором я живу", options: CorrectionOptions()).text == "Дом, в котором я живу")
        #expect(
            fixer.fix("встал рано чтобы успеть", options: CorrectionOptions()).text
                == "Встал рано, чтобы успеть")
        #expect(fixer.fix("however we can wait", options: CorrectionOptions()).text == "However, we can wait")
        #expect(
            fixer.fix("it is a apple and an car", options: CorrectionOptions()).text
                == "It is an apple and a car")
    }

    @Test func correctTextIsUntouched() {
        let fixer = TextFixer(engine: makeEngine())
        for text in ["Я знаю, что он придет.", "Hello, world!", "Привет, как дела?"] {
            #expect(fixer.fix(text, options: CorrectionOptions()).text == text)
        }
    }

    @Test func fixIsIdempotent() {
        let fixer = TextFixer(engine: makeEngine())
        let once = fixer.fix("ghbdtn vbh? я знаю что он придет", options: CorrectionOptions()).text
        #expect(fixer.fix(once, options: CorrectionOptions()).text == once)
    }

    @Test func articles() {
        #expect(PunctuationRules.indefiniteArticle(before: "apple") == "an")
        #expect(PunctuationRules.indefiniteArticle(before: "user") == "a")
        #expect(PunctuationRules.indefiniteArticle(before: "hour") == "an")
        #expect(PunctuationRules.indefiniteArticle(before: "university") == "a")
        #expect(PunctuationRules.indefiniteArticle(before: "uninstall") == "an")
        #expect(PunctuationRules.indefiniteArticle(before: "API") == nil)
    }
}

@Suite struct LearningTests {
    @Test func wordThatComesBackOnAnotherDayIsAdopted() {
        var learning = LearningData()
        check(learning.recordWord("Zoltra", previous: nil, known: false, day: 100), nil)
        #expect(learning.watched.map(\.spelling) == ["Zoltra"])
        check(learning.recordWord("Zoltra", previous: nil, known: false, day: 101), "Zoltra")
        #expect(learning.vocabulary.knows("zoltra") == "Zoltra")
        #expect(learning.autoLearned.contains("Zoltra"))
        #expect(learning.watched.isEmpty)
    }

    @Test func aBurstOnOneDayHasToBeLonger() {
        // The same unknown string four times in a row is as likely a typo being fought with.
        var learning = LearningData()
        for _ in 0..<4 { check(learning.recordWord("могну", previous: nil, known: false, day: 100), nil) }
        check(learning.recordWord("могну", previous: nil, known: false, day: 100), "могну")
    }

    @Test func doubtfulWordHasToProveMore() {
        // A word that looks like a slip of a known one: two days are not enough, three are.
        var learning = LearningData()
        for day in 100...101 {
            check(learning.recordWord("могну", previous: nil, known: false, doubtful: true, day: day), nil)
        }
        #expect(learning.watched.first?.isDoubtful == true)
        check(learning.recordWord("могну", previous: nil, known: false, doubtful: true, day: 102), "могну")
    }

    @Test func twoLetterWordIsAlwaysDoubtful() {
        var learning = LearningData()
        for _ in 0..<9 { check(learning.recordWord("bk", previous: nil, known: false, day: 100), nil) }
        check(learning.recordWord("bk", previous: nil, known: false, day: 101), "bk")
        // Too short to drive completions.
        #expect(learning.wordCounts["bk"] == nil)
    }

    @Test func removedWordIsNotLearnedAgain() {
        var learning = LearningData()
        _ = learning.recordWord("оки-доки", previous: nil, known: false, day: 100)
        check(learning.recordWord("оки-доки", previous: nil, known: false, day: 101), "оки-доки")
        learning.removeWord("оки-доки")
        #expect(learning.vocabulary.words.isEmpty)
        #expect(learning.declined == ["оки-доки"])
        for day in 102...110 {
            check(learning.recordWord("оки-доки", previous: nil, known: false, day: day), nil)
        }
        #expect(learning.watched.isEmpty)
        // Adding it by hand lifts the ban.
        learning.addWord("оки-доки")
        #expect(learning.declined.isEmpty)
        #expect(learning.vocabulary.knows("оки-доки") != nil)
    }

    @Test func watchedWordCanBeAdoptedOrDeclinedByHand() {
        var learning = LearningData()
        _ = learning.recordWord("Zoltra", previous: nil, known: false, day: 100)
        _ = learning.recordWord("кринжово", previous: nil, known: false, day: 100)
        learning.adopt("zoltra")
        #expect(learning.vocabulary.words == ["Zoltra"])
        // Chosen by the user, not picked up by the application.
        #expect(learning.autoLearned.isEmpty)
        learning.decline("кринжово")
        #expect(learning.watched.isEmpty)
        #expect(learning.declined == ["кринжово"])
    }

    @Test func staleObservationsAreForgotten() {
        var learning = LearningData()
        _ = learning.recordWord("Zoltra", previous: nil, known: false, day: 100)
        learning.forgetStaleObservations(day: 130)
        #expect(learning.watched.count == 1)
        learning.forgetStaleObservations(day: 200)
        #expect(learning.watched.isEmpty)
    }

    @Test func countsOfEarlierBuildsBecomeObservations() throws {
        let old = #"{"unknownCounts": {"zoltra": 2}}"#
        let learning = try JSONDecoder().decode(LearningData.self, from: Data(old.utf8))
        #expect(learning.watched.first?.spelling == "zoltra")
        #expect(learning.watched.first?.count == 2)
        let again = try JSONDecoder().decode(LearningData.self, from: JSONEncoder().encode(learning))
        #expect(again == learning)
    }

    @Test func twoUndosBecomeARule() {
        var learning = LearningData()
        check(learning.recordRejection(typed: "Ghbdtn"), false)
        check(learning.recordRejection(typed: "ghbdtn"), true)
        #expect(learning.vocabulary.keepAsTyped.contains("ghbdtn"))
    }

    @Test func twoManualConversionsBecomeARule() {
        var learning = LearningData()
        _ = learning.recordManualConversion(typed: "zoltra")
        check(learning.recordManualConversion(typed: "zoltra"), true)
        #expect(learning.vocabulary.alwaysConvert.contains("zoltra"))
    }

    @Test func survivesEncodingAndOldFiles() throws {
        var learning = LearningData()
        learning.recordWord("привет", previous: "всем", known: true)
        learning.recordTypo(corrected: "программа")
        let decoded = try JSONDecoder().decode(LearningData.self, from: JSONEncoder().encode(learning))
        #expect(decoded == learning)
        // A file written by an older version, with fields missing.
        let partial = try JSONDecoder().decode(LearningData.self, from: Data("{}".utf8))
        #expect(partial == LearningData())
    }

    @Test func digitsAndFragmentsAreNotLearned() {
        #expect(!LearningData.isLearnable("a"))
        #expect(LearningData.isLearnable("bk"))
        #expect(!LearningData.isLearnable("pass123"))
        #expect(!LearningData.isLearnable("-word"))
        #expect(LearningData.isLearnable("кто-то"))
    }
}

@Suite struct CompletionTests {
    private let engine = CompletionEngine(frequency: [
        .russian: FrequencyList(words: ["привет", "пожалуйста", "проект", "проверить"]),
        .english: FrequencyList(words: ["please", "project", "design"]),
    ])

    @Test func completesFromTheFrequencyList() {
        #expect(engine.complete(prefix: "пожа", language: .russian)?.remainder == "луйста")
        #expect(engine.complete(prefix: "Про", language: .russian)?.word == "Проект")
        #expect(engine.complete(prefix: "PLE", language: .english)?.remainder == "ASE")
    }

    @Test func staysQuietWhenNothingFits() {
        #expect(engine.complete(prefix: "пр", language: .russian) == nil)
        #expect(engine.complete(prefix: "ghb", language: .english) == nil)
        // One letter left: not worth a hint.
        #expect(engine.complete(prefix: "приве", language: .russian) == nil)
    }

    @Test func unsuitableWordsAreOfferedOnlyToTheirOwner() {
        let engine = CompletionEngine(
            frequency: [.russian: FrequencyList(words: ["проект"], extended: ["проклятье"])],
            unsuitable: [.russian: ["проклятье"]])
        #expect(engine.complete(prefix: "прок", language: .russian) == nil)
        var learning = LearningData()
        learning.addWord("проклятье")
        #expect(engine.complete(prefix: "прок", language: .russian, learning: learning)?.word == "проклятье")
    }

    @Test func nothingIsShownWhenTwoWordsAreEquallyLikely() {
        let engine = CompletionEngine(frequency: [
            .russian: FrequencyList(words: ["проверка", "проверить", "провод"])
        ])
        // Three words share the prefix and none of them is more likely than the other two together.
        #expect(engine.complete(prefix: "про", language: .russian) == nil)
        #expect(engine.complete(prefix: "провод", language: .russian) == nil)
        #expect(engine.complete(prefix: "провери", language: .russian)?.word == "проверить")
    }

    @Test func personalHistoryWins() {
        var learning = LearningData()
        for _ in 0..<6 { learning.recordWord("проверить", previous: "надо", known: true) }
        #expect(
            engine.complete(prefix: "про", language: .russian, previous: "надо", learning: learning)?.word
                == "проверить")
        #expect(engine.nextWord(after: "надо", learning: learning) == "проверить")
    }
}

@Suite struct TrainerTests {
    @Test func countsSpeedAccuracyAndCombo() {
        var session = TrainerSession(text: "abc de", language: .english, source: .words)
        check(session.type("a", at: 0), .correct)
        check(session.type("x", at: 1), .wrong(expected: "b"))
        #expect(session.combo == 0)
        check(session.type("b", at: 2), .correct)
        for (index, character) in "c de".enumerated() { _ = session.type(character, at: Double(3 + index)) }
        #expect(session.isFinished)
        #expect(session.mistakes == 1)
        #expect(abs(session.accuracy - 6.0 / 7.0) < 0.0001)
        // Six characters in six seconds: 1.2 words in 0.1 minute.
        #expect(abs(session.wpm(at: 6) - 12) < 0.01)
        #expect(session.result(at: 6).missedKeys == ["b": 1])
    }

    @Test func timedExerciseEndsOnItsOwn() {
        var session = TrainerSession(
            text: String(repeating: "a", count: 100), language: .english, source: .words, timeLimit: 5)
        _ = session.type("a", at: 10)
        session.tick(at: 14.9)
        #expect(!session.isFinished)
        session.tick(at: 15.2)
        #expect(session.isFinished)
        #expect(session.elapsed(at: 99) == 5)
        check(session.type("a", at: 16), .ignored)
    }

    @Test func yoMayBeTypedAsYe() {
        var session = TrainerSession(text: "ёж", language: .russian, source: .texts)
        check(session.type("е", at: 0), .correct)
    }

    @Test func profileTracksLevelRecordAndStreak() {
        var profile = TrainerProfile()
        let calendar = Calendar(identifier: .gregorian)
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        func result(_ wpm: Double, _ date: Date) -> TrainerResult {
            TrainerResult(
                date: date, language: .russian, source: .words, wpm: wpm, accuracy: 0.97, duration: 30,
                characters: 200,
                mistakes: 4, maxCombo: 50, score: 5000, timeline: [], missedKeys: ["ж": 3])
        }
        let first = profile.record(result(40, day), calendar: calendar)
        #expect(first.isRecord && first.leveledUp && first.streakDays == 1)
        let second = profile.record(result(35, day.addingTimeInterval(86_400)), calendar: calendar)
        #expect(!second.isRecord && second.streakDays == 2)
        let third = profile.record(result(50, day.addingTimeInterval(4 * 86_400)), calendar: calendar)
        #expect(third.isRecord && third.streakDays == 1)
        #expect(profile.weakKeys(limit: 3) == ["ж"])
        #expect(profile.level >= 2)
    }

    @Test func phrasesWithSecretsAreNeverCollected() {
        #expect(PhraseCollector.isSafe("Давай созвонимся завтра после обеда"))
        #expect(!PhraseCollector.isSafe("мой код 482913 для входа в банк"))
        #expect(!PhraseCollector.isSafe("напиши мне на a.sobolev@example.com сегодня вечером"))
        #expect(!PhraseCollector.isSafe("да нет"))
        var collector = PhraseCollector()
        check(collector.add(chunk: "Давай", endsSentence: false, endsLine: false), nil)
        _ = collector.add(chunk: "созвонимся", endsSentence: false, endsLine: false)
        _ = collector.add(chunk: "завтра", endsSentence: false, endsLine: false)
        check(
            collector.add(chunk: "утром.", endsSentence: true, endsLine: false),
            "Давай созвонимся завтра утром.")
    }

    @Test func bundledPassagesAreTypeable() {
        let resources = CoreResources.load()
        for language in Language.allCases {
            let passages = resources.trainer.passages[language] ?? []
            #expect(passages.count >= 30)
            for passage in passages {
                #expect(TrainerContent.isTypeable(passage.text, language: language), "\(passage.id)")
            }
            #expect((resources.trainer.words[language] ?? []).count >= 300)
            #expect((resources.frequency[language]?.count ?? 0) >= 2000)
        }
        #expect(resources.terms.count >= 500)
        #expect(resources.terms.term(for: "figma")?.canonical == "Figma")
    }
}

@Suite struct UpdateTests {
    @Test func versionsAreOrderedByNumbers() throws {
        let old = try #require(AppVersion("1.2.0"))
        #expect(try #require(AppVersion("v1.10.0")) > old)
        #expect(try #require(AppVersion("1.2.1")) > old)
        #expect(try #require(AppVersion("1.2")) == old)
        #expect(try #require(AppVersion("1.2.0-beta.3")) == old)
        #expect(try #require(AppVersion("2")) > old)
        #expect(AppVersion("nightly") == nil)
        #expect(AppVersion("") == nil)
        #expect(old.description == "1.2.0")
    }

    private static let feed = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en-US">
          <id>tag:github.com,2008:https://github.com/example/app/releases</id>
          <link type="text/html" rel="alternate" href="https://github.com/example/app/releases"/>
          <title>Release notes from app</title>
          <entry>
            <id>tag:github.com,2008:Repository/1/v1.3.0</id>
            <link rel="alternate" type="text/html" href="https://github.com/example/app/releases/tag/v1.3.0"/>
            <title>LangSwitch 1.3.0 beta</title>
            <content type="html">&lt;p&gt;notes&lt;/p&gt;</content>
          </entry>
          <entry>
            <id>tag:github.com,2008:Repository/1/v1.10.0</id>
            <link rel="alternate" type="text/html" href="https://github.com/example/app/releases/tag/v1.10.0"/>
            <title>LangSwitch 1.10.0</title>
          </entry>
          <entry>
            <id>tag:github.com,2008:Repository/1/experiment</id>
            <link rel="alternate" type="text/html" href="https://github.com/example/app/releases/tag/experiment"/>
            <title>x</title>
          </entry>
          <entry>
            <id>tag:github.com,2008:Repository/1/bad</id>
            <link rel="alternate" type="text/html" href="https://github.com/example/app/releases/tag/v2.0/../../evil"/>
            <title>path trick</title>
          </entry>
        </feed>
        """#

    @Test func releasesAreReadFromTheFeed() throws {
        let releases = try ReleaseFeed.releases(fromAtom: Data(Self.feed.utf8), repository: "example/app")
        // The tag that is not a version and the one that is not a plain tag are gone.
        #expect(releases.map(\.version.description) == ["1.3.0", "1.10.0"])
        #expect(releases[0].title == "LangSwitch 1.3.0 beta")
        #expect(releases[0].page.absoluteString == "https://github.com/example/app/releases/tag/v1.3.0")
        #expect(
            releases[0].diskImage.absoluteString
                == "https://github.com/example/app/releases/download/v1.3.0/LangSwitch-1.3.0.dmg")
        #expect(
            releases[0].checksums.absoluteString
                == "https://github.com/example/app/releases/download/v1.3.0/SHA256SUMS.txt")
        #expect(releases[0].diskImageName == "LangSwitch-1.3.0.dmg")

        let current = try #require(AppVersion("1.2.0"))
        #expect(
            ReleaseFeed.updates(in: releases, newerThan: current).map(\.version.description) == [
                "1.10.0", "1.3.0",
            ])
        #expect(ReleaseFeed.updates(in: releases, newerThan: try #require(AppVersion("1.3.0"))).count == 1)
        #expect(ReleaseFeed.updates(in: releases, newerThan: try #require(AppVersion("2.0"))).isEmpty)
    }

    @Test func checksumIsReadFromTheList() {
        let digest = String(repeating: "ab12", count: 16)
        let list =
            "\(digest)  LangSwitch-1.3.0.zip\n\(digest.uppercased()) *LangSwitch-1.3.0.dmg\nnot a line\n"
        #expect(ReleaseFeed.checksum(for: "LangSwitch-1.3.0.dmg", in: list) == digest)
        #expect(ReleaseFeed.checksum(for: "LangSwitch-1.3.0.zip", in: list) == digest)
        #expect(ReleaseFeed.checksum(for: "Other.dmg", in: list) == nil)
        #expect(ReleaseFeed.checksum(for: "LangSwitch-1.3.0.dmg", in: "short  LangSwitch-1.3.0.dmg") == nil)
    }

    @Test func aBrokenFeedIsAnError() {
        #expect(throws: (any Error).self) {
            try ReleaseFeed.releases(
                fromAtom: Data("{\"message\": \"rate limit\"}".utf8), repository: "example/app")
        }
    }
}
