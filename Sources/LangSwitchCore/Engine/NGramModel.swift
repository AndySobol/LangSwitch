import Foundation

/// A character trigram model of one language.
///
/// It answers one question: "does this letter sequence look like a word of the language?", which lets
/// the engine recognise words that no dictionary lists (surnames, slang) and reject keyboard noise such
/// as "ghbdtn". Scores are z-scores against the words the model was trained on.
package struct NGramModel: Sendable {
    package let language: Language
    private let size: Int
    private let index: [Character: Int]
    private let trigrams: [Float]
    private let mean: Float
    private let deviation: Float

    /// Accumulates training words one at a time, so a whole dictionary never has to sit in memory.
    package struct Builder {
        fileprivate let language: Language
        fileprivate let index: [Character: Int]
        fileprivate let size: Int
        fileprivate var tri: [Float]
        fileprivate var bi: [Float]
        fileprivate var uni: [Float]
        fileprivate var sample: [[UInt8]] = []
        private var seen = 0

        package init(language: Language) {
            self.language = language
            var index: [Character: Int] = [:]
            // 0 is the word boundary, 1 is "any other character".
            for (offset, letter) in language.alphabet.enumerated() { index[letter] = offset + 2 }
            if language == .english { index["'"] = language.alphabet.count + 2 }
            self.index = index
            size = index.count + 2
            tri = [Float](repeating: 0, count: size * size * size)
            bi = [Float](repeating: 0, count: size * size)
            uni = [Float](repeating: 0, count: size)
        }

        /// Adds a lower-case word; frequent words should carry a larger weight.
        package mutating func add(_ word: String, weight: Float = 1) {
            let codes = NGramModel.encode(word, index: index)
            guard codes.count >= 4 else { return }
            for position in 2..<codes.count {
                let a = codes[position - 2]
                let b = codes[position - 1]
                let c = codes[position]
                tri[(a * size + b) * size + c] += weight
                bi[b * size + c] += weight
                uni[c] += weight
            }
            // A sample of words for calibration; every 7th keeps start-up cheap.
            seen += 1
            if seen % 7 == 0 && sample.count < 12_000 { sample.append(codes.map { UInt8($0) }) }
        }

        package func build() -> NGramModel { NGramModel(self) }
    }

    /// - Parameter words: lower-case training words with a weight (frequent words should weigh more).
    package init(language: Language, words: some Sequence<(word: String, weight: Float)>) {
        var builder = Builder(language: language)
        for (word, weight) in words { builder.add(word, weight: weight) }
        self.init(builder)
    }

    private init(_ builder: Builder) {
        language = builder.language
        index = builder.index
        size = builder.size
        let size = builder.size
        let tri = builder.tri
        let bi = builder.bi
        let uni = builder.uni
        let sample = builder.sample.map { $0.map(Int.init) }

        // Convert counts to log-probabilities with interpolation between orders.
        let total = max(uni.reduce(0, +), 1)
        var uniLog = [Float](repeating: 0, count: size)
        for c in 0..<size { uniLog[c] = (uni[c] + 0.5) / (total + 0.5 * Float(size)) }
        var biProb = [Float](repeating: 0, count: size * size)
        for b in 0..<size {
            var rowTotal: Float = 0
            for c in 0..<size { rowTotal += bi[b * size + c] }
            for c in 0..<size {
                let estimate = rowTotal > 0 ? bi[b * size + c] / rowTotal : 0
                biProb[b * size + c] = 0.85 * estimate + 0.15 * uniLog[c]
            }
        }
        var triLog = [Float](repeating: 0, count: size * size * size)
        for a in 0..<size {
            for b in 0..<size {
                let base = (a * size + b) * size
                var rowTotal: Float = 0
                for c in 0..<size { rowTotal += tri[base + c] }
                for c in 0..<size {
                    let estimate = rowTotal > 0 ? tri[base + c] / rowTotal : 0
                    triLog[base + c] = log(0.8 * estimate + 0.2 * biProb[b * size + c])
                }
            }
        }
        self.trigrams = triLog

        var sum: Float = 0
        var squares: Float = 0
        var counted: Float = 0
        for codes in sample {
            let value = Self.rawScore(codes, trigrams: triLog, size: size)
            sum += value
            squares += value * value
            counted += 1
        }
        if counted > 1 {
            let mean = sum / counted
            self.mean = mean
            self.deviation = max(sqrt(max(squares / counted - mean * mean, 0)), 0.05)
        } else {
            self.mean = -2.2
            self.deviation = 0.5
        }
    }

    private static func encode(_ word: String, index: [Character: Int]) -> [Int] {
        var codes = [0, 0]
        for character in word.lowercased() { codes.append(index[character] ?? 1) }
        codes.append(0)
        return codes
    }

    private static func rawScore(_ codes: [Int], trigrams: [Float], size: Int) -> Float {
        var total: Float = 0
        for position in 2..<codes.count {
            total += trigrams[(codes[position - 2] * size + codes[position - 1]) * size + codes[position]]
        }
        return total / Float(codes.count - 2)
    }

    /// How word-like `word` is: 0 is a typical dictionary word, below about -2.5 is noise.
    package func plausibility(of word: String) -> Float {
        let codes = Self.encode(word, index: index)
        guard codes.count >= 4 else { return -10 }
        return (Self.rawScore(codes, trigrams: trigrams, size: size) - mean) / deviation
    }
}
