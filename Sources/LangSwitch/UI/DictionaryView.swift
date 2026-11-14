import LangSwitchCore
import SwiftUI

struct DictionaryView: View {
    @Environment(AppModel.self) private var model
    @State private var newWord = ""

    private func add() {
        let word = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !word.contains(where: \.isWhitespace) else { return }
        model.updateLearning { $0.addWord(word) }
        newWord = ""
    }

    var body: some View {
        let vocabulary = model.learning.vocabulary
        Page(
            title: loc("Словарь", "Dictionary"),
            subtitle: loc(
                "Ваши слова, сленг и исключения. LangSwitch пополняет его сам, пока вы печатаете.",
                "Your words, slang and exceptions. LangSwitch adds to it as you type.")
        ) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: loc("Мои слова", "My words"), symbol: "text.badge.plus")
                HStack {
                    TextField(loc("Новое слово, имя или название", "A new word or name"), text: $newWord)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.hairline))
                        .onSubmit(add)
                    Button(loc("Добавить", "Add"), action: add).buttonStyle(.primary).tint(
                        Theme.ink
                    )
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if vocabulary.words.isEmpty {
                    Text(
                        loc(
                            "Слова, которые вы добавите сами или которые LangSwitch освоит, наблюдая за вашим набором, появятся здесь и перестанут исправляться.",
                            "Words you add, or that LangSwitch picks up from your typing, appear here and stop being corrected."
                        )
                    )
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                } else {
                    ChipFlow(items: vocabulary.words.sorted { $0.lowercased() < $1.lowercased() }) { word in
                        Chip(
                            text: word,
                            accent: model.learning.autoLearned.contains(word) ? Theme.muted : Theme.ink
                        ) {
                            model.updateLearning { $0.removeWord(word) }
                        }
                    }
                    HStack(spacing: 14) {
                        Label(loc("добавлено вами", "added by you"), systemImage: "circle.fill")
                            .foregroundStyle(Theme.ink)
                        Label(
                            loc("выучено автоматически", "learned automatically"), systemImage: "circle.fill"
                        )
                        .foregroundStyle(Theme.muted)
                    }
                    .font(.caption)
                    .labelStyle(.titleAndIcon)
                }
            }
            .card()

            watching

            HStack(alignment: .top, spacing: 14) {
                ruleList(
                    title: loc("Не конвертировать", "Never convert"), symbol: "hand.raised.fill",
                    empty: loc(
                        "Сюда попадает то, что вы дважды вернули после автозамены раскладки.",
                        "Whatever you restored twice after a layout conversion lands here."),
                    items: vocabulary.keepAsTyped.sorted()
                ) { item in
                    model.updateLearning {
                        $0.vocabulary.keepAsTyped.remove(item)
                        $0.rejections[item] = nil
                    }
                }
                ruleList(
                    title: loc("Всегда конвертировать", "Always convert"), symbol: "arrow.left.arrow.right",
                    empty: loc(
                        "Сюда попадает то, что вы дважды сконвертировали вручную.",
                        "Whatever you converted by hand twice lands here."),
                    items: vocabulary.alwaysConvert.sorted()
                ) { item in
                    model.updateLearning {
                        $0.vocabulary.alwaysConvert.remove(item)
                        $0.manualConversions[item] = nil
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: loc("Слова, в которых вы ошибаетесь", "Words you mistype"), symbol: "scope")
                let weak = model.learning.typoCounts.sorted {
                    $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
                }.prefix(24)
                if weak.isEmpty {
                    Text(
                        loc(
                            "Когда LangSwitch исправит несколько опечаток, здесь появится список для тренировки.",
                            "Once a few typos have been fixed, a practice list appears here.")
                    )
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                } else {
                    ChipFlow(items: weak.map { "\($0.key) ×\($0.value)" }) { text in
                        Text(text).font(.callout).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Theme.surfaceStrong, in: Capsule())
                    }
                    Button {
                        model.settings.trainerSource = .weakWords
                        model.selection = .trainer
                    } label: {
                        Label(loc("Потренировать", "Practise them"), systemImage: "gamecontroller.fill")
                    }
                }
            }
            .card()

            if !model.phrases.phrases.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(
                        title: loc("Собранные фразы", "Collected phrases"), symbol: "quote.bubble.fill")
                    ForEach(model.phrases.phrases.suffix(12).reversed()) { phrase in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(phrase.text).font(.callout)
                                Text(
                                    phrase.application + " · "
                                        + phrase.date.formatted(date: .abbreviated, time: .shortened)
                                )
                                .font(.caption)
                                .foregroundStyle(Theme.faint)
                            }
                            Spacer()
                            Button {
                                model.deletePhrase(phrase.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.muted)
                        }
                    }
                }
                .card()
            }
        }
    }

    /// Unknown words on their way into the vocabulary, and the ones the user turned down.
    @ViewBuilder private var watching: some View {
        let watched = Array(model.learning.watched.prefix(14))
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: loc("Присматриваюсь", "Watching"), symbol: "eye.fill")
            Text(
                loc(
                    "Незнакомые слова, которые вы оставили как набрали. Слово попадает в словарь, когда возвращается: в другой день или несколько раз за один. Похожему на опечатку и очень короткому нужно больше.",
                    "Unknown words you left as typed. A word joins the dictionary when it comes back: on another day, or several times in one. A word that looks like a typo, or a very short one, needs more."
                )
            )
            .font(.callout)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            if watched.isEmpty {
                Text(loc("Пока наблюдать не за чем.", "Nothing to watch yet."))
                    .font(.callout)
                    .foregroundStyle(Theme.faint)
            } else {
                VStack(spacing: 8) {
                    ForEach(watched, id: \.spelling) { item in watchedRow(item) }
                }
            }
        }
        .card()

        if !model.learning.declined.isEmpty {
            ruleList(
                title: loc("Не запоминать", "Never learn"), symbol: "nosign",
                empty: "", items: model.learning.declined.sorted()
            ) { item in
                model.updateLearning { $0.declined.remove(item) }
            }
        }
    }

    private func watchedRow(_ item: WordObservation) -> some View {
        let word = item.spelling
        let times = loc("встреч: \(item.count)", "seen \(item.count)×")
        let days = loc("дней: \(item.days)", "days: \(item.days)")
        let doubt = item.isDoubtful ? " · " + loc("нужно больше подтверждений", "needs more evidence") : ""
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(word).font(.callout.weight(.medium))
                Text("\(times) · \(days)\(doubt)").font(.caption).foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 8)
            ProgressView(value: item.progress)
                .progressViewStyle(.linear)
                .tint(Theme.ink)
                .frame(width: 96)
            Button {
                model.updateLearning { $0.adopt(word) }
            } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.ink)
            .help(loc("Добавить в словарь сейчас", "Add to the dictionary now"))
            Button {
                model.updateLearning { $0.decline(word) }
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
            .help(loc("Это не слово — не запоминать", "Not a word — never learn it"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func ruleList(
        title: String, symbol: String, empty: String, items: [String], remove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, symbol: symbol)
            if items.isEmpty {
                Text(empty).font(.callout).foregroundStyle(Theme.muted).fixedSize(
                    horizontal: false, vertical: true)
            } else {
                ChipFlow(items: items) { item in Chip(text: item, accent: Theme.ink) { remove(item) } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct Chip: View {
    let text: String
    let accent: Color
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(text).font(.callout)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.muted)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(accent.opacity(0.16), in: Capsule())
    }
}

/// Lays chips out left to right, wrapping to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in arrangement.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), points)
    }
}

struct ChipFlow<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        FlowLayout { ForEach(items, id: \.self) { content($0) } }
    }
}
