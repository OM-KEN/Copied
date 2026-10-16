import CoreGraphics
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private let sourcePID: Int32 = 101
private let otherPID: Int32 = 202

private extension CopyGestureStateMachine {
    mutating func handle(_ type: CGEventType, frontmostPID: Int32?) -> (consume: Bool, request: Request?) {
        handle(type, frontmostPID: frontmostPID, frontmostBundleIdentifier: "com.apple.finder")
    }
}

private func releasedRequest(_ state: inout CopyGestureStateMachine) -> CopyGestureStateMachine.Request {
    _ = state.handle(.leftMouseDown, frontmostPID: sourcePID)
    _ = state.handle(.rightMouseDown, frontmostPID: sourcePID)
    return state.handle(.leftMouseUp, frontmostPID: sourcePID).request!
}

@main
struct CopyGestureStateMachineTests {
    static func main() {
        thirdPartyCopiesBeforeLeftRelease()
        consecutiveGesturesUseTheirOwnSourceTiming()
        timingIsBoundWhenTheGestureIsRecognized()
        olderSystemsKeepImmediateTimingForEverySource()
        waitsForReleaseAndConsumesOnlyOnce()
        rightUpFallbackWaitsForRelease()
        leftReleaseBeforeRightDoesNotTrigger()
        nextLeftDownInvalidatesWaitingAndScheduledRequests()
        resetInvalidatesWaitingAndScheduledRequests()
        sourceActivationPreservesLeftPress()
        applicationSwitchCancelsWaitingAndScheduledRequests()
        targetMustMatchAtReleaseAndSend()
        olderSystemsRequestCopyBeforeRelease()
        missingTargetDoesNotRequestCopy()
        print("CopyGestureStateMachineTests passed")
    }

    private static func thirdPartyCopiesBeforeLeftRelease() {
        var state = CopyGestureStateMachine(isMacOS27OrLater: true)
        _ = state.handle(.leftMouseDown, frontmostPID: sourcePID,
                         frontmostBundleIdentifier: "com.google.Chrome")
        let rightDown = state.handle(.rightMouseDown, frontmostPID: sourcePID,
                                     frontmostBundleIdentifier: "com.google.Chrome")
        expect(rightDown.consume && rightDown.request != nil,
               "macOS 27 third-party Chrome must copy without releasing left button")
        expect(state.consume(rightDown.request!, frontmostPID: sourcePID),
               "third-party request can send while left is still pressed")
    }

    private static func consecutiveGesturesUseTheirOwnSourceTiming() {
        var state = CopyGestureStateMachine(isMacOS27OrLater: true)
        let sources: [(String?, Bool)] = [
            ("com.apple.finder", true),
            ("com.google.Chrome", false),
            ("com.apple.TextEdit", true),
            ("com.todoist.mac.Todoist", false),
            ("com.apple.Safari", true),
            (nil, false),
            ("", false),
            ("com.applelike.editor", false)
        ]
        for (bundle, waitsForRelease) in sources {
            _ = state.handle(.leftMouseDown, frontmostPID: sourcePID, frontmostBundleIdentifier: bundle)
            let down = state.handle(.rightMouseDown, frontmostPID: sourcePID, frontmostBundleIdentifier: bundle)
            expect(down.consume, "each recognized right down is swallowed")
            expect((down.request == nil) == waitsForRelease, "source determines timing for this gesture: \(bundle ?? "nil")")
            if let request = down.request {
                expect(state.consume(request, frontmostPID: sourcePID), "immediate copy sends while left is held")
            }
            let up = state.handle(.leftMouseUp, frontmostPID: sourcePID, frontmostBundleIdentifier: bundle)
            expect((up.request != nil) == waitsForRelease, "left up emits only the waiting source's copy")
            if let request = up.request {
                expect(state.consume(request, frontmostPID: sourcePID), "system source sends after release")
            }
        }
    }

    private static func timingIsBoundWhenTheGestureIsRecognized() {
        var state = CopyGestureStateMachine(isMacOS27OrLater: true)
        _ = state.handle(.leftMouseDown, frontmostPID: otherPID, frontmostBundleIdentifier: "com.apple.finder")
        state.cancelPendingCopy()
        let thirdParty = state.handle(.rightMouseDown, frontmostPID: sourcePID, frontmostBundleIdentifier: "com.google.Chrome")
        expect(thirdParty.request != nil, "source activated before recognition selects its own immediate timing")
        expect(state.consume(thirdParty.request!, frontmostPID: sourcePID), "recognized third party can send immediately")

        _ = state.handle(.leftMouseDown, frontmostPID: otherPID, frontmostBundleIdentifier: "com.google.Chrome")
        state.cancelPendingCopy()
        let system = state.handle(.rightMouseDown, frontmostPID: sourcePID, frontmostBundleIdentifier: "com.apple.TextEdit")
        expect(system.request == nil, "system source activated before recognition selects waiting timing")
        let release = state.handle(.leftMouseUp, frontmostPID: sourcePID, frontmostBundleIdentifier: nil)
        expect(release.request != nil, "later unavailable bundle metadata cannot change recognized waiting timing")
        expect(state.consume(release.request!, frontmostPID: sourcePID), "original target remains bound")
    }

