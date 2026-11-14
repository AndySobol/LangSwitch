import CoreGraphics
import Foundation
import LangSwitchCore

/// Types into the focused application by posting keyboard events.
///
/// Deleting with Backspace and typing with Unicode key events is the one editing mechanism every text
/// field on macOS understands — native, web and Electron alike — and it keeps the application's own
/// undo history intact.
struct TextInjector {
    /// Marks events posted by LangSwitch so the event tap lets them through untouched.
    static let marker: Int64 = 0x4C_53_57_31  // "LSW1"

    private let source = CGEventSource(stateID: .privateState)

    static func isOwn(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    private func post(_ event: CGEvent, proxy: CGEventTapProxy?) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        if let proxy {
            // Inside the tap callback: inserted right behind the tap, ahead of any key still queued.
            event.tapPostEvent(proxy)
        } else {
            event.post(tap: .cgSessionEventTap)
        }
    }

    func key(_ keyCode: UInt16, flags: CGEventFlags = [], proxy: CGEventTapProxy?) {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown)
            else {
                continue
            }
            event.flags = flags
            post(event, proxy: proxy)
        }
    }

    func backspace(_ count: Int, proxy: CGEventTapProxy?) {
        for _ in 0..<max(count, 0) { key(KeyCode.delete, proxy: proxy) }
    }

    func type(_ text: String, proxy: CGEventTapProxy?) {
        // A key event carries at most 20 UTF-16 units; never split a grapheme between two events.
        var chunk: [UniChar] = []
        func flush() {
            guard !chunk.isEmpty else { return }
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else {
                    continue
                }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                post(event, proxy: proxy)
            }
            chunk.removeAll(keepingCapacity: true)
        }
        for character in text {
            if character == "\n" {
                flush()
                key(KeyCode.returnKey, proxy: proxy)
                continue
            }
            if character == "\t" {
                flush()
                key(KeyCode.tab, proxy: proxy)
                continue
            }
            let units = Array(String(character).utf16)
            if chunk.count + units.count > 20 { flush() }
            chunk.append(contentsOf: units)
        }
        flush()
    }

    func apply(_ replacement: Replacement, proxy: CGEventTapProxy?) {
        backspace(replacement.deleteCount, proxy: proxy)
        type(replacement.insert, proxy: proxy)
    }
}
