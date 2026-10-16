import AppKit
import CoreGraphics

/// Global left-button + right-button → Command-C gesture.
/// The low-level tap is shared with toast side-button quick triggering.
final class CopyGestureManager {
    static let shared = CopyGestureManager()

    private var listenerToken: UUID?
    private var state: CopyGestureStateMachine

    var isRunning: Bool { listenerToken != nil }
    private(set) var lastDiagnostic = ""

    private init() {
        if #available(macOS 27.0, *) {
            state = CopyGestureStateMachine(isMacOS27OrLater: true)
        } else {
            state = CopyGestureStateMachine(isMacOS27OrLater: false)
        }
    }

    func start() {
        guard listenerToken == nil else {
            lastDiagnostic = String(localized: "已运行")
            return
        }
        tryStart(promptForAccessibility: true)
    }

    private func tryStart(promptForAccessibility: Bool) {
        listenerToken = GlobalMouseEventCoordinator.shared.addListener(
            promptForAccessibility: promptForAccessibility
        ) { [weak self] type, _ in
            self?.handleEvent(type: type) ?? false
        }
        lastDiagnostic = GlobalMouseEventCoordinator.shared.lastDiagnostic

        if listenerToken == nil, promptForAccessibility {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.listenerToken == nil else { return }
                self.tryStart(promptForAccessibility: false)
                self.lastDiagnostic = GlobalMouseEventCoordinator.shared.lastDiagnostic
            }
        } else if listenerToken != nil {
            registerStateResetObservers()
        }
    }

    func stop() {
        GlobalMouseEventCoordinator.shared.removeListener(listenerToken)
        listenerToken = nil
        resetState()
        unregisterStateResetObservers()
        NSLog("Copied: gesture — stopped")
    }

    private func handleEvent(type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            break
        default:
            return false
        }
        let sourceApp = NSWorkspace.shared.frontmostApplication
        let decision = state.handle(
            type,
            frontmostPID: sourceApp?.processIdentifier,
            frontmostBundleIdentifier: sourceApp?.bundleIdentifier
        )
        if let request = decision.request {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(15)) { [weak self] in
                guard let self, self.isRunning,
                      self.state.consume(
                        request,
                        frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
                      ) else { return }
                self.simulateCommandC()
            }
        }
        return decision.consume
    }

    private func simulateCommandC() {
        for descriptor in CopyGestureEventSequence.commandC {
            guard let event = CGEvent(
                keyboardEventSource: nil,
                virtualKey: descriptor.virtualKey,
                keyDown: descriptor.isKeyDown
            ) else { continue }
            event.flags = descriptor.flags
            event.post(tap: .cgSessionEventTap)
        }
    }

    private func registerStateResetObservers() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(resetState),
            name: NSApplication.didResignActiveNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(cancelPendingCopy),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
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
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func cancelPendingCopy() {
        state.cancelPendingCopy()
    }

    @objc private func resetState() {
        state.reset()
    }
}
