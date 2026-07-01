import AppKit
import CoreGraphics

/// 全局手势：左键按住 + 右键 → ⌘C。
///
/// 使用 CGEventTap 拦截并吞掉右键事件。
/// 需要辅助功能权限（与现有 NSEvent flagsChanged 监听不同 — flagsChanged 无需权限）。
final class CopyGestureManager {
    static let shared = CopyGestureManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isLeftPressed = false

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
            // First failure — show system authorization dialog, then retry
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
            (1 << CGEventType.rightMouseDown.rawValue)

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
            return Unmanaged.passRetained(event)

        case .leftMouseUp:
            isLeftPressed = false
            return Unmanaged.passRetained(event)

        case .rightMouseDown:
            guard isLeftPressed else {
                return Unmanaged.passRetained(event)
            }
            NSLog("Copied: gesture — left+right detected, sending ⌘C")
            // Consume right-click, send ⌘C after micro-delay
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(15)) {
                self.simulateCommandC()
            }
            return nil

        case .tapDisabledByTimeout,
             .tapDisabledByUserInput:
            isLeftPressed = false
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            NSLog("Copied: gesture — tap disabled, re-enabled")
            return nil

        default:
            return Unmanaged.passRetained(event)
        }
    }

    // MARK: - ⌘C Simulation

    /// 发送 ⌘C 按键序列。只发送带 .maskCommand 修饰键的 C 键事件，
    /// 不发送显式的 ⌘ 按下/松开事件。这能防止合成事件触发
    /// ToastWindowController 的 ⌘ 快速触发检测（该检测依赖
    /// NSEvent.flagsChanged 全局监听器）。
    private func simulateCommandC() {
        let source = CGEventSource(stateID: .privateState)

        // C down（带 .maskCommand 修饰键 — 系统视为 ⌘+C）
        if let e = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) {
            e.flags = .maskCommand
            e.post(tap: .cgSessionEventTap)
        }

        // C up
        if let e = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false) {
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
    }
}
