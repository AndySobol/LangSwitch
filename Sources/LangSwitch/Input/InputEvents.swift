import CoreGraphics
import Foundation
import LangSwitchCore

/// Settings the input engine works from. Built on the main actor, applied on the input actor.
struct EngineConfig: Sendable, Equatable {
    var enabled = true
    var options = CorrectionOptions()
    var backspaceUndoes = true
    var doubleShiftConverts = true
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
