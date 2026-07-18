import AppKit
import CoreGraphics
import Foundation

final class QuickTriggerCancellation {
    private var cancellation: (() -> Void)?
    private(set) var isCancelled = false

    init(_ cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        guard let cancellation else { return }
        self.cancellation = nil
        isCancelled = true
        cancellation()
    }

    deinit {
        cancel()
    }
}

struct QuickTriggerModifierEvent: Equatable {
    let keyCode: UInt16
    let modifierFlags: NSEvent.ModifierFlags
    let timestamp: TimeInterval
}

struct QuickTriggerMouseEvent: Equatable {
    enum Kind: Equatable {
        case leftDown
        case leftUp
        case rightDown
        case rightUp
        case otherDown
        case otherUp
        case scrollWheel
    }

    let kind: Kind
    let button: Int
}

struct QuickTriggerCoordinatorEnvironment {
    var readSettings: () -> QuickTriggerSettings
    var currentModifierFlags: () -> NSEvent.ModifierFlags
    var captureEventCounters: () -> QuickTriggerEventCounters
    var systemUptime: () -> TimeInterval
    var dispatchAsync: (@escaping () -> Void) -> Void
    var schedule: (_ delay: TimeInterval, _ action: @escaping () -> Void) -> QuickTriggerCancellation
    var addGlobalModifierMonitor: (
        _ handler: @escaping (QuickTriggerModifierEvent) -> Void
    ) -> QuickTriggerCancellation?
    var addLocalModifierMonitor: (
        _ handler: @escaping (QuickTriggerModifierEvent) -> Void
    ) -> QuickTriggerCancellation?
    var addLocalKeyDownMonitor: (
        _ handler: @escaping () -> Void
    ) -> QuickTriggerCancellation?
    var addMouseListener: (
        _ handler: @escaping (QuickTriggerMouseEvent) -> Bool
    ) -> QuickTriggerCancellation?

    static var live: QuickTriggerCoordinatorEnvironment {
        QuickTriggerCoordinatorEnvironment(
            readSettings: { QuickTriggerSettings.current() },
            currentModifierFlags: { NSEvent.modifierFlags },
            captureEventCounters: {
                func count(_ type: CGEventType) -> UInt32 {
                    CGEventSource.counterForEventType(.hidSystemState, eventType: type)
                }
                return QuickTriggerEventCounters(
                    keyDown: count(.keyDown),
                    leftMouseDown: count(.leftMouseDown),
                    leftMouseUp: count(.leftMouseUp),
                    rightMouseDown: count(.rightMouseDown),
                    rightMouseUp: count(.rightMouseUp),
                    otherMouseDown: count(.otherMouseDown),
                    otherMouseUp: count(.otherMouseUp),
                    scrollWheel: count(.scrollWheel)
                )
            },
            systemUptime: { ProcessInfo.processInfo.systemUptime },
            dispatchAsync: { action in DispatchQueue.main.async(execute: action) },
            schedule: { delay, action in
                let work = DispatchWorkItem(block: action)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                return QuickTriggerCancellation { work.cancel() }
            },
            addGlobalModifierMonitor: { handler in
                guard let token = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: {
                    event in
                    MainActor.assumeIsolated {
                        handler(
                            QuickTriggerModifierEvent(
                                keyCode: event.keyCode,
                                modifierFlags: event.modifierFlags,
                                timestamp: event.timestamp
                            )
                        )
                    }
                }) else { return nil }
                return QuickTriggerCancellation { NSEvent.removeMonitor(token) }
            },
            addLocalModifierMonitor: { handler in
                guard let token = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: {
                    event in
                    MainActor.assumeIsolated {
                        handler(
                            QuickTriggerModifierEvent(
                                keyCode: event.keyCode,
                                modifierFlags: event.modifierFlags,
                                timestamp: event.timestamp
                            )
                        )
                    }
                    return event
                }) else { return nil }
                return QuickTriggerCancellation { NSEvent.removeMonitor(token) }
            },
            addLocalKeyDownMonitor: { handler in
                guard let token = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: {
                    event in
                    MainActor.assumeIsolated { handler() }
                    return event
                }) else { return nil }
                return QuickTriggerCancellation { NSEvent.removeMonitor(token) }
            },
            addMouseListener: { handler in
                let token = GlobalMouseEventCoordinator.shared.addListener(
                    promptForAccessibility: false
                ) { type, event in
                    guard let kind = QuickTriggerMouseEvent.Kind(cgEventType: type) else {
                        return false
                    }
                    let mouseEvent = QuickTriggerMouseEvent(
                        kind: kind,
                        button: Int(event.getIntegerValueField(.mouseEventButtonNumber))
                    )
                    return MainActor.assumeIsolated { handler(mouseEvent) }
                }
                guard let token else { return nil }
                return QuickTriggerCancellation {
                    GlobalMouseEventCoordinator.shared.removeListener(token)
                }
            }
        )
    }
}

