import AppKit
import SwiftUI

/// A button that records a keyboard shortcut: click, press the combination, done.
struct HotkeyRecorder: View {
    let action: HotkeyAction
    @Environment(AppModel.self) private var model
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(
                    isRecording
                        ? loc("Нажмите сочетание…", "Press shortcut…")
                        : (model.settings.hotkey(for: action)?.display ?? loc("Не задано", "Not set"))
                )
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(minWidth: 120)
            }
            .buttonStyle(.secondary)
            .tint(isRecording ? Theme.ink : nil)
            if model.settings.hotkey(for: action) != nil {
                Button {
                    // An invalid shortcut marks "cleared on purpose", as opposed to "use the default".
                    model.settings.hotkeys[action.rawValue] = Hotkey(keyCode: 0)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.muted)
                .help(loc("Убрать сочетание", "Remove shortcut"))
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Escape cancels
                stop()
                return nil
            }
            let flags = event.modifierFlags
            let hotkey = Hotkey(
                keyCode: event.keyCode, command: flags.contains(.command), option: flags.contains(.option),
                control: flags.contains(.control), shift: flags.contains(.shift))
            guard hotkey.isValid else {
                NSSound.beep()
                return nil
            }
            model.settings.hotkeys[action.rawValue] = hotkey
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
