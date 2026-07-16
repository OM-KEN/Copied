import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct QuickTriggerStateMachineTests {
    static func main() {
        let base = QuickTriggerEventCounters.zero

        expect(
            QuickTriggerModifierPolicy.hasInterferingModifier(
                eventFlags: [.control, .capsLock],
                triggerFlags: .control
            ),
            "Caps Lock cancels a Control quick-trigger sequence"
        )
        expect(
            !QuickTriggerModifierPolicy.hasInterferingModifier(
                eventFlags: .control,
                triggerFlags: .control
            ),
            "the configured modifier is not interference"
        )
        var capsLockCancellation = KeyboardQuickTriggerStateMachine(mode: .singleTap)
        capsLockCancellation.appeared(preExisting: false)
        _ = capsLockCancellation.targetChanged(isDown: true, at: 0, counters: base, context: 1)
        if QuickTriggerModifierPolicy.hasInterferingModifier(
            eventFlags: [.control, .capsLock],
            triggerFlags: .control
        ) {
            capsLockCancellation.cancel()
        }
        expect(
            !capsLockCancellation.targetChanged(isDown: false, at: 0.1, counters: base, context: 1),
            "Caps Lock cancellation prevents release from triggering"
        )

        var exactBoundary = KeyboardQuickTriggerStateMachine(mode: .doubleTap)
        exactBoundary.appeared(preExisting: false)
        expect(!exactBoundary.targetChanged(isDown: true, at: 0, counters: base, context: 1), "first down")
        expect(!exactBoundary.targetChanged(isDown: false, at: 0.1, counters: base, context: 1), "first up")
        expect(exactBoundary.visualState == .waitingForSecondTap, "waiting highlight")
        expect(!exactBoundary.targetChanged(isDown: true, at: 0.45, counters: base, context: 1), "350 ms boundary second down")
        expect(exactBoundary.targetChanged(isDown: false, at: 0.5, counters: base, context: 1), "second release triggers")

        var late = KeyboardQuickTriggerStateMachine(mode: .doubleTap)
        late.appeared(preExisting: false)
        _ = late.targetChanged(isDown: true, at: 0, counters: base, context: 1)
        _ = late.targetChanged(isDown: false, at: 0.1, counters: base, context: 1)
        expect(!late.targetChanged(isDown: true, at: 0.451, counters: base, context: 1), "late press begins a new first tap")
        expect(late.visualState == .pressed, "late press is a fresh sequence")

        var cancelled = KeyboardQuickTriggerStateMachine(mode: .doubleTap)
        cancelled.appeared(preExisting: false)
        _ = cancelled.targetChanged(isDown: true, at: 0, counters: base, context: 1)
        var keyboardChanged = base
        keyboardChanged.keyDown = 1
        expect(!cancelled.targetChanged(isDown: false, at: 0.1, counters: keyboardChanged, context: 1), "ordinary key cancels")
        expect(cancelled.visualState == .idle, "cancel clears visual state")

        var waitingCancellation = KeyboardQuickTriggerStateMachine(mode: .doubleTap)
        waitingCancellation.appeared(preExisting: false)
        _ = waitingCancellation.targetChanged(isDown: true, at: 0, counters: base, context: 1)
        _ = waitingCancellation.targetChanged(isDown: false, at: 0.1, counters: base, context: 1)
        var scrolled = base
        scrolled.scrollWheel = 1
        expect(!waitingCancellation.validate(counters: scrolled, context: 1), "scroll cancels while waiting")
        expect(waitingCancellation.visualState == .idle, "HID polling clears waiting highlight")

        var single = KeyboardQuickTriggerStateMachine(mode: .singleTap)
        single.appeared(preExisting: false)
        _ = single.targetChanged(isDown: true, at: 0, counters: base, context: 7)
        expect(single.targetChanged(isDown: false, at: 0.1, counters: base, context: 7), "single mode triggers on release")

        var preExisting = KeyboardQuickTriggerStateMachine(mode: .singleTap)
        preExisting.appeared(preExisting: true)
        expect(!preExisting.targetChanged(isDown: false, at: 0.1, counters: base, context: 1), "pre-held release ignored")

        var actionChanged = KeyboardQuickTriggerStateMachine(mode: .doubleTap)
        actionChanged.appeared(preExisting: false)
        _ = actionChanged.targetChanged(isDown: true, at: 0, counters: base, context: 1)
        _ = actionChanged.targetChanged(isDown: false, at: 0.1, counters: base, context: 1)
        actionChanged.contextChanged()
        expect(!actionChanged.targetChanged(isDown: true, at: 0.2, counters: base, context: 2), "action change cancels waiting tap")

        var mouse = MouseQuickTriggerStateMachine()
        expect(mouse.mouseDown(button: 4, configuredButton: 4, context: 9, canPerform: true), "matching side-button down consumed")
        let mouseResult = mouse.mouseUp(button: 4, context: 9)
        expect(mouseResult.consume && mouseResult.trigger, "matching pair triggers on release")
        expect(!mouse.mouseDown(button: 2, configuredButton: 4, context: 9, canPerform: true), "non-side button ignored")
        expect(mouse.mouseDown(button: 5, configuredButton: 5, context: 10, canPerform: true), "second pair locks")
        mouse.cancelPendingTrigger()
        let cancelledMouse = mouse.mouseUp(button: 5, context: 11)
        expect(cancelledMouse.consume && !cancelledMouse.trigger, "matching up remains consumed after context change")

        print("QuickTriggerStateMachineTests: PASS")
    }
}
