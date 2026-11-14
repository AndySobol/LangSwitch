import Foundation
import LangSwitchCore
import LangSwitchLexicon

// Builds the generated language data from open corpora. See docs/DATA.md for sources and licences.
//
//   swift run -c release LangSwitchData <raw-data-folder> <repository-root>
//
// Reads   <raw>/frequencywords-<code>/<code>_full.txt   word counts from film subtitles
//         <raw>/tatoeba-<code>/<iso>_sentences.tsv       sentences, "id<TAB>language<TAB>text"
// Writes  Sources/LangSwitchCore/Resources/Frequency/<code>-extended.txt
//         Sources/LangSwitchCore/Resources/Context/<code>.pairs
//         Tests/LangSwitchLexiconTests/Fixtures/sentences-<code>.txt   (held out of the model)
//         Tests/LangSwitchLexiconTests/Fixtures/unlisted-<code>.txt    (real words the lists lack)

struct Settings {
    /// A dictionary word is listed when the corpus has it at least this often per million words.
    let knownPerMillion = 0.13
    /// A word the dictionary lacks must be this frequent to count as a word people really write, and
    /// must also occur in the second, hand-written corpus: subtitles are full of recognition debris.
    let unknownPerMillion = 3.0
    let unknownInSentences = 3
    /// One sentence in this many is kept out of the context model and used for measurements.
    let heldOutEvery = 25
    let heldOutSample = 1500
    /// Pairs seen fewer times are noise.
    let minimumPairCount = 2
}

let settings = Settings()
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: LangSwitchData <raw-data-folder> <repository-root>\n".utf8))
    exit(2)
}
let raw = URL(fileURLWithPath: arguments[1], isDirectory: true)
let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
let resources = root.appendingPathComponent("Sources/LangSwitchCore/Resources")
let fixtures = root.appendingPathComponent("Tests/LangSwitchLexiconTests/Fixtures")

func note(_ text: String) { print(text) }

func read(_ url: URL) -> String {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        FileHandle.standardError.write(Data("cannot read \(url.path)\n".utf8))
        exit(1)
    }
    return text
}

/// A token the lists may hold: letters of the language, with a hyphen or an apostrophe inside.
func isWord(_ word: Substring, _ language: Language) -> Bool {
    guard word.count >= 2, word.count <= 24, let first = word.first, let last = word.last,
        language.isLetter(first), language.isLetter(last)
    else { return false }
    var joiners = 0
    for character in word where !language.isLetter(character) {
        guard character == "-" || (character == "'" && language == .english) else { return false }
        joiners += 1
    }
    return joiners <= 1
}

/// Splits a sentence into lower-case words; `clause` is called where a pair of neighbours is broken.
func scan(_ text: Substring, _ language: Language, word: (String) -> Void, clause: () -> Void) {
    let closing: Set<Character> = [".", "!", "?", ";", ":", "(", ")", "\"", "«", "»", "—", "–", "…"]
    var token = ""
    func flush() {
        if !token.isEmpty { word(token.trimmingCharacters(in: CharacterSet(charactersIn: "-'"))) }
        token = ""
    }
    for character in text.lowercased() {
        let folded: Character = character == "ё" ? "е" : character == "’" ? "'" : character
        if language.isLetter(folded) || folded == "-" || folded == "'" {
            token.append(folded)
        } else {
            flush()
            if closing.contains(folded) || folded.isNumber { clause() }
        }
    }
    flush()
}

// The engine as it is without the generated data: it decides which unlisted words are typos.
let runtime = LanguageRuntime(resources: CoreResources.load(generated: false))
guard runtime.hasFullDictionaries else {
    FileHandle.standardError.write(Data("the spelling dictionaries are missing\n".utf8))
    exit(1)
}
let speller = runtime.engine.speller
let vocabulary = runtime.vocabulary