    private static func olderSystemsKeepImmediateTimingForEverySource() {
        for bundle: String? in ["com.apple.finder", "com.google.Chrome", nil] {
            var state = CopyGestureStateMachine(isMacOS27OrLater: false)
            _ = state.handle(.leftMouseDown, frontmostPID: sourcePID, frontmostBundleIdentifier: bundle)
            let rightDown = state.handle(.rightMouseDown, frontmostPID: sourcePID, frontmostBundleIdentifier: bundle)
            expect(rightDown.request != nil, "older systems never wait for release")
            expect(state.consume(rightDown.request!, frontmostPID: sourcePID), "older source copies while left is held")
        }
    }

    private static func waitsForReleaseAndConsumesOnlyOnce() {
        var state = CopyGestureStateMachine(isMacOS27OrLater: true)
        let leftDown = state.handle(.leftMouseDown, frontmostPID: sourcePID)
        expect(!leftDown.consume && leftDown.request == nil, "left down passes through")
        let rightDown = state.handle(.rightMouseDown, frontmostPID: sourcePID)
        expect(rightDown.consume, "recognized right down is swallowed")
        expect(rightDown.request == nil, "macOS 27 copy must wait for left release")
        for event: CGEventType in [.rightMouseDown, .rightMouseUp, .rightMouseUp] {
            expect(state.handle(event, frontmostPID: sourcePID).request == nil,
                   "repeated right events cannot schedule another copy")
        }
        let leftUp = state.handle(.leftMouseUp, frontmostPID: sourcePID)
        expect(!leftUp.consume, "real left up reaches the source app before delayed copy")
        expect(leftUp.request?.targetPID == sourcePID, "left up emits the original target request")
        expect(state.handle(.leftMouseUp, frontmostPID: sourcePID).request == nil,
               "duplicate left up cannot emit another request")
        expect(state.consume(leftUp.request!, frontmostPID: sourcePID), "released request can send")
        expect(!state.consume(leftUp.request!, frontmostPID: sourcePID), "request sends at most once")
    }

    private static func rightUpFallbackWaitsForRelease() {
        var state = CopyGestureStateMachine(isMacOS27OrLater: true)
        _ = state.handle(.leftMouseDown, frontmostPID: sourcePID)
        let fallback = state.handle(.rightMouseUp, frontmostPID: sourcePID)
        expect(!fallback.consume && fallback.request == nil, "missing right down uses a pending fallback")
        expect(state.handle(.rightMouseUp, frontmostPID: sourcePID).request == nil,
               "repeated fallback remains pending")
        let request = state.handle(.leftMouseUp, frontmostPID: sourcePID).request
        expect(request != nil, "right up fallback emits on left release")
        expect(state.consume(request!, frontmostPID: sourcePID), "fallback sends once")
    }

    private static func leftReleaseBeforeRightDoesNotTrigger() {
        var state = CopyGestureStateMachine(isMacOS27OrLater: true)
        _ = state.handle(.leftMouseDown, frontmostPID: sourcePID)
        _ = state.handle(.leftMouseUp, frontmostPID: sourcePID)
        for event: CGEventType in [.rightMouseDown, .rightMouseUp] {
            let result = state.handle(event, frontmostPID: sourcePID)
            expect(!result.consume && result.request == nil, "right events after left release do not trigger")
        }
    }

    private static func nextLeftDownInvalidatesWaitingAndScheduledRequests() {
        var state = CopyGestureStateMachine(isMacOS27OrLater: true)
        _ = state.handle(.leftMouseDown, frontmostPID: sourcePID)
        _ = state.handle(.rightMouseDown, frontmostPID: sourcePID)
        _ = state.handle(.leftMouseDown, frontmostPID: sourcePID)
        expect(state.handle(.leftMouseUp, frontmostPID: sourcePID).request == nil,
               "new left down drops the prior waiting request")

        let scheduled = releasedRequest(&state)
        _ = state.handle(.leftMouseDown, frontmostPID: sourcePID)
        expect(!state.consume(scheduled, frontmostPID: sourcePID), "new press invalidates delayed send")
        _ = state.handle(.rightMouseDown, frontmostPID: sourcePID)
        let next = state.handle(.leftMouseUp, frontmostPID: sourcePID).request!
        expect(state.consume(next, frontmostPID: sourcePID), "new gesture remains usable")
    }

