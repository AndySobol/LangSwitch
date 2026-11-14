import Charts
import LangSwitchCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var sample =
        "Ghbdtn^ vtyz pjden Fyyf b z lbpfqyth d Vjcrdt! Z hf,jnf. d figma e;t 12 ktn"
    @State private var fixed: String?
    @State private var isFixing = false

    var body: some View {
        @Bindable var model = model
        Page(
            title: loc("Обзор", "Overview"),
            subtitle: loc("Что LangSwitch сделал за вас сегодня", "What LangSwitch did for you today")
        ) {
            HStack(spacing: 16) {
                Image(systemName: model.settings.enabled ? "bolt.fill" : "pause.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(model.settings.enabled ? Theme.ink : Theme.muted)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 52, height: 52)
                    .background(Theme.surfaceStrong, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.hairline))
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        model.settings.enabled
                            ? loc("Автоисправление включено", "Auto-correction is on")
                            : loc("На паузе", "Paused")
                    )
                    .font(.title3.weight(.semibold))
                    HStack(spacing: 6) {
                        LanguageBadge(language: model.currentLayout?.language)
                        Text(model.currentLayout?.name ?? loc("Раскладка не определена", "Unknown layout"))
                            .foregroundStyle(Theme.muted)
                        if let pause = model.settings.hotkey(for: .togglePause) {
                            Text("·").foregroundStyle(Theme.faint)
                            KeyCap(text: pause.display)
                        }
                    }
                    .font(.callout)
                }
                Spacer()
                Toggle("", isOn: $model.settings.enabled).toggleStyle(.mono).labelsHidden().controlSize(
                    .large)
            }
            .card()

            let today = model.statistics.today
            HStack(spacing: 14) {
                StatTile(
                    title: loc("Слов набрано", "Words typed"), value: today.words,
                    symbol: "character.cursor.ibeam", color: Theme.ink)
                StatTile(
                    title: loc("Раскладка", "Layout fixes"), value: today.layoutFixes,
                    symbol: "arrow.left.arrow.right", color: Theme.ink)
                StatTile(
                    title: loc("Опечатки", "Typos fixed"), value: today.spellingFixes,
                    symbol: "textformat.abc.dottedunderline", color: Theme.ink)
                StatTile(
                    title: loc("Дополнения", "Completions"), value: today.completions, symbol: "sparkles",
                    color: Theme.ink)
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(
                        title: loc("Исправления за 14 дней", "Fixes, last 14 days"), symbol: "chart.bar.fill")
                    Chart(model.statistics.recent(14), id: \.date) { day in
                        BarMark(x: .value("day", day.date, unit: .day), y: .value("fixes", day.value.fixes))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Theme.ink.opacity(0.9), Theme.ink.opacity(0.35)],
                                    startPoint: .top, endPoint: .bottom)
                            )
                            .cornerRadius(4)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                            AxisValueLabel(format: .dateTime.day())
                        }
                    }
                    .frame(height: 150)
                }
                .card()

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(
                        title: loc("Последние исправления", "Recent fixes"), symbol: "clock.arrow.circlepath")
                    if model.recent.isEmpty {
                        Text(
                            loc(
                                "Пока пусто — начните печатать в любом приложении.",
                                "Nothing yet — start typing anywhere.")
                        )
                        .font(.callout)
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, minHeight: 138, alignment: .center)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(model.recent.prefix(5)) { record in
                                HStack(spacing: 8) {
                                    Image(
                                        systemName: record.isUndo
                                            ? "arrow.uturn.backward" : Theme.symbol(for: record.kinds)
                                    )
                                    .foregroundStyle(Theme.ink)
                                    .frame(width: 18)
                                    Text(record.original).strikethrough(!record.isUndo).foregroundStyle(
                                        .secondary)
                                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(
                                        .tertiary)
                                    Text(record.corrected)
                                    Spacer()
                                    if let application = record.application {
                                        Text(application).font(.caption).foregroundStyle(Theme.faint)
                                    }
                                }
                                .font(.callout)
                                .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 138, alignment: .top)
                    }
                }
                .card()
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: loc("Попробовать", "Try it"), symbol: "wand.and.stars")
                Text(
                    loc(
                        "Вставьте текст с неправильной раскладкой или опечатками. То же самое делает горячая клавиша для выделенного текста.",
                        "Paste text typed on the wrong layout or with typos. The shortcut for selected text does the same."
                    )
                )
                .font(.callout)
                .foregroundStyle(Theme.muted)
                TextEditor(text: $sample)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 74)
                    .background(
                        .primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack(spacing: 10) {
                    Button {
                        isFixing = true
                        let text = sample
                        Task {
                            let result = await model.fix(text)
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                fixed = result.text
                            }
                            isFixing = false
                        }
                    } label: {
                        Label(loc("Исправить", "Fix"), systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.primary)
                    .disabled(isFixing || !model.isLoaded)
                    if let hotkey = model.settings.hotkey(for: .fixSelection) {
                        KeyCap(text: hotkey.display)
                        Text(
                            loc(
                                "— для выделенного текста в любом приложении",
                                "— for selected text in any application")
                        )
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                    }
                }
                if let fixed {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ink)
                        Text(fixed).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(
                        Theme.surfaceStrong, in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .card()
        }
    }
}

struct StatTile: View {
    let title: String
    let value: Int
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .glyphTile()
            Text("\(value)")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
            Text(title).font(.caption).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }
}
