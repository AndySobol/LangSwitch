import Foundation
import LangSwitchCore
import Observation
import SwiftUI

/// Drives one trainer exercise: builds the text, feeds key presses to the session, hands out rewards.
@MainActor
@Observable
final class TrainerModel {
    enum Phase: Equatable {
        case setup
        case running
        case finished
    }

    private(set) var phase = Phase.setup
    private(set) var session: TrainerSession?
    private(set) var result: TrainerResult?
    private(set) var reward: TrainerProfile.Reward?
    private(set) var title = ""
    private(set) var notice: String?
    /// Words of the exercise with the index of their first character.
    private(set) var words: [(start: Int, characters: [Character])] = []
    /// Changes on every wrong key; the view shakes on it.
    private(set) var errorPulse = 0
    /// Changes when a combo milestone is reached.
    private(set) var comboPulse = 0
    private(set) var now: TimeInterval = 0

    let particles = ParticleSystem()
    @ObservationIgnored var caretPoint = CGPoint.zero
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var recentPassages: Set<String> = []
    @ObservationIgnored private weak var app: AppModel?

    func attach(_ app: AppModel) { self.app = app }

    private static func clock() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        guard let app else { return }
        let settings = app.settings
        let language = settings.trainerLanguage
        let content = app.trainerContent
        var generator = SystemRandomNumberGenerator()
        var text = ""
        var limit: TimeInterval?
        notice = nil
        title = ""

        switch settings.trainerSource {
        case .words:
            text = content.randomWords(
                language: language,
                count: settings.trainerDuration == 0 ? 150 : max(40, settings.trainerDuration * 3),
                using: &generator)
            // Zero means "no time limit": type until the text ends or Esc.
            limit = settings.trainerDuration == 0 ? nil : TimeInterval(settings.trainerDuration)
        case .texts:
            if let passage = content.passage(
                language: language, difficulty: settings.trainerDifficulty, excluding: recentPassages,
                using: &generator)
            {
                text = passage.text
                title = passage.title
                recentPassages.insert(passage.id)
                if recentPassages.count > 30 { recentPassages.removeAll() }
            }
        case .weakWords:
            let weak = app.learning.weakWords(limit: 40)
            if weak.filter({ Language.dominant(in: $0) == language }).isEmpty {
                notice = loc(
                    "Слабых слов пока нет — тренируем частые слова.",
                    "No weak words yet — practising frequent words.")
            }
            text = content.weakWordsDrill(weak, language: language, count: 36, using: &generator)
        case .myTexts:
            if let own = app.phrases.exercise(language: language, targetLength: 280, using: &generator) {
                text = own
            } else {
                notice = loc(
                    "Своих фраз на этом языке пока нет. Включите сбор фраз в настройках — а пока текст из набора.",
                    "No phrases of your own in this language yet. Turn on phrase collection in Settings — a bundled text for now."
                )
                text = content.passage(language: language, difficulty: nil, using: &generator)?.text ?? ""
            }
        }
        if text.isEmpty { text = content.randomWords(language: language, count: 40, using: &generator) }
        guard !text.isEmpty else {
            notice = loc("Не удалось загрузить тексты.", "Could not load the texts.")
            return
        }

        session = TrainerSession(
            text: text, language: language, source: settings.trainerSource, timeLimit: limit)
        var words: [(Int, [Character])] = []
        var start = 0
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            // Each word carries its trailing space so the caret can rest on it.
            let characters = Array(word) + [" "]
            words.append((start, characters))
            start += characters.count
        }
        if !words.isEmpty { words[words.count - 1].1.removeLast() }
        self.words = words.map { (start: $0.0, characters: $0.1) }
        result = nil
        reward = nil
        now = Self.clock()
        phase = .running
        app.selectLayout(for: language)
    }

    /// Esc: an exercise with enough typed to be worth a result ends with the result screen.
    func quit() {
        if phase == .running, let session, session.position >= 15 {
            finish()
        } else {
            stop()
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        session = nil
        phase = .setup
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.phase == .running else { return }
                self.now = Self.clock()
                self.session?.tick(at: self.now)
                if self.session?.isFinished == true { self.finish() }
            }
        }
    }

    func type(_ character: Character) {
        guard phase == .running, var session else { return }
        let time = Self.clock()
        let wasStarted = session.isStarted
        let feedback = session.type(character, at: time)
        self.session = session
        now = time
        if !wasStarted && session.isStarted { startTicker() }
        switch feedback {
        case .correct, .finished:
            let combo = session.combo
            let tier: [Color] =
                combo >= 60
                ? [Theme.ink, Theme.ink, .white]
                : combo >= 20 ? [Theme.ink, Theme.ink] : [Theme.ink, Theme.ink]
            particles.burst(
                at: caretPoint, count: combo >= 20 ? 4 : 2, colors: tier, speed: 40...150, size: 1.5...3.5)
            if combo > 0, combo % 25 == 0 {
                comboPulse += 1
                particles.burst(
                    at: caretPoint, count: 28, colors: [Theme.ink, Theme.ink, Theme.ink, .white],
                    speed: 120...360, size: 2.5...6)
            }
            if feedback == .finished { finish() }
        case .wrong:
            errorPulse += 1
        case .ignored:
            break
        }
    }

    private func finish() {
        guard phase == .running, let session, let app else { return }
        ticker?.cancel()
        ticker = nil
        let result = session.result(at: Self.clock())
        self.result = result
        // An exercise abandoned after a few keys is not a result worth recording.
        if result.characters >= 15 { reward = app.record(result) }
        phase = .finished
    }

    func celebrate(width: CGFloat) {
        guard let reward, reward.isRecord || reward.leveledUp || (result?.accuracy ?? 0) >= 0.97 else {
            return
        }
        particles.confetti(
            width: width, colors: [Theme.ink, Theme.ink, Theme.ink, Theme.ink, Theme.ink])
    }
}
