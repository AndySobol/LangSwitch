import CHunspell
import Foundation
import LangSwitchCore

/// Owns the native Hunspell handles for Russian and English.
///
/// Not `Sendable` on purpose: an instance belongs to one executor (the input thread) and the C handles
/// never leave it.
package final class HunspellDictionary: SpellingDictionary {
    package enum Failure: Error {
        case missingResource(String)
        case initialization(Language)
    }

    private var handles: [Language: OpaquePointer] = [:]
    private let folder: URL

    package static var libraryVersion: String { String(cString: Hunspell_get_library_version()) }

    private static func fileName(_ language: Language) -> String { language == .russian ? "ru_RU" : "en_US" }

    /// Folder with the `ru` and `en` dictionary directories.
    package static var bundledFolder: URL? {
        ResourceLocator.bundle(named: "LangSwitch_LangSwitchLexicon", fallback: Bundle.module)
            .resourceURL?.appendingPathComponent("Hunspell")
    }

    package static func url(_ language: Language, extension fileExtension: String, in folder: URL) -> URL {
        folder.appendingPathComponent(language.rawValue)
            .appendingPathComponent(fileName(language) + "." + fileExtension)
    }

    package init(folder: URL? = nil) throws {
        guard let folder = folder ?? Self.bundledFolder else { throw Failure.missingResource("Hunspell") }
        self.folder = folder
        for language in Language.allCases {
            let affix = Self.url(language, extension: "aff", in: folder)
            let words = Self.url(language, extension: "dic", in: folder)
            guard FileManager.default.isReadableFile(atPath: affix.path),
                FileManager.default.isReadableFile(atPath: words.path)
            else { throw Failure.missingResource(affix.lastPathComponent) }
            guard let handle = Hunspell_create(affix.path, words.path) else {
                throw Failure.initialization(language)
            }
            handles[language] = handle
        }
    }

    deinit {
        for handle in handles.values { Hunspell_destroy(handle) }
    }

    private static func accepts(_ word: String) -> Bool {
        !word.isEmpty && word.utf8.count <= 96
            && word.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" || $0 == "’" }
    }

    package func contains(_ word: String, language: Language) -> Bool {
        guard Self.accepts(word), let handle = handles[language] else { return false }
        return Hunspell_spell(handle, word) != 0
    }

    /// Dictionary stems of a word form ("сделал" → "сделать").
    package func stems(of word: String, language: Language) -> [String] {
        guard Self.accepts(word), let handle = handles[language] else { return [] }
        var list: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        let count = word.withCString { Hunspell_stem(handle, &list, $0) }
        defer { Hunspell_free_list(handle, &list, count) }
        guard count > 0, let list else { return [] }
        return (0..<min(Int(count), 8)).compactMap { index in
            list[index].flatMap { String(validatingCString: $0) }
        }
    }
}
