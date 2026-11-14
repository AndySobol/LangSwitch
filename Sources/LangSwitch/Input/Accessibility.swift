import AppKit
import ApplicationServices

/// Read-only queries about the focused text field. Safe to call from any thread; every call is bounded
/// by a short messaging timeout so an unresponsive application cannot stall typing.
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security → Accessibility.
    @MainActor static func requestTrust() {
        // The literal value of kAXTrustedCheckOptionPrompt, which is not concurrency-safe to reference.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func focusedElement(timeout: Float) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
                == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
                == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    /// Length of the selection in the focused field; nil when the application does not say.
    ///
    /// Address bars select their inline suggestion: a Backspace there removes the suggestion instead of
    /// the last typed character, so a correction must not be attempted while something is selected.
    static func selectionLength(timeout: Float = 0.05) -> Int? {
        guard let element = focusedElement(timeout: timeout), let range = selectedRange(of: element) else {
            return nil
        }
        return range.length
    }

    static func selectedText(timeout: Float = 0.25) -> String? {
        guard let element = focusedElement(timeout: timeout) else { return nil }
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
            let text = value as? String, !text.isEmpty
        else { return nil }
        return text
    }

    enum CaretContext {
        /// The caret is at the very start of the field or right after whitespace.
        case wordStart
        /// The caret follows a letter, digit or punctuation: text continues an existing word.
        case insideWord
        /// The application does not say.
        case unknown
    }

    /// What is immediately before the caret in the focused field.
    static func caretContext(timeout: Float = 0.05) -> CaretContext {
        guard let element = focusedElement(timeout: timeout), let range = selectedRange(of: element),
            range.length == 0, range.location >= 0
        else { return .unknown }
        if range.location == 0 { return .wordStart }
        var before = CFRange(location: range.location - 1, length: 1)
        guard let parameter = AXValueCreate(.cfRange, &before) else { return .unknown }
        var value: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
            let text = value as? String, let character = text.last
        else { return .unknown }
        return character.isWhitespace || character.isNewline ? .wordStart : .insideWord
    }

    /// True when the focused element accepts typing.
    static func focusIsEditable(timeout: Float = 0.25) -> Bool {
        guard let element = focusedElement(timeout: timeout) else { return false }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
            == .success,
            settable.boolValue
        {
            return true
        }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
            let role = role as? String
        else { return false }
        return ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"].contains(role)
    }

    /// Screen rectangle of the insertion point in AppKit coordinates (origin bottom-left), when available.
    static func caretRect(timeout: Float = 0.1) -> CGRect? {
        guard let element = focusedElement(timeout: timeout), let range = selectedRange(of: element),
            range.length == 0
        else { return nil }

        func bounds(_ range: CFRange) -> CGRect? {
            var range = range
            guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
            var value: CFTypeRef?
            guard
                AXUIElementCopyParameterizedAttributeValue(
                    element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value)
                    == .success,
                let value, CFGetTypeID(value) == AXValueGetTypeID()
            else { return nil }
            var rect = CGRect.zero
            guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 4, rect.height < 200
            else {
                return nil
            }
            return rect
        }

        var rect = bounds(range)
        if rect == nil || rect?.width ?? 0 > 2, range.location > 0 {
            // Many editors only report bounds for real characters: take the right edge of the previous one.
            if let previous = bounds(CFRange(location: range.location - 1, length: 1)) {
                rect = CGRect(x: previous.maxX, y: previous.minY, width: 1, height: previous.height)
            }
        }
        guard let rect, let primary = NSScreen.screens.first else { return nil }
        // Accessibility uses a top-left origin on the primary display.
        return CGRect(
            x: rect.minX, y: primary.frame.maxY - rect.maxY, width: max(rect.width, 1), height: rect.height)
    }

    /// Electron applications build their accessibility tree only when asked to.
    static func enableManualAccessibility(pid: pid_t) {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