for language in Language.allCases {
    let code = language.rawValue
    let iso = language == .russian ? "rus" : "eng"
    let core = runtime.resources.frequency[language] ?? FrequencyList()

    // The sentences: one in `heldOutEvery` is kept for measurements, the rest train the model.
    var training: [Substring] = []
    var heldOut: [String] = []
    var seen: [String: Int] = [:]
    let sentenceText = read(raw.appendingPathComponent("tatoeba-\(code)/\(iso)_sentences.tsv"))
    for line in sentenceText.split(separator: "\n") {
        let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, let id = Int(fields[0]) else { continue }
        let text = fields[2]
        if id % settings.heldOutEvery == 0 {
            // Plain sentences only: the measurements type them key by key on one layout.
            let plain = text.allSatisfy { language.isLetter($0) || " ,.!?-".contains($0) }
            if plain, (4...10).contains(text.split(separator: " ").count), text.first?.isUppercase == true {
                heldOut.append(String(text))
            }
            continue
        }
        training.append(text)
        scan(text, language, word: { seen[$0, default: 0] += 1 }, clause: {})
    }

    // 1. The extended frequency list.
    var counts: [(word: String, count: Int)] = []
    var total = 0
    for line in read(raw.appendingPathComponent("frequencywords-\(code)/\(code)_full.txt")).split(
        separator: "\n")
    {
        guard let space = line.lastIndex(of: " "), let count = Int(line[line.index(after: space)...]) else {
            continue
        }
        total += count
        let word = line[..<space]
        // «ё» is counted with «е» elsewhere in the corpus; the engine accepts either spelling.
        if isWord(word, language), !word.contains("ё") { counts.append((String(word), count)) }
    }
    let knownFloor = Int((settings.knownPerMillion * Double(total) / 1_000_000).rounded(.up))
    let unknownFloor = Int((settings.unknownPerMillion * Double(total) / 1_000_000).rounded(.up))
    note(
        "\(code): \(total) words in the corpus; listing dictionary words from \(knownFloor), others from \(unknownFloor)"
    )

    var extended: [String] = []
    var admitted: [String] = []
    var rejected: [String] = []
    for (word, count) in counts.sorted(by: { $0.count == $1.count ? $0.word < $1.word : $0.count > $1.count })
    where count >= knownFloor && core.rank(of: word) == nil {
        let known = vocabulary.isKnown(word, language: language)
        // The dictionary accepts any two words joined by a hyphen, so a hyphenated form has to prove
        // itself the way an unlisted word does.
        if known && !word.contains("-") {
            extended.append(word)
            continue
        }
        guard count >= unknownFloor, seen[word, default: 0] >= settings.unknownInSentences else { continue }
        // Halves of contractions left by the corpus tokeniser: "didn", "doesn".
        if language == .english, vocabulary.isKnown(word + "'t", language: language) { continue }
        // A frequent string that the model can explain as a spelling mistake is a frequent mistake.
        let looksLikeAMistake =
            speller.autoCorrection(for: word, language: language) != nil
            || speller.candidates(for: word, language: language).contains {
                $0.edit.family == .orthographic || $0.edit.family == .boundary
            }
        if looksLikeAMistake {
            rejected.append(word)
        } else {
            extended.append(word)
            admitted.append(word)
        }
    }
    note("\(code): \(extended.count) words added, \(admitted.count) of them unknown to the dictionary")
    note("  admitted: \(admitted.prefix(80).joined(separator: " "))")
    note("  rejected as mistakes: \(rejected.prefix(80).joined(separator: " "))")
    try (extended.joined(separator: "\n") + "\n").write(
        to: resources.appendingPathComponent("Frequency/\(code)-extended.txt"), atomically: true,
        encoding: .utf8)

    // 2. The context model, over the full list.
    let list = FrequencyList(words: Array(core.words), extended: extended)
    guard list.count <= ContextModel.vocabularyLimit else {
        FileHandle.standardError.write(Data("the list is too long for the context model\n".utf8))
        exit(1)
    }
    var builder = ContextModel.Builder()
    for text in training {
        var previous: Int?
        scan(
            text, language,
            word: { word in
                guard let rank = list.rank(of: word) else {
                    previous = nil
                    return
                }
                if let previous { builder.add(previous, rank) }
                previous = rank
            },
            clause: { previous = nil })
    }
    let model = builder.build(
        vocabulary: list.count, signature: list.signature, minimumCount: settings.minimumPairCount)
    try model.write(to: resources.appendingPathComponent("Context/\(code).pairs"))
    note(
        "\(code): \(training.count) sentences, \(builder.pairCount) distinct pairs, file \(model.count / 1024) KB"
    )

    // Words that people write again and again in hand-written sentences, yet neither the dictionary nor
    // the frequency list has them: names, regional spellings, new words. Nothing here is a typo, so the
    // measurements use them as words that must be left alone.
    let unlisted = seen.filter { item in
        item.value >= 5 && isWord(Substring(item.key), language) && list.rank(of: item.key) == nil
            && !vocabulary.isKnown(item.key, language: language)
    }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(3000).map(\.key)
    try (unlisted.joined(separator: "\n") + "\n").write(
        to: fixtures.appendingPathComponent("unlisted-\(code).txt"), atomically: true, encoding: .utf8)
    note("\(code): \(unlisted.count) unlisted words: \(unlisted.prefix(40).joined(separator: " "))")

    let step = max(heldOut.count / settings.heldOutSample, 1)
    let sample = stride(from: 0, to: heldOut.count, by: step).prefix(settings.heldOutSample).map {
        heldOut[$0]
    }
    try (sample.joined(separator: "\n") + "\n").write(
        to: fixtures.appendingPathComponent("sentences-\(code).txt"), atomically: true, encoding: .utf8)
    note("\(code): \(sample.count) held-out sentences written")
}
