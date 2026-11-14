import CoreGraphics
import Foundation
import LangSwitchCore

/// A keyboard shortcut: one key plus modifiers.
struct Hotkey: Codable, Sendable, Hashable {
    var keyCode: UInt16
    var command = false
    var option = false
    var control = false
    var shift = false

    static let relevantFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    var flags: CGEventFlags {
        var flags: CGEventFlags = []
        if command { flags.insert(.maskCommand) }
        if option { flags.insert(.maskAlternate) }
        if control { flags.insert(.maskControl) }
        if shift { flags.insert(.maskShift) }
        return flags
    }

    func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        keyCode == self.keyCode && flags.intersection(Self.relevantFlags) == self.flags
    }

    /// A shortcut needs a modifier other than Shift, otherwise it would shadow ordinary typing.
    var isValid: Bool { command || option || control }

    private static let keyNames: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12",
    ]

    var display: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        if let name = Self.keyNames[keyCode] {
            text += name
        } else if let character = KeyboardLayout.abc.character(for: KeyStroke(keyCode: keyCode)) {
            text += String(character).uppercased()
        } else {
            text += "#\(keyCode)"
        }
        return text
    }
}

/// The commands a shortcut can trigger.
enum HotkeyAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case convertLayout
    case fixSelection
    case suggest
    case togglePause

    var id: String { rawValue }

    var defaultHotkey: Hotkey {
        switch self {
        case .convertLayout: Hotkey(keyCode: 37, option: true, control: true)  // ⌃⌥L
        case .fixSelection: Hotkey(keyCode: 3, option: true, control: true)  // ⌃⌥F
        case .suggest: Hotkey(keyCode: 1, option: true, control: true)  // ⌃⌥S
        case .togglePause: Hotkey(keyCode: 35, option: true, control: true)  // ⌃⌥P
        }
    }
}
