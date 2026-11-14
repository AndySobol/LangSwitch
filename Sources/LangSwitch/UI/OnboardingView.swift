import SwiftUI

/// First launch: what the application does and the one permission it needs.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 20)
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.brand).frame(
                    width: 96, height: 96
                )
                .shadow(color: Theme.violet.opacity(0.45), radius: 24, y: 10)
                Image(systemName: "keyboard.fill").font(.system(size: 40, weight: .semibold)).foregroundStyle(
                    .white)
            }
            VStack(spacing: 8) {
                Text(loc("Пишите, не думая о раскладке", "Type without thinking about the layout"))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text(
                    loc(
                        "LangSwitch на лету исправляет раскладку, опечатки и пунктуацию в любом приложении. Всё работает на этом Mac, без сети.",
                        "LangSwitch fixes the layout, typos and punctuation as you type, in every application. Everything runs on this Mac, offline."
                    )
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            }

            VStack(alignment: .leading, spacing: 14) {
                step(
                    1, done: model.isTrusted,
                    title: loc("Разрешите «Универсальный доступ»", "Allow Accessibility access"),
                    detail: loc(
                        "Нужен, чтобы видеть нажатия клавиш и заменять ошибочный текст. macOS не даёт сторонним программам доступ к полям с паролями.",
                        "Needed to see key presses and replace mistyped text. macOS never exposes password fields to other applications."
                    )
                ) {
                    if model.isTrusted {
                        Label(loc("Готово", "Done"), systemImage: "checkmark.circle.fill").foregroundStyle(
                            Theme.mint)
                    } else {
                        Button(loc("Открыть настройки", "Open Settings")) { model.requestAccessibility() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.violet)
                    }
                }
                Divider()
                step(
                    2, done: model.hasBothLayouts,
                    title: loc("Две раскладки: русская и латинская", "Two layouts: Russian and Latin"),
                    detail: model.hasBothLayouts
                        ? model.layouts.layouts.map(\.name).joined(separator: " · ")
                        : loc(
                            "Добавьте русскую и английскую раскладки в Системных настройках → Клавиатура → Источники ввода.",
                            "Add a Russian and an English layout in System Settings → Keyboard → Input Sources."
                        )
                ) {
                    if model.hasBothLayouts {
                        Label(loc("Готово", "Done"), systemImage: "checkmark.circle.fill").foregroundStyle(
                            Theme.mint)
                    }
                }
            }
            .card()
            .frame(maxWidth: 620)

            Button {
                model.settings.onboardingCompleted = true
            } label: {
                Text(loc("Начать", "Get started")).frame(width: 180)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(Theme.indigo)
            .disabled(!model.isTrusted)

            if !model.isTrusted {
                Text(
                    loc(
                        "После включения переключателя в Системных настройках это окно обновится само.",
                        "This window updates by itself once the switch is turned on in System Settings.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 20)
        }
        .padding(30)
        .onAppear { model.pollTrust() }
    }

    private func step<Trailing: View>(
        _ number: Int, done: Bool, title: String, detail: String, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text("\(number)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(done ? AnyShapeStyle(Theme.mint) : AnyShapeStyle(Theme.calm), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            trailing()
        }
    }
}