private extension QuickTriggerMouseEvent.Kind {
    init?(cgEventType: CGEventType) {
        switch cgEventType {
        case .leftMouseDown: self = .leftDown
        case .leftMouseUp: self = .leftUp
        case .rightMouseDown: self = .rightDown
        case .rightMouseUp: self = .rightUp
        case .otherMouseDown: self = .otherDown
        case .otherMouseUp: self = .otherUp
        case .scrollWheel: self = .scrollWheel
        default: return nil
        }
    }
}

final class QuickTriggerCoordinator {
    struct Context {
        let id: Int
        let isValid: () -> Bool
        let canPerform: () -> Bool
    }

    var onPerformPrimary: (() -> Void)?
    var onVisualStateChanged: ((QuickTriggerVisualState) -> Void)?

    private enum Lifecycle {
        case stopped
        case active
        case suspended
    }

    private let environment: QuickTriggerCoordinatorEnvironment
    private var lifecycle: Lifecycle = .stopped
    private var context: Context?
    private var settings: QuickTriggerSettings?
    private var contextEpoch = 0
    private var monitoringEpoch = 0
    private var monitoringInstalled = false

    private var globalModifierMonitor: QuickTriggerCancellation?
    private var localModifierMonitor: QuickTriggerCancellation?
    private var localKeyDownMonitor: QuickTriggerCancellation?
    private var mouseListener: QuickTriggerCancellation?
    private var timeout: QuickTriggerCancellation?
    private var hidPoll: QuickTriggerCancellation?

    private var keyboardState = KeyboardQuickTriggerStateMachine(mode: .doubleTap)
    private var modifierPolicy = QuickTriggerModifierKeyPolicy(targetModifier: .control)
    private var mouseState = MouseQuickTriggerStateMachine()
    private var publishedVisualState = QuickTriggerVisualState.idle

    init(environment: QuickTriggerCoordinatorEnvironment = .live) {
        self.environment = environment
    }

    func start(context newContext: Context) {
        let newSettings = environment.readSettings()
        let sameContext = context?.id == newContext.id
        let settingsChanged = settings != newSettings

        switch lifecycle {
        case .stopped:
            context = newContext
            settings = newSettings
            lifecycle = .active
            resetSequence(for: newSettings)
            reconcileMonitoring()

        case .suspended:
            context = newContext
            if !sameContext || settingsChanged {
                settings = newSettings
                resetSequence(for: newSettings)
            }

        case .active:
            context = newContext
            if !sameContext || settingsChanged {
                let shouldReinstall = settingsChanged
                if shouldReinstall { removeMonitoring() }
                settings = newSettings
                resetSequence(for: newSettings)
            } else if !monitoringInstalled {
                resetSequence(for: newSettings)
            }
            reconcileMonitoring()
        }
    }

    func suspend() {
        guard lifecycle == .active else { return }
        lifecycle = .suspended
        removeMonitoring()
    }

    func resume(context newContext: Context) {
        if lifecycle == .active {
            start(context: newContext)
            return
        }
        guard lifecycle == .suspended else { return }
        let newSettings = environment.readSettings()
        context = newContext
        settings = newSettings
        lifecycle = .active
        resetSequence(for: newSettings)
        reconcileMonitoring()
    }

    func stop() {
        guard lifecycle != .stopped || context != nil || monitoringInstalled else { return }
        lifecycle = .stopped
        removeMonitoring()
        context = nil
        settings = nil
    }

    private func reconcileMonitoring() {
        guard lifecycle == .active,
              let context,
              context.isValid(),
              context.canPerform() else {
            removeMonitoring()
            return
        }
        if !monitoringInstalled { installMonitoring() }
    }

    private func installMonitoring() {
        guard lifecycle == .active, !monitoringInstalled, let settings else { return }
        monitoringInstalled = true
        monitoringEpoch += 1
        let installedEpoch = monitoringEpoch

        if settings.keyboardModifier != .disabled {
            globalModifierMonitor = environment.addGlobalModifierMonitor { [weak self] event in
                self?.handleModifierEvent(event, monitoringEpoch: installedEpoch)
            }
            localModifierMonitor = environment.addLocalModifierMonitor { [weak self] event in
                self?.handleModifierEvent(event, monitoringEpoch: installedEpoch)
            }
        }
        localKeyDownMonitor = environment.addLocalKeyDownMonitor { [weak self] in
            self?.handleLocalKeyDown(monitoringEpoch: installedEpoch)
        }
        mouseListener = environment.addMouseListener { [weak self] event in
            self?.handleMouseEvent(event, monitoringEpoch: installedEpoch) ?? false
        }
    }

