import Foundation

/// Locates SwiftPM resource bundles both inside the packaged application and in development builds.
///
/// `Bundle.module` cannot be used on its own: SwiftPM's generated accessor looks next to the executable
/// or at the absolute build path of the machine that compiled it, and crashes anywhere else. Inside
/// `LangSwitch.app` the bundles live in `Contents/Resources`, which is checked first.
package enum ResourceLocator {
    package static func bundle(named name: String, fallback: @autoclosure () -> Bundle) -> Bundle {
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name + ".bundle"),
            let bundle = Bundle(url: url)
        {
            return bundle
        }
        return fallback()
    }
}

/// The data files bundled with the core module.
package struct CoreResources: Sendable {
    package var frequency: [Language: FrequencyList] = [:]
    package var terms = TermLexicon()
    package var abbreviations: Set<String> = []
    package var thesaurus: [Language: Thesaurus] = [:]
    package var trainer = TrainerContent()

    package init() {}

    private static var bundle: Bundle {
        ResourceLocator.bundle(named: "LangSwitch_LangSwitchCore", fallback: Bundle.module)
    }

    private static func text(_ path: String) -> String? {
        guard let url = bundle.resourceURL?.appendingPathComponent(path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func lines(_ path: String) -> [String] {
        text(path)?.split(whereSeparator: \.isNewline).map(String.init) ?? []
    }

    /// Reads every bundled file. Missing files leave the corresponding feature empty rather than failing.
    package static func load() -> CoreResources {
        var resources = CoreResources()
        for language in Language.allCases {
            let code = language.rawValue
            resources.frequency[language] = FrequencyList(
                words: lines("Frequency/\(code).txt").map { $0.lowercased() })
            if let synonyms = text("Rules/synonyms-\(code).tsv") {
                resources.thesaurus[language] = Thesaurus(tsv: synonyms)
            }
            resources.trainer.words[language] = lines("Trainer/words-\(code).txt")
            if let url = bundle.resourceURL?.appendingPathComponent("Trainer/texts-\(code).json"),
                let data = try? Data(contentsOf: url),
                let passages = try? JSONDecoder().decode([TrainerPassage].self, from: data)
            {
                resources.trainer.passages[language] = passages
            }
        }
        if let terms = text("Terms/terms.tsv") { resources.terms = TermLexicon(tsv: terms) }
        resources.abbreviations = Set(lines("Rules/abbreviations.txt").map { $0.lowercased() })
        return resources
    }
}
