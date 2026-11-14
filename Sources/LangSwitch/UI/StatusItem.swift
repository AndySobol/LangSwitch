import AppKit
import LangSwitchCore
import Observation
import SwiftUI

/// The menu-bar item: a badge with the current layout and a popover with quick controls.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuPanel(close: { [weak self] in self?.popover.performClose(nil) }).environment(model))
        item.button?.target = self
        item.button?.action = #selector(toggle)
        observe()
    }

    /// Redraws the badge whenever the layout or the paused state changes.
    private func observe() {
        withObservationTracking {
            item.button?.image = Self.badge(
                language: model.currentLayout?.language, active: model.settings.enabled && model.isRunning)
            item.button?.toolTip = "LangSwitch"
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private static func badge(language: Language?, active: Bool) -> NSImage {
        let size = NSSize(width: 26, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let box = rect.insetBy(dx: 0.75, dy: 0.75)
            let path = NSBezierPath(roundedRect: box, xRadius: 4.5, yRadius: 4.5)
            NSColor.black.setStroke()
            NSColor.black.setFill()
            path.lineWidth = 1.5
            let text = (language?.badge ?? "··") as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
                .foregroundColor: NSColor.black.withAlphaComponent(active ? 1 : 0.55),
            ]
            if active {
                path.stroke()
            } else {
                path.setLineDash([2, 2], count: 2, phase: 0)
                NSColor.black.withAlphaComponent(0.55).setStroke()
                path.stroke()
            }
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
                withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refreshTrust()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

/// The popover content.
struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .glyphTile(size: 34, radius: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text("LangSwitch").font(.headline)
                    Text(status).font(.caption).foregroundStyle(Theme.muted)
                }
                Spacer()
                Toggle("", isOn: $model.settings.enabled).toggleStyle(.mono).labelsHidden()
            }

            if !model.isTrusted {
                Button {
                    model.openMainWindow?()
                    close()
                } label: {
                    Label(
                        loc("Нужен доступ «Универсальный доступ»", "Accessibility access is required"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.primary)
            }

            HStack(spacing: 8) {
                tile(loc("Слов", "Words"), model.statistics.today.words, Theme.ink)
                tile(loc("Раскладка", "Layout"), model.statistics.today.layoutFixes, Theme.ink)
                tile(loc("Опечатки", "Typos"), model.statistics.today.spellingFixes, Theme.ink)
            }

            VStack(spacing: 6) {
                Toggle(loc("Раскладка", "Layout"), isOn: $model.settings.fixesLayout)
                Toggle(loc("Орфография", "Spelling"), isOn: $model.settings.fixesSpelling)
                Toggle(loc("Пунктуация", "Punctuation"), isOn: $model.settings.fixesPunctuation)
                Toggle(loc("Автодополнение", "Autocomplete"), isOn: $model.settings.completion)
            }
            .toggleStyle(.monoRow)
            .controlSize(.small)
            .disabled(!model.settings.enabled)

            if let last = model.recent.first {
                HStack(spacing: 6) {
                    Image(systemName: Theme.symbol(for: last.kinds)).foregroundStyle(
                        Theme.ink)
                    Text(last.original).strikethrough().foregroundStyle(Theme.muted)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(Theme.faint)
                    Text(last.corrected)
                }
                .font(.caption)
                .lineLimit(1)
            }

            Divider()
            HStack(spacing: 6) {
                Button {
                    model.selection = .trainer
                    model.openMainWindow?()
                    close()
                } label: {
                    Label(loc("Тренажёр", "Trainer"), systemImage: "gamecontroller.fill")
                }
                Button {
                    model.selection = .overview
                    model.openMainWindow?()
                    close()
                } label: {
                    Label(loc("Открыть", "Open"), systemImage: "macwindow")
                }
                Spacer()
                Button(loc("Выйти", "Quit")) { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 320)
        // The popover takes keyboard focus when it opens; a focus ring on the first button is noise.
        .focusEffectDisabled()
        .buttonStyle(.secondary)
        .foregroundStyle(Theme.ink)
        .background(Color.black.opacity(0.35))
        .preferredColorScheme(.dark)
    }

    private var status: String {
        if !model.isTrusted { return loc("Ожидает разрешения", "Waiting for permission") }
        if !model.settings.enabled { return loc("На паузе", "Paused") }
        let layout = model.currentLayout?.name ?? "—"
        return loc("Активен · \(layout)", "Active · \(layout)")
    }

    private func tile(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.system(size: 18, weight: .bold, design: .rounded)).contentTransition(
                .numericText())
            Text(title).font(.caption2).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline))
    }
}
