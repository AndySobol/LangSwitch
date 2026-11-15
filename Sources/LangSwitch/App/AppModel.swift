import AppKit
import LangSwitchCore
import OSLog
import Observation
import ServiceManagement

/// A correction shown in the interface.
struct CorrectionRecord: Identifiable, Sendable, Equatable {
    let id = UUID()
    let original: String
    let corrected: String
    let kinds: CorrectionKinds
    let application: String?
    let date: Date
    let isUndo: Bool
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview, trainer, dictionary, applications, settings
    var id: String { rawValue }
}

/// Carries events from the input thread to the main actor in the order they were produced.
final class EventRelay: Sendable {
    @MainActor var handler: ((InputEvent) -> Void)?

    nonisolated init() {}

    func send(_ event: InputEvent) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.handler?(event) }
        }
    }
}

/// The application's state on the main actor: settings, statistics, what was learned, and the bridge to
/// the input engine.
@MainActor
@Observable
final class AppModel {
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settingsChanged(from: oldValue)
        }
    }
    private(set) var statistics: Statistics
    private(set) var learning: LearningData
    private(set) var profile: TrainerProfile
    private(set) var phrases: PhraseLibrary
    private(set) var recent: [CorrectionRecord] = []
    private(set) var isTrusted = false
    private(set) var isRunning = false
    private(set) var isLoaded = false
    private(set) var layouts = LayoutSnapshot()
    private(set) var trainerContent = TrainerContent()
    private(set) var launchesAtLogin = false
    var selection = SidebarItem.overview
    /// Skips the onboarding gate; set only by the snapshot renderer.
    var previewMode = false

    @ObservationIgnored let engine: InputEngine
    @ObservationIgnored let inputSources = InputSources()
    @ObservationIgnored private let store: Store
    /// False for the snapshot renderer: nothing is written to the user's settings.
    @ObservationIgnored private let persistsSettings: Bool
    @ObservationIgnored private let relay = EventRelay()
    @ObservationIgnored let hud = NotchHUD()
    @ObservationIgnored let ghost = CompletionOverlay()
    @ObservationIgnored let popup = SuggestionPopup()
    /// Observable on its own: the settings screen and the menu read its state.
    @ObservationIgnored let updater = Updater()
    @ObservationIgnored private var saveScheduled = false
    @ObservationIgnored private var trustPolling: Task<Void, Never>?
    @ObservationIgnored private var completionRequest = 0
    @ObservationIgnored var openMainWindow: (() -> Void)?

    private static let settingsKey = "settings.v1"

    init(store: Store = Store(), persistsSettings: Bool = true) {
        self.store = store
        self.persistsSettings = persistsSettings
        if persistsSettings, let data = UserDefaults.standard.data(forKey: Self.settingsKey),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        {
            settings = decoded
        } else {
            settings = AppSettings()
        }
        statistics = store.load(Statistics.self, from: "statistics.json") ?? Statistics()
        learning = store.load(LearningData.self, from: "learning.json") ?? LearningData()
        profile = store.load(TrainerProfile.self, from: "trainer.json") ?? TrainerProfile()
        phrases = store.load(PhraseLibrary.self, from: "phrases.json") ?? PhraseLibrary()
        let relay = relay
        engine = InputEngine(emit: { relay.send($0) })
        InterfaceLanguage.selected = settings.interfaceLanguage
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Start-up

    func start() {
        relay.handler = { [weak self] in self?.handle($0) }
        layouts = inputSources.snapshot
        inputSources.onChange = { [weak self] snapshot, byUser in
            guard let self else { return }
            self.layouts = snapshot
            let recent = self.inputSources.recent
            Task { await self.engine.setLayouts(snapshot, recent: recent, byUser: byUser) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationChanged() }
        }
        // macOS posts this when the Accessibility list changes; the new state is readable a moment later.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    self.refreshTrust()
                }
            }
        }
        phrases.prune(olderThan: settings.phraseRetentionDays)
        // The snapshot renderer runs the same start-up; it must not go to the network.
        if persistsSettings {
            updater.willRelaunch = { [weak self] in await self?.flushAndSave() }
            updater.onUpdateFound = { [weak self] release in
                guard let self, self.settings.showsHUD else { return }
                self.hud.show(
                    .message(
                        symbol: "arrow.down.circle.fill",
                        text: loc(
                            "Доступна версия \(release.version)", "Version \(release.version) is available")),
                    duration: 3)
            }
            updater.startAutomaticChecks { [weak self] in self?.settings.checksForUpdates ?? false }
        }

        let learning = learning
        let config = settings.engineConfig
        let snapshot = layouts
        let recent = inputSources.recent
        let front = frontApplication()
        Task {
            _ = await engine.load(learning: learning)
            await engine.configure(config)
            await engine.setLayouts(snapshot, recent: recent, byUser: false)
            await engine.setApplication(front)
            trainerContent = await engine.trainerContent()
            isLoaded = true
            Self.log.notice("Engine loaded; Accessibility trusted: \(Accessibility.isTrusted)")
            writeDiagnostics()
            refreshTrust()
            // Without the permission nothing works, so keep looking for it whether or not a window is open.
            if !isRunning { pollTrust() }
        }
    }

    private func frontApplication() -> FrontApplication {
        let application = NSWorkspace.shared.frontmostApplication
        return FrontApplication(
            bundleID: application?.bundleIdentifier, name: application?.localizedName,
            processID: application?.processIdentifier ?? 0)
    }

    private func applicationChanged() {
        let front = frontApplication()
        ghost.hide()
        popup.dismiss()
        Task { await engine.setApplication(front) }
    }

    /// Checks Accessibility access and starts the keyboard tap once it is granted.
    func refreshTrust() {
        // The snapshot renderer shows demo data; the real permission state would overwrite it.
        guard !previewMode else { return }
        let trusted = Accessibility.isTrusted
        let changed = trusted != isTrusted
        isTrusted = trusted
        if changed {
            Self.log.notice("Accessibility trusted: \(trusted)")
            writeDiagnostics()
        }
        guard isTrusted, isLoaded, !isRunning, !isStartingTap else { return }
        isStartingTap = true
        Task {
            let started = await engine.startTap()
            Self.log.notice("Keyboard tap started: \(started)")
            isRunning = started
            isStartingTap = false
            writeDiagnostics()
        }
    }

    /// A small state file for troubleshooting ("why is nothing being corrected?"). States only, no text.
    private func writeDiagnostics() {
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let lines =
            [
                "version: \(version)",
                "updated: \(Date().formatted(.iso8601))",
                "engineLoaded: \(isLoaded)",
                "accessibilityTrusted: \(Accessibility.isTrusted)",
                "keyboardTapRunning: \(isRunning)",
                "layouts: \(layouts.layouts.map(\.id).joined(separator: ", "))",
                "currentLayout: \(layouts.currentID ?? "none")",
                "enabled: \(settings.enabled)",
            ] + engineDiagnostics.lines
        let url = store.folder.appendingPathComponent("diagnostics.txt")
        try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Diagnostics never include typed text: states and counts only.
    private static let log = Logger(subsystem: "io.github.andysobol.LangSwitch", category: "app")
    @ObservationIgnored private var isStartingTap = false
    @ObservationIgnored private var lastRequestedLayout: String?
    @ObservationIgnored private var engineDiagnostics = EngineDiagnostics()

    /// Re-checks the permission until the keyboard tap is running. This is the only periodic work in the
    /// application, and it exists only while the permission is missing.
    func pollTrust() {
        guard trustPolling == nil, !isRunning else { return }
        trustPolling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                self.refreshTrust()
                // Starting the tap is asynchronous; give it a moment before deciding to stop.
                try? await Task.sleep(for: .milliseconds(300))
                if self.isRunning { break }
            }
            self?.trustPolling = nil
        }
    }

    func requestAccessibility() {
        Accessibility.requestTrust()
        pollTrust()
    }

    func openAccessibilitySettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
            NSWorkspace.shared.open(url)
        }
        pollTrust()
    }

    // MARK: - Settings

    private func settingsChanged(from old: AppSettings) {
        if persistsSettings, let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        InterfaceLanguage.selected = settings.interfaceLanguage
        if settings.engineConfig != old.engineConfig {
            let config = settings.engineConfig
            Task { await engine.configure(config) }
        }
        if !settings.completion { ghost.hide() }
        if settings.phraseRetentionDays != old.phraseRetentionDays || !settings.collectsPhrases {
            phrases.prune(olderThan: settings.phraseRetentionDays)
            scheduleSave()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            hud.show(
                .message(
                    symbol: "exclamationmark.triangle.fill",
                    text: loc("Не удалось изменить автозапуск", "Could not change login item")))
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    var currentLayout: KeyboardLayout? { layouts.current }
    var hasBothLayouts: Bool {
        layouts.layouts.contains { $0.language == .russian }
            && layouts.layouts.contains { $0.language == .english }
    }

    /// Fills the model with plausible data for documentation screenshots.
    func applyDemoData() {
        isTrusted = true
        isRunning = true
        settings.onboardingCompleted = true
        var statistics = Statistics()
        let calendar = Calendar.current
        let fixes = [9, 14, 11, 19, 7, 3, 16, 22, 13, 18, 6, 4, 21, 17]
        for (offset, count) in fixes.enumerated() {
            guard let date = calendar.date(byAdding: .day, value: offset - fixes.count + 1, to: Date()) else {
                continue
            }
            statistics.days[Statistics.key(for: date)] = DayStatistics(
                words: 900 + count * 70, characters: 5200 + count * 400, layoutFixes: count,
                spellingFixes: count / 2 + 3, punctuationFixes: count / 3 + 1, completions: count + 5)
        }
        self.statistics = statistics
        let samples: [(String, String, CorrectionKinds, String)] = [
            ("ghbdtn", "привет", .layout, "Telegram"), ("прогармма", "программа", .spelling, "Notes"),
            ("ашпьф", "Figma", .layout, "Teams"), ("сказал что", "сказал, что", .punctuation, "Mail"),
            ("recieve", "receive", .spelling, "Chrome"),
        ]
        recent = samples.enumerated().map { index, sample in
            CorrectionRecord(
                original: sample.0, corrected: sample.1, kinds: sample.2, application: sample.3,
                date: Date().addingTimeInterval(Double(-index * 90)), isUndo: false)
        }
        var demo = LearningData()
        for word in ["Zoltra", "FigJam", "дизайн-ревью"] { demo.addWord(word) }
        let today = LearningData.today
        // Watched words at different distances from the dictionary; one already adopted on its own.
        let sightings: [(word: String, perDay: [Int], doubtful: Bool)] = [
            ("могну", [1, 2], true), ("оки-доки", [3], false), ("bk", [4, 1], true),
            ("созвонимся-ка", [1], false),
            ("деплойнул", [1, 1], false),
        ]
        for item in sightings {
            for (offset, count) in item.perDay.enumerated() {
                for _ in 0..<count {
                    demo.recordWord(
                        item.word, previous: nil, known: false, doubtful: item.doubtful,
                        day: today - item.perDay.count + 1 + offset)
                }
            }
        }
        learning = demo
        var profile = TrainerProfile()
        for index in 0..<24 {
            let result = TrainerResult(
                date: Date().addingTimeInterval(Double(index - 24) * 86_400 / 3), language: .russian,
                source: .words,
                wpm: 38 + Double(index) * 1.1 + Double((index * 7) % 5), accuracy: 0.95, duration: 30,
                characters: 180,
                mistakes: 6, maxCombo: 60, score: 4200, timeline: [], missedKeys: ["ж": 2, "э": 1, "ъ": 1])
            profile.record(result)
        }
        self.profile = profile
    }

    // MARK: - Persistence

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.saveNow()
        }
    }

    func saveNow() {
        saveScheduled = false
        let store = store
        let statistics = statistics
        let learning = learning
        let profile = profile
        let phrases = phrases
        Task.detached(priority: .utility) {
            store.save(statistics, to: "statistics.json")
            store.save(learning, to: "learning.json")
            store.save(profile, to: "trainer.json")
            store.save(phrases, to: "phrases.json")
        }
    }

    /// Asks the engine for its latest learning data and writes everything out; used when quitting.
    func flushAndSave() async {
        await engine.flush()
        // The flush arrives through the relay on the next main-queue turn.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        store.save(statistics, to: "statistics.json")
        store.save(learning, to: "learning.json")
        store.save(profile, to: "trainer.json")
        store.save(phrases, to: "phrases.json")
    }

    // MARK: - Learning and trainer

    func updateLearning(_ change: @escaping @Sendable (inout LearningData) -> Void) {
        Task { await engine.updateLearning(change) }
    }

    func resetLearning() {
        updateLearning { $0 = LearningData() }
    }

    func deletePhrases() {
        phrases = PhraseLibrary()
        scheduleSave()
    }

    func deletePhrase(_ id: UUID) {
        phrases.phrases.removeAll { $0.id == id }
        scheduleSave()
    }

    @discardableResult
    func record(_ result: TrainerResult) -> TrainerProfile.Reward {
        let reward = profile.record(result)
        scheduleSave()
        return reward
    }

    func resetStatistics() {
        statistics = Statistics()
        recent = []
        scheduleSave()
    }

    /// Selects the layout of `language` (used by the trainer before an exercise).
    func selectLayout(for language: Language) {
        guard layouts.current?.language != language,
            let layout = inputSources.recent.lazy.compactMap({ id in
                self.layouts.layouts.first { $0.id == id && $0.language == language }
            }).first ?? layouts.layouts.first(where: { $0.language == language })
        else { return }
        inputSources.select(layout.id)
    }

    // MARK: - Events from the input engine

    private func handle(_ event: InputEvent) {
        switch event {
        case .corrected(let replacement, let application):
            corrected(replacement, application: application)
        case .selectLayout(let id):
            lastRequestedLayout = id
            inputSources.select(id)
            verifyLayout(id)
        case .completion(let remainder):
            showCompletion(remainder)
        case .completionAccepted:
            statistics.update { $0.completions += 1 }
            scheduleSave()
        case .hotkey(let action):
            perform(action)
        case .doubleClick:
            suggestForSelection(explicit: false)
        case .mouseDown:
            popup.dismissIfMouseOutside()
        case .popupKey(let key):
            popup.handle(key)
        case .learning(let data, let counters):
            learning = data
            if counters != TypingCounters() {
                statistics.update {
                    $0.words += counters.words
                    $0.characters += counters.characters
                }
            }
            scheduleSave()
        case .diagnostics(let diagnostics):
            engineDiagnostics = diagnostics
            writeDiagnostics()
        case .learnedWord(let word):
            if settings.showsHUD {
                hud.show(
                    .message(
                        symbol: "text.book.closed.fill",
                        text: loc("Запомнил слово «\(word)»", "Learned “\(word)”")))
            }
        case .phrase(let text, let language, let application):
            guard settings.collectsPhrases else { return }
            phrases.add(
                CollectedPhrase(text: text, language: language, date: Date(), application: application))
            scheduleSave()
        case .tapStopped:
            isRunning = false
        }
    }

    private func corrected(_ replacement: Replacement, application: String?) {
        let record = CorrectionRecord(
            original: replacement.original, corrected: replacement.corrected, kinds: replacement.kinds,
            application: application, date: Date(), isUndo: replacement.isUndo)
        recent.insert(record, at: 0)
        if recent.count > 40 { recent.removeLast(recent.count - 40) }
        if !replacement.isUndo {
            statistics.update {
                if replacement.kinds.contains(.layout) { $0.layoutFixes += 1 }
                if replacement.kinds.contains(.spelling) { $0.spellingFixes += 1 }
                if replacement.kinds.contains(.punctuation) || replacement.kinds.contains(.capitalization) {
                    $0.punctuationFixes += 1
                }
            }
            scheduleSave()
        }
        if settings.showsHUD { hud.show(.correction(record)) }
    }

    /// The system may refuse a switch; if so, tell the engine what is really selected.
    private func verifyLayout(_ id: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            // A newer request supersedes this check.
            guard let self, self.lastRequestedLayout == id else { return }
            // Ask the system itself rather than trusting what the last notification said.
            self.inputSources.refresh()
            self.layouts = self.inputSources.snapshot
            guard self.inputSources.snapshot.currentID != id else { return }
            let snapshot = self.inputSources.snapshot
            let recent = self.inputSources.recent
            await self.engine.setLayouts(snapshot, recent: recent, byUser: false)
        }
    }

    private func showCompletion(_ remainder: String?) {
        completionRequest += 1
        guard let remainder, settings.completion else {
            ghost.hide()
            hud.hideCompletion()
            return
        }
        let request = completionRequest
        let key = settings.completionAcceptKey.symbol
        Task { [weak self] in
            let rect = await Task.detached(priority: .userInitiated) { Accessibility.caretRect() }.value
            guard let self, self.completionRequest == request else { return }
            if let rect {
                self.hud.hideCompletion()
                self.ghost.show(remainder, at: rect, key: key)
            } else {
                self.ghost.hide()
                self.hud.show(.completion(remainder: remainder, key: key))
            }
        }
    }

    // MARK: - Commands

    func perform(_ action: HotkeyAction) {
        switch action {
        case .togglePause:
            settings.enabled.toggle()
            hud.show(
                .message(
                    symbol: settings.enabled ? "play.fill" : "pause.fill",
                    text: settings.enabled
                        ? loc("LangSwitch включён", "LangSwitch is on")
                        : loc("LangSwitch на паузе", "LangSwitch is paused")))
        case .suggest:
            suggestForSelection(explicit: true)
        case .fixSelection:
            transformSelection { engine, text, options in await engine.fix(text, options: options).text }
        case .convertLayout:
            transformSelection(switchLayout: true) { engine, text, _ in await engine.convertLayout(of: text) }
        }
    }

    private func transformSelection(
        switchLayout: Bool = false,
        _ transform: @escaping @Sendable (InputEngine, String, CorrectionOptions) async -> String
    ) {
        let engine = engine
        // The manual command applies every kind of fix, whatever is enabled for automatic typing.
        let options = CorrectionOptions()
        Task { [weak self] in
            let selected = await Task.detached { Accessibility.selectedText() }.value
            guard let self else { return }
            guard let selected, selected.count <= 6000 else {
                self.hud.show(
                    .message(
                        symbol: "text.cursor", text: loc("Сначала выделите текст", "Select some text first")))
                return
            }
            let result = await transform(engine, selected, options)
            guard result != selected else {
                self.hud.show(
                    .message(symbol: "checkmark.seal.fill", text: loc("Исправлять нечего", "Nothing to fix")))
                return
            }
            await engine.replaceSelection(with: result)
            if switchLayout, let language = Language.dominant(in: result) { self.selectLayout(for: language) }
            self.hud.show(.message(symbol: "wand.and.stars", text: loc("Текст исправлен", "Text fixed")))
        }
    }

    private func suggestForSelection(explicit: Bool) {
        let engine = engine
        let location = NSEvent.mouseLocation
        Task { [weak self] in
            if !explicit { try? await Task.sleep(for: .milliseconds(140)) }
            let selected = await Task.detached { () -> String? in
                guard Accessibility.focusIsEditable() else { return nil }
                return Accessibility.selectedText()
            }.value
            guard let self else { return }
            let word = selected?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !word.isEmpty, word.count <= 40, !word.contains(where: \.isWhitespace),
                word.contains(where: \.isLetter)
            else {
                if explicit {
                    self.hud.show(
                        .message(
                            symbol: "text.cursor", text: loc("Выделите одно слово", "Select a single word")))
                }
                return
            }
            let suggestions = await engine.suggestions(for: word)
            guard !suggestions.isEmpty else {
                if explicit {
                    self.hud.show(
                        .message(symbol: "checkmark.seal.fill", text: loc("Вариантов нет", "No alternatives"))
                    )
                }
                return
            }
            self.popup.show(word: word, suggestions: suggestions, near: location) { [weak self] choice in
                guard let self else { return }
                Task { await self.engine.replaceSelection(with: choice.text) }
            } onVisibilityChange: { [weak self] visible in
                guard let self else { return }
                Task { await self.engine.setPopupActive(visible) }
            }
        }
    }

    /// Runs the full fixer on arbitrary text (the playground in the overview).
    func fix(_ text: String) async -> TextFixer.Result {
        await engine.fix(text, options: CorrectionOptions())
    }
}
