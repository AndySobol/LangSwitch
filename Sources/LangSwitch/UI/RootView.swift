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
        @Bindable var model = model
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $model.selection) { item in
                Label(title(item), systemImage: symbol(item)).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
            .safeAreaInset(edge: .bottom) { SidebarStatus().padding(12) }
        } detail: {
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
            .background(BackdropView())
        }
        // Re-render every string when the interface language changes.
        .id(model.settings.interfaceLanguage)
    }
}

/// A soft colour wash behind the content. Static: no animation runs while the window just sits there.
struct BackdropView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.55, 0.45], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [
                    Theme.indigo.opacity(0.30), Theme.violet.opacity(0.16), .clear,
                    Theme.violet.opacity(0.10), .clear, Theme.pink.opacity(0.10),
                    .clear, Theme.mint.opacity(0.08), Theme.indigo.opacity(0.14),
                ]
            )
            .opacity(scheme == .dark ? 0.9 : 0.6)
        }
        .ignoresSafeArea()
    }
}

struct SidebarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isRunning && model.settings.enabled ? Theme.mint : Theme.amber)
                .frame(width: 8, height: 8)
            Text(
                !model.isTrusted
                    ? loc("Нет доступа", "No access")
                    : model.settings.enabled ? loc("Работает", "Running") : loc("Пауза", "Paused")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
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
                    if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
                }
                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 34)
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
            if let symbol { Image(systemName: symbol).foregroundStyle(Theme.violet) }
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
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 5)
    }
}
