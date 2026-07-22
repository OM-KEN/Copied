import Foundation
import CoreGraphics

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct InteractionWiringTests {
    static func main() {
        expect(
            GlobalMouseEventTapRecoveryPolicy.action(
                for: .tapDisabledByTimeout,
                accessibilityTrusted: true
            ) == .reenable,
            "a timeout may recover while Accessibility permission remains valid"
        )
        expect(
            GlobalMouseEventTapRecoveryPolicy.action(
                for: .tapDisabledByTimeout,
                accessibilityTrusted: false
            ) == .keepDisabled,
            "a timeout cannot recover after Accessibility permission is lost"
        )
        expect(
            GlobalMouseEventTapRecoveryPolicy.action(
                for: .tapDisabledByUserInput,
                accessibilityTrusted: true
            ) == .keepDisabled,
            "a user-disabled tap is never re-enabled"
        )
        expect(
            GlobalMouseEventTapRecoveryPolicy.action(
                for: .tapDisabledByUserInput,
                accessibilityTrusted: false
            ) == .keepDisabled,
            "permission revocation keeps the tap disabled"
        )

        let sequence = CopyGestureEventSequence.commandC
        expect(sequence.count == 4, "Command-C uses four physical-style events")
        expect(sequence[0] == .init(virtualKey: CopyGestureEventSequence.commandKey, isKeyDown: true, flags: .maskCommand), "Command down first")
        expect(sequence[1] == .init(virtualKey: CopyGestureEventSequence.cKey, isKeyDown: true, flags: .maskCommand), "C down second")
        expect(sequence[2] == .init(virtualKey: CopyGestureEventSequence.cKey, isKeyDown: false, flags: .maskCommand), "C up third")
        expect(sequence[3] == .init(virtualKey: CopyGestureEventSequence.commandKey, isKeyDown: false, flags: []), "final Command up clears flags")

        var recorder = MouseButtonRecordingStateMachine()
        expect(!recorder.start(accessibilityTrusted: false), "untrusted recorder does not enter recording state")
        expect(!recorder.isRecording, "untrusted recorder cannot get stuck")
        expect(recorder.start(accessibilityTrusted: true), "trusted recorder starts")
        expect(recorder.handleOtherMouseDown(button: 2) == .ignore, "button below 3 is ignored")
        expect(recorder.isRecording, "ignored button keeps recording")
        expect(recorder.handleOtherMouseDown(button: 4) == .bind(button: 4), "native side button binds")
        expect(!recorder.isRecording, "binding completes recording")
        _ = recorder.start(accessibilityTrusted: true)
        recorder.cancel()
        expect(!recorder.isRecording, "explicit cancel stops recording")

        expect(MenuVersionTextFormatter.string(version: "2.9.1", hasUpdate: false) == "版本 2.9.1", "single menu version string")
        expect(MenuVersionTextFormatter.string(version: "2.9.1", hasUpdate: true) == "版本 2.9.1 · 有新版本", "single update menu string")

        print("InteractionWiringTests: PASS")
    }
}
