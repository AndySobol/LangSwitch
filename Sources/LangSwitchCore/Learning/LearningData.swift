import Foundation

/// A word the dictionaries do not know, watched until it proves to be part of the user's vocabulary.
///
/// One sighting proves nothing: it may be a typo. What tells a word from a slip is that it comes back —
/// and comes back on another day. So every sighting adds evidence, each further one on the same day adds
/// less (a typo fought with in one field must not count five times), and the first one on a new day adds
/// more. The word joins the vocabulary when the evidence reaches a threshold, which is higher for words
/// that look like a slip.
package struct WordObservation: Sendable, Codable, Equatable {
    /// The spelling as last typed, with its capitals.
    package var spelling: String
    /// How many times the word was left as typed.
    package var count = 0
    /// On how many different days.
    package var days = 0
    /// Day of the last sighting and how many sightings that day has had.
    package var lastDay = 0
    package var countThatDay = 0
    package var evidence = 0.0
    /// The word looks like a slip of a known word, or is very short: it has to prove more.
    package var isDoubtful = false

    /// Evidence needed to join the vocabulary: seen on two different days, or five times in one;
    /// for a doubtful word, on three days or about a dozen times.
    package var threshold: Double {
        isDoubtful ? LearningData.doubtfulThreshold : LearningData.adoptionThreshold
    }
    /// From 0 to 1: how far the word is on its way into the vocabulary.
    package var progress: Double { min(evidence / threshold, 1) }
}

