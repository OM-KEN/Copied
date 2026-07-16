import Foundation

struct QuickTriggerEventCounters: Equatable {
    var keyDown: UInt32
    var leftMouseDown: UInt32
    var leftMouseUp: UInt32
    var rightMouseDown: UInt32
    var rightMouseUp: UInt32
    var otherMouseDown: UInt32
    var otherMouseUp: UInt32
    var scrollWheel: UInt32

    static let zero = QuickTriggerEventCounters(
        keyDown: 0,
        leftMouseDown: 0,
        leftMouseUp: 0,
        rightMouseDown: 0,
        rightMouseUp: 0,
        otherMouseDown: 0,
        otherMouseUp: 0,
        scrollWheel: 0
    )
}

enum QuickTriggerVisualState: Equatable {
    case idle
    case waitingForSecondTap
    case pressed
}

struct KeyboardQuickTriggerStateMachine {
    private enum Phase {
        case idle
        case ignoringPreExisting
        case firstPressed(counters: QuickTriggerEventCounters, context: Int)
        case waitingSecond(deadline: TimeInterval, counters: QuickTriggerEventCounters, context: Int)
        case secondPressed(counters: QuickTriggerEventCounters, context: Int)
    }

    let mode: KeyboardQuickTriggerMode
    let doubleTapWindow: TimeInterval
    private(set) var visualState: QuickTriggerVisualState = .idle
    private var phase: Phase = .idle

    init(mode: KeyboardQuickTriggerMode, doubleTapWindow: TimeInterval = 0.350) {
        self.mode = mode
        self.doubleTapWindow = doubleTapWindow
    }

    mutating func appeared(preExisting: Bool) {
        phase = preExisting ? .ignoringPreExisting : .idle
        visualState = .idle
    }

    mutating func targetChanged(
        isDown: Bool,
        at time: TimeInterval,
        counters: QuickTriggerEventCounters,
        context: Int
    ) -> Bool {
        let boundaryTolerance = 0.000_000_001
        if case let .waitingSecond(deadline, baseline, savedContext) = phase,
           time - deadline > boundaryTolerance {
            phase = .idle
            visualState = .idle
            if isDown {
                phase = .firstPressed(counters: counters, context: context)
                visualState = .pressed
            }
            _ = baseline
            _ = savedContext
            return false
        }

        switch (phase, isDown) {
        case (.ignoringPreExisting, false):
            phase = .idle
            visualState = .idle
            return false

        case (.ignoringPreExisting, true):
            return false

        case (.idle, true):
            phase = .firstPressed(counters: counters, context: context)
            visualState = .pressed
            return false

        case let (.firstPressed(baseline, savedContext), false):
            guard counters == baseline, context == savedContext else {
                cancel()
                return false
            }
            if mode == .singleTap {
                cancel()
                return true
            }
            phase = .waitingSecond(
                deadline: time + doubleTapWindow,
                counters: baseline,
                context: savedContext
            )
            visualState = .waitingForSecondTap
            return false

        case let (.waitingSecond(deadline, baseline, savedContext), true):
            guard time - deadline <= boundaryTolerance,
                  counters == baseline,
                  context == savedContext else {
                cancel()
                return false
            }
            phase = .secondPressed(counters: baseline, context: savedContext)
            visualState = .pressed
            return false

        case let (.secondPressed(baseline, savedContext), false):
            guard counters == baseline, context == savedContext else {
                cancel()
                return false
            }
            cancel()
            return true

        default:
            return false
        }
    }

    mutating func tick(at time: TimeInterval) {
        guard case let .waitingSecond(deadline, _, _) = phase, time > deadline else { return }
        cancel()
    }

    @discardableResult
    mutating func validate(counters: QuickTriggerEventCounters, context: Int) -> Bool {
        let isValid: Bool
        switch phase {
        case .idle, .ignoringPreExisting:
            isValid = true
        case let .firstPressed(baseline, savedContext),
             let .waitingSecond(_, baseline, savedContext),
             let .secondPressed(baseline, savedContext):
            isValid = counters == baseline && context == savedContext
        }
        if !isValid { cancel() }
        return isValid
    }

    mutating func cancel() {
        phase = .idle
        visualState = .idle
    }

    mutating func contextChanged() {
        cancel()
    }
}

struct MouseQuickTriggerStateMachine {
    private struct PressedState {
        let button: Int
        let context: Int
        var isValid: Bool
    }

    private var pressed: PressedState?

    mutating func mouseDown(button: Int, configuredButton: Int?, context: Int, canPerform: Bool) -> Bool {
        guard let configuredButton,
              configuredButton >= 3,
              button == configuredButton,
              canPerform else { return false }
        pressed = PressedState(button: button, context: context, isValid: true)
        return true
    }

    mutating func mouseUp(button: Int, context: Int) -> (consume: Bool, trigger: Bool) {
        guard let current = pressed, current.button == button else {
            return (false, false)
        }
        pressed = nil
        return (true, current.isValid && current.context == context)
    }

    mutating func cancelPendingTrigger() {
        pressed?.isValid = false
    }

    mutating func reset() {
        pressed = nil
    }
}
