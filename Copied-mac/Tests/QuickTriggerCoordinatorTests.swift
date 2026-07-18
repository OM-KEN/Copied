import AppKit
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private final class ScheduledProbe {
    let delay: TimeInterval
    let action: () -> Void
    var isCancelled = false
    var hasFired = false

    init(delay: TimeInterval, action: @escaping () -> Void) {
        self.delay = delay
        self.action = action
    }

    func fire(evenIfCancelled: Bool = false) {
        guard !hasFired, evenIfCancelled || !isCancelled else { return }
        hasFired = true
        action()
    }
}

private final class FakeQuickTriggerEnvironment {
    var settings = QuickTriggerSettings(
        keyboardModifier: .control,
        keyboardMode: .doubleTap,
        mouseButton: 3
    )
    var modifierFlags: NSEvent.ModifierFlags = []
    var counters = QuickTriggerEventCounters.zero
    var uptime: TimeInterval = 0

    var globalInstallCount = 0
    var localModifierInstallCount = 0
    var localKeyInstallCount = 0
    var mouseInstallCount = 0
    var globalRemoveCount = 0
    var localModifierRemoveCount = 0
    var localKeyRemoveCount = 0
    var mouseRemoveCount = 0

    var globalHandlers: [(QuickTriggerModifierEvent) -> Void] = []
    var localModifierHandlers: [(QuickTriggerModifierEvent) -> Void] = []
    var localKeyHandlers: [() -> Void] = []
    var mouseHandlers: [(QuickTriggerMouseEvent) -> Bool] = []
    var activeGlobalHandler: ((QuickTriggerModifierEvent) -> Void)?
    var activeLocalModifierHandler: ((QuickTriggerModifierEvent) -> Void)?
    var activeLocalKeyHandler: (() -> Void)?
    var activeMouseHandler: ((QuickTriggerMouseEvent) -> Bool)?
    private var activeGlobalID = 0
    private var activeLocalModifierID = 0
    private var activeLocalKeyID = 0
    private var activeMouseID = 0

    var asyncActions: [() -> Void] = []
    var scheduled: [ScheduledProbe] = []

    func makeEnvironment() -> QuickTriggerCoordinatorEnvironment {
        QuickTriggerCoordinatorEnvironment(
            readSettings: { [unowned self] in settings },
            currentModifierFlags: { [unowned self] in modifierFlags },
            captureEventCounters: { [unowned self] in counters },
            systemUptime: { [unowned self] in uptime },
            dispatchAsync: { [unowned self] action in asyncActions.append(action) },
            schedule: { [unowned self] delay, action in
                let probe = ScheduledProbe(delay: delay, action: action)
                scheduled.append(probe)
                return QuickTriggerCancellation { probe.isCancelled = true }
            },
            addGlobalModifierMonitor: { [unowned self] handler in
                globalInstallCount += 1
                activeGlobalID = globalInstallCount
                let id = activeGlobalID
                globalHandlers.append(handler)
                activeGlobalHandler = handler
                return QuickTriggerCancellation { [unowned self] in
                    globalRemoveCount += 1
                    if activeGlobalID == id { activeGlobalHandler = nil }
                }
            },
            addLocalModifierMonitor: { [unowned self] handler in
                localModifierInstallCount += 1
                activeLocalModifierID = localModifierInstallCount
                let id = activeLocalModifierID
                localModifierHandlers.append(handler)
                activeLocalModifierHandler = handler
                return QuickTriggerCancellation { [unowned self] in
                    localModifierRemoveCount += 1
                    if activeLocalModifierID == id { activeLocalModifierHandler = nil }
                }
            },
            addLocalKeyDownMonitor: { [unowned self] handler in
                localKeyInstallCount += 1
                activeLocalKeyID = localKeyInstallCount
                let id = activeLocalKeyID
                localKeyHandlers.append(handler)
                activeLocalKeyHandler = handler
                return QuickTriggerCancellation { [unowned self] in
                    localKeyRemoveCount += 1
                    if activeLocalKeyID == id { activeLocalKeyHandler = nil }
                }
            },
            addMouseListener: { [unowned self] handler in
                mouseInstallCount += 1
                activeMouseID = mouseInstallCount
                let id = activeMouseID
                mouseHandlers.append(handler)
                activeMouseHandler = handler
                return QuickTriggerCancellation { [unowned self] in
                    mouseRemoveCount += 1
                    if activeMouseID == id { activeMouseHandler = nil }
                }
            }
        )
    }

