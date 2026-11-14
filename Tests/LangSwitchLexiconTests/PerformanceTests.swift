import Foundation
import LangSwitchCore
import Testing

@testable import LangSwitchLexicon

@Suite struct PerformanceTests {
    /// The decision at a word boundary runs inside the keyboard event tap, so it has to be far below the
    /// threshold of perception. Run with `swift test -c release --filter PerformanceTests` for real numbers.
    @Test func wordBoundaryStaysWithinBudget() {
        withRuntime { runtime in
            let words = (runtime.resources.frequency[.russian]?.words ?? []).prefix(600).filter {
                $0.count >= 2
            }
            var worst = 0.0
            var total = 0.0
            var count = 0
            for word in words {
                // Alternate blind typing (conversion) and normal typing with a typo-sized detour.
                for (active, source) in [
                    (KeyboardLayout.abc, KeyboardLayout.russian),
                    (KeyboardLayout.russian, KeyboardLayout.russian),
                ] {
                    var simulator = TypingSimulator(engine: runtime.engine, active: active)
                    simulator.press(keysFor: word + "ъ", on: source)
                    let start = DispatchTime.now().uptimeNanoseconds
                    simulator.boundary(.space)
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                    worst = max(worst, elapsed)
                    total += elapsed
                    count += 1
                }
            }
            let average = total / Double(max(count, 1))
            print(
                String(
                    format: "boundary: average %.3f ms, worst %.3f ms over %d chunks", average, worst, count))
            // Sanity bounds against pathological regressions only. Tests run unoptimised, in parallel and
            // on shared CI machines; the real budget (about 0.8 ms in a release build) is recorded in docs/qa.
            #expect(average < 50)
            #expect(worst < 500)
        }
    }

    @Test func runtimeLoadsQuickly() {
        let start = DispatchTime.now().uptimeNanoseconds
        let runtime = LanguageRuntime()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        print(String(format: "runtime load: %.2f s", elapsed))
        #expect(runtime.hasFullDictionaries)
        // No time bound here: the suite runs in parallel and unoptimised. See docs/qa for release numbers.
    }
}