    private static func resetInvalidatesWaitingAndScheduledRequests() {
        var state = CopyGestureStateMachine(isMacOS27OrLater: true)
        _ = state.handle(.leftMouseDown, frontmostPID: sourcePID)
        _ = state.handle(.rightMouseDown, frontmostPID: sourcePID)
        state.reset()
        expect(state.handle(.leftMouseUp, frontmostPID: sourcePID).request == nil,
               "stop/reset removes waiting copy")
        expect(state.handle(.rightMouseUp, frontmostPID: sourcePID).request == nil,
               "reset clears left press so a late fallback cannot fire")
        let scheduled = releasedRequest(&state)
        state.reset()
        expect(!state.consume(scheduled, frontmostPID: sourcePID), "stop/reset invalidates scheduled copy")
    }

    private static func sourceActivationPreservesLeftPress() {
        var state = CopyGestureStateMachine(isMacOS27OrLater: true)
        _ = state.handle(.leftMouseDown, frontmostPID: otherPID)
        state.cancelPendingCopy()
        let rightDown = state.handle(.rightMouseDown, frontmostPID: sourcePID)
        expect(rightDown.consume, "activating the clicked source app preserves the initial left down")
        let request = state.handle(.leftMouseUp, frontmostPID: sourcePID).request
        expect(request != nil && state.consume(request!, frontmostPID: sourcePID),
               "selection gesture survives source activation before right down")
    }

    private static func applicationSwitchCancelsWaitingAndScheduledRequests() {
        var state = CopyGestureStateMachine(isMacOS27OrLater: true)
        _ = state.handle(.leftMouseDown, frontmostPID: sourcePID)
        _ = state.handle(.rightMouseDown, frontmostPID: sourcePID)
        state.cancelPendingCopy()
        expect(state.handle(.rightMouseUp, frontmostPID: otherPID).request == nil,
               "activation cancellation cannot create a new right up fallback")
        state.cancelPendingCopy()
        expect(state.handle(.leftMouseUp, frontmostPID: sourcePID).request == nil,
               "switching away and back cancels waiting copy")
        let scheduled = releasedRequest(&state)
        state.cancelPendingCopy()
        state.cancelPendingCopy()
        expect(!state.consume(scheduled, frontmostPID: sourcePID),
               "switching away and back cancels scheduled copy")
    }

    private static func targetMustMatchAtReleaseAndSend() {
        var state = CopyGestureStateMachine(isMacOS27OrLater: true)
        _ = state.handle(.leftMouseDown, frontmostPID: sourcePID)
        _ = state.handle(.rightMouseDown, frontmostPID: sourcePID)
        expect(state.handle(.leftMouseUp, frontmostPID: otherPID).request == nil,
               "release in a different app cannot schedule copy")
        let scheduled = releasedRequest(&state)
        expect(!state.consume(scheduled, frontmostPID: otherPID), "target is checked immediately before send")
        expect(!state.consume(scheduled, frontmostPID: sourcePID), "target mismatch invalidates request permanently")
    }

    private static func olderSystemsRequestCopyBeforeRelease() {
        var state = CopyGestureStateMachine(isMacOS27OrLater: false)
        _ = state.handle(.leftMouseDown, frontmostPID: sourcePID)
        let rightDown = state.handle(.rightMouseDown, frontmostPID: sourcePID)
        expect(rightDown.consume && rightDown.request != nil, "older systems schedule on right down")
        expect(state.handle(.rightMouseUp, frontmostPID: sourcePID).request == nil, "right up does not repeat copy")
        expect(state.handle(.leftMouseUp, frontmostPID: sourcePID).request == nil, "left up does not repeat copy")
        expect(state.consume(rightDown.request!, frontmostPID: sourcePID), "early left release preserves scheduled copy")

        _ = state.handle(.leftMouseDown, frontmostPID: sourcePID)
        let fallback = state.handle(.rightMouseUp, frontmostPID: sourcePID)
        expect(!fallback.consume && fallback.request != nil, "older right up fallback still schedules immediately")
        expect(state.consume(fallback.request!, frontmostPID: sourcePID), "older fallback sends")
    }

    private static func missingTargetDoesNotRequestCopy() {
        var state = CopyGestureStateMachine(isMacOS27OrLater: true)
        _ = state.handle(.leftMouseDown, frontmostPID: nil)
        _ = state.handle(.rightMouseDown, frontmostPID: nil)
        expect(state.handle(.leftMouseUp, frontmostPID: sourcePID).request == nil,
               "a later front app cannot acquire an unidentified target's request")
    }
}
