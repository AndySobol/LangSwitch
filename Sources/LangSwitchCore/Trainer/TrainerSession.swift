import Foundation

/// What to practise.
package enum TrainerSource: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Random frequent words.
    case words
    /// Bundled passages.
    case texts
    /// Words the user mistypes most.
    case weakWords
    /// Phrases collected from the user's own typing (opt-in).
    case myTexts

    package var id: String { rawValue }
}

/// One finished exercise.
package struct TrainerResult: Sendable, Codable, Equatable, Identifiable {
    package var id = UUID()
    package var date: Date
    package var language: Language
    package var source: TrainerSource
    /// Net speed: correctly typed characters / 5 per minute.
    package var wpm: Double
    /// Share of key presses that were right, 0…1.
    package var accuracy: Double
    package var duration: TimeInterval
    package var characters: Int
    package var mistakes: Int
    package var maxCombo: Int
    package var score: Int
    /// Speed sampled once a second, for the result chart.
    package var timeline: [Double]
    /// Expected character → number of wrong presses.
    package var missedKeys: [String: Int]

    package init(
        date: Date, language: Language, source: TrainerSource, wpm: Double, accuracy: Double,
        duration: TimeInterval, characters: Int, mistakes: Int, maxCombo: Int, score: Int, timeline: [Double],
        missedKeys: [String: Int]
    ) {
        self.date = date
        self.language = language
        self.source = source
        self.wpm = wpm
        self.accuracy = accuracy
        self.duration = duration
        self.characters = characters
        self.mistakes = mistakes
        self.maxCombo = maxCombo
        self.score = score
        self.timeline = timeline
        self.missedKeys = missedKeys
    }
}

/// The state of one exercise in progress. Pure value type: the view feeds it key presses.
package struct TrainerSession: Sendable {
    package enum Feedback: Sendable, Equatable {
        case correct
        case wrong(expected: Character)
        case finished
        case ignored
    }

    package let target: [Character]
    package let language: Language
    package let source: TrainerSource
    /// Time limit in seconds; nil for "type the whole text".
    package let timeLimit: TimeInterval?

    package private(set) var position = 0
    package private(set) var mistakes = 0
    package private(set) var keystrokes = 0
    package private(set) var combo = 0
    package private(set) var maxCombo = 0
    package private(set) var score = 0
    package private(set) var startedAt: TimeInterval?
    package private(set) var lastKeyAt: TimeInterval?
    package private(set) var finishedAt: TimeInterval?
    package private(set) var missedKeys: [Character: Int] = [:]
    /// Positions where a wrong key was pressed (shown as marks under the text).
    package private(set) var errorPositions: Set<Int> = []
    package private(set) var timeline: [Double] = []
    private var lastSampledSecond = 0

    package init(text: String, language: Language, source: TrainerSource, timeLimit: TimeInterval? = nil) {
        self.target = Array(text)
        self.language = language
        self.source = source
        self.timeLimit = timeLimit
    }

    package var isFinished: Bool { finishedAt != nil }
    package var isStarted: Bool { startedAt != nil }
    package var progress: Double { target.isEmpty ? 1 : Double(position) / Double(target.count) }
    package var expected: Character? { position < target.count ? target[position] : nil }

    /// Score multiplier grows with the streak: ×1 … ×5.
    package var multiplier: Int { min(1 + combo / 20, 5) }

    package func elapsed(at now: TimeInterval) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max((finishedAt ?? now) - startedAt, 0)
    }

    package func remaining(at now: TimeInterval) -> TimeInterval? {
        guard let timeLimit else { return nil }
        return max(timeLimit - elapsed(at: now), 0)
    }

    package func wpm(at now: TimeInterval) -> Double {
        let time = elapsed(at: now)
        guard time >= 0.5 else { return 0 }
        return Double(position) / 5 / (time / 60)
    }

    package var accuracy: Double {
        keystrokes == 0 ? 1 : Double(keystrokes - mistakes) / Double(keystrokes)
    }

    /// Call regularly while the exercise runs: samples the chart and ends timed exercises.
    package mutating func tick(at now: TimeInterval) {
        guard let startedAt, finishedAt == nil else { return }
        let second = Int(now - startedAt)
        while lastSampledSecond < second {
            lastSampledSecond += 1
            timeline.append(wpm(at: startedAt + Double(lastSampledSecond)))
        }
        if let timeLimit, now - startedAt >= timeLimit { finishedAt = startedAt + timeLimit }
    }

    package mutating func type(_ character: Character, at now: TimeInterval) -> Feedback {
        guard finishedAt == nil, position < target.count else { return .ignored }
        if startedAt == nil { startedAt = now }
        tick(at: now)
        guard finishedAt == nil else { return .finished }
        keystrokes += 1
        lastKeyAt = now
        let expected = target[position]
        guard Self.matches(character, expected) else {
            mistakes += 1
            combo = 0
            missedKeys[expected, default: 0] += 1
            errorPositions.insert(position)
            return .wrong(expected: expected)
        }
        position += 1
        combo += 1
        maxCombo = max(maxCombo, combo)
        score += 10 * multiplier
        if position == target.count {
            finishedAt = now
            return .finished
        }
        return .correct
    }

    /// «ё» may be typed as «е»: most people do, and the trainer should not punish it.
    private static func matches(_ typed: Character, _ expected: Character) -> Bool {
        if typed == expected { return true }
        return (expected == "ё" && typed == "е") || (expected == "Ё" && typed == "Е")
    }

    package func result(at now: TimeInterval, date: Date = Date()) -> TrainerResult {
        TrainerResult(
            date: date, language: language, source: source, wpm: wpm(at: now), accuracy: accuracy,
            duration: elapsed(at: now), characters: position, mistakes: mistakes, maxCombo: maxCombo,
            score: score + Int(accuracy * 100) * 5, timeline: timeline,
            missedKeys: Dictionary(uniqueKeysWithValues: missedKeys.map { (String($0.key), $0.value) }))
    }
}

