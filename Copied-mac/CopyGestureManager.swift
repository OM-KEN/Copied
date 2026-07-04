import AppKit
import CoreGraphics

/// 全局手势：左键按住 + 右键 → ⌘C。
///
/// CGEventTap 在 .headInsertEventTap 拦截鼠标事件：
/// - rightMouseDown：吞掉 + 触发 ⌘C。
/// - rightMouseUp 兜底：若左键仍按住但 rightMouseDown 未触发手势
///   （事件被 WindowServer 静默吞掉 — 发生于左先松之后），在此补触发。
///
/// 需要辅助功能权限。
final class CopyGestureManager {
    static let shared = CopyGestureManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isLeftPressed = false
    private var gestureFired = false

    var isRunning: Bool { eventTap != nil }
    private(set) var lastDiagnostic = ""

    private init() {}

    // MARK: - Start / Stop

    func start() {
        guard eventTap == nil else {
            lastDiagnostic = "已运行"
            return
        }
        tryCreateTap()
    }

    private func tryCreateTap(afterAuthPrompt: Bool = false) {
        let trusted = AXIsProcessTrusted()
        lastDiagnostic = "AXIsProcessTrusted=\(trusted)"

        if !trusted && !afterAuthPrompt {
            lastDiagnostic += "\n弹出授权对话框…"
            let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.lastDiagnostic += "\n授权对话框已关闭，重试…"
                self?.tryCreateTap(afterAuthPrompt: true)
            }
            return
        }

        if afterAuthPrompt {
            lastDiagnostic += "\n重新检查: AXIsProcessTrusted=\(trusted)"
        }

        let events: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: events,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let mgr = Unmanaged<CopyGestureManager>
                    .fromOpaque(refcon!).takeUnretainedValue()
                return mgr.handleEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            lastDiagnostic += "\ntapCreate → nil"
            if trusted {
                lastDiagnostic += "（权限已授但签名不匹配？试试去系统设置关掉再重开 Copied 的辅助功能开关）"
            } else {
                lastDiagnostic += "（请在弹窗中授权，或去系统设置手动开启）"
            }
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        registerStateResetObservers()
        lastDiagnostic += "\n✅ 启动成功，等待手势…"
    }

    func stop() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        eventTap = nil
        runLoopSource = nil
        isLeftPressed = false
        gestureFired = false
        unregisterStateResetObservers()
        NSLog("Copied: gesture — stopped")
    }

    // MARK: - Event Handling

    private func handleEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        switch type {
        case .leftMouseDown:
            isLeftPressed = true
            gestureFired = false
            return Unmanaged.passRetained(event)

        case .leftMouseUp:
            isLeftPressed = false
            gestureFired = false
            return Unmanaged.passRetained(event)

        case .rightMouseDown:
            guard isLeftPressed, !gestureFired else {
                return Unmanaged.passRetained(event)
            }
            gestureFired = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(15)) {
                self.simulateCommandC()
            }
            return nil

        case .rightMouseUp:
            if isLeftPressed, !gestureFired {
                // rightMouseDown 被 WindowServer 在左先松之后静默吞掉。
                // 左键仍按住 + 本手势未触发 → 补触发。
                gestureFired = true
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(15)) {
                    self.simulateCommandC()
                }
            }
            return Unmanaged.passRetained(event)

        case .tapDisabledByTimeout,
             .tapDisabledByUserInput:
            isLeftPressed = false
            gestureFired = false
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil

        default:
            return Unmanaged.passRetained(event)
        }
    }

    // MARK: - ⌘C Simulation

    private func simulateCommandC() {
        if let e = CGEvent(keyboardEventSource: nil, virtualKey: 0x08, keyDown: true) {
            e.flags = .maskCommand
            e.post(tap: .cgSessionEventTap)
        }
        if let e = CGEvent(keyboardEventSource: nil, virtualKey: 0x08, keyDown: false) {
            e.flags = .maskCommand
            e.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - State Reset

    private func registerStateResetObservers() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(resetState),
            name: NSApplication.didResignActiveNotification, object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(resetState),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(resetState),
            name: NSNotification.Name("com.apple.systemWillSleep"), object: nil
        )
    }

    private func unregisterStateResetObservers() {
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func resetState() {
        isLeftPressed = false
        gestureFired = false
    }
}