/// Everything the application learns about its user. Stored locally; never leaves the Mac.
package struct LearningData: Sendable, Codable, Equatable {
    package var vocabulary = PersonalVocabulary()
    /// Words the application added on its own after seeing them typed repeatedly.
    package var autoLearned: Set<String> = []
    /// How often each word was typed (lower-case); drives personal completions.
    package var wordCounts: [String: Int] = [:]
    /// Unknown words left as typed (lower-case), on their way into the vocabulary.
    package var observations: [String: WordObservation] = [:]
    /// Words (lower-case) the user removed or refused: never added automatically again.
    package var declined: Set<String> = []
    /// previous word → next word → count; drives next-word suggestions.
    package var bigrams: [String: [String: Int]] = [:]
    /// Typed chunk (lower-case) → how many times its conversion was undone.
    package var rejections: [String: Int] = [:]
    /// Typed chunk (lower-case) → how many times it was converted by hand.
    package var manualConversions: [String: Int] = [:]
    /// Correct spelling → how many times the user mistyped it; feeds the "weak words" drill.
    package var typoCounts: [String: Int] = [:]

    package init() {}

    package static let adoptionThreshold = 3.0
    package static let doubtfulThreshold = 5.0
    /// A watched word that has not come back for this many days is forgotten.
    private static let observationLifetime = 60
    private static let wordLimit = 6000
    private static let bigramLimit = 2500

    private enum CodingKeys: String, CodingKey {
        case vocabulary, autoLearned, wordCounts, observations, declined, unknownCounts, bigrams, rejections,
            manualConversions, typoCounts
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vocabulary =
            try container.decodeIfPresent(PersonalVocabulary.self, forKey: .vocabulary)
            ?? PersonalVocabulary()
        autoLearned = try container.decodeIfPresent(Set<String>.self, forKey: .autoLearned) ?? []
        wordCounts = try container.decodeIfPresent([String: Int].self, forKey: .wordCounts) ?? [:]
        observations =
            try container.decodeIfPresent([String: WordObservation].self, forKey: .observations) ?? [:]
        declined = try container.decodeIfPresent(Set<String>.self, forKey: .declined) ?? []
        // Counts kept by earlier builds become observations made "today".
        let today = Self.today
        for (word, count) in try container.decodeIfPresent([String: Int].self, forKey: .unknownCounts) ?? [:]
        where observations[word] == nil {
            observations[word] = WordObservation(
                spelling: word, count: count, days: 1, lastDay: today, countThatDay: count,
                evidence: min(Double(count), 2))
        }
        bigrams = try container.decodeIfPresent([String: [String: Int]].self, forKey: .bigrams) ?? [:]
        rejections = try container.decodeIfPresent([String: Int].self, forKey: .rejections) ?? [:]
        manualConversions =
            try container.decodeIfPresent([String: Int].self, forKey: .manualConversions) ?? [:]
        typoCounts = try container.decodeIfPresent([String: Int].self, forKey: .typoCounts) ?? [:]
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vocabulary, forKey: .vocabulary)
        try container.encode(autoLearned, forKey: .autoLearned)
        try container.encode(wordCounts, forKey: .wordCounts)
        try container.encode(observations, forKey: .observations)
        try container.encode(declined, forKey: .declined)
        try container.encode(bigrams, forKey: .bigrams)
        try container.encode(rejections, forKey: .rejections)
        try container.encode(manualConversions, forKey: .manualConversions)
        try container.encode(typoCounts, forKey: .typoCounts)
    }

    /// Days since 1970 in the user's time zone: what "another day" means for an observation.
    package static var today: Int {
        Int((Date().timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT())) / 86_400)
    }

    /// A word must look like a word to be remembered: letters, at least two, no digits.
    package static func isLearnable(_ word: String) -> Bool {
        word.count >= 2 && word.count <= 32
            && word.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" }
            && word.first?.isLetter == true && word.last?.isLetter == true
    }

    /// Records a finished word. Returns the word when it has just joined the vocabulary.
    ///
    /// - Parameters:
    ///   - mayLearn: false for unknown words that must never become vocabulary (see
    ///     `CorrectionEngine.mayLearn`); such a word is not counted at all.
    ///   - doubtful: the word looks like a slip of a known word; it needs more evidence.
    ///   - day: the day of the sighting (see `today`).
    @discardableResult
    package mutating func recordWord(
        _ word: String, previous: String?, known: Bool, mayLearn: Bool = true, doubtful: Bool = false,
        day: Int = LearningData.today
    ) -> String? {
        guard Self.isLearnable(word), known || mayLearn else { return nil }
        let lower = word.lowercased()
        // Two letters say too little to predict or complete anything.
        if word.count >= 3 {
            wordCounts[lower, default: 0] += 1
            if let previous, Self.isLearnable(previous) {
                bigrams[previous.lowercased(), default: [:]][lower, default: 0] += 1
            }
        }
        var adopted: String?
        if !known, vocabulary.knows(word) == nil, !declined.contains(lower) {
            adopted = observe(word, doubtful: doubtful || word.count <= 2, day: day)
        }
        pruneIfNeeded(day: day)
        return adopted
    }

    private mutating func observe(_ word: String, doubtful: Bool, day: Int) -> String? {
        let lower = word.lowercased()
        var observation = observations[lower] ?? WordObservation(spelling: word)
        let isNewDay = observation.count > 0 && day != observation.lastDay
        if observation.count == 0 || isNewDay {
            observation.days += 1
            observation.countThatDay = 0
        }
        observation.lastDay = day
        observation.count += 1
        observation.countThatDay += 1
        // Each further sighting on the same day weighs less; coming back on another day weighs more.
        observation.evidence += 1 / Double(observation.countThatDay).squareRoot() + (isNewDay ? 1 : 0)
        // The spelling the user actually uses, capitals included.
        observation.spelling = word
        // Once doubtful, a word stays doubtful: the judgement was made with a context that may be gone.
        observation.isDoubtful = observation.isDoubtful || doubtful
        guard observation.evidence >= observation.threshold else {
            observations[lower] = observation
            return nil
        }
        observations[lower] = nil
        vocabulary.words.insert(word)
        autoLearned.insert(word)
        return word
    }

    /// Forgets watched words that have not come back for two months.
    package mutating func forgetStaleObservations(day: Int = LearningData.today) {
        observations = observations.filter { day - $0.value.lastDay <= Self.observationLifetime }
    }

    /// The user wants a watched word in the vocabulary now.
    package mutating func adopt(_ word: String) {
        let lower = word.lowercased()
        let spelling = observations[lower]?.spelling ?? word
        observations[lower] = nil
        declined.remove(lower)
        vocabulary.words.insert(spelling)
    }

    /// The user says a watched or learned word is not a word of theirs: it is dropped and never added
    /// automatically again.
    package mutating func decline(_ word: String) {
        let lower = word.lowercased()
        observations[lower] = nil
        for known in vocabulary.words where known.lowercased() == lower {
            vocabulary.words.remove(known)
            autoLearned.remove(known)
        }
        declined.insert(lower)
        if declined.count > 2000 { declined = Set(declined.sorted().prefix(1500)) }
    }

    /// Watched words, the closest to joining the vocabulary first.
    package var watched: [WordObservation] {
        observations.values.sorted {
            $0.progress == $1.progress
                ? $0.spelling.lowercased() < $1.spelling.lowercased() : $0.progress > $1.progress
        }
    }

    /// The user undid a conversion. After two undos the chunk is never converted again.
    @discardableResult
    package mutating func recordRejection(typed: String) -> Bool {
        let key = typed.lowercased()
        let count = rejections[key, default: 0] + 1
        rejections[key] = count
        vocabulary.alwaysConvert.remove(key)
        if count >= 2 {
            vocabulary.keepAsTyped.insert(key)
            return true
        }
        return false
    }

    /// The user converted a chunk by hand. After two times it is converted automatically.
    @discardableResult
    package mutating func recordManualConversion(typed: String) -> Bool {
        let key = typed.lowercased()
        let count = manualConversions[key, default: 0] + 1
        manualConversions[key] = count
        vocabulary.keepAsTyped.remove(key)
        if count >= 2 {
            vocabulary.alwaysConvert.insert(key)
            return true
        }
        return false
    }

    package mutating func recordTypo(corrected: String) {
        guard Self.isLearnable(corrected) else { return }
        typoCounts[corrected.lowercased(), default: 0] += 1
        if typoCounts.count > 800 { typoCounts = Self.trimmed(typoCounts, to: 600) }
    }

    /// Drops automatically learned words that fail `isValid` (and everything counted for them).
    /// Returns the words removed.
    @discardableResult
    package mutating func removeAutoLearned(where isInvalid: (String) -> Bool) -> [String] {
        let removed = autoLearned.filter(isInvalid)
        for word in removed {
            autoLearned.remove(word)
            vocabulary.words.remove(word)
            let lower = word.lowercased()
            wordCounts[lower] = nil
            observations[lower] = nil
            bigrams[lower] = nil
            for key in bigrams.keys { bigrams[key]?[lower] = nil }
        }
        return removed.sorted()
    }

    package mutating func addWord(_ word: String) {
        vocabulary.words.insert(word)
        observations[word.lowercased()] = nil
        declined.remove(word.lowercased())
    }

    /// Removes a word from the vocabulary. One that the application had added on its own is also
    /// remembered as declined, or it would be back after a few more sightings.
    package mutating func removeWord(_ word: String) {
        if autoLearned.contains(word) {
            decline(word)
        } else {
            vocabulary.words.remove(word)
        }
    }

    /// Words mistyped most often, best candidates for practice first.
    package func weakWords(limit: Int) -> [String] {
        typoCounts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit).map(
            \.key)
    }

    private static func trimmed(_ counts: [String: Int], to limit: Int) -> [String: Int] {
        let kept = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(
            limit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    private mutating func pruneIfNeeded(day: Int) {
        if wordCounts.count > Self.wordLimit {
            wordCounts = Self.trimmed(wordCounts, to: Self.wordLimit * 3 / 4)
        }
        if observations.count > 1500 {
            // Words that never came back go first, then the weakest.
            observations = observations.filter { day - $0.value.lastDay <= Self.observationLifetime }
            if observations.count > 1200 {
                let kept = observations.sorted { $0.value.evidence > $1.value.evidence }.prefix(1000)
                observations = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
            }
        }
        if bigrams.count > Self.bigramLimit {
            var totals: [String: Int] = [:]
            for (key, followers) in bigrams { totals[key] = followers.values.reduce(0, +) }
            let keep = Set(Self.trimmed(totals, to: Self.bigramLimit * 3 / 4).keys)
            bigrams = bigrams.filter { keep.contains($0.key) }
        }
        for (key, followers) in bigrams where followers.count > 12 {
            bigrams[key] = Self.trimmed(followers, to: 8)
        }
    }
}
