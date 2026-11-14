import Foundation

/// Punctuation rules that are safe to apply mechanically.
///
/// Every rule here is a narrow, high-precision slice of the full norm (Lopatin's academic reference for
/// Russian, standard usage guides for English). Constructions whose punctuation depends on meaning are
/// deliberately left alone: a missed comma is cheaper than a wrong one.
package enum PunctuationRules {
    private static func set(_ words: String) -> Set<String> {
        Set(words.split(separator: " ").map(String.init))
    }

    /// Verbs and predicatives after which «что» opens a subordinate clause.
    private static let statementLeads = set(
        """
        знаю знаешь знает знаем знаете знают знал знала знали зная сказал сказала сказали скажу скажешь \
        скажет скажи скажите говорю говоришь говорит говорим говорят говорил говорила говорили думаю \
        думаешь думает думаем думают думал думала думали подумал подумала понимаю понимаешь понимает \
        понимаем понимают понял поняла поняли понятно считаю считаешь считает считаем считают считал \
        надеюсь надеемся надеется вижу видишь видит видим видят видел видела видели увидел увидела \
        слышу слышал слышала слышали помню помнишь помнит помним кажется казалось показалось оказалось \
        оказывается решил решила решили написал написала написали пишет пишут ответил ответила \
        объяснил объяснила уверен уверена уверены боюсь чувствую верю жаль жалко рад рада рады ясно \
        видно очевидно известно важно странно интересно главное хорошо плохо круто здорово узнал \
        узнала узнали заметил заметила выяснил выяснилось сообщил сообщила предупредил напомнил \
        напоминаю подтвердил означает значит получается выходит дело том тому того
        """)

    /// Verbs after which a question word («как», «где», «когда» …) opens a subordinate clause.
    private static let questionLeads = set(
        """
        знаю знаешь знает знаем знаете знают знал знала знали понимаю понимаешь понимает понял поняла \
        поняли помню помнишь помнит скажи скажите сказал сказала скажу спросил спросила спроси объясни \
        объясните объяснил расскажи расскажите рассказал покажи покажите показал интересно непонятно \
        неясно неважно смотри смотрите посмотри посмотрите подскажи подскажите узнай узнал узнала уточни \
        уточните уточнил уточню напомни напомните придумал придумала решил решила решили вспомнил
        """)

    private static let questionWords = set(
        "как где когда куда откуда почему зачем сколько кто какой какая какое какие чей")
    private static let prepositions = set(
        """
        в во на с со к ко о об от до из у за по при для без через под над между про перед около после \
        среди вокруг возле вместо кроме против ради внутри вне мимо благодаря согласно вопреки из-за из-под \
        насчет насчёт напротив посреди сквозь вдоль
        """)
    private static let conjunctions = set("и а но да или либо ни то не ну вот же")
    private static let comparatives = set(
        """
        лучше хуже больше меньше быстрее медленнее раньше позже дальше ближе выше ниже проще сложнее \
        легче труднее дешевле дороже чаще реже сильнее слабее важнее удобнее красивее интереснее
        """)

    /// Introductory words and phrases that are always set off by commas.
    package static let russianParentheticals: [[String]] = [
        "конечно", "например", "кстати", "во-первых", "во-вторых", "в-третьих", "к сожалению", "к счастью",
        "по-моему", "по-твоему", "по-вашему", "наверное", "наверно", "пожалуйста", "безусловно", "впрочем",
        "следовательно", "видимо", "по-видимому", "разумеется", "несомненно", "кроме того", "более того",
        "с одной стороны", "с другой стороны", "между прочим", "скорее всего", "честно говоря",
        "откровенно говоря", "грубо говоря", "иными словами", "другими словами", "на мой взгляд",
    ].map { $0.split(separator: " ").map(String.init) }

    /// Sentence-opening English adverbials followed by a comma.
    package static let englishIntroductions: [[String]] = [
        "however", "therefore", "moreover", "furthermore", "nevertheless", "nonetheless", "unfortunately",
        "fortunately", "additionally", "meanwhile", "consequently", "otherwise", "for example",
        "for instance",
        "in addition", "in fact", "of course", "on the other hand", "in conclusion", "in other words",
        "as a result", "by the way", "first of all", "to be honest",
    ].map { $0.split(separator: " ").map(String.init) }

    /// Whether a comma belongs right before `word`.
    ///
    /// - Parameters:
    ///   - word: the lower-case word being considered.
    ///   - next: the following lower-case word, or nil when it has not been typed yet.
    ///   - previous: preceding lower-case words of the same clause, nearest last, with no punctuation
    ///     between them and `word`.
    package static func needsCommaBefore(
        word: String, next: String?, previous: [String], language: Language
    ) -> Bool {
        guard language == .russian, let before = previous.last else { return false }
        switch word {
        case "что":
            if let next, ["ли", "ж", "же", "бы", "за", "угодно"].contains(next) { return false }
            return statementLeads.contains(before)
        case "чтобы", "чтоб":
            return !conjunctions.contains(before)
                && !["лишь", "только", "того", "тем", "вместо", "без", "для", "так", "затем", "разве"]
                    .contains(before)
        case "а", "но":
            if prepositions.contains(before) || conjunctions.contains(before) { return false }
            if word == "а"
                && ["буква", "буквы", "пункт", "пункте", "вариант", "витамин", "группа", "класс"].contains(
                    before)
            {
                return false
            }
            return true
        case "однако", "зато":
            return !conjunctions.contains(before)
        case "если":
            return !conjunctions.contains(before)
                && ![
                    "что", "даже", "только", "лишь", "как", "разве", "особенно", "кроме", "будто", "а", "чем",
                ]
                .contains(before)
        case "поэтому":
            return !conjunctions.contains(before) && before != "именно"
        case "потому":
            guard next == "что" else { return false }
            return !conjunctions.contains(before)
                && !["именно", "только", "лишь", "просто", "может", "наверное", "отчасти"].contains(before)
        case "хотя":
            guard let next, next != "бы", next != "б" else { return false }
            return !conjunctions.contains(before)
        case "то":
            return next == "есть" && !conjunctions.contains(before)
        case "чем":
            return comparatives.contains(before)
        default:
            if word.hasPrefix("котор"), word.count >= 7 {
                return !prepositions.contains(before) && !conjunctions.contains(before)
            }
            if questionWords.contains(word) {
                if word == "как" && (next == "будто" || next == "бы" || next == "раз" || next == "только") {
                    return false
                }
                return questionLeads.contains(before)
            }
            return false
        }
    }

    /// For «котор…» after a preposition the comma goes before the preposition: «дом, в котором».
    package static func needsCommaBeforePreposition(word: String, preposition: String, previous: String?)
        -> Bool
    {
        guard word.hasPrefix("котор"), word.count >= 7, prepositions.contains(preposition), let previous
        else {
            return false
        }
        return !conjunctions.contains(previous) && !prepositions.contains(previous)
    }

    /// "a" or "an" for the following English word, or nil when the rule cannot tell.
    package static func indefiniteArticle(before word: String) -> String? {
        let lower = word.lowercased()
        guard let first = lower.first, first.isASCIILetter, lower.count >= 2, word != word.uppercased() else {
            return nil
        }
        let vowelSoundExceptions = ["hour", "honest", "honor", "honour", "heir"]
        let consonantSoundExceptions = [
            "uni", "use", "usu", "usa", "util", "uk", "eu", "one", "once", "ubiq", "ufo", "uber",
        ]
        if vowelSoundExceptions.contains(where: lower.hasPrefix) { return "an" }
        // "uninstall", "unimportant", "unidentified" start with a vowel sound, "uniform" does not.
        if ["unin", "unim", "unid"].contains(where: lower.hasPrefix) { return "an" }
        if lower.hasPrefix("one") && lower.count > 4 && !lower.hasPrefix("one-") { return nil }
        if consonantSoundExceptions.contains(where: lower.hasPrefix) { return "a" }
        return "aeiou".contains(first) ? "an" : "a"
    }
}
