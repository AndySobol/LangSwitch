import AppKit
import LangSwitchCore

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
} else if CommandLine.arguments.contains("--check-update") {
    // Developer mode: ask the releases page once, print the answer and quit.
    application.setActivationPolicy(.prohibited)
    Task { @MainActor in
        let updater = Updater()
        await updater.check(userInitiated: true)
        switch updater.state {
        case .available(let release):
            print("\(updater.current) → \(release.version): \(release.diskImageName)")
            // With --download the image is also fetched and verified; its path is printed.
            if CommandLine.arguments.contains("--download") {
                do {
                    print("verified: \(try await updater.download(release).path)")
                } catch {
                    print("failed: \((error as? UpdateError)?.message ?? "\(error)")")
                    exit(1)
                }
            }
        case .upToDate: print("\(updater.current) is the latest version")
        case .failed(let message): print("failed: \(message)")
        default: print("no answer")
        }
        exit(0)
    }
    application.run()
} else if CommandLine.arguments.contains("--self-update") {
    // Developer mode: the whole update without the interface — check, download, verify, replace this
    // very bundle and start the new one.
    application.setActivationPolicy(.prohibited)
    Task { @MainActor in
        let updater = Updater()
        await updater.check(userInitiated: true)
        guard case .available(let release) = updater.state else {
            print("nothing to install: \(updater.state)")
            exit(0)
        }
        print("installing \(release.version) over \(Bundle.main.bundleURL.path)")
        await updater.install()
        // Reached only when the installation did not end in a restart.
        print("not installed: \(updater.state)")
        exit(1)
    }
    application.run()
} else if let flag = CommandLine.arguments.firstIndex(of: "--install-update"),
    flag + 3 < CommandLine.arguments.count
{
    // Developer mode: `--install-update <image> <version> <bundle>` runs the installer on the given
    // bundle instead of the running one, to test it on a copy.
    let arguments = CommandLine.arguments
    do {
        guard let version = AppVersion(arguments[flag + 2]) else { throw UpdateError.notThisApplication }
        try UpdateInstaller.install(
            image: URL(fileURLWithPath: arguments[flag + 1]), expecting: version,
            bundleID: Bundle.main.bundleIdentifier ?? "", over: URL(fileURLWithPath: arguments[flag + 3]))
        print("installed \(version)")
        exit(0)
    } catch {
        print("failed: \(error)")
        exit(1)
    }
} else {
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