    func fireModifier(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        timestamp: TimeInterval
    ) {
        activeGlobalHandler?(
            QuickTriggerModifierEvent(
                keyCode: keyCode,
                modifierFlags: flags,
                timestamp: timestamp
            )
        )
    }

    @discardableResult
    func fireMouse(_ kind: QuickTriggerMouseEvent.Kind, button: Int = 0) -> Bool {
        activeMouseHandler?(QuickTriggerMouseEvent(kind: kind, button: button)) ?? false
    }

    func flushAsync() {
        while !asyncActions.isEmpty {
            let action = asyncActions.removeFirst()
            action()
        }
    }

    func firstActiveScheduled(delay: TimeInterval) -> ScheduledProbe? {
        scheduled.first {
            !$0.isCancelled && !$0.hasFired && abs($0.delay - delay) < 0.000_001
        }
    }
}

private final class ContextProbe {
    var validIDs: Set<Int> = []
    var canPerform = true

    func context(_ id: Int) -> QuickTriggerCoordinator.Context {
        QuickTriggerCoordinator.Context(
            id: id,
            isValid: { [unowned self] in validIDs.contains(id) },
            canPerform: { [unowned self] in canPerform }
        )
    }
}

@main
struct QuickTriggerCoordinatorTests {
    static func main() {
        lifecycleOperationsAreIdempotent()
        deinitReleasesOwnedResources()
        doubleTapTriggersOnSecondReleaseOnly()
        timeoutAndHIDCancellationAreBounded()
        singleTapSupportsEveryModifier()
        ordinaryInputDoesNotPublishIdleAgain()
        staleContextAndCallbacksCannotPerform()
        settingsChangesReplaceTheOldSequence()
        sideButtonPairsOnceAndRejectsStaleUp()
        disabledInputsDoNotTrigger()
        ineligibleContextDoesNotInstallUntilEligible()
        print("QuickTriggerCoordinatorTests: PASS")
    }

    private static func makeCoordinator(
        fake: FakeQuickTriggerEnvironment,
        contextProbe: ContextProbe,
        id: Int = 1
    ) -> (QuickTriggerCoordinator, () -> Int, () -> [QuickTriggerVisualState]) {
        contextProbe.validIDs.insert(id)
        let coordinator = QuickTriggerCoordinator(environment: fake.makeEnvironment())
        var performCount = 0
        var visuals: [QuickTriggerVisualState] = []
        coordinator.onPerformPrimary = { performCount += 1 }
        coordinator.onVisualStateChanged = { visuals.append($0) }
        coordinator.start(context: contextProbe.context(id))
        return (
            coordinator,
            { _ = coordinator; return performCount },
            { _ = coordinator; return visuals }
        )
    }

    private static func lifecycleOperationsAreIdempotent() {
        let fake = FakeQuickTriggerEnvironment()
        let context = ContextProbe()
        let (coordinator, performCount, visuals) = makeCoordinator(
            fake: fake,
            contextProbe: context
        )

        expect(fake.globalInstallCount == 1, "start installs one global modifier monitor")
        expect(fake.localModifierInstallCount == 1, "start installs one local modifier monitor")
        expect(fake.localKeyInstallCount == 1, "start installs one keyDown monitor")
        expect(fake.mouseInstallCount == 1, "start installs one shared mouse listener")

        coordinator.start(context: context.context(1))
        expect(fake.globalInstallCount == 1, "repeated start does not reinstall")

        fake.fireModifier(keyCode: 59, flags: .control, timestamp: 0)
        let stalePoll = fake.firstActiveScheduled(delay: 0.020)
        expect(stalePoll != nil, "pressed state schedules HID validation")

        coordinator.suspend()
        coordinator.suspend()
        expect(fake.globalRemoveCount == 1, "repeated suspend removes global monitor once")
        expect(fake.localModifierRemoveCount == 1, "suspend removes local modifier monitor")
        expect(fake.localKeyRemoveCount == 1, "suspend removes keyDown monitor")
        expect(fake.mouseRemoveCount == 1, "suspend removes mouse listener")
        expect(stalePoll?.isCancelled == true, "suspend cancels pending HID poll")
        let visualCountAfterSuspend = visuals().count
        stalePoll?.fire(evenIfCancelled: true)
        expect(visuals().count == visualCountAfterSuspend, "suspended stale poll cannot publish")
        expect(performCount() == 0, "suspended stale poll cannot perform")

        coordinator.resume(context: context.context(1))
        coordinator.resume(context: context.context(1))
        expect(fake.globalInstallCount == 2, "resume reinstalls exactly once")
        expect(fake.mouseInstallCount == 2, "resume reinstalls mouse listener exactly once")

        coordinator.stop()
        coordinator.stop()
        expect(fake.globalRemoveCount == 2, "repeated stop removes global monitor once")
        expect(fake.mouseRemoveCount == 2, "repeated stop removes mouse listener once")
    }

