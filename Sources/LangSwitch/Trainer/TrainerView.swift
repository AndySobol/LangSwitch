import Charts
import LangSwitchCore
import SwiftUI

struct TrainerView: View {
    @Environment(AppModel.self) private var app
    @State private var trainer = TrainerModel()

    var body: some View {
        ZStack {
            switch trainer.phase {
            case .setup:
                TrainerSetup(trainer: trainer).transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .running: TrainerStage(trainer: trainer).transition(.opacity)
            case .finished:
                TrainerResults(trainer: trainer).transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: trainer.phase)
        .onAppear { trainer.attach(app) }
        .onDisappear { if trainer.phase == .running { trainer.stop() } }
    }
}

/// The exercise screen on its own, for the snapshot renderer.
struct TrainerPreview: View {
    let trainer: TrainerModel
    var body: some View { TrainerStage(trainer: trainer) }
}

// MARK: - Setup

private struct TrainerSetup: View {
    @Environment(AppModel.self) private var app
    let trainer: TrainerModel

    private func title(_ source: TrainerSource) -> (String, String, String) {
        switch source {
        case .words:
            (
                loc("Слова", "Words"), loc("Частые слова на время", "Frequent words against the clock"),
                "bolt.fill"
            )
        case .texts:
            (
                loc("Тексты", "Texts"), loc("Связные отрывки с пунктуацией", "Passages with punctuation"),
                "text.alignleft"
            )
        case .weakWords:
            (
                loc("Мои ошибки", "My mistakes"),
                loc("Слова, в которых вы ошибаетесь", "The words you mistype"),
                "scope"
            )
        case .myTexts:
            (
                loc("Мои фразы", "My phrases"),
                loc("То, что вы сами писали на этой неделе", "What you wrote yourself this week"),
                "quote.bubble.fill"
            )
        }
    }

