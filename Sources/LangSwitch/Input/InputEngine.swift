import AppKit
import CoreGraphics
import Foundation
import LangSwitchCore
import LangSwitchLexicon

/// Values handed from the C tap callback into the input actor. The callback runs on the input thread,
/// so nothing actually crosses threads; the wrapper only states that to the compiler.
private struct TapInvocation: @unchecked Sendable {
    let proxy: CGEventTapProxy
    let type: CGEventType
    let event: CGEvent
    let engine: UnsafeMutableRawPointer
}

private func tapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let invocation = TapInvocation(proxy: proxy, type: type, event: event, engine: refcon)
    let swallow = InputActor.assumeIsolated {
        Unmanaged<InputEngine>.fromOpaque(invocation.engine).takeUnretainedValue()
            .handle(invocation.type, invocation.event, invocation.proxy)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

/// Watches the keyboard, keeps the typing session and applies corrections.
@InputActor
final class InputEngine {
    private let emit: @Sendable (InputEvent) -> Void
    private let injector = TextInjector()
    private let ownBundleID = Bundle.main.bundleIdentifier

    private var runtime: LanguageRuntime?
    private var session: TypingSession?
    private var config = EngineConfig()
    private var snapshot = LayoutSnapshot()
    private var recentLayouts: [String] = []
    private var application = FrontApplication()
    private var learning = LearningData()
    private var counters = TypingCounters()
    private var collector = PhraseCollector()
    private var flushScheduled = false
    private var diagnostics = EngineDiagnostics()
    private let tracing = ProcessInfo.processInfo.environment["LANGSWITCH_TRACE"] == "1"

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?

    /// A layout switch we requested; until macOS confirms it, keys are rewritten to the new layout.
    private var pendingLayout: (layout: KeyboardLayout, deadline: CFAbsoluteTime)?
    private var completion: CompletionEngine.Suggestion?
    private var popupActive = false
    private var lastAutoConversion: (typed: String, corrected: String)?

    // Double-Shift detection.
    private var shiftDownAt: CFAbsoluteTime?
    private var shiftIsClean = false
    private var lastShiftTapAt: CFAbsoluteTime = 0

    nonisolated init(emit: @escaping @Sendable (InputEvent) -> Void) {
        self.emit = emit
    }

    // MARK: - Lifecycle

    /// Loads dictionaries and models. Takes a moment; called once after launch.
    func load(learning: LearningData) -> Bool {
        self.learning = learning
        // Heal data written by earlier builds: words that were "learned" only because a conversion had
        // failed. They are judged against a vocabulary that does not contain them yet.
        var cleaned = learning
        let suspects = cleaned.autoLearned
        cleaned.removeAutoLearned { _ in true }
        let runtime = LanguageRuntime(personal: cleaned.vocabulary)
        let invalid = Set(
            suspects.filter { word in
                guard let language = Language.dominant(in: word) else { return true }
                return !runtime.engine.mayLearn(word, language: language, layouts: KeyboardLayout.builtIn)
            })
        if !invalid.isEmpty {
            self.learning.removeAutoLearned { invalid.contains($0) }
            diagnostics.removedLearnedWords = invalid.count
            scheduleFlush()
        }
        self.learning.forgetStaleObservations()
        runtime.vocabulary.personal = self.learning.vocabulary
        self.runtime = runtime
        rebuildSession()
        return runtime.hasFullDictionaries
    }

    /// Installs the keyboard tap. Fails until Accessibility access is granted.
    func startTap() -> Bool {
        if tap != nil { return true }
        var mask: CGEventMask = 0
        for type in [
            CGEventType.keyDown, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown,
            .otherMouseDown,
        ] {
            mask |= CGEventMask(1) << CGEventMask(type.rawValue)
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask,
                callback: tapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(InputActor.executor.cfRunLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.tapSource = source
        return true
    }

    func stopTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let tapSource { CFRunLoopRemoveSource(InputActor.executor.cfRunLoop, tapSource, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.tapSource = nil
    }

    // MARK: - Commands from the main actor

    func configure(_ config: EngineConfig) {
        self.config = config
        applyOptions()
        if !config.completion { hideCompletion() }
    }

    func setLayouts(_ snapshot: LayoutSnapshot, recent: [String], byUser: Bool) {
        recentLayouts = recent
        if let pending = pendingLayout, snapshot.currentID == pending.layout.id {
            pendingLayout = nil
            self.snapshot = snapshot
            return
        }
        if !byUser, let pending = pendingLayout, CFAbsoluteTimeGetCurrent() < pending.deadline {
            // A late notice about an earlier switch, while a newer one is under way: keep the newer
            // belief. If it is wrong, the next key press says so and the session follows the keyboard.
            self.snapshot.layouts = snapshot.layouts
            return
        }
        pendingLayout = nil
        self.snapshot = snapshot
        guard let current = snapshot.current else {
            session = nil
            hideCompletion()
            return
        }
        let layouts = TypingSession.Layouts(
            current: current, alternative: snapshot.alternative(preferring: recent))
        if session == nil {
            rebuildSession()
        } else {
            session?.layoutsChanged(layouts, byUser: byUser)
        }
        if byUser { hideCompletion() }
        if byUser { diagnostics.layoutChangesByUser += 1 } else { diagnostics.layoutChangesByApp += 1 }
    }

    func setApplication(_ application: FrontApplication) {
        guard application != self.application else { return }
        self.application = application
        session?.interrupt()
        collector.reset()
        lastAutoConversion = nil
        hideCompletion()
        applyOptions()
    }

    func setPopupActive(_ active: Bool) { popupActive = active }

    /// Types `text` over the current selection.
    func replaceSelection(with text: String) {
        injector.type(text, proxy: nil)
        session?.interrupt()
    }

    func suggestions(for word: String) -> [WordSuggestion] {
        runtime?.suggestions.suggestions(for: word) ?? []
    }

    func fix(_ text: String, options: CorrectionOptions) -> TextFixer.Result {
        runtime?.fixer.fix(text, options: options) ?? TextFixer.Result(text: text, kinds: [])
    }

    func convertLayout(of text: String) -> String {
        runtime?.fixer.convertLayout(text) ?? text
    }

    func trainerContent() -> TrainerContent { runtime?.resources.trainer ?? TrainerContent() }

    /// Applies an edit to what the application has learned (from the dictionary screen).
    func updateLearning(_ change: @Sendable (inout LearningData) -> Void) {
        change(&learning)
        runtime?.vocabulary.personal = learning.vocabulary
        emit(.learning(learning, counters))
        counters = TypingCounters()
    }

    /// Hands the current learning data to the main actor for saving.
    func flush() {
        flushScheduled = false
        emit(.learning(learning, counters))
        counters = TypingCounters()
        diagnostics.currentLayout = session?.layouts.current.id ?? "none"
        diagnostics.alternativeLayout = session?.layouts.alternative?.id ?? "none"
        diagnostics.hasSession = session != nil
        emit(.diagnostics(diagnostics))
    }

    /// Layouts used to ask "what would this word be on the other layout?" when learning.
    private var learningLayouts: [KeyboardLayout] {
        snapshot.layouts.isEmpty ? KeyboardLayout.builtIn : snapshot.layouts
    }

    // MARK: - State helpers

    private var isOwnApplication: Bool { application.bundleID != nil && application.bundleID == ownBundleID }

    private var isExcluded: Bool {
        guard let id = application.bundleID else { return false }
        return id == ownBundleID || config.excludedApplications.contains(id)
    }

    private func rebuildSession() {
        guard runtime != nil, let current = snapshot.current else {
            session = nil
            return
        }
        session = TypingSession(
            layouts: TypingSession.Layouts(
                current: current, alternative: snapshot.alternative(preferring: recentLayouts)))
        applyOptions()
    }

    private func applyOptions() {
        var options = config.enabled ? config.options : CorrectionOptions.none
        if let id = application.bundleID, config.layoutOnlyApplications.contains(id) {
            options = CorrectionOptions(
                layout: options.layout, spelling: false, punctuation: false, capitalization: false)
        }
        session?.options = options
        session?.backspaceUndoes = config.backspaceUndoes
        session?.convertsEarly = config.convertsEarly
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @InputActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.flushScheduled else { return }
            self.flush()
        }
    }

    private func hideCompletion() {
        guard completion != nil else { return }
        completion = nil
        emit(.completion(nil))
    }

    private func switchLayout(to id: String) {
        guard let layout = snapshot.layouts.first(where: { $0.id == id }) else { return }
        snapshot.currentID = id
        session?.layoutsChanged(
            TypingSession.Layouts(
                current: layout, alternative: snapshot.alternative(preferring: recentLayouts)),
            byUser: false)
        pendingLayout = (layout, CFAbsoluteTimeGetCurrent() + 0.6)
        emit(.selectLayout(id))
    }

    // MARK: - Event handling

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent, _ proxy: CGEventTapProxy) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            session?.interrupt()
            hideCompletion()
            return false
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            session?.interrupt()
            hideCompletion()
            shiftDownAt = nil
            if popupActive { emit(.mouseDown) }
            return false
        case .leftMouseUp:
            if config.suggestsOnDoubleClick, !isExcluded,
                event.getIntegerValueField(.mouseEventClickState) == 2
            {
                emit(.doubleClick)
            }
            return false
        case .flagsChanged:
            handleFlags(event, proxy)
            return false
        case .keyDown:
            if TextInjector.isOwn(event) { return false }
            return handleKeyDown(event, proxy)
        default:
            return false
        }
    }

    private func handleFlags(_ event: CGEvent, _ proxy: CGEventTapProxy) {
        guard config.doubleShiftConverts, !isExcluded else { return }
        let flags = event.flags.intersection(Hotkey.relevantFlags)
        let now = CFAbsoluteTimeGetCurrent()
        if flags == .maskShift {
            shiftDownAt = now
            shiftIsClean = true
        } else if flags.isEmpty, let downAt = shiftDownAt {
            shiftDownAt = nil
            guard shiftIsClean, now - downAt < 0.3 else { return }
            if now - lastShiftTapAt < 0.45 {
                lastShiftTapAt = 0
                convertManually(proxy)
            } else {
                lastShiftTapAt = now
            }
        } else {
            shiftDownAt = nil
        }
    }

    private func handleKeyDown(_ event: CGEvent, _ proxy: CGEventTapProxy) -> Bool {
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        shiftIsClean = false
        lastShiftTapAt = 0

        for (action, hotkey) in config.hotkeys where hotkey.matches(keyCode: keyCode, flags: flags) {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return true }
            if action == .convertLayout {
                convertManually(proxy)
            } else {
                emit(.hotkey(action))
            }
            return true
        }

        if popupActive {
            switch keyCode {
            case KeyCode.upArrow:
                emit(.popupKey(.up))
                return true
            case KeyCode.downArrow:
                emit(.popupKey(.down))
                return true
            case KeyCode.returnKey, KeyCode.keypadEnter, KeyCode.tab:
                emit(.popupKey(.confirm))
                return true
            case KeyCode.escape:
                emit(.popupKey(.dismiss))
                return true
            case 18, 19, 20, 21, 23, 22, 26, 28, 25:
                let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
                emit(.popupKey(.number(digits[keyCode] ?? 1)))
                return true
            default:
                emit(.popupKey(.dismiss))
            }
        }

        guard !isExcluded, session != nil, let runtime else { return false }
        let command = flags.contains(.maskCommand)
        let control = flags.contains(.maskControl)
        let option = flags.contains(.maskAlternate)
        let shift = flags.contains(.maskShift)

        if let suggestion = completion {
            if keyCode == config.completionAcceptKey, !command, !control, !option, !shift {
                completion = nil
                injector.type(suggestion.remainder, proxy: proxy)
                session?.inserted(suggestion.remainder)
                emit(.completion(nil))
                emit(.completionAccepted)
                return true
            }
            hideCompletion()
        }

        if command || control {
            session?.interrupt()
            return false
        }

        switch keyCode {
        case KeyCode.delete:
            if option {
                session?.interrupt()
                return false
            }
            guard let output = session?.backspace(), case .replace(let replacement, _) = output else {
                updateCompletion()
                return false
            }
            return apply(replacement, redeliver: nil, proxy)
        case KeyCode.space, KeyCode.returnKey, KeyCode.keypadEnter, KeyCode.tab:
            if option {
                session?.taint()
                return false
            }
            let boundary: Boundary =
                keyCode == KeyCode.space ? .space : keyCode == KeyCode.tab ? .tab : .newline
            return handleBoundary(boundary, event, proxy, runtime)
        default:
            if KeyCode.navigation.contains(keyCode) {
                session?.interrupt()
                return false
            }
            var length = 0
            var units = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(
                maxStringLength: 4, actualStringLength: &length, unicodeString: &units)
            guard length == 1, let scalar = Unicode.Scalar(units[0]), scalar.value >= 0x20,
                scalar.value != 0x7F,
                !(0xF700...0xF8FF).contains(scalar.value)
            else {
                // Function keys carry private-use characters and change nothing; anything else is unknown text.
                if length != 1 || !(0xF700...0xF8FF).contains(Int(units[0])) { session?.taint() }
                return false
            }
            if option {
                session?.taint()
                return false
            }
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                // A held key: macOS may show the accent menu instead of repeating, so the number of
                // characters in the field is unknown.
                session?.taint()
                return false
            }
            let stroke = KeyStroke(keyCode: keyCode, shift: shift, capsLock: flags.contains(.maskAlphaShift))
            var produced = Character(scalar)
            if let pending = pendingLayout {
                if CFAbsoluteTimeGetCurrent() < pending.deadline,
                    let rewritten = pending.layout.character(for: stroke)
                {
                    // macOS has not switched yet: make this key type what the new layout would.
                    let replacement = Array(String(rewritten).utf16)
                    event.keyboardSetUnicodeString(
                        stringLength: replacement.count, unicodeString: replacement)
                    produced = rewritten
                } else {
                    pendingLayout = nil
                }
            }
            if session?.isUnanchored == true, session?.currentText.isEmpty == true {
                // The user deleted past what we had seen. Ask the field where the caret landed: at a
                // word start everything works as usual; inside a word nothing must be touched.
                switch Accessibility.caretContext() {
                case .wordStart: session?.anchor()
                case .insideWord: session?.taint()
                case .unknown: break
                }
            }
            if session?.character(stroke, produced: produced) == true, let current = session?.layouts.current
            {
                // The key typed what only the other layout explains: follow the keyboard, not the notice.
                snapshot.currentID = current.id
                diagnostics.layoutResyncs += 1
            }
            counters.characters += 1
            diagnostics.keys += 1
            scheduleFlush()
            if convertEarly(runtime, proxy) { return true }
            updateCompletion()
            return false
        }
    }

    private func handleBoundary(
        _ boundary: Boundary, _ event: CGEvent, _ proxy: CGEventTapProxy, _ runtime: LanguageRuntime
    ) -> Bool {
        guard var session else { return false }
        let typed = session.currentText
        let previous = session.previousWord
        let summary = typed.isEmpty ? nil : session.chunkSummary
        if !typed.isEmpty {
            diagnostics.boundaries += 1
            if session.isTainted { diagnostics.taintedChunks += 1 }
            if session.layouts.alternative == nil { diagnostics.chunksWithoutAlternative += 1 }
        }
        let keyCodes = tracing ? session.currentKeyCodes : []
        let alternative =
            tracing ? session.layouts.alternative?.render(keyCodes.map { KeyStroke(keyCode: $0) }) : nil
        let (output, result) = session.boundary(boundary, engine: runtime.engine)
        self.session = session
        if let summary {
            let layout = session.layouts.current.language.rawValue
            let outcome: String
            if case .replace(let replacement, _) = output {
                outcome = "replace kinds=\(replacement.kinds.rawValue)"
            } else {
                outcome = "pass"
            }
            diagnostics.note("boundary layout=\(layout) \(summary) → \(outcome)")
        }
        if tracing, !typed.isEmpty {
            diagnostics.trace =
                "typed=\(typed) keys=\(keyCodes) alternative=\(alternative ?? "nil") result=\(result?.text ?? "nil") "
                + "kinds=\(result?.kinds.rawValue ?? -1)"
        }
        if let result {
            learn(from: result, typed: typed, previous: previous, boundary: boundary, runtime: runtime)
        }
        guard case .replace(let replacement, _) = output else {
            suggestNextWord(boundary: boundary, runtime: runtime)
            return false
        }
        let applied = apply(replacement, redeliver: event, proxy)
        if applied, replacement.kinds.contains(.layout) {
            lastAutoConversion = (replacement.original, replacement.corrected)
        }
        return applied
    }

    /// Performs a replacement in the focused field. Returns true when the triggering key was consumed.
    private func apply(_ replacement: Replacement, redeliver event: CGEvent?, _ proxy: CGEventTapProxy?)
        -> Bool
    {
        // An inline suggestion is selected (address bars): Backspace would eat it instead of our text.
        if let selected = Accessibility.selectionLength(), selected > 0 {
            session?.interrupt()
            diagnostics.skippedBecauseOfSelection += 1
            scheduleFlush()
            return false
        }
        if replacement.kinds.contains(.layout) {
            diagnostics.layoutConversions += 1
        } else {
            diagnostics.otherCorrections += 1
        }
        injector.apply(replacement, proxy: proxy)
        if let event, let copy = event.copy() {
            copy.setIntegerValueField(.eventSourceUserData, value: TextInjector.marker)
            if let proxy { copy.tapPostEvent(proxy) } else { copy.post(tap: .cgSessionEventTap) }
        }
        if let id = replacement.switchLayoutTo { switchLayout(to: id) }
        if replacement.isUndo { lastAutoConversion = nil }
        emit(.corrected(replacement, application: application.name))
        return true
    }

    private func convertManually(_ proxy: CGEventTapProxy?) {
        guard !isExcluded, var session else {
            emit(.hotkey(.convertLayout))
            return
        }
        guard let replacement = session.convertManually() else {
            // Nothing typed that we know of: let the main actor try the selection.
            emit(.hotkey(.convertLayout))
            return
        }
        self.session = session
        hideCompletion()
        let rejected = lastAutoConversion
        guard apply(replacement, redeliver: nil, proxy) else { return }
        if replacement.isUndo {
            // Taking back an automatic layout conversion by hand is the one signal that teaches
            // "leave this alone"; a plain Backspace never is.
            if let rejected, replacement.kinds.contains(.layout) {
                _ = learning.recordRejection(typed: rejected.typed)
            }
            // Taking back a spelling fix says "this is my word": remember it at once.
            if replacement.kinds.contains(.spelling), !replacement.corrected.contains(" "),
                LearningData.isLearnable(replacement.corrected)
            {
                learning.addWord(replacement.corrected)
            }
        } else {
            _ = learning.recordManualConversion(typed: replacement.original)
        }
        runtime?.vocabulary.personal = learning.vocabulary
        scheduleFlush()
    }

    /// Converts the word being typed without waiting for the boundary, when the session is sure.
    /// Returns true when the key that triggered it was consumed.
    private func convertEarly(_ runtime: LanguageRuntime, _ proxy: CGEventTapProxy) -> Bool {
        guard var candidate = session, let replacement = candidate.earlyConversion(engine: runtime.engine)
        else {
            return false
        }
        if let selected = Accessibility.selectionLength(), selected > 0 {
            diagnostics.skippedBecauseOfSelection += 1
            return false
        }
        session = candidate
        hideCompletion()
        diagnostics.layoutConversions += 1
        diagnostics.note("early len=\(replacement.deleteCount) → replace kinds=\(replacement.kinds.rawValue)")
        // The key that tipped the decision has not reached the application yet, so one character fewer
        // is on screen than the session has counted.
        injector.backspace(replacement.deleteCount - 1, proxy: proxy)
        injector.type(replacement.insert, proxy: proxy)
        if let id = replacement.switchLayoutTo { switchLayout(to: id) }
        lastAutoConversion = (replacement.original, replacement.corrected)
        emit(.corrected(replacement, application: application.name))
        return true
    }

    // MARK: - Learning and completion

    private func learn(
        from result: ChunkResult, typed: String, previous: String?, boundary: Boundary,
        runtime: LanguageRuntime
    ) {
        guard let language = result.language else { return }
        let words = Tokenizer.words(in: result.text, language: language)
        counters.words += words.count
        if config.learnsWords, !TextProtection.isProtected(result.text) {
            var before = previous
            for word in words {
                let known = runtime.vocabulary.isKnown(word, language: language)
                // An unknown word left as typed is watched: see `WordObservation`.
                let learnability =
                    known
                    ? CorrectionEngine.Learnability.ordinary
                    : runtime.engine.learnability(of: word, language: language, layouts: learningLayouts)
                if let promoted = learning.recordWord(
                    word, previous: before, known: known, mayLearn: learnability != .never,
                    doubtful: learnability == .doubtful)
                {
                    runtime.vocabulary.personal = learning.vocabulary
                    emit(.learnedWord(promoted))
                }
                before = word
            }
            if result.kinds.contains(.spelling), words.count == 1, let word = words.first {
                learning.recordTypo(corrected: word)
            }
        }
        if config.collectsPhrases {
            let finished = collector.add(
                chunk: result.text, endsSentence: runtime.engine.endsSentence(result.text),
                endsLine: boundary == .newline)
            if let finished, let phraseLanguage = Language.dominant(in: finished) {
                emit(.phrase(finished, phraseLanguage, application: application.name ?? ""))
            }
        }
        scheduleFlush()
    }

    private func updateCompletion() {
        guard config.completion, config.enabled, let session, !session.isTainted, let runtime else {
            hideCompletion()
            return
        }
        if let id = application.bundleID, config.layoutOnlyApplications.contains(id) {
            hideCompletion()
            return
        }
        let language = session.language
        let text = session.currentText
        // The word being typed: the trailing run of letters of the chunk.
        var prefix = ""
        for character in text.reversed() {
            guard language.isLetter(character) else { break }
            prefix.insert(character, at: prefix.startIndex)
        }
        guard !prefix.isEmpty,
            let suggestion = runtime.completion.complete(
                prefix: prefix, language: language, previous: session.previousWord, learning: learning,
                minimumPrefix: config.completionMinimumPrefix)
        else {
            hideCompletion()
            return
        }
        if suggestion != completion {
            completion = suggestion
            emit(.completion(suggestion.remainder))
        }
    }

    private func suggestNextWord(boundary: Boundary, runtime: LanguageRuntime) {
        guard config.completion, config.enabled, boundary == .space, let previous = session?.previousWord,
            let next = runtime.completion.nextWord(after: previous, learning: learning)
        else { return }
        completion = CompletionEngine.Suggestion(word: next, remainder: next)
        emit(.completion(next))
    }
}
