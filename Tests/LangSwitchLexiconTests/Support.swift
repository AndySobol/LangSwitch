import Foundation
import LangSwitchCore
import LangSwitchLexicon

/// The full language stack is expensive to build, so every test shares one instance.
/// Tests only read from it; Swift Testing runs them on arbitrary threads, hence the lock.
final class SharedRuntime: @unchecked Sendable {
    static let shared = SharedRuntime()
    private let lock = NSLock()
    private let runtime = LanguageRuntime()

    func withRuntime<T>(_ body: (LanguageRuntime) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(runtime)
    }
}

func withRuntime<T>(_ body: (LanguageRuntime) throws -> T) rethrows -> T {
    try SharedRuntime.shared.withRuntime(body)
}

/// Types `intended` using the keys of its own layout while `active` is the selected layout.
func typeBlind(_ intended: String, active: KeyboardLayout, options: CorrectionOptions = CorrectionOptions())
    -> String
{
    withRuntime { runtime in
        var simulator = TypingSimulator(engine: runtime.engine, active: active, options: options)
        var index = intended.startIndex
        // Each whitespace-separated chunk is typed on the layout of its own script.
        while index < intended.endIndex {
            var end = index
            while end < intended.endIndex, !intended[end].isWhitespace { end = intended.index(after: end) }
            let chunk = String(intended[index..<end])
            let source: KeyboardLayout = Language.dominant(in: chunk) == .russian ? .russian : .abc
            simulator.press(keysFor: chunk, on: source)
            if end < intended.endIndex {
                simulator.press(keysFor: String(intended[end]), on: source)
                end = intended.index(after: end)
            }
            index = end
        }
        return simulator.document
    }
}