    private static func deinitReleasesOwnedResources() {
        let fake = FakeQuickTriggerEnvironment()
        let context = ContextProbe()
        context.validIDs.insert(1)
        var coordinator: QuickTriggerCoordinator? = QuickTriggerCoordinator(
            environment: fake.makeEnvironment()
        )
        coordinator?.start(context: context.context(1))
        expect(fake.globalInstallCount == 1, "owned monitor is installed before deinit")
        coordinator = nil
        expect(fake.globalRemoveCount == 1, "deinit releases the global modifier monitor")
        expect(fake.localModifierRemoveCount == 1, "deinit releases the local modifier monitor")
        expect(fake.localKeyRemoveCount == 1, "deinit releases the keyDown monitor")
        expect(fake.mouseRemoveCount == 1, "deinit releases the shared mouse listener")
    }

    private static func doubleTapTriggersOnSecondReleaseOnly() {
        let fake = FakeQuickTriggerEnvironment()
        let context = ContextProbe()
        let (_, performCount, visuals) = makeCoordinator(fake: fake, contextProbe: context)

        fake.fireModifier(keyCode: 59, flags: .control, timestamp: 0.0)
        fake.fireModifier(keyCode: 59, flags: [], timestamp: 0.1)
        fake.flushAsync()
        expect(performCount() == 0, "first release does not perform in double-tap mode")
        expect(
            fake.firstActiveScheduled(delay: 0.351) != nil,
            "double tap uses 351ms expiry for a 350ms window; scheduled=\(fake.scheduled.map { ($0.delay, $0.isCancelled, $0.hasFired) })"
        )

        fake.fireModifier(keyCode: 59, flags: .control, timestamp: 0.2)
        expect(performCount() == 0, "second press does not perform before release")
        fake.fireModifier(keyCode: 59, flags: [], timestamp: 0.3)
        expect(performCount() == 0, "release remains deferred until the main queue callback")
        fake.flushAsync()

        expect(performCount() == 1, "second release performs exactly once")
        expect(
            visuals() == [.pressed, .waitingForSecondTap, .pressed, .idle],
            "double tap publishes only value changes"
        )
    }

    private static func timeoutAndHIDCancellationAreBounded() {
        do {
            let fake = FakeQuickTriggerEnvironment()
            let context = ContextProbe()
            let (_, performCount, visuals) = makeCoordinator(fake: fake, contextProbe: context)
            fake.fireModifier(keyCode: 59, flags: .control, timestamp: 0.0)
            fake.fireModifier(keyCode: 59, flags: [], timestamp: 0.1)
            fake.flushAsync()
            fake.uptime = 0.452
            fake.firstActiveScheduled(delay: 0.351)?.fire()
            expect(performCount() == 0, "timeout does not perform")
            expect(visuals().last == .idle, "timeout resets waiting visual once")
        }

        do {
            let fake = FakeQuickTriggerEnvironment()
            let context = ContextProbe()
            let (_, performCount, visuals) = makeCoordinator(fake: fake, contextProbe: context)
            fake.fireModifier(keyCode: 59, flags: .control, timestamp: 0.0)
            fake.fireModifier(keyCode: 59, flags: [], timestamp: 0.1)
            fake.flushAsync()
            fake.counters.scrollWheel = 1
            fake.firstActiveScheduled(delay: 0.020)?.fire()
            expect(performCount() == 0, "HID counter change cancels without performing")
            expect(visuals().last == .idle, "HID counter change resets visual state")
        }
    }

