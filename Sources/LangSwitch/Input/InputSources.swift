import Carbon.HIToolbox
import Foundation
import LangSwitchCore

/// The keyboard layouts enabled in macOS and which one is selected.
struct LayoutSnapshot: Sendable, Equatable {
    var layouts: [KeyboardLayout] = []
    /// Identifier of the selected input source; nil when it is not a plain keyboard layout (an IME).
    var currentID: String?

    var current: KeyboardLayout? { layouts.first { $0.id == currentID } }

    /// The layout of the other script: the one a mistyped chunk is re-read on.
    func alternative(preferring recent: [String] = []) -> KeyboardLayout? {
        guard let current else { return nil }
        let others = layouts.filter { $0.language != current.language }
        return recent.lazy.compactMap { id in others.first { $0.id == id } }.first ?? others.first
    }
}

/// Wraps Text Input Sources. TIS must only be used on the main thread.
@MainActor
final class InputSources {
    private var sources: [String: TISInputSource] = [:]
    private(set) var snapshot = LayoutSnapshot()
    /// Most recently used layout identifiers, newest first.
    private(set) var recent: [String] = []
    /// A switch LangSwitch asked for and has not seen confirmed yet.
    private var expectedID: String?
    var onChange: ((LayoutSnapshot, _ byUser: Bool) -> Void)?

    init() {
        reload()
        let center = DistributedNotificationCenter.default()
        for name in [
            kTISNotifySelectedKeyboardInputSourceChanged as String,
            kTISNotifyEnabledKeyboardInputSourcesChanged as String,
        ] {
            center.addObserver(
                self, selector: #selector(inputSourcesChanged), name: Notification.Name(name), object: nil,
                suspensionBehavior: .deliverImmediately)
        }
    }

    @objc private func inputSourcesChanged() {
        let previous = snapshot
        reload()
        guard snapshot != previous else { return }
        let byUser = snapshot.currentID != expectedID
        if snapshot.currentID == expectedID { expectedID = nil }
        onChange?(snapshot, byUser)
    }

    private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }

    private func reload() {
        let filter =
            [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any]
            as CFDictionary
        let list = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
        var layouts: [KeyboardLayout] = []
        var sources: [String: TISInputSource] = [:]
        for source in list {
            guard let id: String = Self.property(source, kTISPropertyInputSourceID),
                let type: String = Self.property(source, kTISPropertyInputSourceType),
                type == (kTISTypeKeyboardLayout as String),
                let selectable: Bool = Self.property(source, kTISPropertyInputSourceIsSelectCapable),
                selectable,
                let layout = Self.makeLayout(source, id: id)
            else { continue }
            layouts.append(layout)
            sources[id] = source
        }
        self.sources = sources
        var currentID: String?
        if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
            let id: String = Self.property(current, kTISPropertyInputSourceID), sources[id] != nil
        {
            currentID = id
            recent.removeAll { $0 == id }
            recent.insert(id, at: 0)
        }
        snapshot = LayoutSnapshot(layouts: layouts, currentID: currentID)
    }

    /// Reads what every text key produces on a layout, with and without Shift.
    private static func makeLayout(_ source: TISInputSource, id: String) -> KeyboardLayout? {
        guard let data: Data = property(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let name: String = property(source, kTISPropertyLocalizedName) ?? id
        var base: [UInt16: Character] = [:]
        var shifted: [UInt16: Character] = [:]
        let keyboardType = UInt32(LMGetKbdType())
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for keyCode in UInt16(0)...50 where keyCode != 36 && keyCode != 48 && keyCode != 49 {
                for (modifiers, isShifted) in [(UInt32(0), false), (UInt32(shiftKey >> 8), true)] {
                    var deadKeys: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(
                        layout, keyCode, UInt16(kUCKeyActionDown), modifiers, keyboardType,
                        OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, characters.count, &length,
                        &characters)
                    guard status == noErr, length == 1, let scalar = Unicode.Scalar(characters[0]),
                        scalar.value >= 0x20, scalar.value != 0x7F
                    else { continue }
                    if isShifted {
                        shifted[keyCode] = Character(scalar)
                    } else {
                        base[keyCode] = Character(scalar)
                    }
                }
            }
        }
        var cyrillic = 0
        var latin = 0
        for character in base.values {
            if Language.russian.isLetter(character) { cyrillic += 1 }
            if Language.english.isLetter(character) { latin += 1 }
        }
        // Only Latin and Russian layouts take part; others (Greek, Ukrainian, …) are left alone.
        guard max(cyrillic, latin) >= 20 else { return nil }
        if cyrillic > latin {
            // Ukrainian, Bulgarian and other Cyrillic layouts are not Russian: require the Russian letters.
            let required: Set<Character> = ["ы", "э", "ъ"]
            guard required.isSubset(of: Set(base.values)) else { return nil }
        }
        return KeyboardLayout(
            id: id, name: name, language: cyrillic > latin ? .russian : .english, base: base, shifted: shifted
        )
    }

    func select(_ id: String) {
        guard let source = sources[id], snapshot.currentID != id else { return }
        expectedID = id
        TISSelectInputSource(source)
    }
}