    var body: some View {
        @Bindable var app = app
        let profile = app.profile
        Page(
            title: loc("Тренажёр", "Trainer"),
            subtitle: loc(
                "Слепая печать как игра: скорость, серии, уровни",
                "Touch typing as a game: speed, streaks, levels")
        ) {
            HStack(spacing: 14) {
                HStack(spacing: 16) {
                    ZStack {
                        Circle().stroke(Theme.surfaceStrong, lineWidth: 7)
                        Circle().trim(from: 0, to: profile.levelProgress)
                            .stroke(Theme.ink, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: -2) {
                            Text("\(profile.level)").font(.system(size: 26, weight: .heavy, design: .rounded))
                            Text(loc("уровень", "level")).font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    .frame(width: 78, height: 78)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc("\(profile.experience) опыта", "\(profile.experience) XP")).font(
                            .title3.weight(.semibold))
                        Text(
                            loc(
                                "До следующего уровня: \(max(TrainerProfile.threshold(for: profile.level + 1) - profile.experience, 0))",
                                "To the next level: \(max(TrainerProfile.threshold(for: profile.level + 1) - profile.experience, 0))"
                            )
                        )
                        .font(.callout)
                        .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
                .card()
                badge(
                    value: "\(profile.streakDays)", label: loc("дней подряд", "day streak"),
                    symbol: "flame.fill", color: Theme.ink)
                badge(
                    value: String(
                        format: "%.0f", profile.bestWPM[app.settings.trainerLanguage.rawValue] ?? 0),
                    label: loc("рекорд, сл/мин", "best WPM"), symbol: "trophy.fill", color: Theme.ink)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(
                        title: loc("Что тренируем", "What to practise"), symbol: "slider.horizontal.3")
                    Spacer()
                    CapsulePicker(
                        selection: $app.settings.trainerLanguage,
                        options: [(Language.russian, "Русский"), (Language.english, "English")])
                }
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(TrainerSource.allCases) { source in
                        let selected = app.settings.trainerSource == source
                        Button {
                            withAnimation(.snappy) { app.settings.trainerSource = source }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: title(source).2)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(selected ? Theme.onInk : Theme.ink)
                                    .frame(width: 36, height: 36)
                                    .background(
                                        selected
                                            ? AnyShapeStyle(Theme.ink)
                                            : AnyShapeStyle(Theme.surfaceStrong),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(title(source).0).font(.headline)
                                    Text(title(source).1).font(.caption).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                            }
                            .padding(10)
                            .background(
                                .primary.opacity(selected ? 0.07 : 0.03),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(
                                    selected ? Theme.ink.opacity(0.5) : .clear, lineWidth: 1.5)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 14) {
                    if app.settings.trainerSource == .words {
                        Text(loc("Время", "Time")).foregroundStyle(Theme.muted)
                        CapsulePicker(
                            selection: $app.settings.trainerDuration,
                            options: [15, 30, 60, 120].map { ($0, loc("\($0) с", "\($0) s")) } + [
                                (0, loc("Без времени", "No limit"))
                            ])
                    } else if app.settings.trainerSource == .texts {
                        Text(loc("Сложность", "Difficulty")).foregroundStyle(Theme.muted)
                        CapsulePicker(
                            selection: $app.settings.trainerDifficulty,
                            options: [
                                (1, loc("Лёгкая", "Easy")), (2, loc("Средняя", "Medium")),
                                (3, loc("Сложная", "Hard")),
                            ])
                    }
                    Spacer()
                    Button {
                        trainer.start()
                    } label: {
                        Label(loc("Начать", "Start"), systemImage: "play.fill").font(.headline).padding(
                            .horizontal, 18
                        ).padding(.vertical, 4)
                    }
                    .controlSize(.large)
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!app.isLoaded)
                }
            }
            .card()

            if profile.history.count >= 2 {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(
                        title: loc("Скорость по занятиям", "Speed by session"), symbol: "chart.xyaxis.line")
                    let history = Array(profile.history.suffix(40).enumerated())
                    Chart(history, id: \.offset) { item in
                        AreaMark(x: .value("n", item.offset), y: .value("wpm", item.element.wpm))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Theme.ink.opacity(0.35), .clear], startPoint: .top,
                                    endPoint: .bottom)
                            )
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("n", item.offset), y: .value("wpm", item.element.wpm))
                            .foregroundStyle(Theme.ink)
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    }
                    .chartXAxis(.hidden)
                    .frame(height: 130)
                }
                .card()
            }

            let weak = profile.weakKeys(limit: 10)
            if !weak.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(
                        title: loc("Клавиши, на которых вы спотыкаетесь", "Keys you stumble on"),
                        symbol: "keyboard")
                    HStack(spacing: 6) {
                        ForEach(weak, id: \.self) { key in
                            Text(key == " " ? "␣" : key.uppercased())
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .frame(width: 34, height: 34)
                                .background(
                                    Theme.surfaceStrong,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .card()
            }
        }
    }

    private func badge(value: String, label: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(color)
            Text(value).font(.system(size: 26, weight: .heavy, design: .rounded))
            Text(label).font(.caption).foregroundStyle(Theme.muted)
        }
        .frame(width: 120, alignment: .leading)
        .card()
    }
}

// MARK: - Stage

private struct CaretKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// One word of the exercise. Equatable so that only the word under the caret redraws on a key press.
private struct WordView: View, Equatable {
    let characters: [Character]
    let start: Int
    /// Caret position relative to this word; negative before the word, beyond the end after it.
    let caret: Int
    let errors: Set<Int>
    let fontSize: CGFloat

