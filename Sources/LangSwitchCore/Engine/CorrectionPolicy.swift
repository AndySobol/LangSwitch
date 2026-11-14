import Foundation

/// Decides whether a proposed replacement is safe to apply without asking.
///
/// The spelling model explains an unknown word; this policy weighs the explanation. It is a set of
/// small logistic models, one per kind of slip, fitted by `scripts/train-correction-policy.py` to the
/// evaluation corpora and stored in `Rules/correction-policy.json`. The features describe the proposal
/// — how common the word is, whether it was seen after the previous word, how far the next explanation
/// is — and never a particular word.
package struct CorrectionPolicy: Sendable, Decodable {
    /// Everything the policy looks at.
    package struct Evidence: Sendable {
        package var edit = ""
        package var length = 0
        /// Rank of the rarest word of the replacement in the frequency list; nil when one is unlisted.
        package var rank: Int?
        /// The same through dictionary forms.
        package var lemmaRank: Int?
        package var seenAfterPrevious = 0
        /// Distance to the next explanation; nil when there is none.
        package var margin: Float?
        package var rivalIsRanked = false
        package var firstLetterChanged = false
        /// How word-like the typed string is by the letter model.
        package var plausibility: Float = 0
        package var candidateCount = 1
        package var seenTogether = 0
        package var gluedFunctionWord = false
        package var score: Float = 0
        package var isEnglish = false

        package init() {}
    }

    package let threshold: Float
    let features: [String]
    /// One weight per feature, for every kind of slip.
    let models: [String: [Float]]

    package init(data: Data) throws {
        self = try JSONDecoder().decode(CorrectionPolicy.self, from: data)
    }

    private func value(_ feature: String, _ evidence: Evidence) -> Float {
        let margin = min(evidence.margin ?? 1, 1)
        switch feature {
        case "bias": return 1
        case "length2": return evidence.length == 2 ? 1 : 0
        case "length3": return evidence.length == 3 ? 1 : 0
        case "length4": return evidence.length == 4 ? 1 : 0
        case "long": return evidence.length >= 7 ? 1 : 0
        case "size": return Float(min(evidence.length, 12)) / 12
        case "rank": return evidence.rank.map { 1 - log10(Float($0) + 10) / 5.5 } ?? 0
        case "unranked": return evidence.rank == nil ? 1 : 0
        case "lemmaOnly": return evidence.rank == nil && evidence.lemmaRank != nil ? 1 : 0
        case "commonest": return (evidence.rank.map { $0 < 300 } ?? false) ? 1 : 0
        case "everyday": return (evidence.rank.map { $0 < 6000 } ?? false) ? 1 : 0
        case "listed": return (evidence.rank.map { $0 < 30000 } ?? false) ? 1 : 0
        case "seenAfter": return evidence.seenAfterPrevious > 0 ? 1 : 0
        case "seenAfterLog": return min(log10(Float(evidence.seenAfterPrevious) + 1) / 3, 1)
        case "margin": return margin
        case "clear": return margin >= 0.15 ? 1 : 0
        case "distinct": return margin >= 0.4 ? 1 : 0
        case "unique": return evidence.margin == nil ? 1 : 0
        case "firstLetter": return evidence.firstLetterChanged ? 1 : 0
        case "plausibility": return max(-4, min(evidence.plausibility, 2)) / 4
        case "rivalRanked": return evidence.rivalIsRanked && margin < 0.5 ? 1 : 0
        case "candidates": return min(log10(Float(max(evidence.candidateCount, 1))) / 1.5, 1)
        case "seenTogether": return evidence.seenTogether > 0 ? 1 : 0
        case "seenTogetherLog": return min(log10(Float(evidence.seenTogether) + 1) / 3, 1)
        case "glued": return evidence.gluedFunctionWord ? 1 : 0
        case "score": return evidence.score / 2.5
        case "english": return evidence.isEnglish ? 1 : 0
        default: return 0
        }
    }

    /// The chance that the proposal is what the user meant; nil for a kind of slip no model covers.
    package func confidence(_ evidence: Evidence) -> Float? {
        guard let weights = models[evidence.edit], weights.count == features.count else { return nil }
        var sum: Float = 0
        for (index, feature) in features.enumerated() { sum += weights[index] * value(feature, evidence) }
        return 1 / (1 + exp(-max(-30, min(sum, 30))))
    }
}