    private static func singleTapSupportsEveryModifier() {
        let cases: [(KeyboardQuickTriggerModifier, UInt16, NSEvent.ModifierFlags)] = [
            (.control, 59, .control),
            (.command, 55, .command),
            (.option, 58, .option),
            (.shift, 56, .shift),
        ]
        for (modifier, keyCode, flags) in cases {
            let fake = FakeQuickTriggerEnvironment()
            fake.settings.keyboardModifier = modifier
            fake.settings.keyboardMode = .singleTap
            let context = ContextProbe()
            let (_, performCount, _) = makeCoordinator(fake: fake, contextProbe: context)
            fake.fireModifier(keyCode: keyCode, flags: flags, timestamp: 0.0)
            fake.fireModifier(keyCode: keyCode, flags: [], timestamp: 0.1)
            fake.flushAsync()
            expect(performCount() == 1, "single tap performs once for \(modifier)")
        }
    }

    private static func ordinaryInputDoesNotPublishIdleAgain() {
        let fake = FakeQuickTriggerEnvironment()
        let context = ContextProbe()
        let (_, performCount, visuals) = makeCoordinator(fake: fake, contextProbe: context)
        expect(!fake.fireMouse(.leftDown), "ordinary mouse down is not consumed")
        expect(!fake.fireMouse(.leftUp), "ordinary mouse up is not consumed")
        fake.activeLocalKeyHandler?()
        expect(visuals().isEmpty, "idle ordinary input publishes no visual callback")

        fake.fireModifier(keyCode: 59, flags: .control, timestamp: 0.0)
        fake.fireModifier(keyCode: 55, flags: [.control, .command], timestamp: 0.1)
        expect(performCount() == 0, "other real modifier cancels active sequence")
        expect(visuals() == [.pressed, .idle], "pressed to idle publishes exactly once")
    }

    private static func staleContextAndCallbacksCannotPerform() {
        let fake = FakeQuickTriggerEnvironment()
        let context = ContextProbe()
        let (coordinator, performCount, visuals) = makeCoordinator(fake: fake, contextProbe: context)

        let stoppedModifierHandler = fake.globalHandlers[0]
        fake.fireModifier(keyCode: 59, flags: .control, timestamp: 0.0)
        fake.fireModifier(keyCode: 59, flags: [], timestamp: 0.1)
        let staleTimeout = fake.firstActiveScheduled(delay: 0.351)

        context.validIDs.insert(2)
        coordinator.start(context: context.context(2))
        let visualCountAfterReplacement = visuals().count
        fake.flushAsync()
        staleTimeout?.fire(evenIfCancelled: true)
        expect(performCount() == 0, "old release and timeout cannot operate new context")
        expect(visuals().count == visualCountAfterReplacement, "old callbacks cannot publish into new context")

        coordinator.stop()
        stoppedModifierHandler(
            QuickTriggerModifierEvent(keyCode: 59, modifierFlags: .control, timestamp: 0.2)
        )
        stoppedModifierHandler(
            QuickTriggerModifierEvent(keyCode: 59, modifierFlags: [], timestamp: 0.3)
        )
        fake.flushAsync()
        expect(performCount() == 0, "stopped monitor callback is permanently stale")
    }

    private static func settingsChangesReplaceTheOldSequence() {
        let fake = FakeQuickTriggerEnvironment()
        let context = ContextProbe()
        let (_, performCount, visuals) = makeCoordinator(fake: fake, contextProbe: context)
        fake.fireModifier(keyCode: 59, flags: .control, timestamp: 0.0)
        fake.settings.keyboardModifier = .command
        fake.settings.keyboardMode = .singleTap
        fake.fireModifier(keyCode: 59, flags: [], timestamp: 0.1)
        expect(fake.globalRemoveCount == 0, "settings callback defers monitor replacement")
        fake.flushAsync()

        expect(fake.globalInstallCount == 2, "settings change replaces modifier monitors once")
        expect(fake.globalRemoveCount == 1, "settings change removes old modifier monitor")
        expect(performCount() == 0, "old settings sequence cannot perform")
        expect(visuals().last == .idle, "settings change resets active visual state")

        fake.fireModifier(keyCode: 55, flags: .command, timestamp: 0.2)
        fake.fireModifier(keyCode: 55, flags: [], timestamp: 0.3)
        fake.flushAsync()
        expect(performCount() == 1, "replacement settings handle the next sequence")

        let mouseFake = FakeQuickTriggerEnvironment()
        let mouseContext = ContextProbe()
        let (_, mousePerformCount, _) = makeCoordinator(
            fake: mouseFake,
            contextProbe: mouseContext
        )
        mouseFake.settings.keyboardMode = .singleTap
        expect(!mouseFake.fireMouse(.leftDown), "settings-changing ordinary mouse input is not consumed")
        expect(
            mouseFake.mouseRemoveCount == 0,
            "mouse callback does not mutate the shared listener registry while it is dispatching"
        )
        mouseFake.flushAsync()
        expect(mouseFake.mouseRemoveCount == 1, "deferred refresh removes the old mouse listener")
        expect(mouseFake.mouseInstallCount == 2, "deferred refresh installs one replacement listener")
        expect(mousePerformCount() == 0, "settings refresh does not perform an Action")
    }

