import AppKit
import LangSwitchCore
import Observation
import SwiftUI

/// What the HUD shows.
enum NotchContent: Equatable {
    case correction(CorrectionRecord)
    case message(symbol: String, text: String)
    case completion(remainder: String, key: String)
}

@MainActor
@Observable
final class NotchState {
    var content: NotchContent?
    var isExpanded = false
    /// Size of the physical notch; zero width on displays without one.
    var notch = CGSize.zero
}

/// A black tab that grows out of the notch, Dynamic Island style.
///
/// The top edge has the width of the notch, so the shape seems to be part of the hardware; below the menu
/// bar it widens to fit the content. On displays without a notch it is a capsule under the menu bar.
struct NotchShape: Shape {
    var topWidth: CGFloat
    var topHeight: CGFloat
    var radius: CGFloat = 18

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topWidth, topHeight) }
        set {
            topWidth = newValue.first
            topHeight = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset = max((rect.width - topWidth) / 2, 0)
        let shoulder = min(topHeight, rect.height)
        let curve = min(inset, 14)
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY + max(shoulder - curve, 0)))
        // Flare out from the notch to the wider body.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - inset + curve, y: rect.minY + shoulder),
            control: CGPoint(x: rect.maxX - inset, y: rect.minY + shoulder))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY + shoulder))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + shoulder + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY + shoulder))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + shoulder + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY + shoulder),
            control: CGPoint(x: rect.minX, y: rect.minY + shoulder))
        path.addLine(to: CGPoint(x: rect.minX + inset - curve, y: rect.minY + shoulder))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + inset, y: rect.minY + max(shoulder - curve, 0)),
            control: CGPoint(x: rect.minX + inset, y: rect.minY + shoulder))
        path.closeSubpath()
        return path
    }
}

struct NotchView: View {
    let state: NotchState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasNotch: Bool { state.notch.width > 0 }

    var body: some View {
        VStack(spacing: 0) {
            if let content = state.content, state.isExpanded {
                row(content)
                    .frame(minWidth: hasNotch ? state.notch.width + 56 : 0)
                    .padding(.horizontal, 18)
                    .padding(.top, hasNotch ? state.notch.height + 6 : 9)
                    .padding(.bottom, 10)
                    .background {
                        if hasNotch {
                            NotchShape(topWidth: state.notch.width, topHeight: state.notch.height).fill(
                                .black)
                        } else {
                            Capsule().fill(.black.opacity(0.88))
                        }
                    }
                    .padding(.top, hasNotch ? 0 : 6)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .scale(scale: 0.55, anchor: .top).combined(with: .opacity),
                                removal: .scale(scale: 0.7, anchor: .top).combined(with: .opacity)))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.36, dampingFraction: 0.74), value: state.isExpanded)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state.content)
    }

    @ViewBuilder
    private func row(_ content: NotchContent) -> some View {
        switch content {
        case .correction(let record):
            HStack(spacing: 9) {
                Image(systemName: record.isUndo ? "arrow.uturn.backward" : Theme.symbol(for: record.kinds))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(record.isUndo ? Theme.amber : Theme.color(for: record.kinds))
                    .symbolEffect(.bounce, value: record.id)
                Text(record.original)
                    .strikethrough(!record.isUndo, color: .white.opacity(0.5))
                    .foregroundStyle(.white.opacity(0.5))
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(
                    .white.opacity(0.4))
                Text(record.corrected).foregroundStyle(.white)
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .lineLimit(1)
        case .message(let symbol, let text):
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.violet)
                Text(text).foregroundStyle(.white)
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .lineLimit(1)
        case .completion(let remainder, let key):
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .bold)).foregroundStyle(
                    Theme.mint)
                Text("…" + remainder).foregroundStyle(.white.opacity(0.75))
                Text(key)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        .white.opacity(0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .lineLimit(1)
        }
    }
}

/// Owns the HUD window. The window exists only while something is shown: nothing is drawn at rest.
@MainActor
final class NotchHUD {
    private let state = NotchState()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

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
        // Above the menu bar, so the shape can overlap the notch area.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: NotchView(state: state))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    /// The display the user is working on: the one with the keyboard focus.
    private func targetScreen() -> NSScreen? { NSScreen.main ?? NSScreen.screens.first }

    private func place(_ panel: NSPanel) {
        guard let screen = targetScreen() else { return }
        var notch = CGSize.zero
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea,
            let right = screen.auxiliaryTopRightArea
        {
            notch = CGSize(
                width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        }
        state.notch = notch
        let size = CGSize(width: 620, height: 120)
        let top = notch.width > 0 ? screen.frame.maxY : screen.visibleFrame.maxY
        panel.setFrame(
            CGRect(
                x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width,
                height: size.height),
            display: false)
    }

    func show(_ content: NotchContent, duration: Double = 1.7) {
        let panel = panel ?? makePanel()
        self.panel = panel
        place(panel)
        panel.orderFrontRegardless()
        state.content = content
        state.isExpanded = true
        hideTask?.cancel()
        // A completion stays until it is accepted or dismissed.
        if case .completion = content { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.collapse()
        }
    }

    func hideCompletion() {
        if case .completion = state.content { collapse() }
    }

    private func collapse() {
        state.isExpanded = false
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, !self.state.isExpanded else { return }
            self.state.content = nil
            self.panel?.orderOut(nil)
        }
    }
}
