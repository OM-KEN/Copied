import AppKit
import CoreGraphics

/// Global left-button + right-button → Command-C gesture.
/// The low-level tap is shared with toast side-button quick triggering.
final class CopyGestureManager {
    static let shared = CopyGestureManager()

    private var listenerToken: UUID?
    private var isLeftPressed = false
    private var gestureFired = false

    var isRunning: Bool { listenerToken != nil }
    private(set) var lastDiagnostic = ""

    private init() {}

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
        ) { [weak self] type, event in
            self?.handleEvent(type: type, event: event) ?? false
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

    private func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .leftMouseDown:
            isLeftPressed = true
            gestureFired = false
            return false
        case .leftMouseUp:
            isLeftPressed = false
            gestureFired = false
            return false
        case .rightMouseDown:
            guard isLeftPressed, !gestureFired else { return false }
            gestureFired = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(15)) { [weak self] in
                self?.simulateCommandC()
            }
            return true
        case .rightMouseUp:
            if isLeftPressed, !gestureFired {
                gestureFired = true
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(15)) { [weak self] in
                    self?.simulateCommandC()
                }
            }
            return false
        default:
            return false
        }
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