    private static func sideButtonPairsOnceAndRejectsStaleUp() {
        let fake = FakeQuickTriggerEnvironment()
        let context = ContextProbe()
        let (coordinator, performCount, visuals) = makeCoordinator(fake: fake, contextProbe: context)
        expect(fake.fireMouse(.otherDown, button: 3), "configured side-button down is consumed")
        fake.flushAsync()
        expect(performCount() == 0, "side button does not perform on down")
        expect(fake.fireMouse(.otherUp, button: 3), "matching side-button up is consumed")
        fake.flushAsync()
        expect(performCount() == 1, "matching side-button pair performs exactly once")
        expect(visuals() == [.pressed, .idle], "side-button visual changes are deduplicated")

        expect(fake.fireMouse(.otherDown, button: 3), "second side-button down locks context")
        fake.flushAsync()
        context.validIDs.insert(2)
        coordinator.start(context: context.context(2))
        expect(!fake.fireMouse(.otherUp, button: 3), "old context mouseUp is not routed")
        fake.flushAsync()
        expect(performCount() == 1, "old context mouseUp cannot perform")

        expect(fake.fireMouse(.otherDown, button: 3), "new context accepts a fresh side-button down")
        fake.flushAsync()
        let stoppedMouseHandler = fake.activeMouseHandler
        coordinator.stop()
        expect(
            stoppedMouseHandler?(QuickTriggerMouseEvent(kind: .otherUp, button: 3)) == false,
            "stopped mouse listener callback is permanently stale"
        )
        fake.flushAsync()
        expect(performCount() == 1, "mouseUp delivered after stop cannot perform")
    }

    private static func disabledInputsDoNotTrigger() {
        let fake = FakeQuickTriggerEnvironment()
        fake.settings.keyboardModifier = .disabled
        fake.settings.mouseButton = nil
        let context = ContextProbe()
        let (_, performCount, visuals) = makeCoordinator(fake: fake, contextProbe: context)

        expect(fake.globalInstallCount == 0, "disabled keyboard installs no global modifier monitor")
        expect(fake.localModifierInstallCount == 0, "disabled keyboard installs no local modifier monitor")
        expect(!fake.fireMouse(.otherDown, button: 3), "unconfigured side button is not consumed")
        expect(!fake.fireMouse(.otherUp, button: 3), "unconfigured side-button up is not consumed")
        fake.flushAsync()
        expect(performCount() == 0, "disabled keyboard and unconfigured mouse never perform")
        expect(visuals().isEmpty, "disabled inputs publish no visual updates")
    }

    private static func ineligibleContextDoesNotInstallUntilEligible() {
        let fake = FakeQuickTriggerEnvironment()
        let context = ContextProbe()
        context.validIDs.insert(1)
        context.canPerform = false
        fake.modifierFlags = .control
        let coordinator = QuickTriggerCoordinator(environment: fake.makeEnvironment())
        var visuals: [QuickTriggerVisualState] = []
        var performCount = 0
        coordinator.onPerformPrimary = { performCount += 1 }
        coordinator.onVisualStateChanged = { visuals.append($0) }
        coordinator.start(context: context.context(1))
        expect(fake.globalInstallCount == 0, "no Action installs no modifier monitor")
        expect(fake.mouseInstallCount == 0, "no Action installs no mouse listener")
        expect(visuals.isEmpty, "ineligible idle context publishes nothing")

        context.canPerform = true
        coordinator.start(context: context.context(1))
        expect(fake.globalInstallCount == 1, "same context installs once when Action becomes available")
        expect(fake.mouseInstallCount == 1, "eligible context installs shared mouse listener")
        fake.fireModifier(keyCode: 59, flags: [], timestamp: 0.1)
        fake.flushAsync()
        expect(performCount == 0, "newly eligible context suppresses a pre-held modifier release")
    }
}
