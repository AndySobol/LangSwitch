import Foundation
import LangSwitchCore

/// An application the user configured a special behaviour for.
struct ApplicationRule: Codable, Sendable, Hashable, Identifiable {
    enum Mode: String, Codable, Sendable, CaseIterable, Identifiable {
        /// LangSwitch does nothing here.
        case off
        /// Only the keyboard layout is fixed: no spelling, punctuation or completions.
        case layoutOnly
        var id: String { rawValue }
    }

    var bundleID: String
    var name: String
    var mode: Mode
    var id: String { bundleID }
}

enum CompletionAcceptKey: String, Codable, Sendable, CaseIterable, Identifiable {
    case tab, rightArrow
    var id: String { rawValue }
    var keyCode: UInt16 { self == .tab ? KeyCode.tab : KeyCode.rightArrow }
    var symbol: String { self == .tab ? "⇥" : "→" }
}

/// Everything the user can configure. Stored as one JSON value in UserDefaults.
struct AppSettings: Codable, Sendable, Equatable {
    var enabled = true
    var fixesLayout = true
    var fixesSpelling = true
    var fixesPunctuation = true
    var fixesCapitalization = true
    var backspaceUndoes = false
    var doubleShiftConverts = true
    var convertsEarly = true

    var completion = true
    var completionMinimumPrefix = 3
    var completionAcceptKey = CompletionAcceptKey.tab
    var suggestsOnDoubleClick = true

    var hotkeys: [String: Hotkey] = [:]
    var applicationRules: [ApplicationRule] = AppSettings.defaultRules

    var learnsWords = true
    var collectsPhrases = false
    var phraseRetentionDays = 7

    var showsHUD = true
    /// Ask the releases page for a newer version once a day.
    var checksForUpdates = true
    var interfaceLanguage = InterfaceLanguage.system
    var onboardingCompleted = false

    var trainerLanguage = Language.russian
    var trainerSource = TrainerSource.words
    var trainerDuration = 30
    var trainerDifficulty = 1

    init() {}

    /// Terminals and code editors: commands and identifiers must not be "corrected".
    static let defaultRules: [ApplicationRule] = [
        ("com.apple.Terminal", "Terminal"), ("com.googlecode.iterm2", "iTerm"),
        ("dev.warp.Warp-Stable", "Warp"),
        ("com.mitchellh.ghostty", "Ghostty"), ("net.kovidgoyal.kitty", "kitty"),
        ("com.microsoft.VSCode", "Visual Studio Code"), ("com.apple.dt.Xcode", "Xcode"),
        ("com.todesktop.230313mzl4w4u92", "Cursor"), ("dev.zed.Zed", "Zed"),
        ("com.sublimetext.4", "Sublime Text"), ("com.jetbrains.intellij", "IntelliJ IDEA"),
        ("com.jetbrains.WebStorm", "WebStorm"), ("com.jetbrains.pycharm", "PyCharm"),
    ].map { ApplicationRule(bundleID: $0.0, name: $0.1, mode: .layoutOnly) }

