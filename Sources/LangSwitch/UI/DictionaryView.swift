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
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button(loc("Добавить", "Add"), action: add).buttonStyle(.borderedProminent).tint(
                        Theme.indigo
                    )
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if vocabulary.words.isEmpty {
                    Text(
                        loc(
                            "Слова, которые вы добавите или которые встретятся три раза, появятся здесь и перестанут исправляться.",
                            "Words you add, or type three times, appear here and stop being corrected.")
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else {
                    ChipFlow(items: vocabulary.words.sorted { $0.lowercased() < $1.lowercased() }) { word in
                        Chip(
                            text: word,
                            accent: model.learning.autoLearned.contains(word) ? Theme.mint : Theme.indigo
                        ) {
                            model.updateLearning { $0.removeWord(word) }
                        }
                    }
                    HStack(spacing: 14) {
                        Label(loc("добавлено вами", "added by you"), systemImage: "circle.fill")
                            .foregroundStyle(Theme.indigo)
                        Label(
                            loc("выучено автоматически", "learned automatically"), systemImage: "circle.fill"
                        )
                        .foregroundStyle(Theme.mint)
                    }
                    .font(.caption)
                    .labelStyle(.titleAndIcon)
                }
            }
            .card()

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
                    .foregroundStyle(.secondary)
                } else {
                    ChipFlow(items: weak.map { "\($0.key) ×\($0.value)" }) { text in
                        Text(text).font(.callout).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Theme.amber.opacity(0.16), in: Capsule())
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
                                .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button {
                                model.deletePhrase(phrase.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .card()
            }
        }
    }

    private func ruleList(
        title: String, symbol: String, empty: String, items: [String], remove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, symbol: symbol)
            if items.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
            } else {
                ChipFlow(items: items) { item in Chip(text: item, accent: Theme.violet) { remove(item) } }
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
                .foregroundStyle(.secondary)
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
