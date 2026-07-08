import AppKit
import SwiftUI

// MARK: - SwiftUI Checkmark Symbol

/// 24pt 蓝底白勾 `checkmark.app.fill`，原生绘制入场。
/// `drawOff` 活跃时符号不可见，切到不活跃时反向播放 → 等同 drawOn 正向绘制。
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
/// 24pt `checkmark.app.fill`（蓝底白勾），`.drawOff` 反向动画绘制入场，
/// 鼠标右上角 4pt，1s 自消。每次 `show()` 重建窗口（不复用），状态机极简。
final class LightReminderController {
    static let shared = LightReminderController()

    private var window: NSWindow?
    private var dismissTimer: Timer?

    private let size: CGFloat = 24
    private let offset: CGFloat = 4
    private let displayDuration: TimeInterval = 1.0

    // MARK: - Public

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "lightReminderEnabled")
    }

    func show() {
        dismissTimer?.invalidate()

        // 立即清理旧窗口（不等动画完成）
        window?.orderOut(nil)
        window = nil

        createWindow(at: NSEvent.mouseLocation)

        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: displayDuration, repeats: false
        ) { [weak self] _ in
            self?.dismiss()
        }
    }

    // MARK: - Window Creation

    private func createWindow(at cursor: NSPoint) {
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

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
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
    }

    // MARK: - Position

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

        guard let window else { return }
        self.window = nil  // 先清引用，防止 completion 与新窗口冲突

        guard animated else {
            window.orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
        }
    }
}
