import AppKit
import LangSwitchCore
import SwiftUI

/// Renders the application's screens to PNG files without showing them:
/// `LangSwitch --snapshots <folder>`. Used to check layouts and to produce documentation images.
@MainActor
enum SnapshotRenderer {
    private static func render(_ view: some View, size: CGSize, to url: URL, dark: Bool) async {
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView = host
        window.orderBack(nil)
        // Give SwiftUI a few run-loop turns to lay out, load images and settle animations.
        try? await Task.sleep(for: .milliseconds(900))
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
    }

    static func run(folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LangSwitchSnapshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = AppModel(store: Store(folder: scratch), persistsSettings: false)
        model.start()
        for _ in 0..<100 where !model.isLoaded { try? await Task.sleep(for: .milliseconds(100)) }
        let size = CGSize(width: 1040, height: 720)
        // First launch, before any permission or demo data.
        for dark in [false, true] {
            await render(
                RootView().environment(model), size: size,
                to: folder.appendingPathComponent("onboarding\(dark ? "-dark" : "").png"), dark: dark)
        }
        model.previewMode = true
        model.applyDemoData()
        model.settings.interfaceLanguage = .russian

        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            for item in SidebarItem.allCases {
                model.selection = item
                await render(
                    RootView().environment(model), size: size,
                    to: folder.appendingPathComponent("\(item.rawValue)\(suffix).png"), dark: dark)
            }

            // The trainer in the middle of an exercise.
            let trainer = TrainerModel()
            trainer.attach(model)
            model.settings.trainerSource = .texts
            trainer.start()
            if let target = trainer.session?.target {
                for (index, character) in target.prefix(46).enumerated() {
                    if index == 20 { trainer.type("#") }
                    trainer.type(character)
                }
            }
            await render(
                TrainerPreview(trainer: trainer).environment(model).background(BackdropView()), size: size,
                to: folder.appendingPathComponent("trainer-stage\(suffix).png"), dark: dark)
            trainer.stop()
        }

        await render(
            MenuPanel(close: {}).environment(model), size: CGSize(width: 320, height: 420),
            to: folder.appendingPathComponent("menu.png"), dark: true)

        // Floating pieces on a neutral background.
        let record = CorrectionRecord(
            original: "ghbdtn", corrected: "привет", kinds: .layout, application: "Notes", date: Date(),
            isUndo: false)
        let state = NotchState()
        state.notch = CGSize(width: 200, height: 37)
        state.content = .correction(record)
        state.isExpanded = true
        await render(
            NotchView(state: state).background(Color.gray.opacity(0.35)),
            size: CGSize(width: 620, height: 120),
            to: folder.appendingPathComponent("notch.png"), dark: false)
        let popup = SuggestionPopupState()
        popup.word = "быстро"
        popup.suggestions = await model.engine.suggestions(for: "быстро")
        await render(
            SuggestionPopupView(state: popup, choose: { _ in }).padding(20),
            size: CGSize(width: 330, height: 420),
            to: folder.appendingPathComponent("popup.png"), dark: false)
        print(folder.path)
    }
}
