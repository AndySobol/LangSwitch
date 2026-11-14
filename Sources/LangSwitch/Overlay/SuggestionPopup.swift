import AppKit
import LangSwitchCore
import Observation
import SwiftUI

@MainActor
@Observable
final class SuggestionPopupState {
    var word = ""
    var suggestions: [WordSuggestion] = []
    var selected = 0
}

struct SuggestionPopupView: View {
    let state: SuggestionPopupState
    let choose: (WordSuggestion) -> Void

    private func title(_ kind: WordSuggestion.Kind) -> String {
        switch kind {
        case .spelling: loc("Написание", "Spelling")
        case .layout: loc("Раскладка", "Layout")
        case .form: loc("Форма слова", "Word form")
        case .synonym: loc("Синоним", "Synonym")
        case .capitalization: loc("Регистр", "Case")
        }
    }

    private func color(_ kind: WordSuggestion.Kind) -> Color {
        switch kind {
        case .spelling: Theme.mint
        case .layout: Theme.indigo
        case .form: Theme.amber
        case .synonym: Theme.violet
        case .capitalization: Theme.pink
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Theme.violet)
                Text(state.word).fontWeight(.semibold).lineLimit(1)
                Spacer()
                KeyCap(text: "esc")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ForEach(Array(state.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    choose(suggestion)
                } label: {
                    HStack(spacing: 8) {
                        Text(index < 9 ? "\(index + 1)" : "·")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        Text(suggestion.text).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 12)
                        Text(title(suggestion.kind))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(color(suggestion.kind))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        index == state.selected
                            ? AnyShapeStyle(Theme.indigo.opacity(0.22)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { state.selected = index } }
            }
        }
        .padding(5)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1)))
    }
}

/// The list of replacements for a selected word. It never takes keyboard focus: arrow keys, digits,
/// Return and Escape are routed to it by the event tap while it is visible, so the selection in the
/// other application stays intact.
@MainActor
final class SuggestionPopup {
    private let state = SuggestionPopupState()
    private var panel: NSPanel?
    private var onChoose: ((WordSuggestion) -> Void)?
    private var onVisibilityChange: ((Bool) -> Void)?
    private var timeout: Task<Void, Never>?

    var isVisible: Bool { panel?.isVisible ?? false }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = SuggestionPopupView(state: state) { [weak self] in self?.choose($0) }
        panel.contentView = NSHostingView(rootView: view)
        return panel
    }

    func show(
        word: String, suggestions: [WordSuggestion], near point: CGPoint,
        onChoose: @escaping (WordSuggestion) -> Void, onVisibilityChange: @escaping (Bool) -> Void
    ) {
        let panel = panel ?? makePanel()
        self.panel = panel
        self.onChoose = onChoose
        self.onVisibilityChange = onVisibilityChange
        state.word = word
        state.suggestions = Array(suggestions.prefix(10))
        state.selected = 0
        let size = panel.contentView?.fittingSize ?? CGSize(width: 280, height: 200)
        var origin = CGPoint(x: point.x - 24, y: point.y - size.height - 18)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y < visible.minY { origin.y = point.y + 18 }
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        onVisibilityChange(true)
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        guard isVisible else { return }
        timeout?.cancel()
        panel?.orderOut(nil)
        onVisibilityChange?(false)
    }

    func dismissIfMouseOutside() {
        guard let panel, panel.isVisible, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        dismiss()
    }

    private func choose(_ suggestion: WordSuggestion) {
        let handler = onChoose
        dismiss()
        handler?(suggestion)
    }

    func handle(_ key: PopupKey) {
        guard isVisible, !state.suggestions.isEmpty else { return }
        switch key {
        case .up: state.selected = (state.selected - 1 + state.suggestions.count) % state.suggestions.count
        case .down: state.selected = (state.selected + 1) % state.suggestions.count
        case .confirm: choose(state.suggestions[state.selected])
        case .dismiss: dismiss()
        case .number(let number):
            if number >= 1, number <= state.suggestions.count { choose(state.suggestions[number - 1]) }
        }
    }
}
