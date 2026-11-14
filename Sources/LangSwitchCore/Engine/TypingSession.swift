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

    /// A finished chunk as it stands in the field, with enough to undo or toggle it.
    private struct Committed {
        var finalText: String
        /// ", " when a comma was inserted in place of the space before the chunk.
        var leading = ""
        var boundary: Boundary
        /// The keys that typed the chunk; empty when the text no longer maps to key presses.
        var strokes: [KeyStroke]
        /// What the user's keys produced before any correction.
        var typedText: String
        var layoutBefore: String
        var layoutAfter: String
        var corrected: Bool
        var kinds: CorrectionKinds
        var endsWithPunctuation: Bool
    }

    package var options = CorrectionOptions()
    /// Backspace right after an automatic correction restores what was typed. Off by default: deleting
    /// the space after a corrected word is far more often an edit than a protest.
    package var backspaceUndoes = false
    /// Convert an obviously mistyped word after a few letters instead of waiting for the space.
    package var convertsEarly = true
    package private(set) var layouts: Layouts

    private var typed: [Typed] = []
    /// The chunk contains something the session cannot reproduce; nothing about it can be trusted.
    private var tainted = false
    /// The chunk may have started in the middle of existing text: the caret was placed with the mouse,
    /// or the user deleted further back than the session had seen. The keys typed since are known
    /// exactly, so an obvious wrong layout can still be fixed; spelling needs the whole word.
    private var unanchored = false
    /// The user converted this chunk by hand; do not second-guess it at the boundary.
    private var manuallyConverted = false
    /// Set when the chunk was converted while being typed: the layout it was typed on.
    private var earlyOriginalLayout: KeyboardLayout?
    private var history: [Committed] = []
    /// Whitespace typed after the last committed chunk beyond its own boundary ("word␣␣").
    private var extraBoundaries = 0
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
    package var isUnanchored: Bool { unanchored }
    package var isAtSentenceStart: Bool { sentenceStart }
    /// Lower-case previous word, when it directly precedes the caret's chunk.
    package var previousWord: String? {
        guard let last = history.last, !last.endsWithPunctuation, last.boundary == .space,
            extraBoundaries == 0
        else { return nil }
        return Tokenizer.tokens(in: last.finalText).last(where: \.isWord)?.text.lowercased()
    }
    /// Language the user is currently writing in, judged by the layout.
    package var language: Language { layouts.current.language }

    /// A text-free description of the chunk being typed, for diagnostics.
    package var chunkSummary: String {
        let currentID = layouts.current.id
        let mismatches = typed.filter { layouts.current.character(for: $0.stroke) != $0.character }.count
        let uniform = typed.allSatisfy { $0.layoutID == currentID }
        return "len=\(typed.count) uniform=\(uniform) mismatch=\(mismatches) tainted=\(tainted) "
            + "unanchored=\(unanchored) early=\(earlyOriginalLayout != nil) manual=\(manuallyConverted)"
    }

    private mutating func resetChunk() {
        typed.removeAll(keepingCapacity: true)
        tainted = false
        manuallyConverted = false
        earlyOriginalLayout = nil
    }

    // MARK: - Events

    /// The system layout changed. `byUser` is false for switches the application performed itself.
    package mutating func layoutsChanged(_ layouts: Layouts, byUser: Bool) {
        self.layouts = layouts
        if byUser {
            context.manualSwitch = true
            if !typed.isEmpty { tainted = true }
        }
    }

    /// The caret is known to be at the start of a word after all.
    package mutating func anchor() { unanchored = false }

    /// Something happened that moved the caret or changed the text behind our back (a click, an arrow
    /// key, a shortcut, another application). Everything known about the field is void, including the
    /// language of the surrounding text, and the next chunk may start in the middle of a word.
    package mutating func interrupt() {
        resetChunk()
        history.removeAll(keepingCapacity: true)
        extraBoundaries = 0
        unanchored = true
        justCorrected = false
        sentenceStart = false
        context = LayoutDecider.Context()
    }

    /// Something was typed that the session cannot reproduce (a dead key, an Option combination, a held
    /// key). The field now contains characters the session did not count.
    package mutating func taint() {
        tainted = true
        justCorrected = false
    }

    /// A text key was pressed. `produced` is the character macOS reports for it, when available.
    ///
    /// The produced character is the ground truth about the active layout. If the key typed what only
    /// the *other* layout explains, the session was told about a layout switch too late or not at all;
    /// it follows the evidence and swaps its layouts. Returns true when that happened.
    @discardableResult
    package mutating func character(_ stroke: KeyStroke, produced: Character? = nil) -> Bool {
        justCorrected = false
        var resynced = false
        if let produced, let alternative = layouts.alternative,
            let expected = layouts.current.character(for: stroke), expected != produced,
            alternative.character(for: stroke) == produced
        {
            let previous = layouts.current
            layouts = Layouts(current: alternative, alternative: previous)
            // Earlier keys of this chunk were recorded with the same wrong assumption.
            typed = typed.map { entry in
                alternative.character(for: entry.stroke) == entry.character
                    ? Typed(stroke: entry.stroke, character: entry.character, layoutID: alternative.id)
                    : entry
            }
            resynced = true
        }
        guard let character = produced ?? layouts.current.character(for: stroke),
            !character.isWhitespace, !character.isNewline
        else {
            tainted = true
            return resynced
        }
        typed.append(Typed(stroke: stroke, character: character, layoutID: layouts.current.id))
        if typed.count > 96 { tainted = true }
        return resynced
    }

    /// Call after `character`: converts the chunk right away when it is clearly meant for the other
    /// layout. `deleteCount` counts every character of the chunk, including the key just pressed.
    package mutating func earlyConversion(engine: CorrectionEngine) -> Replacement? {
        guard convertsEarly, options.layout, !tainted, !manuallyConverted, earlyOriginalLayout == nil,
            typed.count >= 4, typed.count <= 14, let alternative = layouts.alternative
        else { return nil }
        let original = layouts.current
        guard typed.allSatisfy({ $0.layoutID == original.id }) else { return nil }
        let text = currentText
        let strokes = typed.map(\.stroke)
        let converted = alternative.render(strokes)
        guard converted.count == strokes.count,
            engine.decider.shouldConvertEarly(
                typed: text, typedLanguage: original.language, alternative: converted, context: context)
        else { return nil }
        typed = zip(strokes, converted).map { Typed(stroke: $0, character: $1, layoutID: alternative.id) }
        earlyOriginalLayout = original
        justCorrected = false
        return Replacement(
            deleteCount: text.count, insert: converted, switchLayoutTo: alternative.id, kinds: .layout,
            original: text, corrected: converted)
    }

    /// Text arrived that was not typed key by key (an accepted completion).
    package mutating func inserted(_ text: String) {
        justCorrected = false
        guard !text.contains(where: \.isWhitespace), let strokes = layouts.current.strokes(for: text) else {
            tainted = true
            return
        }
        for (stroke, character) in zip(strokes, text) {
            typed.append(Typed(stroke: stroke, character: character, layoutID: layouts.current.id))
        }
    }

    package mutating func backspace() -> SessionOutput {
        if justCorrected, backspaceUndoes, extraBoundaries == 0, let last = history.last, last.corrected,
            last.boundary == .space
        {
            justCorrected = false
            return .replace(undo(last), swallowKey: true)
        }
        justCorrected = false
        if tainted {
            // Unknown characters are in the field: after deleting, the caret may be anywhere.
            resetChunk()
            history.removeAll(keepingCapacity: true)
            extraBoundaries = 0
            unanchored = true
            return .pass
        }
        if !typed.isEmpty {
            typed.removeLast()
            if typed.isEmpty {
                // The chunk is gone, and with it everything that was decided about it.
                manuallyConverted = false
                earlyOriginalLayout = nil
            }
            return .pass
        }
        if extraBoundaries > 0 {
            extraBoundaries -= 1
            return .pass
        }
        if let last = history.popLast() {
            // The boundary is being deleted: the caret is back at the end of the previous chunk.
            if last.boundary != .newline, !last.corrected, last.layoutBefore == layouts.current.id,
                last.strokes.count == last.typedText.count, !last.strokes.isEmpty
            {
                typed = zip(last.strokes, last.typedText).map {
                    Typed(stroke: $0, character: $1, layoutID: last.layoutBefore)
                }
            } else {
                // A corrected chunk no longer maps to key presses: from here on the caret is inside
                // text the session cannot account for.
                history.removeAll(keepingCapacity: true)
                unanchored = true
            }
            return .pass
        }
        unanchored = true
        return .pass
    }

    /// Restores what the user typed in place of the last committed chunk.
    private mutating func undo(_ last: Committed) -> Replacement {
        history.removeLast()
        var restored = last
        restored.finalText = last.typedText
        restored.corrected = false
        restored.layoutAfter = last.layoutBefore
        restored.leading = ""
        history.append(restored)
        return Replacement(
            deleteCount: last.leading.count + last.finalText.count + 1,
            insert: (last.leading.isEmpty ? "" : " ") + last.typedText + String(last.boundary.character),
            switchLayoutTo: last.layoutBefore != layouts.current.id ? last.layoutBefore : nil,
            kinds: last.kinds, original: last.finalText, corrected: last.typedText, isUndo: true)
    }

    /// Space, Tab or Return: the chunk is complete.
    package mutating func boundary(_ boundary: Boundary, engine: CorrectionEngine) -> (
        SessionOutput, ChunkResult?
    ) {
        justCorrected = false
        guard !typed.isEmpty else {
            if tainted {
                // Something unknown was typed and then a boundary: nothing behind the caret is known.
                tainted = false
                history.removeAll(keepingCapacity: true)
                extraBoundaries = 0
            } else if boundary == .newline {
                sentenceStart = true
                history.removeAll(keepingCapacity: true)
                extraBoundaries = 0
                context.endSentence()
            } else if !history.isEmpty {
                // A second space: the next chunk no longer directly follows the previous word.
                extraBoundaries += 1
            }
            // Whatever preceded, the next chunk starts right after whitespace.
            unanchored = false
            return (.pass, nil)
        }
        let wasUnanchored = unanchored
        let earlyOriginal = earlyOriginalLayout
        defer {
            resetChunk()
            unanchored = false
            if history.count > 8 { history.removeFirst(history.count - 8) }
        }
        if tainted {
            history.removeAll(keepingCapacity: true)
            extraBoundaries = 0
            sentenceStart = false
            context.manualSwitch = false
            return (.pass, nil)
        }

        let text = currentText
        let strokes = typed.map(\.stroke)
        let layoutID = layouts.current.id
        let uniform = typed.allSatisfy { $0.layoutID == layoutID }
        let adjacent = extraBoundaries == 0
        var result = ChunkResult(text: text, language: Language.dominant(in: text))

        // A chunk that may be the tail of an existing word gets its layout fixed and nothing else.
        let options =
            wasUnanchored
            ? CorrectionOptions(
                layout: self.options.layout, spelling: false, punctuation: false, capitalization: false)
            : self.options
        if uniform, !options.isEmpty {
            var input = ChunkInput(typed: text, typedLanguage: layouts.current.language)
            if !manuallyConverted, earlyOriginal == nil, let alternative = layouts.alternative {
                let rendered = alternative.render(strokes)
                // A key outside the layout tables (the numeric keypad) would silently drop a character.
                if rendered.count == strokes.count {
                    input.alternative = rendered
                }
            }
            input.context = context
            input.context.fragment = wasUnanchored
            input.sentenceStart = sentenceStart && !wasUnanchored
            input.mayOpenSentence = history.isEmpty
            input.previousWords = wasUnanchored || !adjacent ? [] : previousWords()
            result = engine.process(input, options: options)
        }

        var output = SessionOutput.pass
        var leading = ""
        var layoutAfter = layoutID
        if result.converted, let alternative = layouts.alternative { layoutAfter = alternative.id }

        // The space slipped by one letter between this word and the previous one: repair both at once.
        // One slipped space is preferred to a second, missing one («ка кдела» is «как дела», not
        // «ка к дела»); any other repair of the word itself stands.
        let splitOnly = result.kinds == .spelling && result.text.contains(" ") && !text.contains(" ")
        if uniform, !wasUnanchored, adjacent, options.spelling, result.text == text || splitOnly,
            !result.commaBefore,
            let previous = history.last, previous.boundary == .space, !previous.corrected,
            previous.leading.isEmpty,
            previous.layoutAfter == layoutID, let language = result.language,
            let repair = engine.spaceSlip(previous: previous.finalText, current: text, language: language)
        {
            history.removeLast()
            let original = previous.finalText + " " + text
            let repaired = repair.0 + " " + repair.1
            history.append(
                Committed(
                    finalText: repaired, boundary: boundary, strokes: [], typedText: original,
                    layoutBefore: layoutID,
                    layoutAfter: layoutID, corrected: true, kinds: .spelling, endsWithPunctuation: false))
            justCorrected = true
            context.manualSwitch = false
            sentenceStart = false
            var merged = result
            merged.text = repaired
            merged.kinds = .spelling
            merged.hasKnownWord = true
            let replacement = Replacement(
                deleteCount: original.count, insert: repaired, switchLayoutTo: nil, kinds: .spelling,
                original: original, corrected: repaired)
            return (.replace(replacement, swallowKey: false), merged)
        }

        if result.text != text || result.commaBefore {
            var deleteCount = text.count
            var inserted = result.text
            var original = text
            if result.commaBefore, adjacent, history.last?.boundary == .space {
                // Reach back over the separating space: "сказал что" → "сказал, что".
                deleteCount += 1
                leading = ", "
                inserted = leading + result.text
            } else {
                result.commaBefore = false
                if result.text == text { result.kinds.remove(.punctuation) }
            }
            // The word before was too short to judge on its own («b» for «и»). Now that this chunk
            // proves the wrong layout, convert that word as well.
            if result.converted, leading.isEmpty, adjacent, let alternative = layouts.alternative,
                let index = history.indices.last,
                let earlier = retroConversion(of: history[index], to: alternative, engine: engine)
            {
                deleteCount += history[index].finalText.count + 1
                inserted = earlier + " " + result.text
                original = history[index].finalText + " " + text
                history[index].finalText = earlier
                history[index].layoutAfter = alternative.id
                history[index].corrected = true
                history[index].kinds = .layout
            }
            if inserted != text {
                let replacement = Replacement(
                    deleteCount: deleteCount, insert: inserted,
                    switchLayoutTo: layoutAfter != layoutID ? layoutAfter : nil, kinds: result.kinds,
                    original: original, corrected: inserted)
                output = .replace(replacement, swallowKey: false)
            }
        }

        // A chunk converted while it was being typed counts as corrected too.
        let corrected = output != .pass || earlyOriginal != nil
        history.append(
            Committed(
                finalText: result.text, leading: leading, boundary: boundary, strokes: strokes,
                typedText: earlyOriginal?.render(strokes) ?? text,
                layoutBefore: earlyOriginal?.id ?? layoutID,
                layoutAfter: layoutAfter, corrected: corrected,
                kinds: earlyOriginal != nil ? result.kinds.union(.layout) : result.kinds,
                endsWithPunctuation: result.text.last.map { !$0.isLetter && !$0.isNumber } ?? true))
        extraBoundaries = 0
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

    /// The other-layout reading of an earlier, uncorrected chunk, when it is a real word and the chunk
    /// as typed was not.
    private func retroConversion(
        of chunk: Committed, to alternative: KeyboardLayout, engine: CorrectionEngine
    )
        -> String?
    {
        guard chunk.boundary == .space, !chunk.corrected, chunk.leading.isEmpty,
            chunk.layoutBefore == layouts.current.id,
            chunk.layoutAfter == layouts.current.id, !chunk.strokes.isEmpty,
            chunk.strokes.count == chunk.typedText.count,
            chunk.finalText == chunk.typedText, chunk.typedText.count <= 3
        else { return nil }
        let rendered = alternative.render(chunk.strokes)
        guard rendered.count == chunk.strokes.count, rendered != chunk.typedText else { return nil }
        let own = engine.decider.reading(of: chunk.typedText, language: layouts.current.language)
        let other = engine.decider.reading(of: rendered, language: alternative.language)
        // Only when the typed form is not an everyday word of its language and the other reading is.
        guard other.allKnown, other.worstRank != nil, !(own.allKnown && own.worstRank != nil), !own.hasTerm,
            !own.hasPersonal
        else { return nil }
        return rendered
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

    /// The user's explicit gesture (double Shift or the shortcut).
    ///
    /// On the word being typed it re-types it on the other layout. Right after a finished word it undoes
    /// the correction that was just made, or converts the word if nothing had been corrected.
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
            earlyOriginalLayout = nil
            justCorrected = false
            return Replacement(
                deleteCount: original.count, insert: converted, switchLayoutTo: alternative.id,
                kinds: .layout,
                original: original, corrected: converted)
        }
        guard !tainted, extraBoundaries == 0, var last = history.popLast(), last.boundary != .newline else {
            return nil
        }
        justCorrected = false
        if last.corrected {
            // Undo: put back exactly what was typed, on the layout it was typed on.
            history.append(last)
            var replacement = undo(last)
            replacement.isUndo = true
            return replacement
        }
        guard last.layoutBefore == currentID, !last.strokes.isEmpty,
            last.strokes.count == last.typedText.count
        else {
            history.append(last)
            return nil
        }
        let target = alternative.render(last.strokes)
        guard target.count == last.strokes.count, target != last.finalText else {
            history.append(last)
            return nil
        }
        let replacement = Replacement(
            deleteCount: last.finalText.count + 1, insert: target + String(last.boundary.character),
            switchLayoutTo: alternative.id, kinds: .layout, original: last.finalText, corrected: target)
        // Remember the conversion as a correction, so that the same gesture toggles it back.
        last.finalText = target
        last.layoutAfter = alternative.id
        last.corrected = true
        last.kinds = .layout
        history.append(last)
        return replacement
    }
}
