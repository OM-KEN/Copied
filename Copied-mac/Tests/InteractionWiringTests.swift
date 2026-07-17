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

        expect(
            CollapsedToastMouseUpPolicy.decide(
                isPrimaryActionHovered: true,
                isPreviewHovered: false
            ) == .performPrimaryAction,
            "primary action mouseUp is routed by the controller"
        )
        expect(
            CollapsedToastMouseUpPolicy.decide(
                isPrimaryActionHovered: false,
                isPreviewHovered: true
            ) == .expandPreview,
            "preview mouseUp expands the toast"
        )
        expect(
            CollapsedToastMouseUpPolicy.decide(
                isPrimaryActionHovered: false,
                isPreviewHovered: false
            ) == .dismiss,
            "background mouseUp dismisses the toast"
        )

        var manualActionGuard = ManualPrimaryActionEventGuard()
        manualActionGuard.begin(eventNumber: 42)
        expect(
            !manualActionGuard.consumeIfMatching(eventNumber: nil),
            "callbacks without the manual mouse event are never suppressed"
        )
        expect(
            !manualActionGuard.consumeIfMatching(eventNumber: 43),
            "different event is never suppressed"
        )
        expect(
            manualActionGuard.consumeIfMatching(eventNumber: 42),
            "matching SwiftUI callback is suppressed once"
        )
        expect(
            !manualActionGuard.consumeIfMatching(eventNumber: 42),
            "matching callback cannot be suppressed twice"
        )
        manualActionGuard.begin(eventNumber: 44)
        manualActionGuard.clear(eventNumber: 44)
        expect(
            !manualActionGuard.consumeIfMatching(eventNumber: 44),
            "guard expires when the event run loop completes"
        )

        print("InteractionWiringTests: PASS")
    }
}
