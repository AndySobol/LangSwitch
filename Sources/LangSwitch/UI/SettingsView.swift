import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsReset = false

    private func title(_ action: HotkeyAction) -> (String, String) {
        switch action {
        case .convertLayout:
            (
                loc("Сменить раскладку слова или выделения", "Convert the word or selection"),
                loc(
                    "Перепечатывает последнее слово в другой раскладке, даже если словарь его не знает.",
                    "Re-types the last word on the other layout, even when no dictionary knows it.")
            )
        case .fixSelection:
            (
                loc("Исправить выделенный текст", "Fix the selected text"),
                loc(
                    "Раскладка, орфография и пунктуация во всём выделении, включая запятые.",
                    "Layout, spelling and punctuation across the selection, commas included.")
            )
        case .suggest:
            (
                loc("Варианты для выделенного слова", "Alternatives for the selected word"),
                loc(
                    "Написание, формы слова и синонимы с учётом части речи.",
                    "Spelling, word forms and synonyms that respect the part of speech.")
            )
        case .togglePause:
            (
                loc("Пауза / продолжить", "Pause / resume"),
                loc(
                    "Мгновенно останавливает все автоисправления.",
                    "Stops every automatic correction at once.")
            )
        }
    }

    /// Version, check, download and install.
    @ViewBuilder private var updates: some View {
        @Bindable var model = model
        let updater = model.updater
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: loc("Обновления", "Updates"), symbol: "arrow.down.circle")
            SettingRow(
                title: loc("Версия \(updater.current)", "Version \(updater.current)"), detail: updateStatus
            ) {
                if updater.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Button(loc("Проверить сейчас", "Check now")) {
                        Task { await updater.check(userInitiated: true) }
                    }
                }
            }
            if let release = updater.release {
                SettingRow(
                    title: loc(
                        "Доступна версия \(release.version)", "Version \(release.version) is available"),
                    detail: loc(
                        "Программа скачает образ, сверит контрольную сумму и подпись, заменит себя и запустится заново. Сборка не подписана сертификатом разработчика, поэтому macOS может заново попросить разрешение «Универсальный доступ».",
                        "The application downloads the image, checks its checksum and signature, replaces itself and starts again. The build has no developer certificate, so macOS may ask for Accessibility access again."
                    )
                ) {
                    HStack(spacing: 8) {
                        Button(loc("Что нового", "What’s new")) {
                            if UpdateSource.isReleasePage(release.page) {
                                NSWorkspace.shared.open(release.page)
                            }
                        }
                        if case .manual(_, let image) = updater.state {
                            Button(loc("Открыть образ", "Open the image")) { NSWorkspace.shared.open(image) }
                                .buttonStyle(.primary)
                        } else {
                            Button(loc("Скачать и установить", "Download and install")) {
                                Task { await updater.install() }
                            }
                            .buttonStyle(.primary)
                            .disabled(updater.isBusy)
                        }
                    }
                }
            }
            SettingRow(
                title: loc("Проверять автоматически", "Check automatically"),
                detail: loc(
                    "Раз в сутки программа спрашивает у GitHub номер последней версии LangSwitch. В запросе нет ничего о вас и вашем наборе.",
                    "Once a day the application asks GitHub for the latest LangSwitch version. The request says nothing about you or your typing."
                )
            ) { Toggle("", isOn: $model.settings.checksForUpdates).labelsHidden() }
        }
        .toggleStyle(.mono)
        .card()
    }

    private var updateStatus: String {
        let updater = model.updater
        switch updater.state {
        case .idle:
            guard let last = updater.lastCheck else { return loc("Ещё не проверялось.", "Not checked yet.") }
            return loc("Последняя проверка: ", "Last checked: ")
                + last.formatted(date: .abbreviated, time: .shortened)
        case .checking: return loc("Проверяю…", "Checking…")
        case .upToDate: return loc("У вас последняя версия.", "You have the latest version.")
        case .available: return loc("Есть обновление.", "An update is available.")
        case .downloading: return loc("Скачиваю…", "Downloading…")
        case .installing:
            return loc("Устанавливаю, программа перезапустится…", "Installing; the application will restart…")
        case .manual:
            return loc(
                "Образ скачан и проверен, но заменить программу на месте не удалось. Перетащите LangSwitch из открывшегося образа в «Программы».",
                "The image is downloaded and verified, but the application could not be replaced in place. Drag LangSwitch from the opened image to Applications."
            )
        case .failed(let message): return message
        }
    }

    var body: some View {
        @Bindable var model = model
        Page(title: loc("Настройки", "Settings")) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(
                    title: loc("Исправления при наборе", "Corrections while typing"), symbol: "wand.and.stars"
                )
                SettingRow(
                    title: loc("Автоисправление", "Auto-correction"),
                    detail: loc(
                        "Главный выключатель. На паузе работают только горячие клавиши.",
                        "The master switch. While paused only the shortcuts work.")
                ) { Toggle("", isOn: $model.settings.enabled).labelsHidden() }
                Divider()
                Group {
                    SettingRow(
                        title: loc("Раскладка", "Layout"),
                        detail: loc(
                            "«ghbdtn» → «привет», «руддщ» → «hello». Названия и команды вроде Figma, git, gmail не трогаются.",
                            "“ghbdtn” → “привет”, “руддщ” → “hello”. Names and commands such as Figma, git, gmail are left alone."
                        )
                    ) { Toggle("", isOn: $model.settings.fixesLayout).labelsHidden() }
                    SettingRow(
                        title: loc("Не дожидаться пробела", "Do not wait for the space"),
                        detail: loc(
                            "Слово конвертируется уже после четырёх букв, если в текущей раскладке оно ни во что не складывается.",
                            "A word is converted after four letters when it cannot be anything on the current layout."
                        )
                    ) { Toggle("", isOn: $model.settings.convertsEarly).labelsHidden() }
                    .disabled(!model.settings.fixesLayout)
                    SettingRow(
                        title: loc("Орфография", "Spelling"),
                        detail: loc(
                            "Промахи рук и ошибки по правилам языка: «првиет», «любиш», «вобщем». Учитывает предыдущее слово.",
                            "Slips of the hand and spelling mistakes: “teh”, “definately”, “dont”. The previous word counts."
                        )
                    ) { Toggle("", isOn: $model.settings.fixesSpelling).labelsHidden() }
                    SettingRow(
                        title: loc("Пунктуация", "Punctuation"),
                        detail: loc(
                            "Запятые перед «что», «чтобы», «который», «а», «но»; пробел после запятой.",
                            "Commas before Russian conjunctions; a space after a comma.")
                    ) { Toggle("", isOn: $model.settings.fixesPunctuation).labelsHidden() }
                    SettingRow(
                        title: loc("Заглавные буквы", "Capital letters"),
                        detail: loc(
                            "Начало предложения, имена собственные, «ПРивет» → «Привет», figma → Figma.",
                            "Sentence starts, proper names, “HEllo” → “Hello”, figma → Figma.")
                    ) { Toggle("", isOn: $model.settings.fixesCapitalization).labelsHidden() }
                    SettingRow(
                        title: loc("Backspace отменяет исправление", "Backspace undoes a correction"),
                        detail: loc(
                            "Выключено по умолчанию: удаление пробела после слова чаще правка, чем отказ. Отменить исправление всегда можно двойным Shift.",
                            "Off by default: deleting the space after a word is usually an edit. Double Shift always undoes a correction."
                        )
                    ) { Toggle("", isOn: $model.settings.backspaceUndoes).labelsHidden() }
                    SettingRow(
                        title: loc(
                            "Двойной Shift: отменить или сменить раскладку", "Double Shift: undo or convert"),
                        detail: loc(
                            "Сразу после исправления возвращает набранное. В остальных случаях перепечатывает слово в другой раскладке. Дважды отменённая конвертация больше не повторяется.",
                            "Right after a correction it restores what you typed; otherwise it re-types the word on the other layout. A conversion undone twice is not repeated."
                        )
                    ) { Toggle("", isOn: $model.settings.doubleShiftConverts).labelsHidden() }
                }
                .disabled(!model.settings.enabled)
            }
            .toggleStyle(.mono)
            .card()

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(
                    title: loc("Автодополнение и варианты", "Autocomplete and alternatives"),
                    symbol: "sparkles"
                )
                SettingRow(
                    title: loc("Подсказка окончания слова", "Suggest the rest of the word"),
                    detail: loc(
                        "Серый текст после каретки. Где приложение не сообщает положение каретки, подсказка появляется в «чёлке».",
                        "Grey text after the caret. Where an application does not report the caret, the hint appears in the notch."
                    )
                ) { Toggle("", isOn: $model.settings.completion).labelsHidden() }
                SettingRow(title: loc("Принимать клавишей", "Accept with")) {
                    CapsulePicker(
                        selection: $model.settings.completionAcceptKey,
                        options: [
                            (CompletionAcceptKey.tab, "Tab ⇥"),
                            (CompletionAcceptKey.rightArrow, loc("Стрелка →", "Arrow →")),
                        ])
                }
                .disabled(!model.settings.completion)
                SettingRow(
                    title: loc("Подсказывать после", "Suggest after"),
                    detail: loc("Сколько букв нужно набрать.", "How many letters must be typed.")
                ) {
                    Stepper(value: $model.settings.completionMinimumPrefix, in: 2...5) {
                        Text("\(model.settings.completionMinimumPrefix)").monospacedDigit()
                    }
                }
                .disabled(!model.settings.completion)
                Divider()
                SettingRow(
                    title: loc("Варианты по двойному клику", "Alternatives on double-click"),
                    detail: loc(
                        "Выделите слово двойным кликом в любом поле ввода — появится список замен.",
                        "Double-click a word in any text field to see replacements.")
                ) { Toggle("", isOn: $model.settings.suggestsOnDoubleClick).labelsHidden() }
            }
            .toggleStyle(.mono)
            .card()

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: loc("Горячие клавиши", "Keyboard shortcuts"), symbol: "command")
                ForEach(HotkeyAction.allCases) { action in
                    SettingRow(title: title(action).0, detail: title(action).1) {
                        HotkeyRecorder(action: action)
                    }
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(
                    title: loc("Обучение и приватность", "Learning and privacy"), symbol: "lock.shield.fill")
                SettingRow(
                    title: loc("Запоминать мои слова", "Learn my words"),
                    detail: loc(
                        "Слова, которые вы пишете часто, попадают в личный словарь и в автодополнение. Хранится только на этом Mac.",
                        "Words you use often join your dictionary and completions. Stored on this Mac only.")
                ) { Toggle("", isOn: $model.settings.learnsWords).labelsHidden() }
                SettingRow(
                    title: loc("Собирать мои фразы для тренажёра", "Collect my phrases for the trainer"),
                    detail: loc(
                        "Выключено по умолчанию. Сохраняются только обычные предложения: без чисел, адресов, ссылок и полей с паролями.",
                        "Off by default. Only ordinary sentences are kept: no numbers, addresses, links or password fields."
                    )
                ) { Toggle("", isOn: $model.settings.collectsPhrases).labelsHidden() }
                SettingRow(title: loc("Хранить фразы", "Keep phrases for")) {
                    CapsulePicker(
                        selection: $model.settings.phraseRetentionDays,
                        options: [
                            (1, loc("1 день", "1 day")), (7, loc("7 дней", "7 days")),
                            (30, loc("30 дней", "30 days")),
                        ])
                }
                .disabled(!model.settings.collectsPhrases)
                HStack {
                    Button(loc("Удалить собранные фразы", "Delete collected phrases")) {
                        model.deletePhrases()
                    }
                    .disabled(model.phrases.phrases.isEmpty)
                    Button(loc("Сбросить всё выученное…", "Reset everything learned…"), role: .destructive) {
                        confirmsReset = true
                    }
                    Spacer()
                    Text(
                        loc(
                            "\(model.phrases.phrases.count) фраз · \(model.learning.wordCounts.count) слов",
                            "\(model.phrases.phrases.count) phrases · \(model.learning.wordCounts.count) words"
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                }
                .padding(.top, 4)
            }
            .toggleStyle(.mono)
            .card()
            .confirmationDialog(
                loc(
                    "Сбросить личный словарь, статистику и собранные фразы?",
                    "Reset your dictionary, statistics and collected phrases?"),
                isPresented: $confirmsReset
            ) {
                Button(loc("Сбросить", "Reset"), role: .destructive) {
                    model.resetLearning()
                    model.resetStatistics()
                    model.deletePhrases()
                }
            } message: {
                Text(loc("Это действие нельзя отменить.", "This cannot be undone."))
            }

            updates

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: loc("Система", "System"), symbol: "macwindow")
                SettingRow(title: loc("Запускать при входе", "Launch at login")) {
                    Toggle(
                        "", isOn: Binding(get: { model.launchesAtLogin }, set: { model.setLaunchAtLogin($0) })
                    ).labelsHidden()
                }
                SettingRow(
                    title: loc("Показывать исправления в «чёлке»", "Show corrections in the notch"),
                    detail: loc(
                        "Короткая подсказка «было → стало» у выреза экрана; на мониторах без выреза — под строкой меню.",
                        "A brief “before → after” hint at the notch; under the menu bar on displays without one."
                    )
                ) { Toggle("", isOn: $model.settings.showsHUD).labelsHidden() }
                SettingRow(title: loc("Язык интерфейса", "Interface language")) {
                    CapsulePicker(
                        selection: $model.settings.interfaceLanguage,
                        options: [
                            (InterfaceLanguage.system, loc("Как в системе", "System")),
                            (InterfaceLanguage.russian, "Русский"), (InterfaceLanguage.english, "English"),
                        ])
                }
                SettingRow(
                    title: loc("Универсальный доступ", "Accessibility access"),
                    detail: model.isTrusted
                        ? loc("Разрешён.", "Granted.")
                        : loc(
                            "Не разрешён: автоисправление не работает.",
                            "Not granted: auto-correction is off.")
                ) {
                    Button(loc("Открыть настройки", "Open Settings")) { model.openAccessibilitySettings() }
                }
            }
            .toggleStyle(.mono)
            .card()

            let version =
                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            Text(
                "LangSwitch \(version) · "
                    + loc(
                        "ваш набор не покидает этот Mac; в сеть программа ходит только за обновлениями",
                        "your typing never leaves this Mac; the network is used for updates only")
            )
            .font(.caption)
            .foregroundStyle(Theme.muted)
        }
    }
}