    private func removeMonitoring() {
        monitoringEpoch += 1
        globalModifierMonitor?.cancel()
        localModifierMonitor?.cancel()
        localKeyDownMonitor?.cancel()
        mouseListener?.cancel()
        globalModifierMonitor = nil
        localModifierMonitor = nil
        localKeyDownMonitor = nil
        mouseListener = nil
        monitoringInstalled = false
        invalidateSequence()
    }

    private func resetSequence(for settings: QuickTriggerSettings) {
        contextEpoch += 1
        cancelScheduledTasks()
        keyboardState = KeyboardQuickTriggerStateMachine(mode: settings.keyboardMode)
        modifierPolicy = QuickTriggerModifierKeyPolicy(targetModifier: settings.keyboardModifier)
        mouseState.reset()
        let targetIsDown = settings.keyboardModifier != .disabled
            && environment.currentModifierFlags().contains(settings.keyboardModifier.nseventFlags)
        modifierPolicy.appeared(preExisting: targetIsDown)
        keyboardState.appeared(preExisting: targetIsDown)
        publishVisualState(.idle)
    }

    private func invalidateSequence() {
        contextEpoch += 1
        cancelScheduledTasks()
        keyboardState.contextChanged()
        modifierPolicy.reset()
        mouseState.reset()
        publishVisualState(.idle)
    }

    private func cancelScheduledTasks() {
        timeout?.cancel()
        hidPoll?.cancel()
        timeout = nil
        hidPoll = nil
    }

    private func handleModifierEvent(
        _ event: QuickTriggerModifierEvent,
        monitoringEpoch installedEpoch: Int
    ) {
        guard callbackIsCurrent(monitoringEpoch: installedEpoch) else { return }
        guard settingsAreCurrent() else { return }
        guard contextIsUsable() else {
            invalidateSequence()
            return
        }
        guard let settings, settings.keyboardModifier != .disabled else {
            cancelKeyboard()
            return
        }

        let counters = environment.captureEventCounters()
        let decision = modifierPolicy.handleFlagsChanged(
            keyCode: event.keyCode,
            eventFlags: event.modifierFlags,
            sequenceActive: keyboardState.visualState != .idle
        )

        let isDown: Bool
        switch decision {
        case .ignore:
            return
        case .cancelOtherModifier:
            cancelKeyboard()
            cancelMouse()
            return
        case .cancelTargetSideConflict:
            cancelKeyboard()
            cancelMouse()
            return
        case .targetDown:
            isDown = true
        case .targetUp:
            isDown = false
        }
        cancelMouse()

        if isDown {
            let shouldPerform = keyboardState.targetChanged(
                isDown: true,
                at: event.timestamp,
                counters: counters,
                context: contextEpoch
            )
            updateKeyboardVisualState()
            if shouldPerform { performPrimary() }
        } else {
            let capturedContextEpoch = contextEpoch
            let capturedContextID = context?.id
            let timestamp = event.timestamp
            environment.dispatchAsync { [weak self] in
                guard let self,
                      self.asyncCallbackIsCurrent(
                        contextEpoch: capturedContextEpoch,
                        contextID: capturedContextID
                      ),
                      self.settingsAreCurrent() else { return }
                let releaseCounters = self.environment.captureEventCounters()
                let shouldPerform = self.keyboardState.targetChanged(
                    isDown: false,
                    at: timestamp,
                    counters: releaseCounters,
                    context: capturedContextEpoch
                )
                self.updateKeyboardVisualState()
                if shouldPerform { self.performPrimary() }
            }
        }
    }

    private func handleLocalKeyDown(monitoringEpoch installedEpoch: Int) {
        guard callbackIsCurrent(monitoringEpoch: installedEpoch) else { return }
        guard settingsAreCurrent() else { return }
        cancelKeyboard()
        cancelMouse()
    }

