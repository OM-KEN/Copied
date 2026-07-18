import Foundation
import AppKit

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

        expect(!QuickTriggerVisualState.idle.shouldPublishIdleReset, "idle does not publish an idle reset")
        expect(QuickTriggerVisualState.pressed.shouldPublishIdleReset, "pressed publishes an idle reset")
        expect(
            QuickTriggerVisualState.waitingForSecondTap.shouldPublishIdleReset,
            "waiting publishes an idle reset"
        )

        var staleFlagPolicy = QuickTriggerModifierKeyPolicy(targetModifier: .control)
        staleFlagPolicy.appeared(preExisting: false)
        var staleFlagSingle = KeyboardQuickTriggerStateMachine(mode: .singleTap)
        staleFlagSingle.appeared(preExisting: false)
        expect(
            staleFlagPolicy.handleFlagsChanged(
                keyCode: 59,
                eventFlags: [.control, .function, .numericPad],
                sequenceActive: false
            ) == .targetDown,
            "Control keyCode wins over stale Function/NumericPad flags"
        )
        _ = staleFlagSingle.targetChanged(isDown: true, at: 0, counters: base, context: 1)
        expect(
            staleFlagPolicy.handleFlagsChanged(
                keyCode: 59,
                eventFlags: [.function, .numericPad],
                sequenceActive: true
            ) == .targetUp,
            "Control release ignores stale Function/NumericPad flags"
        )
        expect(staleFlagSingle.targetChanged(isDown: false, at: 0.1, counters: base, context: 1), "stale flags still allow single tap")

        var heldRepeatPolicy = QuickTriggerModifierKeyPolicy(targetModifier: .control)
        heldRepeatPolicy.appeared(preExisting: false)
        expect(
            heldRepeatPolicy.handleFlagsChanged(
                keyCode: 59,
                eventFlags: [.control, .function, .numericPad],
                sequenceActive: false
            ) == .targetDown,
            "initial held Control event is a down transition"
        )
        expect(
            heldRepeatPolicy.handleFlagsChanged(
                keyCode: 59,
                eventFlags: [.control, .function, .numericPad],
                sequenceActive: true
            ) == .ignore,
            "repeated flagsChanged while Control remains held is ignored"
        )
        expect(heldRepeatPolicy.isAnyTargetKeyDown, "held repeat keeps target down")
        expect(
            heldRepeatPolicy.handleFlagsChanged(
                keyCode: 59,
                eventFlags: [.function, .numericPad],
                sequenceActive: true
            ) == .targetUp,
            "Control flag disappearance is the release transition"
        )

        var staleDoublePolicy = QuickTriggerModifierKeyPolicy(targetModifier: .control)
        staleDoublePolicy.appeared(preExisting: false)
        var staleDouble = KeyboardQuickTriggerStateMachine(mode: .doubleTap)
        staleDouble.appeared(preExisting: false)
        for (isDown, time) in [(true, 0.0), (false, 0.1), (true, 0.2)] {
            let flags: NSEvent.ModifierFlags = isDown
                ? [.control, .function, .numericPad]
                : [.function, .numericPad]
            let decision = staleDoublePolicy.handleFlagsChanged(
                keyCode: 59,
                eventFlags: flags,
                sequenceActive: staleDouble.visualState != .idle
            )
            expect(decision == (isDown ? .targetDown : .targetUp), "double-tap target transition")
            _ = staleDouble.targetChanged(isDown: isDown, at: time, counters: base, context: 1)
        }
        expect(
            staleDoublePolicy.handleFlagsChanged(
                keyCode: 59,
                eventFlags: [.function, .numericPad],
                sequenceActive: true
            ) == .targetUp,
            "second stale release"
        )
        expect(staleDouble.targetChanged(isDown: false, at: 0.3, counters: base, context: 1), "stale flags still allow double tap")

        for otherKeyCode: UInt16 in [55, 58, 56, 57, 63] {
            var policy = QuickTriggerModifierKeyPolicy(targetModifier: .control)
            policy.appeared(preExisting: false)
            expect(policy.handleFlagsChanged(keyCode: 59, eventFlags: .control, sequenceActive: false) == .targetDown, "target starts")
            expect(
                policy.handleFlagsChanged(keyCode: otherKeyCode, eventFlags: [], sequenceActive: true)
                    == .cancelOtherModifier(keyCode: otherKeyCode),
                "real modifier keyCode \(otherKeyCode) cancels active sequence"
            )
        }

        var idleOtherModifier = QuickTriggerModifierKeyPolicy(targetModifier: .control)
        idleOtherModifier.appeared(preExisting: false)
        expect(idleOtherModifier.handleFlagsChanged(keyCode: 55, eventFlags: .command, sequenceActive: false) == .ignore, "idle other modifier ignored")
        expect(!idleOtherModifier.isAnyTargetKeyDown, "idle other modifier does not stick target down")

        var preHeldPolicy = QuickTriggerModifierKeyPolicy(targetModifier: .control)
        preHeldPolicy.appeared(preExisting: true)
        var preHeldMachine = KeyboardQuickTriggerStateMachine(mode: .singleTap)
        preHeldMachine.appeared(preExisting: true)
        expect(
            preHeldPolicy.handleFlagsChanged(keyCode: 59, eventFlags: [.function, .numericPad], sequenceActive: false) == .targetUp,
            "pre-held target release classified"
        )
        expect(!preHeldMachine.targetChanged(isDown: false, at: 0.1, counters: base, context: 1), "pre-held target release ignored")

        var preHeldBothSides = QuickTriggerModifierKeyPolicy(targetModifier: .control)
        preHeldBothSides.appeared(preExisting: true)
        expect(preHeldBothSides.handleFlagsChanged(keyCode: 62, eventFlags: .control, sequenceActive: false) == .ignore, "pre-held second side is suppressed")
        expect(preHeldBothSides.handleFlagsChanged(keyCode: 59, eventFlags: .control, sequenceActive: false) == .ignore, "pre-held first side release waits")
        expect(preHeldBothSides.handleFlagsChanged(keyCode: 62, eventFlags: [], sequenceActive: false) == .targetUp, "pre-held both sides rearm after all release")
        expect(!preHeldBothSides.isAnyTargetKeyDown, "pre-held both sides cannot stick target state")

        var dualSidePolicy = QuickTriggerModifierKeyPolicy(targetModifier: .control)
        dualSidePolicy.appeared(preExisting: false)
        expect(dualSidePolicy.handleFlagsChanged(keyCode: 59, eventFlags: .control, sequenceActive: false) == .targetDown, "left Control down")
        expect(dualSidePolicy.handleFlagsChanged(keyCode: 62, eventFlags: .control, sequenceActive: true) == .cancelTargetSideConflict, "simultaneous Controls cancel")
        expect(dualSidePolicy.handleFlagsChanged(keyCode: 59, eventFlags: .control, sequenceActive: false) == .ignore, "first conflict release suppressed")
        expect(dualSidePolicy.handleFlagsChanged(keyCode: 62, eventFlags: [], sequenceActive: false) == .ignore, "all conflict keys release before rearm")
        expect(dualSidePolicy.handleFlagsChanged(keyCode: 59, eventFlags: .control, sequenceActive: false) == .targetDown, "rearmed after both release")

        var sideSwitchPolicy = QuickTriggerModifierKeyPolicy(targetModifier: .control)
        sideSwitchPolicy.appeared(preExisting: false)
        expect(sideSwitchPolicy.handleFlagsChanged(keyCode: 59, eventFlags: .control, sequenceActive: false) == .targetDown, "left starts sequence")
        expect(sideSwitchPolicy.handleFlagsChanged(keyCode: 59, eventFlags: [], sequenceActive: true) == .targetUp, "left releases")
        expect(sideSwitchPolicy.handleFlagsChanged(keyCode: 62, eventFlags: .control, sequenceActive: true) == .cancelTargetSideConflict, "switching target side mid-sequence cancels")

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
