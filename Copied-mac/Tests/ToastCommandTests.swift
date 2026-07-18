import AppKit
import Foundation
import SwiftUI

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private enum TestAction: Equatable {
    case primary
    case secondary
}

@main
struct ToastCommandTests {
    static func main() {
        commandKindsAreDistinct()
        dispatcherExecutesOnceAndRejectsReentry()
        actionDispositionMatchesPresentationBehavior()
        panelConfigurationSupportsNonactivatingFirstMouse()
        productionWiringUsesOneCommandPath()
        print("ToastCommandTests: PASS")
    }

    private static func commandKindsAreDistinct() {
        let commands: [ToastCommand<TestAction>] = [
            .performPrimary,
            .performAction(.secondary),
            .expand,
            .collapse,
            .dismiss,
            .editInTextEdit,
            .openUpdateAbout,
        ]
        expect(commands.map(\.kind) == ToastCommandKind.allCases, "all commands remain distinct")
        if case let .performAction(action) = commands[1] {
            expect(action == .secondary, "performAction preserves its action")
        } else {
            expect(false, "performAction command")
        }
    }

    private static func dispatcherExecutesOnceAndRejectsReentry() {
        let dispatcher = ToastCommandDispatcher<TestAction>()
        var executionCount = 0
        var nestedAccepted = true
        let accepted = dispatcher.dispatch(.performAction(.primary)) { command in
            executionCount += 1
            nestedAccepted = dispatcher.dispatch(command) { _ in executionCount += 1 }
        }
        expect(accepted, "first command is accepted")
        expect(!nestedAccepted, "same synchronous command cannot dispatch reentrantly")
        expect(executionCount == 1, "one dispatch executes one action")
    }

    private static func actionDispositionMatchesPresentationBehavior() {
        expect(
            ToastActionDisposition(performsInlineUpdate: true) == .keepPresented,
            "inline action keeps the toast presented"
        )
        expect(
            ToastActionDisposition(performsInlineUpdate: false) == .dismiss,
            "regular action dismisses the toast"
        )
    }

    private static func panelConfigurationSupportsNonactivatingFirstMouse() {
        let panel = ToastPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60))
        expect(panel.styleMask.contains(.borderless), "panel is borderless")
        expect(panel.styleMask.contains(.nonactivatingPanel), "panel is nonactivating")
        expect(panel.canBecomeKey, "panel can become key for text interaction")
        expect(!panel.canBecomeMain, "panel cannot become main")
        expect(panel.becomesKeyOnlyIfNeeded, "panel becomes key only when needed")
        expect(panel.isFloatingPanel, "panel is floating")
        expect(!panel.hidesOnDeactivate, "panel remains visible on source-app activity")

        let hosting = ToastHostingView(rootView: AnyView(EmptyView()))
        expect(hosting.acceptsFirstMouse(for: nil), "hosting view accepts first mouse")
    }

    private static func productionWiringUsesOneCommandPath() {
        let controller = try! String(contentsOfFile: "ToastWindowController.swift", encoding: .utf8)
        let view = try! String(contentsOfFile: "ToastView.swift", encoding: .utf8)
        expect(controller.contains("private func handleCommand("), "controller has one command receiver")
        expect(controller.contains("onCommand:"), "controller injects the command receiver")
        expect(!controller.contains("addLocalMonitorForEvents(matching: .leftMouseUp)"), "window mouseUp routing is removed")
        expect(!controller.contains("ManualPrimaryActionEventGuard"), "manual primary guard is removed")
        expect(!controller.contains("CollapsedToastMouseUpPolicy"), "collapsed mouseUp policy is removed")
        expect(!controller.contains("isUpdateReminderHitRegion"), "update coordinate hit test is removed")
        expect(!controller.contains("findTextView"), "copy monitor view search is removed")
        expect(!view.contains(".onTapGesture"), "SwiftUI uses explicit buttons instead of tap gestures")
        expect(!view.contains("onPreviewHoverChanged"), "preview hover is visual only")
        expect(!view.contains("onPrimaryActionHoverChanged"), "primary hover is visual only")
        expect(!view.contains("onExpandedActionHoverChanged"), "expanded hover is visual only")
        expect(
            view.components(separatedBy: "onCommand(.performPrimary)").count == 3,
            "primary and result buttons both emit the primary command"
        )
    }
}