    private func handleMouseEvent(
        _ event: QuickTriggerMouseEvent,
        monitoringEpoch installedEpoch: Int
    ) -> Bool {
        guard callbackIsCurrent(monitoringEpoch: installedEpoch) else { return false }
        guard settingsAreCurrent() else { return false }
        cancelKeyboard()
        guard let configuredButton = settings?.mouseButton else {
            cancelMouse()
            return false
        }

        switch event.kind {
        case .otherDown where event.button == configuredButton:
            let capturedContextEpoch = contextEpoch
            let capturedContextID = context?.id
            let consume = mouseState.mouseDown(
                button: event.button,
                configuredButton: configuredButton,
                context: capturedContextEpoch,
                canPerform: contextIsUsable()
            )
            if consume {
                environment.dispatchAsync { [weak self] in
                    guard let self,
                          self.asyncCallbackIsCurrent(
                            contextEpoch: capturedContextEpoch,
                            contextID: capturedContextID
                          ) else { return }
                    self.publishVisualState(.pressed)
                }
            }
            return consume

        case .otherUp where event.button == configuredButton:
            let capturedContextEpoch = contextEpoch
            let capturedContextID = context?.id
            let result = mouseState.mouseUp(
                button: event.button,
                context: capturedContextEpoch
            )
            if result.consume {
                environment.dispatchAsync { [weak self] in
                    guard let self,
                          self.asyncCallbackIsCurrent(
                            contextEpoch: capturedContextEpoch,
                            contextID: capturedContextID
                          ) else { return }
                    self.publishVisualState(.idle)
                    if result.trigger { self.performPrimary() }
                }
            }
            return result.consume

        default:
            cancelMouse()
            return false
        }
    }

    private func updateKeyboardVisualState() {
        timeout?.cancel()
        timeout = nil
        publishVisualState(keyboardState.visualState)
        scheduleHIDValidation()

        guard keyboardState.visualState == .waitingForSecondTap else { return }
        let capturedContextEpoch = contextEpoch
        let capturedContextID = context?.id
        timeout = environment.schedule(0.351) { [weak self] in
            guard let self,
                  self.asyncCallbackIsCurrent(
                    contextEpoch: capturedContextEpoch,
                    contextID: capturedContextID
                  ),
                  self.settingsAreCurrent() else { return }
            self.timeout = nil
            self.keyboardState.tick(at: self.environment.systemUptime())
            self.publishVisualState(self.keyboardState.visualState)
            if self.keyboardState.visualState == .idle {
                self.hidPoll?.cancel()
                self.hidPoll = nil
            }
        }
    }

    private func scheduleHIDValidation() {
        hidPoll?.cancel()
        hidPoll = nil
        guard keyboardState.visualState != .idle else { return }
        let capturedContextEpoch = contextEpoch
        let capturedContextID = context?.id
        hidPoll = environment.schedule(0.020) { [weak self] in
            guard let self,
                  self.asyncCallbackIsCurrent(
                    contextEpoch: capturedContextEpoch,
                    contextID: capturedContextID
                  ),
                  self.settingsAreCurrent() else { return }
            self.hidPoll = nil
            let isValid = self.keyboardState.validate(
                counters: self.environment.captureEventCounters(),
                context: capturedContextEpoch
            )
            self.publishVisualState(self.keyboardState.visualState)
            if isValid, self.keyboardState.visualState != .idle {
                self.scheduleHIDValidation()
            }
        }
    }

    private func cancelKeyboard() {
        timeout?.cancel()
        hidPoll?.cancel()
        timeout = nil
        hidPoll = nil
        keyboardState.cancel()
        publishVisualState(.idle)
    }

    private func cancelMouse() {
        mouseState.cancelPendingTrigger()
    }

    private func settingsAreCurrent() -> Bool {
        let current = environment.readSettings()
        guard current == settings else {
            settings = current
            invalidateSequence()
            let capturedContextID = context?.id
            let capturedContextEpoch = contextEpoch
            environment.dispatchAsync { [weak self] in
                guard let self,
                      self.lifecycle == .active,
                      self.context?.id == capturedContextID,
                      self.contextEpoch == capturedContextEpoch,
                      self.settings == current else { return }
                self.removeMonitoring()
                self.resetSequence(for: current)
                self.reconcileMonitoring()
            }
            return false
        }
        return true
    }

    private func callbackIsCurrent(monitoringEpoch installedEpoch: Int) -> Bool {
        lifecycle == .active
            && monitoringInstalled
            && installedEpoch == monitoringEpoch
    }

    private func asyncCallbackIsCurrent(contextEpoch: Int, contextID: Int?) -> Bool {
        lifecycle == .active
            && contextEpoch == self.contextEpoch
            && contextID == context?.id
            && contextIsUsable()
    }

    private func contextIsUsable() -> Bool {
        guard lifecycle == .active, let context else { return false }
        return context.isValid() && context.canPerform()
    }

    private func performPrimary() {
        guard contextIsUsable() else {
            invalidateSequence()
            return
        }
        onPerformPrimary?()
    }

    private func publishVisualState(_ state: QuickTriggerVisualState) {
        guard state != publishedVisualState else { return }
        publishedVisualState = state
        onVisualStateChanged?(state)
    }
}
