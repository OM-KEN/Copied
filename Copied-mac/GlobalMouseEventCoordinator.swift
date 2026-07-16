import AppKit
import CoreGraphics

/// Owns the single session-level mouse event tap shared by copy gestures and
/// the toast side-button quick trigger. Business state remains in each client.
final class GlobalMouseEventCoordinator {
    static let shared = GlobalMouseEventCoordinator()

    typealias Listener = (_ type: CGEventType, _ event: CGEvent) -> Bool

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var listeners: [UUID: Listener] = [:]
    private var swallowedOtherButtons: Set<Int> = []

    private(set) var lastDiagnostic = ""
    var isRunning: Bool { eventTap != nil }

    private init() {}

    @discardableResult
    func addListener(promptForAccessibility: Bool, _ listener: @escaping Listener) -> UUID? {
        guard ensureTap(promptForAccessibility: promptForAccessibility) else { return nil }
        let token = UUID()
        listeners[token] = listener
        return token
    }

    func removeListener(_ token: UUID?) {
        guard let token else { return }
        listeners.removeValue(forKey: token)
        stopIfUnused()
    }

    private func ensureTap(promptForAccessibility: Bool) -> Bool {
        if eventTap != nil { return true }
        let trusted = AXIsProcessTrusted()
        lastDiagnostic = "AXIsProcessTrusted=\(trusted)"
        guard trusted else {
            if promptForAccessibility {
                let options = [
                    kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true
                ] as CFDictionary
                AXIsProcessTrustedWithOptions(options)
                lastDiagnostic += "\n" + String(localized: "弹出授权对话框…")
            }
            return false
        }

        let eventTypes: [CGEventType] = [
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .scrollWheel
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) { partial, type in
            partial | (1 << type.rawValue)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let coordinator = Unmanaged<GlobalMouseEventCoordinator>
                    .fromOpaque(refcon!).takeUnretainedValue()
                return coordinator.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            lastDiagnostic += "\ntapCreate → nil"
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        lastDiagnostic += "\n" + String(localized: "✅ 启动成功，等待手势…")
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return nil
        }

        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        if type == .otherMouseUp, swallowedOtherButtons.remove(button) != nil {
            _ = listeners.values.map { $0(type, event) }
            stopIfUnused()
            return nil
        }

        let shouldConsume = listeners.values.reduce(false) { consumed, listener in
            listener(type, event) || consumed
        }
        if shouldConsume, type == .otherMouseDown {
            swallowedOtherButtons.insert(button)
        }
        return shouldConsume ? nil : Unmanaged.passUnretained(event)
    }

    private func stopIfUnused() {
        guard listeners.isEmpty, swallowedOtherButtons.isEmpty, let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(eventTap)
        self.eventTap = nil
        runLoopSource = nil
    }
}
