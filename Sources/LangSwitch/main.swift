import AppKit

// LangSwitch is a menu-bar application: it has no Dock icon until its window is opened.
let application = NSApplication.shared

if let flag = CommandLine.arguments.firstIndex(of: "--snapshots"), flag + 1 < CommandLine.arguments.count {
    // Developer mode: render every screen to PNG files and quit.
    let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    application.setActivationPolicy(.prohibited)
    Task { @MainActor in
        await SnapshotRenderer.run(folder: folder)
        exit(0)
    }
    application.run()
} else {
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
