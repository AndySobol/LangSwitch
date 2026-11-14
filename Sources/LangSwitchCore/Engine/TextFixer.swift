import Foundation

/// Corrects a whole piece of text at once: the "fix selection" command and the playground.
///
/// Unlike live typing, the complete sentence is available here, so rules that need the following word
/// (introductory phrases, «потому что», articles) can run as well.
package struct TextFixer {
    package struct Result: Sendable, Equatable {
        package var text: String
        package var kinds: CorrectionKinds

        package init(text: String, kinds: CorrectionKinds) {
            self.text = text
            self.kinds = kinds
        }
    }

    private let engine: CorrectionEngine
    private let layouts: [KeyboardLayout]

    package init(engine: CorrectionEngine, layouts: [KeyboardLayout] = KeyboardLayout.builtIn) {
        self.engine = engine
        self.layouts = layouts
    }

    private func layout(for language: Language) -> KeyboardLayout? {
        layouts.first { $0.language == language }
    }

    /// Re-types every character on the other layout, whatever the text says ("only convert layout").
    package func convertLayout(_ text: String) -> String {
        guard let language = Language.dominant(in: text), let source = layout(for: language),
            let target = layout(for: language.other)
        else { return text }
        return source.convert(text, to: target)
    }

    package func fix(_ text: String, options: CorrectionOptions) -> Result {
        var kinds: CorrectionKinds = []
        var output = ""
        var context = LayoutDecider.Context()
        var sentenceStart = true

        // Pass 1: chunk by chunk, exactly as live typing would see them.
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                var end = index
                while end < text.endIndex, text[end].isWhitespace { end = text.index(after: end) }
                let gap = text[index..<end]
                if gap.contains(where: \.isNewline) { sentenceStart = true }
                output += gap
                index = end
                continue
            }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            let chunk = String(text[index..<end])
            index = end

            guard let language = Language.dominant(in: chunk) else {
                output += chunk
                continue
            }
            var input = ChunkInput(typed: chunk, typedLanguage: language)
            if let source = layout(for: language), let target = layout(for: language.other) {
                input.alternative = source.convert(chunk, to: target)
            }
            input.context = context
            input.sentenceStart = sentenceStart
            let result = engine.process(input, options: options)
            kinds.formUnion(result.kinds)
            output += result.text
            if let resultLanguage = result.language, result.hasKnownWord { context.note(resultLanguage) }
            sentenceStart = engine.endsSentence(result.text)
            if sentenceStart { context.endSentence() }
        }

        if options.punctuation {
            let spaced = Self.fixSpacing(output)
            let punctuated = insertCommas(spaced)
            if punctuated != output { kinds.insert(.punctuation) }
            output = punctuated
        }
        if options.spelling {
            let articles = fixArticles(output)
            if articles != output { kinds.insert(.spelling) }
            output = articles
        }
        return Result(text: output, kinds: output == text ? [] : kinds)
    }

    // MARK: - Spacing

    /// Removes spaces before punctuation, collapses runs of spaces and sets Russian dashes.
    package static func fixSpacing(_ text: String) -> String {
        let characters = Array(text)
        var result: [Character] = []
        result.reserveCapacity(characters.count)
        var position = 0
        while position < characters.count {
            let character = characters[position]
            if character == " " {
                var end = position
                while end < characters.count, characters[end] == " " { end += 1 }
                let atLineStart = result.isEmpty || result.last?.isNewline == true
                if atLineStart {
                    result.append(contentsOf: characters[position..<end])  // indentation is intentional
                    position = end
                    continue
                }
                if end < characters.count, ",.;:!?".contains(characters[end]),
                    let before = result.last,
                    before.isLetter || before.isNumber || before == ")" || before == "\""
                {
                    // Keep " :)" and " .gitignore": punctuation must end a word, not start something.
                    let after = end + 1 < characters.count ? characters[end + 1] : " "
                    let endsWord =
                        after.isWhitespace
                        || (characters[end] != "." && characters[end] != ":" && after.isLetter)
                    if endsWord {
                        position = end
                        continue
                    }
                }
                // " - " between Russian words is a dash.
                if end + 1 < characters.count, characters[end] == "-", characters[end + 1] == " ",
                    let before = result.last, Language.russian.isLetter(before) || ",.!?)\"".contains(before),
                    let after = characters[(end + 1)...].first(where: { $0 != " " }),
                    Language.russian.isLetter(after)
                {
                    result.append(contentsOf: " — ")
                    position = end + 1
                    while position < characters.count, characters[position] == " " { position += 1 }
                    continue
                }
                result.append(" ")
                position = end
                continue
            }
            result.append(character)
            position += 1
        }
        return String(result)
    }

    // MARK: - Commas

    private func insertCommas(_ text: String) -> String {
        var tokens = Tokenizer.tokens(in: text)
        // Indices of tokens after which a comma is appended.
        var commaAfter = Set<Int>()
        let wordIndices = tokens.indices.filter { tokens[$0].isWord }

        func lower(_ index: Int) -> String { tokens[index].text.lowercased() }
        /// The separator between two consecutive word tokens is exactly one space.
        func joined(_ left: Int, _ right: Int) -> Bool { right == left + 2 && tokens[left + 1].text == " " }

        for (order, index) in wordIndices.enumerated() {
            guard let language = tokens[index].language else { continue }
            // Words of the same clause before this one.
            var previous: [Int] = []
            var cursor = order
            while cursor > 0, joined(wordIndices[cursor - 1], wordIndices[cursor]), previous.count < 3 {
                previous.insert(wordIndices[cursor - 1], at: 0)
                cursor -= 1
            }
            let next: Int? =
                order + 1 < wordIndices.count && joined(index, wordIndices[order + 1])
                ? wordIndices[order + 1] : nil
            let word = lower(index)

            if language == .russian, let before = previous.last {
                if PunctuationRules.needsCommaBefore(
                    word: word, next: next.map(lower), previous: previous.map(lower), language: .russian)
                {
                    commaAfter.insert(before)
                } else if previous.count >= 2,
                    PunctuationRules.needsCommaBeforePreposition(
                        word: word, preposition: lower(before), previous: lower(previous[previous.count - 2]))
                {
                    commaAfter.insert(previous[previous.count - 2])
                }
            }

            // Introductory phrases starting at this word.
            let phrases =
                language == .russian
                ? PunctuationRules.russianParentheticals : PunctuationRules.englishIntroductions
            for phrase in phrases where phrase[0] == word {
                var members = [index]
                var position = order
                var matched = true
                for expected in phrase.dropFirst() {
                    guard position + 1 < wordIndices.count,
                        joined(wordIndices[position], wordIndices[position + 1]),
                        lower(wordIndices[position + 1]) == expected
                    else {
                        matched = false
                        break
                    }
                    position += 1
                    members.append(wordIndices[position])
                }
                guard matched, var last = members.last else { continue }
                if language == .russian, position + 1 < wordIndices.count,
                    joined(wordIndices[position], wordIndices[position + 1]),
                    lower(wordIndices[position + 1]) == "же"
                {
                    position += 1
                    last = wordIndices[position]
                }
                let followedByWord =
                    position + 1 < wordIndices.count && joined(last, wordIndices[position + 1])
                if language == .english {
                    // Only sentence-opening adverbials: "However, …".
                    let startsSentence = index == 0 || Self.endsSentence(separator: tokens[index - 1].text)
                    if startsSentence && followedByWord { commaAfter.insert(last) }
                } else {
                    if followedByWord { commaAfter.insert(last) }
                    if let before = previous.last, !["и", "а", "но", "да", "или"].contains(lower(before)) {
                        commaAfter.insert(before)
                    }
                }
            }
        }

        for index in commaAfter.sorted(by: >) { tokens[index].text += "," }
        return tokens.map(\.text).joined()
    }

    /// True for the gap between two sentences: ". ", "! ", a line break — but not "2.4.1 " or ", ".
    private static func endsSentence(separator: String) -> Bool {
        if separator.contains(where: \.isNewline) { return true }
        let trimmed = separator.trimmingCharacters(in: .whitespaces)
        return [".", "!", "?", "…", "...", ".\"", "!\"", "?\"", ".)", "!)", "?)"].contains(trimmed)
    }

    // MARK: - Articles

    private func fixArticles(_ text: String) -> String {
        var tokens = Tokenizer.tokens(in: text)
        guard tokens.count >= 3 else { return text }
        for index in 0..<(tokens.count - 2) {
            let article = tokens[index].text
            guard tokens[index].language == .english, ["a", "an"].contains(article.lowercased()),
                tokens[index + 1].text == " ", tokens[index + 2].language == .english
            else { continue }
            let following = tokens[index + 2].text
            guard engine.vocabulary.isKnown(following, language: .english),
                engine.vocabulary.knowledge(of: following, language: .english).isTerm == false,
                let expected = PunctuationRules.indefiniteArticle(before: following),
                expected != article.lowercased()
            else { continue }
            tokens[index].text = article.first?.isUppercase == true ? expected.capitalizedFirst : expected
        }
        return tokens.map(\.text).joined()
    }
}
