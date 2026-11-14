import Foundation

/// The whitespace key that ends a chunk.
package enum Boundary: Sendable, Equatable {
    case space
    case tab
    case newline

    package var character: Character {
        switch self {
        case .space: " "
        case .tab: "\t"
        case .newline: "\n"
        }
    }
}

/// An edit to perform in the focused text field, expressed relative to the caret.
package struct Replacement: Sendable, Equatable {
    /// Characters to delete before the caret.
    package var deleteCount: Int
    /// Text to type in their place.
    package var insert: String
    /// Layout to select afterwards, when the edit changed the language being typed.
    package var switchLayoutTo: String?
    package var kinds: CorrectionKinds
    /// What the user had typed (for the HUD, statistics and undo).
    package var original: String
    /// What it became.
    package var corrected: String
    /// The edit restores what the user typed after an unwanted correction.
    package var isUndo = false
}

/// What the session wants done in response to a key.
package enum SessionOutput: Sendable, Equatable {
    /// Let the key through untouched.
    case pass
    /// Swallow the key, apply the replacement, then deliver the key (unless `swallowKey`).
    case replace(Replacement, swallowKey: Bool)
}

/// Tracks what is being typed in the focused field and decides when to step in.
///
/// The session never reads the screen. It reconstructs the current chunk from key presses and forgets
/// everything as soon as something happens that it cannot follow (a click, a shortcut, a focus change),
/// so a correction is only ever applied to text it has seen typed, character by character.
package struct TypingSession {
    package struct Layouts: Sendable, Equatable {
        package var current: KeyboardLayout
        package var alternative: KeyboardLayout?

        package init(current: KeyboardLayout, alternative: KeyboardLayout?) {
            self.current = current
            self.alternative = alternative
        }
    }

    private struct Typed {
        let stroke: KeyStroke
        let character: Character
        let layoutID: String
    }

    private struct Committed {
        var finalText: String
        /// ", " when a comma was inserted in place of the space before the chunk.
        var leading = ""
        var boundary: Boundary
        var strokes: [KeyStroke]
        var typedText: String
        var layoutBefore: String
        var layoutAfter: String
        var corrected: Bool
        var kinds: CorrectionKinds
        var endsWithPunctuation: Bool
    }

    package var options = CorrectionOptions()
    /// Backspace right after an automatic correction restores what was typed.
    package var backspaceUndoes = true
    /// Convert an obviously mistyped word after a few letters instead of waiting for the space.
    package var convertsEarly = true
    package private(set) var layouts: Layouts

    private var typed: [Typed] = []
    /// The chunk contains something the session cannot reproduce; leave it alone.
    private var tainted = false
    /// The user converted this chunk by hand; do not second-guess it at the boundary.
    private var manuallyConverted = false
    /// The chunk was already converted while being typed.
    private var earlyConverted = false
    private var history: [Committed] = []
    private var justCorrected = false
    private var sentenceStart = false
    private var context = LayoutDecider.Context()

    package init(layouts: Layouts) {
        self.layouts = layouts
    }

    // MARK: - State visible to the application

    /// Key codes of the chunk being typed (diagnostics).
    package var currentKeyCodes: [UInt16] { typed.map(\.stroke.keyCode) }

    /// Text of the chunk being typed, as it appears in the field.
    package var currentText: String { String(typed.map(\.character)) }
    package var isTainted: Bool { tainted }
    package var isAtSentenceStart: Bool { sentenceStart }
    /// Lower-case previous word, when it directly precedes the caret's chunk.
    package var previousWord: String? {
        guard let last = history.last, !last.endsWithPunctuation, last.boundary == .space else { return nil }
        return Tokenizer.tokens(in: last.finalText).last(where: \.isWord)?.text.lowercased()
    }
    /// Language the user is currently writing in, judged by the layout.
    package var language: Language { layouts.current.language }

    // MARK: - Events

    /// The system layout changed. `byUser` is false for switches the application performed itself.
    package mutating func layoutsChanged(_ layouts: Layouts, byUser: Bool) {
        self.layouts = layouts
        if byUser {
            context.manualSwitch = true
            if !typed.isEmpty { tainted = true }
        }
    }

    /// Something happened that moved the caret or changed the text behind our back.
    package mutating func interrupt(resetContext: Bool = false) {
        typed.removeAll(keepingCapacity: true)
        history.removeAll(keepingCapacity: true)
        tainted = false
        manuallyConverted = false
        earlyConverted = false
        justCorrected = false
        sentenceStart = false
        if resetContext { context = LayoutDecider.Context() }
    }

    /// Something was typed that the session cannot reproduce (a dead key, an Option combination).
    package mutating func taint() {
        tainted = true
        justCorrected = false
    }

    /// A text key was pressed. `produced` is the character macOS reports for it, when available.
    package mutating func character(_ stroke: KeyStroke, produced: Character? = nil) {
        justCorrected = false
        guard let character = produced ?? layouts.current.character(for: stroke) else {
            tainted = true
            return
        }
        if character.isWhitespace || character.isNewline {
            tainted = true
            return
        }
        typed.append(Typed(stroke: stroke, character: character, layoutID: layouts.current.id))
        if typed.count > 96 { tainted = true }
    }

    /// Call after `character`: converts the chunk right away when it is clearly meant for the other
    /// layout. `deleteCount` counts every character of the chunk, including the key just pressed.
    package mutating func earlyConversion(engine: CorrectionEngine) -> Replacement? {
        guard convertsEarly, options.layout, !tainted, !manuallyConverted, !earlyConverted, typed.count >= 4,
            typed.count <= 14, let alternative = layouts.alternative
        else { return nil }
        let currentID = layouts.current.id
        guard typed.allSatisfy({ $0.layoutID == currentID }) else { return nil }
        let text = currentText
        let strokes = typed.map(\.stroke)
        let converted = alternative.render(strokes)
        guard converted.count == strokes.count,
            engine.decider.shouldConvertEarly(
                typed: text, typedLanguage: layouts.current.language, alternative: converted, context: context
            )
        else { return nil }
        typed = zip(strokes, converted).map { Typed(stroke: $0, character: $1, layoutID: alternative.id) }
        earlyConverted = true
        justCorrected = false
        return Replacement(
            deleteCount: text.count, insert: converted, switchLayoutTo: alternative.id, kinds: .layout,
            original: text, corrected: converted)
    }

    /// Text arrived that was not typed key by key (paste, dictation, an accepted completion).
    package mutating func inserted(_ text: String) {
        justCorrected = false
        guard !text.contains(where: \.isWhitespace), let strokes = layouts.current.strokes(for: text) else {
            if text.contains(where: \.isWhitespace) { interrupt() } else { tainted = true }
            return
        }
        for (stroke, character) in zip(strokes, text) {
            typed.append(Typed(stroke: stroke, character: character, layoutID: layouts.current.id))
        }
    }

    package mutating func backspace() -> SessionOutput {
        if justCorrected, backspaceUndoes, let last = history.last, last.corrected, last.boundary != .newline
        {
            justCorrected = false
            history.removeLast()
            var restored = last
            restored.finalText = last.typedText
            restored.corrected = false
            restored.layoutAfter = last.layoutBefore
            restored.leading = ""
            history.append(restored)
            let replacement = Replacement(
                deleteCount: last.leading.count + last.finalText.count + 1,
                insert: (last.leading.isEmpty ? "" : " ") + last.typedText + String(last.boundary.character),
                switchLayoutTo: last.layoutAfter != last.layoutBefore ? last.layoutBefore : nil,
                kinds: last.kinds, original: last.finalText, corrected: last.typedText, isUndo: true)
            return .replace(replacement, swallowKey: true)
        }
        justCorrected = false
        if !typed.isEmpty {
            typed.removeLast()
            return .pass
        }
        if let last = history.popLast() {
            // The boundary is being deleted: the caret is back inside the previous chunk.
            if last.boundary != .newline, !last.corrected, last.layoutBefore == layouts.current.id {
                typed = zip(last.strokes, last.typedText).map {
                    Typed(stroke: $0, character: $1, layoutID: last.layoutBefore)
                }
                tainted = false
            } else {
                tainted = true
            }
            manuallyConverted = false
            return .pass
        }
        tainted = true
        return .pass
    }

    /// Space, Tab or Return: the chunk is complete.
    package mutating func boundary(_ boundary: Boundary, engine: CorrectionEngine) -> (
        SessionOutput, ChunkResult?
    ) {
        justCorrected = false
        defer {
            typed.removeAll(keepingCapacity: true)
            tainted = false
            manuallyConverted = false
            earlyConverted = false
            if history.count > 8 { history.removeFirst(history.count - 8) }
        }
        guard !typed.isEmpty else {
            if boundary == .newline {
                sentenceStart = true
                history.removeAll(keepingCapacity: true)
            } else if let last = history.indices.last {
                // A second space: the next chunk no longer directly follows the previous word.
                history[last].endsWithPunctuation = true
            }
            return (.pass, nil)
        }

        let text = currentText
        let strokes = typed.map(\.stroke)
        let layoutID = layouts.current.id
        let uniform = typed.allSatisfy { $0.layoutID == layoutID }
        var result = ChunkResult(text: text, language: Language.dominant(in: text))

        if !tainted, uniform, !options.isEmpty {
            var input = ChunkInput(typed: text, typedLanguage: layouts.current.language)
            if !manuallyConverted, !earlyConverted, let alternative = layouts.alternative {
                input.alternative = alternative.render(strokes)
            }
            input.context = context
            input.sentenceStart = sentenceStart
            input.mayOpenSentence = history.isEmpty
            input.previousWords = previousWords()
            result = engine.process(input, options: options)
        }

        var output = SessionOutput.pass
        var leading = ""
        var layoutAfter = layoutID
        if result.converted, let alternative = layouts.alternative { layoutAfter = alternative.id }
        if result.text != text || result.commaBefore {
            var deleteCount = text.count
            if result.commaBefore, history.last?.boundary == .space {
                // Reach back over the separating space: "сказал что" → "сказал, что".
                deleteCount += 1
                leading = ", "
            } else {
                result.commaBefore = false
                if result.text == text { result.kinds.remove(.punctuation) }
            }
            if leading + result.text != text {
                let replacement = Replacement(
                    deleteCount: deleteCount, insert: leading + result.text,
                    switchLayoutTo: layoutAfter != layoutID ? layoutAfter : nil, kinds: result.kinds,
                    original: text, corrected: result.text)
                output = .replace(replacement, swallowKey: false)
            }
        }

        // A chunk converted while it was being typed counts as corrected too: Backspace restores the
        // original keys on the original layout.
        let earlyOriginal = earlyConverted ? layouts.alternative : nil
        let corrected = output != .pass || earlyOriginal != nil
        history.append(
            Committed(
                finalText: result.text, leading: leading, boundary: boundary, strokes: strokes,
                typedText: earlyOriginal?.render(strokes) ?? text,
                layoutBefore: earlyOriginal?.id ?? layoutID,
                layoutAfter: layoutAfter, corrected: corrected,
                kinds: earlyOriginal != nil ? result.kinds.union(.layout) : result.kinds,
                endsWithPunctuation: result.text.last.map { !$0.isLetter && !$0.isNumber } ?? true))
        justCorrected = corrected

        if let language = result.language, result.hasKnownWord { context.note(language) }
        context.manualSwitch = false
        if boundary == .newline {
            sentenceStart = true
            history.removeAll(keepingCapacity: true)
            justCorrected = false
        } else {
            sentenceStart = engine.endsSentence(result.text)
        }
        if sentenceStart { context.endSentence() }
        return (output, result)
    }

    private func previousWords() -> [String] {
        var words: [String] = []
        for chunk in history.reversed() {
            guard chunk.boundary == .space, !chunk.endsWithPunctuation else { break }
            let chunkWords = Tokenizer.tokens(in: chunk.finalText).filter(\.isWord).map {
                $0.text.lowercased()
            }
            guard !chunkWords.isEmpty else { break }
            words.insert(contentsOf: chunkWords, at: 0)
            if words.count >= 3 { break }
            // A chunk that itself began with punctuation closes the clause.
            if let first = chunk.finalText.first, !first.isLetter { break }
        }
        return words
    }

    // MARK: - Manual conversion

    /// Re-types the current chunk — or the one just finished — on the other layout.
    package mutating func convertManually() -> Replacement? {
        guard let alternative = layouts.alternative else { return nil }
        let currentID = layouts.current.id
        if !typed.isEmpty {
            guard !tainted, typed.allSatisfy({ $0.layoutID == currentID }) else { return nil }
            let original = currentText
            let strokes = typed.map(\.stroke)
            let converted = alternative.render(strokes)
            guard converted.count == strokes.count, converted != original else { return nil }
            typed = zip(strokes, converted).map { Typed(stroke: $0, character: $1, layoutID: alternative.id) }
            manuallyConverted = true
            justCorrected = false
            return Replacement(
                deleteCount: original.count, insert: converted, switchLayoutTo: alternative.id,
                kinds: .layout,
                original: original, corrected: converted)
        }
        guard var last = history.popLast(), last.boundary != .newline else { return nil }
        // Toggle the finished chunk between what was typed and its other-layout reading.
        let target: String
        let targetLayout: String
        if last.layoutAfter == last.layoutBefore {
            guard last.layoutBefore == currentID else {
                history.append(last)
                return nil
            }
            target = alternative.render(last.strokes)
            targetLayout = alternative.id
        } else {
            target = last.typedText
            targetLayout = last.layoutBefore
        }
        guard !target.isEmpty, target != last.finalText else {
            history.append(last)
            return nil
        }
        let replacement = Replacement(
            deleteCount: last.leading.count + last.finalText.count + 1,
            insert: (last.leading.isEmpty ? "" : " ") + target + String(last.boundary.character),
            switchLayoutTo: targetLayout != currentID ? targetLayout : nil, kinds: .layout,
            original: last.finalText, corrected: target)
        last.finalText = target
        last.leading = ""
        last.layoutAfter = targetLayout
        last.corrected = false
        history.append(last)
        justCorrected = false
        return replacement
    }
}
