import Foundation

/// Interface language. Russian is the project's working language; English is the fallback for everyone else.
enum InterfaceLanguage: String, Codable, Sendable, CaseIterable, Identifiable {
    case system, russian, english
    var id: String { rawValue }

    @MainActor static var selected: InterfaceLanguage = .system

    @MainActor static var usesRussian: Bool {
        switch selected {
        case .russian: return true
        case .english: return false
        case .system: return Locale.preferredLanguages.first?.hasPrefix("ru") ?? false
        }
    }
}

/// Picks the string for the current interface language.
@MainActor func loc(_ russian: String, _ english: String) -> String {
    InterfaceLanguage.usesRussian ? russian : english
}
