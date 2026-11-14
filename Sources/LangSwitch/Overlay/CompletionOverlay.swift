import AppKit
import SwiftUI

/// Grey "ghost" text drawn right after the caret of whatever application is in front.
///
/// The text is not inserted anywhere: it is a click-through window positioned from the caret rectangle
/// the application reports through Accessibility. Accepting the suggestion types the letters for real.
@MainActor
final class CompletionOverlay {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let keyLabel = NSTextField(labelWithString: "")

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let content = NSView()
        label.textColor = NSColor(calibratedWhite: 0.56, alpha: 0.95)
        label.lineBreakMode = .byClipping
        keyLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.95)
        keyLabel.alignment = .center
        keyLabel.wantsLayer = true
        keyLabel.layer?.backgroundColor = NSColor(calibratedWhite: 0.45, alpha: 0.85).cgColor
        keyLabel.layer?.cornerRadius = 4
        content.addSubview(label)
        content.addSubview(keyLabel)
        panel.contentView = content
        return panel
    }

    func show(_ remainder: String, at caret: CGRect, key: String) {
        let panel = panel ?? makePanel()
        self.panel = panel
        // Line height is roughly 1.2–1.3× the font size in most text fields.
        let fontSize = min(max(caret.height * 0.78, 10), 40)
        label.font = .systemFont(ofSize: fontSize)
        label.stringValue = remainder
        label.sizeToFit()
        keyLabel.font = .systemFont(ofSize: max(fontSize * 0.6, 8), weight: .semibold)
        keyLabel.stringValue = key
        keyLabel.sizeToFit()
        let keySize = CGSize(width: keyLabel.frame.width + 6, height: keyLabel.frame.height + 1)
        let height = max(label.frame.height, caret.height)
        label.frame.origin = CGPoint(x: 0, y: (height - label.frame.height) / 2)
        keyLabel.frame = CGRect(
            x: label.frame.maxX + 5, y: (height - keySize.height) / 2, width: keySize.width,
            height: keySize.height)
        panel.setFrame(
            CGRect(
                x: caret.maxX + 1, y: caret.midY - height / 2, width: keyLabel.frame.maxX + 2, height: height),
            display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}
