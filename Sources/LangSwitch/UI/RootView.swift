import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    private func title(_ item: SidebarItem) -> String {
        switch item {
        case .overview: loc("Обзор", "Overview")
        case .trainer: loc("Тренажёр", "Trainer")
        case .dictionary: loc("Словарь", "Dictionary")
        case .applications: loc("Приложения", "Applications")
        case .settings: loc("Настройки", "Settings")
        }
    }

    private func symbol(_ item: SidebarItem) -> String {
        switch item {
        case .overview: "square.grid.2x2.fill"
        case .trainer: "gamecontroller.fill"
        case .dictionary: "text.book.closed.fill"
        case .applications: "app.badge.fill"
        case .settings: "gearshape.fill"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SidebarItem.allCases) { item in
                    let selected = model.selection == item
                    Button {
                        model.selection = item
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: symbol(item))
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 18)
                            Text(title(item)).font(.system(size: 13, weight: selected ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(selected ? Theme.ink : Theme.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            selected ? Theme.surfaceStrong : .clear,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                SidebarStatus().padding(.horizontal, 6)
            }
            .padding(.horizontal, 10)
            .padding(.top, 52)
            .padding(.bottom, 14)
            .frame(width: 200)
            .background(Color.black.opacity(0.22))
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }

            Group {
                if !model.previewMode && (!model.isTrusted || !model.settings.onboardingCompleted) {
                    OnboardingView()
                } else {
                    switch model.selection {
                    case .overview: OverviewView()
                    case .trainer: TrainerView()
                    case .dictionary: DictionaryView()
                    case .applications: ApplicationsView()
                    case .settings: SettingsView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(BackdropView())
        .ignoresSafeArea()
        .buttonStyle(.secondary)
        .tint(Theme.ink)
        .foregroundStyle(Theme.ink)
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
        // Re-render every string when the interface language changes.
        .id(model.settings.interfaceLanguage)
    }
}

/// Black glass: the desktop blurred behind the window, darkened, with a faint light from above.
struct BackdropView: View {
    var body: some View {
        ZStack {
            GlassBackdrop()
            Color.black.opacity(0.58)
            RadialGradient(
                colors: [Color.white.opacity(0.07), .clear], center: UnitPoint(x: 0.62, y: -0.1),
                startRadius: 0,
                endRadius: 620)
        }
        .ignoresSafeArea()
    }
}

struct SidebarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let running = model.isRunning && model.settings.enabled
        HStack(spacing: 8) {
            Circle()
                .fill(running ? Theme.ink : .clear)
                .overlay(Circle().strokeBorder(running ? .clear : Theme.muted, lineWidth: 1.2))
                .frame(width: 7, height: 7)
            Text(
                !model.isTrusted
                    ? loc("Нет доступа", "No access")
                    : model.settings.enabled ? loc("Работает", "Running") : loc("Пауза", "Paused")
            )
            .font(.caption)
            .foregroundStyle(Theme.muted)
            Spacer()
            LanguageBadge(language: model.currentLayout?.language)
        }
    }
}

/// A page with a large title and scrolling content, shared by every section.
struct Page<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
                    if let subtitle { Text(subtitle).foregroundStyle(Theme.muted) }
                }
                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 44)
            .padding(.bottom, 28)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

struct SectionHeader: View {
    let title: String
    var symbol: String?
    var body: some View {
        HStack(spacing: 7) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(
                    Theme.muted)
            }
            Text(title).font(.headline)
        }
    }
}

/// A settings row: title and explanation on the left, a control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(Theme.muted).fixedSize(
                        horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 5)
    }
}