    nonisolated static func == (left: WordView, right: WordView) -> Bool {
        left.start == right.start && left.caret == right.caret && left.errors == right.errors
            && left.fontSize == right.fontSize && left.characters == right.characters
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(characters.indices, id: \.self) { index in
                let done = index < caret
                let current = index == caret
                let failed = errors.contains(index)
                Text(String(characters[index]))
                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                    .foregroundStyle(
                        done
                            ? (failed ? Theme.ink : Color.primary)
                            : Color.primary.opacity(current ? 0.9 : 0.32)
                    )
                    .overlay(alignment: .bottom) {
                        if failed { Capsule().fill(Theme.danger).frame(height: 2).offset(y: 2) }
                    }
                    .anchorPreference(key: CaretKey.self, value: .bounds) { current ? $0 : nil }
            }
        }
    }
}

private struct TrainerStage: View {
    @Environment(AppModel.self) private var app
    let trainer: TrainerModel
    @FocusState private var focused: Bool
    @State private var showsKeyboard = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let session = trainer.session
        VStack(spacing: 18) {
            header(session)
            GeometryReader { geometry in
                ScrollViewReader { scroller in
                    ScrollView(.vertical, showsIndicators: false) {
                        FlowLayout(spacing: 0) {
                            ForEach(trainer.words.indices, id: \.self) { index in
                                let word = trainer.words[index]
                                let position = session?.position ?? 0
                                let relative = position - word.start
                                WordView(
                                    characters: word.characters, start: word.start,
                                    caret: min(max(relative, -1), word.characters.count),
                                    errors: Set(
                                        (session?.errorPositions ?? []).compactMap { error in
                                            let offset = error - word.start
                                            return offset >= 0 && offset < word.characters.count
                                                ? offset : nil
                                        }),
                                    fontSize: 27
                                )
                                .equatable()
                                .padding(.vertical, 7)
                                .id(index)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 40)
                        .frame(width: geometry.size.width, alignment: .leading)
                        .overlayPreferenceValue(CaretKey.self) { anchor in
                            GeometryReader { proxy in
                                if let anchor {
                                    let rect = proxy[anchor]
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(Theme.ink)
                                        .frame(width: 3, height: rect.height * 0.92)
                                        .shadow(color: Theme.ink.opacity(0.5), radius: 6)
                                        .position(x: rect.minX - 1, y: rect.midY)
                                        .animation(
                                            reduceMotion
                                                ? nil : .spring(response: 0.16, dampingFraction: 0.82),
                                            value: rect.minX
                                        )
                                        .animation(
                                            reduceMotion
                                                ? nil : .spring(response: 0.22, dampingFraction: 0.85),
                                            value: rect.midY
                                        )
                                        .onChange(of: rect, initial: true) { _, new in
                                            let frame = proxy.frame(in: .named("stage"))
                                            trainer.caretPoint = CGPoint(
                                                x: frame.minX + new.minX, y: frame.minY + new.midY)
                                        }
                                }
                            }
                        }
                    }
                    .scrollDisabled(true)
                    .onChange(of: currentWord(session)) { _, word in
                        withAnimation(.easeOut(duration: 0.25)) { scroller.scrollTo(word, anchor: .center) }
                    }
                }
            }
            .frame(height: 190)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                        .init(color: .black, location: 0.8), .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
            )
            .modifier(ShakeEffect(pulse: reduceMotion ? 0 : CGFloat(trainer.errorPulse)))
            .animation(.linear(duration: 0.22), value: trainer.errorPulse)

            if let notice = trainer.notice {
                Text(notice).font(.callout).foregroundStyle(Theme.muted)
            } else if session?.isStarted != true {
                Text(
                    loc(
                        "Начните печатать — таймер пойдёт с первой клавиши",
                        "Start typing — the clock starts with the first key")
                )
                .font(.callout)
                .foregroundStyle(Theme.muted)
            } else {
                Text(" ").font(.callout)
            }

            if showsKeyboard, let language = session?.language {
                KeyboardHint(layout: layout(for: language), expected: session?.expected)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    KeyCap(text: "esc")
                    Text(loc("завершить", "finish")).foregroundStyle(Theme.muted)
                }
                HStack(spacing: 5) {
                    KeyCap(text: "⇥")
                    Text(loc("заново", "restart")).foregroundStyle(Theme.muted)
                }
                Spacer()
                Toggle(loc("Клавиатура", "Keyboard"), isOn: $showsKeyboard.animation(.snappy)).toggleStyle(
                    .switch
                ).controlSize(.small)
            }
            .font(.caption)
        }
        .padding(.horizontal, 36)
        .padding(.top, 40)
        .padding(.bottom, 22)
        .frame(maxWidth: 940)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: "stage")
        .overlay(ParticleField(system: trainer.particles))
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in
            if press.key == .escape {
                trainer.quit()
                return .handled
            }
            if press.key == .tab {
                trainer.start()
                return .handled
            }
            guard !press.modifiers.contains(.command), !press.modifiers.contains(.control),
                let character = press.characters.first, press.characters.count == 1,
                !character.isNewline,
                character.unicodeScalars.allSatisfy({
                    $0.value >= 0x20 && !(0xF700...0xF8FF).contains($0.value)
                })
            else { return .ignored }
            trainer.type(character)
            return .handled
        }
        .onAppear { focused = true }
        .onTapGesture { focused = true }
    }

    private func currentWord(_ session: TrainerSession?) -> Int {
        let position = session?.position ?? 0
        return trainer.words.lastIndex { $0.start <= position } ?? 0
    }

    private func layout(for language: Language) -> KeyboardLayout {
        app.layouts.layouts.first { $0.language == language } ?? (language == .russian ? .russian : .abc)
    }

    @ViewBuilder
    private func header(_ session: TrainerSession?) -> some View {
        let combo = session?.combo ?? 0
        HStack(alignment: .center, spacing: 22) {
            metric(
                String(format: "%.0f", session?.wpm(at: trainer.now) ?? 0), loc("сл/мин", "WPM"), Theme.ink
            )
            metric(
                String(format: "%.0f%%", (session?.accuracy ?? 1) * 100), loc("точность", "accuracy"),
                Theme.ink)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(combo >= 20 ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(.secondary))
                    .symbolEffect(.bounce, value: trainer.comboPulse)
                Text("\(combo)").font(.system(size: 26, weight: .heavy, design: .rounded)).contentTransition(
                    .numericText())
                Text("×\(session?.multiplier ?? 1)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.onInk)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.ink, in: Capsule())
                    .opacity((session?.multiplier ?? 1) > 1 ? 1 : 0.35)
            }
            .animation(.snappy(duration: 0.18), value: combo)
            Spacer()
            metric("\(session?.score ?? 0)", loc("очки", "score"), Theme.ink)
            if let remaining = session?.remaining(at: trainer.now) {
                metric(String(format: "%.0f", remaining.rounded(.up)), loc("секунд", "seconds"), Theme.ink)
            }
        }
        ProgressView(value: timeProgress(session))
            .tint(Theme.ink)
            .animation(.linear(duration: 0.12), value: trainer.now)
    }

    private func timeProgress(_ session: TrainerSession?) -> Double {
        guard let session else { return 0 }
        if let limit = session.timeLimit { return min(session.elapsed(at: trainer.now) / limit, 1) }
        return session.progress
    }

    private func metric(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(color)
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(Theme.muted)
        }
        .frame(minWidth: 70, alignment: .leading)
    }
}

