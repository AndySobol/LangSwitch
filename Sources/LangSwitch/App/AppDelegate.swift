import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second copy would install a second keyboard tap and correct everything twice.
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let existing = others.first {
                existing.activate()
                NSApp.terminate(nil)
                return
            }
        }
        let model = AppModel()
        self.model = model
        model.openMainWindow = { [weak self] in self?.showWindow() }
        statusItem = StatusItemController(model: model)
        model.start()
        installMenu()
        // LANGSWITCH_NO_WINDOW=1 keeps the window closed at launch (used to measure the idle footprint).
        let staysHidden = ProcessInfo.processInfo.environment["LANGSWITCH_NO_WINDOW"] == "1"
        if !staysHidden, !model.settings.onboardingCompleted || !Accessibility.isTrusted { showWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            await model.flushAndSave()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// A minimal main menu so that ⌘Q, ⌘W and the standard editing shortcuts work in our window.
    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: loc("О программе LangSwitch", "About LangSwitch"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: loc("Скрыть LangSwitch", "Hide LangSwitch"), action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        appMenu.addItem(
            withTitle: loc("Завершить LangSwitch", "Quit LangSwitch"),
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: loc("Правка", "Edit"))
        edit.addItem(withTitle: loc("Отменить", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: loc("Повторить", "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: loc("Вырезать", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(
            withTitle: loc("Скопировать", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(
            withTitle: loc("Вставить", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(
            withTitle: loc("Выбрать все", "Select All"), action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: loc("Окно", "Window"))
        windowMenu.addItem(
            withTitle: loc("Закрыть", "Close"), action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowMenu.addItem(
            withTitle: loc("Свернуть", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    func showWindow() {
        guard let model else { return }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false)
            window.title = "LangSwitch"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.contentMinSize = NSSize(width: 860, height: 560)
            window.delegate = self
            let hosting = NSHostingController(rootView: RootView().environment(model))
            // By default the hosting controller pins the window to the content's ideal size, which blocks
            // resizing. The window owns its size; SwiftUI fills whatever it is given.
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 1040, height: 700))
            window.center()
            window.setFrameAutosaveName("LangSwitchMainWindow")
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.refreshTrust()
        if !model.isRunning { model.pollTrust() }
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a pure menu-bar application: no Dock icon, no window server work.
        NSApp.setActivationPolicy(.accessory)
        // Drop the whole view hierarchy and its graphics surfaces; the window is rebuilt on demand.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.window?.contentViewController = nil
                self?.window = nil
            }
        }
    }
}
