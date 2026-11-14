import CoreGraphics
import Foundation
import LangSwitchCore

/// Settings the input engine works from. Built on the main actor, applied on the input actor.
struct EngineConfig: Sendable, Equatable {
    var enabled = true
    var options = CorrectionOptions()
    var backspaceUndoes = true
    var doubleShiftConverts = true
    var convertsEarly = true
    var completion = true
    var completionMinimumPrefix = 3
    var completionAcceptKey = KeyCode.tab
    var hotkeys: [HotkeyAction: Hotkey] = [:]
    /// Bundle identifiers where LangSwitch does nothing at all.
    var excludedApplications: Set<String> = []
    /// Bundle identifiers where only the layout is fixed (terminals, code editors).
    var layoutOnlyApplications: Set<String> = []
    var learnsWords = true
    var collectsPhrases = false
    var suggestsOnDoubleClick = true
}

enum PopupKey: Sendable, Equatable {
    case up, down, confirm, dismiss
    case number(Int)
}

/// Typing activity since the last report.
struct TypingCounters: Sendable, Equatable {
    var words = 0
    var characters = 0
}

/// What the input engine tells the rest of the application.
enum InputEvent: Sendable {
    case corrected(Replacement, application: String?)
    case selectLayout(String)
    /// Ghost text to show after the caret; nil hides it.
    case completion(String?)
    case completionAccepted
    case hotkey(HotkeyAction)
    case doubleClick
    case mouseDown
    case popupKey(PopupKey)
    case learning(LearningData, TypingCounters)
    case diagnostics(EngineDiagnostics)
    case learnedWord(String)
    case phrase(String, Language, application: String)
    case tapStopped
}

/// The frontmost application, as far as the engine needs to know.
struct FrontApplication: Sendable, Equatable {
    var bundleID: String?
    var name: String?
    var processID: pid_t = 0
}

/// Counters that explain what the engine has been doing. Numbers and identifiers only, never text.
struct EngineDiagnostics: Sendable, Equatable {
    var currentLayout = "none"
    var alternativeLayout = "none"
    var hasSession = false
    var keys = 0
    var boundaries = 0
    var taintedChunks = 0
    var chunksWithoutAlternative = 0
    var layoutConversions = 0
    var otherCorrections = 0
    var skippedBecauseOfSelection = 0
    var interrupts = 0
    var layoutChangesByUser = 0
    var layoutChangesByApp = 0
    var removedLearnedWords = 0
    /// The last chunk as the engine saw it. Filled only when LANGSWITCH_TRACE=1 is set by a developer.
    var trace: String?

    var lines: [String] {
        [
            "engine.currentLayout: \(currentLayout)", "engine.alternativeLayout: \(alternativeLayout)",
            "engine.hasSession: \(hasSession)", "engine.keys: \(keys)", "engine.boundaries: \(boundaries)",
            "engine.taintedChunks: \(taintedChunks)",
            "engine.chunksWithoutAlternative: \(chunksWithoutAlternative)",
            "engine.layoutConversions: \(layoutConversions)", "engine.otherCorrections: \(otherCorrections)",
            "engine.skippedBecauseOfSelection: \(skippedBecauseOfSelection)",
            "engine.interrupts: \(interrupts)",
            "engine.layoutChangesByUser: \(layoutChangesByUser)",
            "engine.layoutChangesByApp: \(layoutChangesByApp)",
            "engine.removedLearnedWords: \(removedLearnedWords)",
        ] + (trace.map { ["engine.trace: \($0)"] } ?? [])
    }
}