/// A short horizontal shake that plays every time `pulse` changes.
private struct ShakeEffect: GeometryEffect {
    var pulse: CGFloat
    var animatableData: CGFloat {
        get { pulse }
        set { pulse = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 7 * sin(pulse * .pi * 3), y: 0))
    }
}

// MARK: - Results

private struct TrainerResults: View {
    @Environment(AppModel.self) private var app
    let trainer: TrainerModel
    @State private var appeared = false

    var body: some View {
        let result = trainer.result
        let reward = trainer.reward
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        if reward?.isRecord == true {
                            Label(loc("Новый рекорд!", "New record!"), systemImage: "trophy.fill")
                                .font(.headline)
                                .foregroundStyle(Theme.ink)
                                .symbolEffect(.bounce, value: appeared)
                        } else if reward?.leveledUp == true {
                            Label(
                                loc("Новый уровень: \(app.profile.level)", "Level up: \(app.profile.level)"),
                                systemImage: "star.fill"
                            )
                            .font(.headline)
                            .foregroundStyle(Theme.ink)
                        }
                        Text(String(format: "%.0f", result?.wpm ?? 0))
                            .font(.system(size: 92, weight: .heavy, design: .rounded))
                            .foregroundStyle(Theme.ink)
                            .scaleEffect(appeared ? 1 : 0.6)
                            .opacity(appeared ? 1 : 0)
                        Text(loc("слов в минуту", "words per minute")).font(.title3).foregroundStyle(
                            .secondary)
                    }
                    .padding(.top, 30)