    // Decoding tolerates missing keys so that settings survive application updates.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let defaults = AppSettings()
        enabled = value(.enabled, defaults.enabled)
        fixesLayout = value(.fixesLayout, defaults.fixesLayout)
        fixesSpelling = value(.fixesSpelling, defaults.fixesSpelling)
        fixesPunctuation = value(.fixesPunctuation, defaults.fixesPunctuation)
        fixesCapitalization = value(.fixesCapitalization, defaults.fixesCapitalization)
        backspaceUndoes = value(.backspaceUndoes, defaults.backspaceUndoes)
        doubleShiftConverts = value(.doubleShiftConverts, defaults.doubleShiftConverts)
        convertsEarly = value(.convertsEarly, defaults.convertsEarly)
        completion = value(.completion, defaults.completion)
        completionMinimumPrefix = value(.completionMinimumPrefix, defaults.completionMinimumPrefix)
        completionAcceptKey = value(.completionAcceptKey, defaults.completionAcceptKey)
        suggestsOnDoubleClick = value(.suggestsOnDoubleClick, defaults.suggestsOnDoubleClick)
        hotkeys = value(.hotkeys, defaults.hotkeys)
        applicationRules = value(.applicationRules, defaults.applicationRules)
        learnsWords = value(.learnsWords, defaults.learnsWords)
        collectsPhrases = value(.collectsPhrases, defaults.collectsPhrases)
        phraseRetentionDays = value(.phraseRetentionDays, defaults.phraseRetentionDays)
        showsHUD = value(.showsHUD, defaults.showsHUD)
        checksForUpdates = value(.checksForUpdates, defaults.checksForUpdates)
        interfaceLanguage = value(.interfaceLanguage, defaults.interfaceLanguage)
        onboardingCompleted = value(.onboardingCompleted, defaults.onboardingCompleted)
        trainerLanguage = value(.trainerLanguage, defaults.trainerLanguage)
        trainerSource = value(.trainerSource, defaults.trainerSource)
        trainerDuration = value(.trainerDuration, defaults.trainerDuration)
        trainerDifficulty = value(.trainerDifficulty, defaults.trainerDifficulty)
    }

    func hotkey(for action: HotkeyAction) -> Hotkey? {
        // An explicitly cleared shortcut is stored with an invalid key and stays cleared.
        if let stored = hotkeys[action.rawValue] { return stored.isValid ? stored : nil }
        return action.defaultHotkey
    }

    var engineConfig: EngineConfig {
        var config = EngineConfig()
        config.enabled = enabled
        config.options = CorrectionOptions(
            layout: fixesLayout, spelling: fixesSpelling, punctuation: fixesPunctuation,
            capitalization: fixesCapitalization)
        config.backspaceUndoes = backspaceUndoes
        config.doubleShiftConverts = doubleShiftConverts
        config.convertsEarly = convertsEarly
        config.completion = completion
        config.completionMinimumPrefix = completionMinimumPrefix
        config.completionAcceptKey = completionAcceptKey.keyCode
        config.suggestsOnDoubleClick = suggestsOnDoubleClick
        for action in HotkeyAction.allCases {
            if let hotkey = hotkey(for: action) { config.hotkeys[action] = hotkey }
        }
        config.excludedApplications = Set(applicationRules.filter { $0.mode == .off }.map(\.bundleID))
        config.layoutOnlyApplications = Set(
            applicationRules.filter { $0.mode == .layoutOnly }.map(\.bundleID))
        config.learnsWords = learnsWords
        config.collectsPhrases = collectsPhrases
        return config
    }
}

/// Counters for one calendar day.
struct DayStatistics: Codable, Sendable, Equatable {
    var words = 0
    var characters = 0
    var layoutFixes = 0
    var spellingFixes = 0
    var punctuationFixes = 0
    var completions = 0

    var fixes: Int { layoutFixes + spellingFixes + punctuationFixes }
}

struct Statistics: Codable, Sendable, Equatable {
    var days: [String: DayStatistics] = [:]

    static func key(for date: Date = Date()) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    var today: DayStatistics { days[Self.key()] ?? DayStatistics() }

    mutating func update(_ change: (inout DayStatistics) -> Void) {
        change(&days[Self.key(), default: DayStatistics()])
        if days.count > 120 {
            for key in days.keys.sorted().dropLast(90) { days[key] = nil }
        }
    }

    var total: DayStatistics {
        days.values.reduce(into: DayStatistics()) { total, day in
            total.words += day.words
            total.characters += day.characters
            total.layoutFixes += day.layoutFixes
            total.spellingFixes += day.spellingFixes
            total.punctuationFixes += day.punctuationFixes
            total.completions += day.completions
        }
    }

    /// The last `count` days, oldest first, including days without activity.
    func recent(_ count: Int) -> [(date: Date, value: DayStatistics)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (date, days[Self.key(for: date)] ?? DayStatistics())
        }
    }
}
