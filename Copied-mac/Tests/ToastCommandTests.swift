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
        clipboardTextPolicySelectsFallbackAction()
        dismissSurfaceVisibilityMatchesAnimationBehavior()
        panelConfigurationSupportsNonactivatingFirstMouse()
        expandedTextSurfaceScopesKeyBehavior()
        expandedTextMetricsAreBounded()
        expandedTextDocumentReservesBottomBarClearance()
        expandedWindowReservesShadowOutsetWithoutChangingContentSize()
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

    private static func clipboardTextPolicySelectsFallbackAction() {
        expect(
            ClipboardTextPolicy.fallback(for: String(repeating: "字", count: 49)) == .search,
            "49 characters stay searchable"
        )
        expect(
            ClipboardTextPolicy.fallback(for: String(repeating: "字", count: 50)) == .saveAs,
            "50 characters prefer Save As"
        )
    }

    private static func dismissSurfaceVisibilityMatchesAnimationBehavior() {
        expect(
            !ToastDismissSurfacePolicy.shouldHideImmediately(
                animated: true,
                isExpanded: true
            ),
            "animated expanded dismissal keeps native layers visible during blur"
        )
        expect(
            ToastDismissSurfacePolicy.shouldHideImmediately(
                animated: true,
                isExpanded: false
            ),
            "animated collapsed dismissal has no expanded layers to preserve"
        )
        expect(
            ToastDismissSurfacePolicy.shouldHideImmediately(
                animated: false,
                isExpanded: true
            ),
            "non-animated dismissal hides expanded layers immediately"
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
        expect(!hosting.needsPanelToBecomeKey, "ordinary SwiftUI controls keep panel non-key")
    }

    private static func expandedTextSurfaceScopesKeyBehavior() {
        let textView = ToastExpandedTextView(frame: .zero)
        expect(textView.needsPanelToBecomeKey, "native text interaction may make panel key")
        expect(textView.acceptsFirstMouse(for: nil), "native text accepts first mouse")

        let visualHosting = ToastVisualHostingView(rootView: AnyView(EmptyView()))
        expect(visualHosting.hitTest(.zero) == nil, "glass-only hosting never owns mouse input")
    }

    private static func expandedTextMetricsAreBounded() {
        let shortHeight = ExpandedTextLayoutMetrics.totalHeight(for: "short")
        let longHeight = ExpandedTextLayoutMetrics.totalHeight(
            for: String(repeating: "long expanded text ", count: 500)
        )
        expect(shortHeight >= ExpandedTextLayoutMetrics.bottomReservedHeight, "short text reserves controls")
        expect(longHeight > shortHeight, "long text grows before the cap")
        expect(longHeight == ExpandedTextLayoutMetrics.maxTotalHeight, "long text is capped")
        expect(
            ExpandedTextLayoutMetrics.viewportHeight(for: "short")
                + ExpandedTextLayoutMetrics.topInset == shortHeight,
            "native text viewport extends behind the bottom bar"
        )
    }

    private static func expandedTextDocumentReservesBottomBarClearance() {
        let viewportHeight: CGFloat = 288
        let usedTextMaxY: CGFloat = 605
        let documentHeight = ExpandedTextLayoutMetrics.documentHeight(
            viewportHeight: viewportHeight,
            usedTextMaxY: usedTextMaxY
        )
        expect(
            documentHeight == 669,
            "native text layout keeps the full bottom clearance"
        )
        expect(
            ExpandedTextLayoutMetrics.bottomReservedHeight
                > ExpandedTextLayoutMetrics.bottomBarVisualHeight,
            "the final line stops above the overlaid bottom bar"
        )
        expect(
            ExpandedTextLayoutMetrics.documentHeight(
                viewportHeight: viewportHeight,
                usedTextMaxY: 100
            ) == viewportHeight,
            "short native text does not create unnecessary scrolling"
        )
    }

    private static func expandedWindowReservesShadowOutsetWithoutChangingContentSize() {
        let contentSize = NSSize(width: 396, height: 197)
        expect(
            ExpandedWindowLayoutMetrics.windowSize(
                for: contentSize,
                isExpanded: false
            ) == contentSize,
            "collapsed window keeps its original bounds"
        )
        let expandedSize = ExpandedWindowLayoutMetrics.windowSize(
            for: contentSize,
            isExpanded: true
        )
        expect(
            expandedSize == NSSize(width: 428, height: 229),
            "expanded window adds transparent room for the shadow"
        )
        let hostingFrame = ExpandedWindowLayoutMetrics.hostingFrame(
            for: contentSize,
            isExpanded: true
        )
        expect(
            hostingFrame == NSRect(x: 16, y: 16, width: 396, height: 197),
            "expanded content keeps its size and moves inward as one surface"
        )
    }

    private static func productionWiringUsesOneCommandPath() {
        let controller = try! String(contentsOfFile: "ToastWindowController.swift", encoding: .utf8)
        let quickTrigger = try! String(
            contentsOfFile: "QuickTriggerCoordinator.swift",
            encoding: .utf8
        )
        let view = try! String(contentsOfFile: "ToastView.swift", encoding: .utf8)
        expect(controller.contains("private func handleCommand("), "controller has one command receiver")
        expect(controller.contains("onCommand:"), "controller injects the command receiver")
        expect(controller.contains("QuickTriggerCoordinator"), "controller delegates quick trigger ownership")
        expect(
            controller.contains("handleCommand(.performPrimary)"),
            "coordinator intent enters the unified primary command path"
        )
        expect(
            controller.contains("guard !viewModel.isExpanded else"),
            "expanded text never starts the automatic dismiss timer"
        )
        expect(controller.contains("quickTriggerCoordinator.suspend()"), "expand suspends quick trigger")
        expect(
            controller.contains("quickTriggerCoordinator.resume(context:"),
            "collapse completion resumes quick trigger"
        )
        expect(controller.contains("quickTriggerCoordinator.stop()"), "dismiss stops quick trigger")
        for forbiddenDetail in [
            "globalTriggerModifierMonitor",
            "localTriggerModifierMonitor",
            "localOtherEventMonitor",
            "mouseEventListenerToken",
            "keyboardQuickTrigger",
            "modifierKeyPolicy",
            "mouseQuickTrigger",
            "quickTriggerTimeout",
            "quickTriggerHIDPoll",
            "captureQuickTriggerEventCounters",
        ] {
            expect(
                !controller.contains(forbiddenDetail),
                "controller no longer owns \(forbiddenDetail)"
            )
        }
        expect(
            !controller.contains("GlobalMouseEventCoordinator.shared.addListener"),
            "controller does not register the shared mouse listener"
        )
        expect(
            !quickTrigger.contains("addLocalMonitorForEvents(matching: .leftMouse"),
            "quick trigger never adds a local left-mouse monitor"
        )
        expect(!controller.contains("addLocalMonitorForEvents(matching: .leftMouseUp)"), "window mouseUp routing is removed")
        expect(!controller.contains("ManualPrimaryActionEventGuard"), "manual primary guard is removed")
        expect(!controller.contains("CollapsedToastMouseUpPolicy"), "collapsed mouseUp policy is removed")
        expect(!controller.contains("isUpdateReminderHitRegion"), "update coordinate hit test is removed")
        expect(!controller.contains("findTextView"), "copy monitor view search is removed")
        expect(controller.contains("addSubview(scrollView, positioned: .above"), "native text is a sibling view")
        expect(controller.contains("bottomBarGlassHosting"), "glass renders between text and controls")
        expect(controller.contains("bottomBarControlsHosting"), "bottom controls keep their own command host")
        expect(!view.contains(".onTapGesture"), "SwiftUI uses explicit buttons instead of tap gestures")
        expect(!view.contains(".textSelection(.enabled)"), "expanded selection is not hosted by root SwiftUI")
        expect(!view.contains("onPreviewHoverChanged"), "preview hover is visual only")
        expect(!view.contains("onPrimaryActionHoverChanged"), "primary hover is visual only")
        expect(!view.contains("onExpandedActionHoverChanged"), "expanded hover is visual only")
        expect(
            view.components(separatedBy: "onCommand(.performPrimary)").count == 3,
            "primary and result buttons both emit the primary command"
        )
    }
}
