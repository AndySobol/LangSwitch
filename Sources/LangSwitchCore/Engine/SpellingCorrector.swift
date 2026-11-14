import Foundation

/// Finds the intended word behind a typo.
///
/// The model has four parts, and a correction is applied only when they agree:
///
/// 1. **How people mistype.** Slips of the hands (swapped neighbours, a dropped or doubled letter, a hit
///    on the next key), word boundaries (a missing space, hyphen or apostrophe) and the places where
///    the spelling rules of the language invite a mistake (unstressed vowels, paired consonants, the
///    soft sign, vowels after hushing sounds, silent letters, prefixes in з/с). Each has a cost.
/// 2. **What is a word.** A candidate must be in the vocabulary; everyday words are preferred.
/// 3. **What stands around.** A candidate seen after the previous word in real text is preferred.
/// 4. **How far the explanation can be trusted.** `CorrectionPolicy` weighs the best candidate: its
///    kind, how common it is, the context, how far the next explanation is. Its weights are fitted to
///    corpora the rules were not written against (`Tests/LangSwitchLexiconTests/Fixtures`); what does
///    not pass is only offered in the list of alternatives.
///
/// There is no table of "known misspellings": a typo is fixed because the model explains it, so the same
/// rules cover words nobody listed.
package struct SpellingCorrector {
    /// The slip that turns the intended word into what was typed.
    package enum Edit: Sendable, Equatable {
        // Slips of the hands.
        case swappedLetters
        case droppedLetter
        case doubledLetter
        case strayLetter
        case neighbouringKey
        // Word boundaries: written together, apart or with a hyphen.
        case missingSpace
        case missingHyphen
        case strayHyphen
        case missingApostrophe
        // Spelling rules: the places where the language itself invites a mistake.
        case droppedDoubleLetter
        /// Unstressed vowels that sound alike: «кампот», "seperate".
        case confusedVowel
        /// Consonants that sound alike: «зделать», «ево», "sertain".
        case confusedConsonant
        /// «любиш», «стараеться», «обьект».
        case softSign
        /// A letter fixed by a rule rather than by ear: vowels after hushing sounds and «ц» («пришол»,
        /// «жызнь», «цыфра»), prefixes in з/с («безплатно», «зделать»).
        case ruleSpelling
        /// Letters that are written but not heard: «лесница», «чуствовать», "definatly".
        case silentLetter
        /// The double consonant put in the wrong place: «исскуство», «проффесия», "occassion".
        case misplacedDouble
        case twoSlips

        package enum Family: Sendable {
            case mechanical, boundary, orthographic, compound
        }

        package var family: Family {
            switch self {
            case .swappedLetters, .droppedLetter, .doubledLetter, .strayLetter, .neighbouringKey: .mechanical
            case .missingSpace, .missingHyphen, .strayHyphen, .missingApostrophe: .boundary
            case .droppedDoubleLetter, .confusedVowel, .confusedConsonant, .softSign, .ruleSpelling,
                .silentLetter,
                .misplacedDouble:
                .orthographic
            case .twoSlips: .compound
            }
        }

        var cost: Float {
            switch self {
            case .ruleSpelling: 0.8
            case .swappedLetters, .doubledLetter: 1.0
            case .missingApostrophe: 1.05
            case .droppedDoubleLetter, .missingHyphen, .strayHyphen, .softSign, .silentLetter: 1.1
            case .missingSpace: 1.2
            case .droppedLetter: 1.4
            case .confusedVowel, .confusedConsonant: 1.5
            case .neighbouringKey, .misplacedDouble: 1.6
            // Fast typists drop letters and swap neighbours; a stray extra letter is rare.
            case .strayLetter: 1.75
            case .twoSlips: 2.4
            }
        }
    }

    package struct Candidate: Sendable, Equatable {
        package let word: String
        /// Lower is better: the cost of the slip minus what frequency and context say for the word.
        package var score: Float
        package let edit: Edit
        /// How often the word follows the previous one in everyday text; 0 when the pair was never seen
        /// or there is nothing to compare with.
        package var followsPrevious = 0
        /// For a replacement of two words: how often they stand next to each other.
        package var innerPair = 0

        init(word: String, score: Float, edit: Edit) {
            self.word = word
            self.score = score
            self.edit = edit
        }
    }

    private let vocabulary: Vocabulary
    private let models: [Language: NGramModel]
    private let policy: CorrectionPolicy?
    private let adjacency: [Language: [Character: [Character]]]

    /// What a language's spelling rules say about letters that get confused.
    private struct Orthography {
        var vowels: Set<Character>
        /// Vowels that sound alike without stress.
        var vowelPairs: [Character: [Character]]
        /// Consonants that sound alike (voicing, assimilation).
        var consonantPairs: [Character: [Character]]
        /// After these letters the vowel is spelled by rule, not by ear.
        var hushing: [Character: [Character: [Character]]] = [:]
        /// A letter that is written between two others but not pronounced.
        var silentBetween: [(before: Character, letter: Character, after: Character)] = []
        /// A letter that is easily lost anywhere, and added before these endings: "truely", "arguement".
        var silentLetter: Character?
        var silentBeforeEndings: Set<String> = []
        var softSigns: Set<Character> = []
        /// Prefixes that are confused with each other: the last consonant follows the next sound
        /// («без-/бес-», «из-/ис-»), the vowel follows the meaning («пре-/при-»).
        var prefixPairs: [(String, String)] = []
        /// Particles attached with a hyphen: «кто-то», «куда-либо», «кое-что».
        var hyphenatedParticles: Set<String> = []
        /// Particles written as separate words: «как будто», «что ли», «хотя бы».
        var separateParticles: Set<String> = []
        var hyphenatedPrefixes: Set<String> = []
        /// «по-дружески»: after this prefix an adverb with one of the endings takes a hyphen. With the
        /// ambiguous endings both spellings exist («по-новому» / «по новому мосту»).
        var adverbPrefix = ""
        var adverbEndings: [String] = []
        var ambiguousAdverbEndings: [String] = []
        /// Words that lean on the next one and are easily glued to it: prepositions, «не», articles.
        var proclitics: Set<String> = []
        /// «во-первых»: after these prefixes an ordinal may be an introductory word.
        var ordinalPrefixes: Set<String> = []
        var ordinals: Set<String> = []
    }

    private static let orthography: [Language: Orthography] = {
        func pairs(_ list: [(Character, Character)]) -> [Character: [Character]] {
            var result: [Character: [Character]] = [:]
            for (first, second) in list {
                result[first, default: []].append(second)
                result[second, default: []].append(first)
            }
            return result
        }
        let afterHushing: [Character: [Character]] = ["о": ["е"], "е": ["о"]]
        var hushing: [Character: [Character: [Character]]] = [:]
        for letter in "жш" { hushing[letter] = afterHushing.merging(["ы": ["и"]]) { first, _ in first } }
        for letter in "чщ" {
            hushing[letter] = afterHushing.merging(["я": ["а"], "ю": ["у"]]) { first, _ in first }
        }
        hushing["ц"] = ["ы": ["и"], "и": ["ы"]]
        let russian = Orthography(
            vowels: Set("аеиоуыэюя"),
            vowelPairs: pairs([("а", "о"), ("е", "и"), ("е", "я"), ("и", "я"), ("е", "э")]),
            consonantPairs: pairs([
                ("б", "п"), ("в", "ф"), ("г", "к"), ("д", "т"), ("ж", "ш"), ("з", "с"), ("г", "в"),
                ("ч", "ш"),
            ]),
            hushing: hushing,
            silentBetween: [
                ("с", "т", "н"), ("з", "д", "н"), ("с", "т", "л"), ("р", "д", "ц"), ("о", "л", "н"),
                ("а", "в", "с"), ("у", "в", "с"), ("н", "т", "с"), ("н", "д", "с"),
            ],
            softSigns: ["ь", "ъ"],
            prefixPairs: [
                ("без", "бес"), ("из", "ис"), ("раз", "рас"), ("воз", "вос"), ("вз", "вс"), ("роз", "рос"),
                ("низ", "нис"), ("через", "черес"), ("пре", "при"),
            ],
            hyphenatedParticles: ["то", "либо", "нибудь"],
            separateParticles: ["бы", "б", "ли", "ль", "же", "ж", "будто"],
            hyphenatedPrefixes: ["кое"],
            adverbPrefix: "по",
            adverbEndings: ["ски", "цки", "ьи"],
            ambiguousAdverbEndings: ["ому", "ему"],
            proclitics: [
                "в", "во", "к", "ко", "с", "со", "у", "о", "об", "на", "по", "за", "до", "от", "из", "не",
                "ни", "и",
                "а", "но", "при", "про", "под", "над", "для", "без",
            ],
            ordinalPrefixes: ["в", "во"],
            ordinals: [
                "первых", "вторых", "третьих", "четвертых", "пятых", "шестых", "седьмых", "восьмых",
                "девятых",
                "десятых",
            ])
        let english = Orthography(
            vowels: Set("aeiouy"),
            vowelPairs: pairs([
                ("a", "e"), ("a", "i"), ("a", "o"), ("a", "u"), ("e", "i"), ("e", "o"), ("e", "u"),
                ("i", "o"),
                ("i", "u"), ("o", "u"), ("i", "y"), ("e", "y"),
            ]),
            consonantPairs: pairs([("c", "s"), ("c", "k"), ("s", "z")]),
            silentLetter: "e",
            silentBeforeEndings: ["ly", "ment", "ments", "able", "ing", "ous", "ful", "ness", "less"],
            proclitics: [
                "a", "an", "the", "in", "on", "at", "to", "of", "no", "as", "is", "it", "up", "so", "i",
            ])
        return [.russian: russian, .english: english]
    }()

    /// - Parameters:
    ///   - models: letter models, which tell how word-like a typed string is.
    ///   - policy: decides what is applied automatically; without it replacements are only offered.
    package init(
        vocabulary: Vocabulary, models: [Language: NGramModel] = [:], policy: CorrectionPolicy? = nil
    ) {
        self.vocabulary = vocabulary
        self.models = models
        self.policy = policy
        self.adjacency = [
            .english: Self.adjacency(for: .abc),
            .russian: Self.adjacency(for: .russian),
        ]
    }

    private static func adjacency(for layout: KeyboardLayout) -> [Character: [Character]] {
        let rows: [[UInt16]] = [
            [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30],
            [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39],
            [6, 7, 8, 9, 11, 45, 46, 43, 47, 44],
        ]
        func letter(_ row: Int, _ column: Int) -> Character? {
            guard rows.indices.contains(row), rows[row].indices.contains(column),
                let character = layout.character(for: KeyStroke(keyCode: rows[row][column])),
                layout.language.isLetter(character)
            else { return nil }
            return character
        }
        var result: [Character: [Character]] = [:]
        for row in rows.indices {
            for column in rows[row].indices {
                guard let key = letter(row, column) else { continue }
                // Rows are staggered: the key above sits half a key to the left.
                let neighbours = [
                    letter(row, column - 1), letter(row, column + 1),
                    letter(row - 1, column), letter(row - 1, column + 1),
                    letter(row + 1, column - 1), letter(row + 1, column),
                ]
                result[key] = neighbours.compactMap { $0 }
            }
        }
        return result
    }

    /// What being a common word is worth to a candidate.
    private func bonus(_ rank: Int?) -> Float {
        guard let rank else { return 0 }
        if rank < 300 { return 0.5 }
        if rank < 1500 { return 0.35 }
        if rank < 6000 { return 0.2 }
        if rank < 20000 { return 0.14 }
        if rank < 60000 { return 0.08 }
        return 0.03
    }

    private enum Scope {
        /// Everything one slip away.
        case all
        /// Slips of the hands that add or move letters: the second half of a double slip.
        case mechanical
    }

    /// Every string one slip away from `word`; for duplicates the cheapest explanation wins.
    private func slips(of word: [Character], language: Language, scope: Scope = .all) -> [String: Edit] {
        var result: [String: Edit] = [:]
        func add(_ characters: [Character], _ edit: Edit) {
            let text = String(characters)
            if let existing = result[text], existing.cost <= edit.cost { return }
            result[text] = edit
        }
        let count = word.count
        for index in 0..<max(count - 1, 0) where word[index] != word[index + 1] {
            var copy = word
            copy.swapAt(index, index + 1)
            add(copy, .swappedLetters)
        }
        for index in 0..<count {
            var copy = word
            copy.remove(at: index)
            let doubled =
                index > 0 && word[index] == word[index - 1]
                || index + 1 < count && word[index] == word[index + 1]
            if word[index] == "-" {
                add(copy, .strayHyphen)
            } else if doubled {
                add(copy, .doubledLetter)
            } else if scope == .all {
                add(copy, .strayLetter)
            }
        }
        for index in 0...count {
            for letter in language.alphabet where letter != "ё" {
                var copy = word
                copy.insert(letter, at: index)
                let doubling =
                    index > 0 && word[index - 1] == letter || index < count && word[index] == letter
                add(copy, doubling ? .droppedDoubleLetter : .droppedLetter)
            }
            if index > 0, index < count, word[index - 1] != "-", word[index] != "-" {
                var hyphenated = word
                hyphenated.insert("-", at: index)
                add(hyphenated, .missingHyphen)
                if language == .english {
                    var contracted = word
                    contracted.insert("'", at: index)
                    add(contracted, .missingApostrophe)
                }
            }
        }
        guard scope != .mechanical, let rules = Self.orthography[language] else { return result }

        for index in 0..<count {
            let letter = word[index]
            func replace(with replacement: Character, _ edit: Edit) {
                var copy = word
                copy[index] = replacement
                add(copy, edit)
            }
            if scope == .all {
                for replacement in adjacency[language]?[letter] ?? [] {
                    replace(with: replacement, .neighbouringKey)
                }
            }
            for replacement in rules.vowelPairs[letter] ?? [] { replace(with: replacement, .confusedVowel) }
            for replacement in rules.consonantPairs[letter] ?? [] {
                replace(with: replacement, .confusedConsonant)
            }
            if index > 0 {
                for replacement in rules.hushing[word[index - 1]]?[letter] ?? [] {
                    replace(with: replacement, .ruleSpelling)
                }
            }
            if rules.softSigns.contains(letter) {
                var copy = word
                copy.remove(at: index)
                add(copy, .softSign)
                for other in rules.softSigns where other != letter { replace(with: other, .softSign) }
            }
            if letter == rules.silentLetter, rules.silentBeforeEndings.contains(String(word[(index + 1)...]))
            {
                var copy = word
                copy.remove(at: index)
                add(copy, .silentLetter)
            }
            if index > 0, index + 1 < count,
                rules.silentBetween.contains(where: {
                    $0.before == word[index - 1] && $0.letter == letter && $0.after == word[index + 1]
                })
            {
                var copy = word
                copy.remove(at: index)
                add(copy, .silentLetter)
            }
        }
        // «безплатно» → «бесплатно», and the prefix «с-», which is never written «з-».
        let text = String(word)
        for (voiced, voiceless) in rules.prefixPairs {
            for (from, to) in [(voiced, voiceless), (voiceless, voiced)]
            where text.hasPrefix(from) && count > from.count {
                add(Array(to) + word[from.count...], .ruleSpelling)
            }
        }
        if language == .russian, count > 2, word[0] == "з", !rules.vowels.contains(word[1]) {
            var copy = word
            copy[0] = "с"
            add(copy, .ruleSpelling)
        }
        for index in 1...max(count, 1) where index <= count {
            let previous = word[index - 1]
            // A soft sign goes after a consonant only.
            if !rules.softSigns.isEmpty, language.isLetter(previous), !rules.vowels.contains(previous),
                !rules.softSigns.contains(previous)
            {
                var copy = word
                copy.insert("ь", at: index)
                add(copy, .softSign)
            }
            if let letter = rules.silentLetter {
                var copy = word
                copy.insert(letter, at: index)
                add(copy, .silentLetter)
            }
            if index < count {
                for rule in rules.silentBetween where rule.before == previous && rule.after == word[index] {
                    var copy = word
                    copy.insert(rule.letter, at: index)
                    add(copy, .silentLetter)
                }
            }
        }
        return result
    }

    /// Words the model can explain as the intention behind `word`, best first.
    ///
    /// - Parameters:
    ///   - previous: the word before this one in the same clause, when there is one.
    ///   - deep: also look two slips away (slower; for the list of alternatives).
    package func candidates(
        for word: String, language: Language, after previous: String? = nil, deep: Bool = false
    ) -> [Candidate] {
        var found = explanations(of: word, language: language, deep: deep)
        for index in found.indices {
            let parts = found[index].word.lowercased().components(separatedBy: " ")
            if let previous, let first = parts.first {
                found[index].followsPrevious = vocabulary.pairCount(previous, first, language: language) ?? 0
            }
            if parts.count == 2, let pair = vocabulary.pairCount(parts[0], parts[1], language: language) {
                found[index].innerPair = pair
                // Two words that are never seen side by side are a poor explanation: «и ать», «о любимый».
                found[index].score += pair > 0 ? -Self.contextBonus(pair) / 2 : 0.5
            }
            // What precedes a split says little: its first half is usually a function word, and those
            // follow anything.
            if parts.count == 1 { found[index].score -= Self.contextBonus(found[index].followsPrevious) }
        }
        return found.sorted { $0.score == $1.score ? $0.word < $1.word : $0.score < $1.score }
    }

    /// What a pair seen in real text is worth: it grows slowly with the number of sightings.
    package static func contextBonus(_ pairs: Int) -> Float {
        pairs > 0 ? min(0.25 + 0.1 * log10(Float(pairs)), 0.55) : 0
    }

    /// Every word the model can reach from `word`, without looking at the sentence.
    private func explanations(of word: String, language: Language, deep: Bool) -> [Candidate] {
        let lower = Array(word.lowercased())
        guard lower.count >= 2, lower.count <= 32,
            lower.allSatisfy({ language.isLetter($0) || $0 == "-" || $0 == "'" })
        else { return [] }
        let typed = String(lower)
        var best: [String: Candidate] = [:]

        func offer(_ spelling: String, _ score: Float, _ edit: Edit) {
            if let existing = best[spelling], existing.score <= score { return }
            best[spelling] = Candidate(word: spelling, score: score, edit: edit)
        }
        func consider(_ text: String, _ edit: Edit, extraCost: Float = 0, joined: Bool = false) {
            guard text != typed else { return }
            let knowledge = vocabulary.knowledge(of: text, language: language)
            guard knowledge.isKnown else { return }
            // The spelling dictionary accepts any two words joined by a hyphen and many apostrophe
            // forms, so "known" proves nothing for these: the form must be attested in real usage.
            if joined || edit == .missingHyphen || edit == .missingApostrophe, knowledge.rank == nil {
                return
            }
            // Lower-case spellings that exist only as proper nouns are offered capitalised.
            let spelling = knowledge.canonical ?? text
            var score = edit.cost + extraCost - bonus(knowledge.rank) + (knowledge.canonical != nil ? 0.4 : 0)
            // The first letter of a word is the one people get right: a slip there is less likely.
            if edit.family == .mechanical, edit != .swappedLetters {
                if text.first != typed.first { score += 0.3 }
                // «кконцу» is far more often «к концу» than a doubled first letter.
                if edit == .doubledLetter, typed.dropFirst() == text, let first = typed.first,
                    Self.orthography[language]?.proclitics.contains(String(first)) == true
                {
                    score += 0.5
                }
            }
            offer(spelling, score, edit)
        }

        // A hyphenated word is judged by its parts and by the hyphenation rules: the dictionary accepts
        // any two words joined by a hyphen, so slips across the whole string would prove nothing.
        if lower.contains("-") {
            hyphenated(lower, language: language, offer: offer)
            return best.values.sorted { $0.score == $1.score ? $0.word < $1.word : $0.score < $1.score }
        }

        let single = slips(of: lower, language: language)
        for (text, edit) in single { consider(text, edit) }

        // A missing space: both halves must be everyday words, or anything could be split.
        if lower.count >= 3 {
            let rules = Self.orthography[language]
            for index in 1..<lower.count {
                let left = String(lower[..<index])
                let right = String(lower[index...])
                let leftRank = vocabulary.rank(of: left, language: language)
                let rightRank = vocabulary.rank(of: right, language: language)
                let leftCommon = leftRank ?? vocabulary.commonness(of: left, language: language)
                let rightCommon = rightRank ?? vocabulary.commonness(of: right, language: language)
                let hyphenated = left + "-" + right

                // Where the grammar asks for a hyphen, a space would be a mistake of its own.
                if let rules {
                    if rules.hyphenatedParticles.contains(right), let leftCommon {
                        offer(hyphenated, Edit.missingHyphen.cost - bonus(leftCommon), .missingHyphen)
                        continue
                    }
                    if rules.hyphenatedPrefixes.contains(left), let rightCommon {
                        offer(hyphenated, Edit.missingHyphen.cost - bonus(rightCommon), .missingHyphen)
                        continue
                    }
                    if left == rules.adverbPrefix, vocabulary.isKnown(right, language: language) {
                        if rules.adverbEndings.contains(where: right.hasSuffix) {
                            offer(hyphenated, Edit.missingHyphen.cost, .missingHyphen)
                            continue
                        }
                        // Both readings exist; offered side by side, they are left to the user.
                        if rules.ambiguousAdverbEndings.contains(where: right.hasSuffix) {
                            offer(hyphenated, Edit.missingSpace.cost - bonus(rightCommon), .missingHyphen)
                        }
                    }
                    if rules.ordinalPrefixes.contains(left), rules.ordinals.contains(right) {
                        offer(hyphenated, Edit.missingSpace.cost - bonus(rightCommon), .missingHyphen)
                    }
                }

                // One half must be an everyday form, the other at least a form of an everyday word:
                // «к вечеру», «не делай».
                if leftRank != nil || rightRank != nil, let leftCommon, let rightCommon,
                    // «по-моему» is one word; offering «по моему» next to it would only create a tie.
                    vocabulary.rank(of: hyphenated, language: language) == nil
                {
                    offer(
                        left + " " + right,
                        Edit.missingSpace.cost - min(bonus(leftCommon), bonus(rightCommon)),
                        .missingSpace)
                }
            }
        }
        // Two slips in a long word, one of them a swap or a doubled letter: «илседования», and the
        // double consonant put in the wrong place — «исскуство», «проффесия».
        if (deep || best.isEmpty) && lower.count >= 7 {
            for (seed, first) in single where first == .swappedLetters || first == .doubledLetter {
                for (text, second) in slips(of: Array(seed), language: language, scope: .mechanical)
                where second != .swappedLetters {
                    if first == .doubledLetter, second == .droppedDoubleLetter {
                        consider(text, .misplacedDouble)
                    } else {
                        consider(
                            text, .twoSlips, extraCost: first.cost + second.cost - Edit.twoSlips.cost,
                            joined: second == .missingHyphen || second == .missingApostrophe)
                    }
                }
            }
        }
        if deep && best.count < 5 {
            for (seed, first) in single where first != .droppedLetter && first != .droppedDoubleLetter {
                for (text, second) in slips(of: Array(seed), language: language) where best[text] == nil {
                    consider(
                        text, .twoSlips, extraCost: first.cost + second.cost - Edit.twoSlips.cost,
                        joined: second == .missingHyphen || second == .missingApostrophe
                            || first == .missingHyphen || first == .missingApostrophe)
                }
            }
        }

        return best.values.sorted { $0.score == $1.score ? $0.word < $1.word : $0.score < $1.score }
    }

    /// Candidates for a word typed with one hyphen.
    private func hyphenated(
        _ lower: [Character], language: Language, offer: (String, Float, Edit) -> Void
    ) {
        guard let hyphen = lower.firstIndex(of: "-"), lower.lastIndex(of: "-") == hyphen else { return }
        let left = String(lower[..<hyphen])
        let right = String(lower[(hyphen + 1)...])
        guard !left.isEmpty, !right.isEmpty else { return }
        let rules = Self.orthography[language]

        // «как-будто», «что-ли»: these particles are written apart, never with a hyphen.
        if let rules, rules.separateParticles.contains(right), vocabulary.isKnown(left, language: language) {
            offer(left + " " + right, Edit.strayHyphen.cost, .strayHyphen)
        }
        // «буд-то», «пол-года»: one word.
        let joined = left + right
        let knowledge = vocabulary.knowledge(of: joined, language: language)
        if knowledge.isKnown {
            offer(knowledge.canonical ?? joined, Edit.strayHyphen.cost - bonus(knowledge.rank), .strayHyphen)
        }
        // A typo inside one of the parts: «дизайн-ситема».
        let leftKnown = vocabulary.isKnown(left, language: language)
        let rightKnown = vocabulary.isKnown(right, language: language)
        guard leftKnown != rightKnown else { return }
        let broken = leftKnown ? right : left
        guard broken.count >= 4 else { return }
        for candidate in explanations(of: broken, language: language, deep: false)
        where !candidate.word.contains(" ") {
            let repaired = leftKnown ? left + "-" + candidate.word : candidate.word + "-" + right
            offer(repaired, candidate.score, candidate.edit)
        }
    }

    /// The confidence a replacement needs to be applied automatically; nil without a policy.
    package var threshold: Float? { policy?.threshold }

    /// The best explanation of an unknown word and how much the policy believes in it.
    package func assessment(
        of word: String, language: Language, after previous: String? = nil
    ) -> (candidate: Candidate, confidence: Float, rank: Int?)? {
        guard let policy else { return nil }
        let found = candidates(for: word, language: language, after: previous)
        guard let best = found.first else { return nil }
        let lower = word.lowercased()
        let target = best.word.lowercased()

        func rank(_ candidate: Candidate, through lemmas: Bool) -> Int? {
            let ranks = candidate.word.components(separatedBy: " ").map {
                lemmas
                    ? vocabulary.commonness(of: $0, language: language)
                    : vocabulary.rank(of: $0, language: language)
            }
            return ranks.contains(nil) ? nil : ranks.compactMap { $0 }.max()
        }
        let parts = target.components(separatedBy: " ")
        let rival = found.dropFirst().first
        var evidence = CorrectionPolicy.Evidence()
        evidence.edit = String(describing: best.edit)
        evidence.length = word.count
        evidence.rank = rank(best, through: false)
        evidence.lemmaRank = rank(best, through: true)
        evidence.seenAfterPrevious = best.followsPrevious
        evidence.margin = rival.map { $0.score - best.score }
        evidence.rivalIsRanked = rival.map { rank($0, through: false) != nil } ?? false
        evidence.firstLetterChanged = target.first != lower.first
        evidence.plausibility = models[language]?.plausibility(of: lower) ?? 0
        evidence.candidateCount = found.count
        evidence.seenTogether = best.innerPair
        evidence.gluedFunctionWord =
            parts.count == 2 && parts[1].count >= 3
            && Self.orthography[language]?.proclitics.contains(parts[0]) == true
        evidence.score = best.score
        evidence.isEnglish = language == .english
        guard let confidence = policy.confidence(evidence) else { return nil }
        return (best, confidence, evidence.rank)
    }

    /// A replacement that is safe to apply without asking, or nil.
    ///
    /// - Parameters:
    ///   - capitalIsOrdinary: the word opens a sentence, so its capital letter does not suggest a name.
    ///   - previous: the word before this one in the same clause, when there is one.
    package func autoCorrection(
        for word: String, language: Language, capitalIsOrdinary: Bool = false, after previous: String? = nil
    ) -> String? {
        guard let policy, word.count >= 2, word.count <= 24 else { return nil }
        // Mixed case such as "iPhone" or "SwiftUI" is deliberate.
        guard word.isAllLowercase || word.isCapitalized || word.isAllUppercase else { return nil }
        // A short capitalised word may be a name the dictionaries lack («Fadil» is not "Fail"), even at
        // the start of a sentence: it has to be a surer case.
        let mayBeName = !word.isAllLowercase && word.count <= 6
        let required = mayBeName ? min(policy.threshold + 0.1, 0.95) : policy.threshold
        guard let (best, confidence, rank) = assessment(of: word, language: language, after: previous),
            confidence >= required
        else { return nil }
        // A typo inside one part of a compound is only offered: the compound itself is nobody's
        // everyday word, so there is nothing to check the repair against.
        if word.contains("-"), best.edit != .strayHyphen { return nil }
        // A capital inside a sentence usually marks a name: only an obvious slip towards a listed word.
        if !word.isAllLowercase && !(capitalIsOrdinary && word.isCapitalized) {
            guard best.edit == .swappedLetters || best.edit == .doubledLetter, rank != nil else { return nil }
        }
        return matchCase(of: word, to: best.word)
    }
}
