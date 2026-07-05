import AppKit
import SwiftUI

// MARK: - SwiftUI Checkmark Symbol

/// 24pt 蓝底白勾 `checkmark.app.fill`，原生绘制入场。
/// `drawOff` 活跃时符号处于"已擦除"状态（不可见），
/// 切到不活跃时系统反向播放 → 效果等同 drawOn 正向绘制。
private struct CheckmarkIcon: View {
    @State private var show = false

    var body: some View {
        Image(systemName: "checkmark.app.fill")
            .font(.system(size: 24))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .blue)
            .symbolEffect(.drawOff, isActive: !show)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    show = true
                }
            }
    }
}

// MARK: - Controller

/// 轻提醒模式浮标控制器。
///
/// 18pt `checkmark.app.fill`（蓝底白勾），`.drawOn` 绘制入场，鼠标右上角，1s 自消。
final class LightReminderController {
    static let shared = LightReminderController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<CheckmarkIcon>?
    private var dismissTimer: Timer?
    private var isShowing = false

    private let size: CGFloat = 24
    private let offset: CGFloat = 4
    private let displayDuration: TimeInterval = 1.0

    // MARK: - Public

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "lightReminderEnabled")
    }

    func show() {
        dismissTimer?.invalidate()

        let cursor = NSEvent.mouseLocation

        if window != nil, isShowing {
            updatePosition(cursor: cursor)
        } else {
            createWindow(at: cursor)
        }

        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: displayDuration, repeats: false
        ) { [weak self] _ in
            self?.dismiss()
        }
    }

    // MARK: - Window Creation

    private func createWindow(at cursor: NSPoint) {
        // 立即清理旧窗口，防止 dismiss 动画回调覆盖新窗口引用
        window?.orderOut(nil)
        window = nil
        hostingView = nil

        guard let screen = screenContaining(cursor) else { return }
        let frame = indicatorFrame(for: cursor, screen: screen)

        let w = NSWindow(
            contentRect: frame, styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        w.level = .floating
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.ignoresMouseEvents = true
        w.isExcludedFromWindowsMenu = true

        let hv = NSHostingView(rootView: CheckmarkIcon())
        hv.frame = NSRect(x: 0, y: 0, width: size, height: size)
        w.contentView = hv

        self.window = w
        self.hostingView = hv

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            w.alphaValue = 1
        } else {
            w.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                w.animator().alphaValue = 1
            }
        }

        w.orderFront(nil)
        isShowing = true
    }

    // MARK: - Position

    private func updatePosition(cursor: NSPoint) {
        guard let window, let screen = screenContaining(cursor) ?? window.screen else { return }
        let frame = indicatorFrame(for: cursor, screen: screen)
        window.setFrame(frame, display: true, animate: false)
    }

    private func indicatorFrame(for cursor: NSPoint, screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        var x = cursor.x + offset
        var y = cursor.y + offset
        x = max(vf.minX + 4, min(x, vf.maxX - size - 4))
        y = max(vf.minY + 4, min(y, vf.maxY - size - 4))
        return NSRect(x: x, y: y, width: size, height: size)
    }

    private func screenContaining(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    // MARK: - Dismiss

    func dismiss(animated: Bool = true) {
        dismissTimer?.invalidate()
        dismissTimer = nil

        guard let window, isShowing else { return }
        isShowing = false

        guard animated else {
            window.orderOut(nil)
            self.window = nil
            self.hostingView = nil
            return
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            window.orderOut(nil)
            // 仅当共享引用仍是本窗口时才清 nil（防止覆盖新窗口引用）
            if self?.window === window {
                self?.window = nil
                self?.hostingView = nil
            }
        }
    }
}