                    HStack(spacing: 12) {
                        tile(
                            String(format: "%.1f%%", (result?.accuracy ?? 0) * 100),
                            loc("точность", "accuracy"), "target", Theme.ink)
                        tile("\(result?.score ?? 0)", loc("очки", "score"), "sparkles", Theme.ink)
                        tile(
                            "\(result?.maxCombo ?? 0)", loc("лучшая серия", "best streak"), "flame.fill",
                            Theme.danger)
                        tile("+\(reward?.experience ?? 0)", loc("опыт", "XP"), "star.fill", Theme.ink)
                    }

                    if let timeline = result?.timeline, timeline.count >= 3 {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(
                                title: loc("Скорость по секундам", "Speed over time"),
                                symbol: "waveform.path.ecg")
                            Chart(Array(timeline.enumerated()), id: \.offset) { item in
                                AreaMark(x: .value("s", item.offset + 1), y: .value("wpm", item.element))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [Theme.ink.opacity(0.35), .clear], startPoint: .top,
                                            endPoint: .bottom)
                                    )
                                    .interpolationMethod(.monotone)
                                LineMark(x: .value("s", item.offset + 1), y: .value("wpm", item.element))
                                    .foregroundStyle(Theme.ink)
                                    .interpolationMethod(.monotone)
                                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            }
                            .frame(height: 130)
                        }
                        .card()
                    }

                    if let missed = result?.missedKeys, !missed.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(
                                title: loc("Где были ошибки", "Where the mistakes were"),
                                symbol: "exclamationmark.circle")
                            HStack(spacing: 6) {
                                ForEach(
                                    missed.sorted {
                                        $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
                                    }.prefix(12), id: \.key
                                ) { key, count in
                                    VStack(spacing: 1) {
                                        Text(key == " " ? "␣" : key).font(
                                            .system(size: 16, weight: .bold, design: .rounded))
                                        Text("×\(count)").font(.caption2).foregroundStyle(Theme.muted)
                                    }
                                    .frame(width: 40, height: 44)
                                    .background(
                                        Theme.surfaceStrong,
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                }
                                Spacer()
                            }
                        }
                        .card()
                    }

                    HStack(spacing: 12) {
                        Button {
                            trainer.stop()
                        } label: {
                            Label(loc("К выбору", "Back"), systemImage: "chevron.left").padding(
                                .horizontal, 8)
                        }
                        .controlSize(.large)
                        Button {
                            trainer.start()
                        } label: {
                            Label(loc("Ещё раз", "Again"), systemImage: "arrow.clockwise").font(.headline)
                                .padding(.horizontal, 14)
                        }
                        .controlSize(.large)
                        .buttonStyle(.primary)
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(.bottom, 26)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .overlay(ParticleField(system: trainer.particles))
            .onAppear {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.62)) { appeared = true }
                trainer.celebrate(width: geometry.size.width)
            }
        }
    }

    private func tile(_ value: String, _ label: String, _ symbol: String, _ color: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .card(padding: 14)
    }
}
