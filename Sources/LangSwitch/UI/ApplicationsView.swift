import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ApplicationsView: View {
    @Environment(AppModel.self) private var model

    private func icon(_ bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }

    private func add(bundleID: String, name: String) {
        guard !model.settings.applicationRules.contains(where: { $0.bundleID == bundleID }) else { return }
        model.settings.applicationRules.append(
            ApplicationRule(bundleID: bundleID, name: name, mode: .layoutOnly))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(
                of: ".app", with: "")
            add(bundleID: id, name: name)
        }
    }

    var body: some View {
        @Bindable var model = model
        Page(
            title: loc("Приложения", "Applications"),
            subtitle: loc(
                "LangSwitch работает во всех приложениях. Здесь — исключения.",
                "LangSwitch works in every application. These are the exceptions.")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeader(title: loc("Особые правила", "Special rules"), symbol: "app.badge.fill")
                    Spacer()
                    Menu {
                        ForEach(
                            NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular },
                            id: \.processIdentifier
                        ) { app in
                            if let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
                                Button(app.localizedName ?? id) {
                                    add(bundleID: id, name: app.localizedName ?? id)
                                }
                            }
                        }
                        Divider()
                        Button(loc("Выбрать приложение…", "Choose an application…"), action: choose)
                    } label: {
                        Label(loc("Добавить", "Add"), systemImage: "plus")
                    }
                    .fixedSize()
                }
                Text(
                    loc(
                        "«Только раскладка» подходит терминалам и редакторам кода: команды и идентификаторы не исправляются и не дополняются.",
                        "“Layout only” suits terminals and code editors: commands and identifiers are neither corrected nor completed."
                    )
                )
                .font(.callout)
                .foregroundStyle(Theme.muted)

                ForEach($model.settings.applicationRules) { $rule in
                    HStack(spacing: 10) {
                        Image(nsImage: icon(rule.bundleID)).resizable().frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(rule.name)
                            Text(rule.bundleID).font(.caption2).foregroundStyle(Theme.faint)
                        }
                        Spacer()
                        CapsulePicker(
                            selection: $rule.mode,
                            options: [
                                (ApplicationRule.Mode.layoutOnly, loc("Только раскладка", "Layout only")),
                                (ApplicationRule.Mode.off, loc("Выключено", "Off")),
                            ])
                        Button {
                            model.settings.applicationRules.removeAll { $0.bundleID == rule.bundleID }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.muted)
                    }
                    .padding(.vertical, 3)
                }
            }
            .card()

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield.fill").foregroundStyle(Theme.ink)
                Text(
                    loc(
                        "Поля с паролями защищает сама macOS: пока активен защищённый ввод, нажатия клавиш не видит ни одна программа, включая LangSwitch.",
                        "Password fields are protected by macOS itself: while secure input is active no application, LangSwitch included, sees key presses."
                    )
                )
                .font(.callout)
                .foregroundStyle(Theme.muted)
            }
            .card()
        }
    }
}