/// Long-term progress: experience, level, records and the practice streak.
package struct TrainerProfile: Sendable, Codable, Equatable {
    package var experience = 0
    package var bestWPM: [String: Double] = [:]
    package var history: [TrainerResult] = []
    package var keyMisses: [String: Int] = [:]
    package var keyHits: [String: Int] = [:]
    package var streakDays = 0
    package var lastPracticeDay: String?

    package init() {}

    /// Experience needed to reach `level` (level 1 starts at 0).
    package static func threshold(for level: Int) -> Int {
        guard level > 1 else { return 0 }
        return Int(400 * pow(Double(level - 1), 1.6))
    }

    package var level: Int {
        var level = 1
        while experience >= Self.threshold(for: level + 1) { level += 1 }
        return level
    }

    /// Progress towards the next level, 0…1.
    package var levelProgress: Double {
        let current = Self.threshold(for: level)
        let next = Self.threshold(for: level + 1)
        return Double(experience - current) / Double(max(next - current, 1))
    }

    package struct Reward: Sendable, Equatable {
        package var experience: Int
        package var isRecord: Bool
        package var leveledUp: Bool
        package var streakDays: Int
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    @discardableResult
    package mutating func record(_ result: TrainerResult, calendar: Calendar = .current) -> Reward {
        let levelBefore = level
        let gained = max(result.score / 10, 1)
        experience += gained
        let key = result.language.rawValue
        let isRecord = result.characters >= 40 && result.accuracy >= 0.9 && result.wpm > (bestWPM[key] ?? 0)
        if isRecord { bestWPM[key] = result.wpm }
        history.append(result)
        if history.count > 400 { history.removeFirst(history.count - 400) }
        for (character, count) in result.missedKeys { keyMisses[character.lowercased(), default: 0] += count }

        let today = Self.dayKey(result.date, calendar: calendar)
        if lastPracticeDay != today {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: result.date).map {
                Self.dayKey($0, calendar: calendar)
            }
            streakDays = lastPracticeDay == yesterday ? streakDays + 1 : 1
            lastPracticeDay = today
        }
        return Reward(
            experience: gained, isRecord: isRecord, leveledUp: level > levelBefore, streakDays: streakDays)
    }

    /// Keys missed most often, worst first.
    package func weakKeys(limit: Int) -> [String] {
        keyMisses.filter { $0.value >= 2 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map(\.key)
    }
}
