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

private final class LockedTestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    func set(_ value: Value) {
        lock.withLock { storage = value }
    }

    func get() -> Value {
        lock.withLock { storage }
    }
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
        pathologicalExpandedTextGeometryReturnsWithinWatchdog()
        expandedTextDocumentReservesBottomBarClearance()
        expandedWindowKeepsContentTopAlignedAndReservesShadowOutset()
        expandedTextTopCornersFollowLayerGeometry()
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
            ClipboardTextPolicy.fallback(textLength: 49) == .search,
            "49 characters stay searchable"
        )
        expect(
            ClipboardTextPolicy.fallback(textLength: 50) == .saveAs,
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
                + ExpandedTextLayoutMetrics.bottomBarVisualHeight == shortHeight,
            "native text viewport reaches the card top and ends above the bottom controls"
        )
    }

    private static func pathologicalExpandedTextGeometryReturnsWithinWatchdog() {
        let pathological = String(repeating: "aaaaaaaaaaaaaaa\n", count: 4_096)
        expect(pathological.utf16.count == 65_536, "pathological fixture reaches the display bound")

        let completion = DispatchSemaphore(value: 0)
        let measuredHeight = LockedTestValue<CGFloat?>(nil)
        DispatchQueue(label: "com.copied.tests.expanded-text-watchdog").async {
            measuredHeight.set(ExpandedTextLayoutMetrics.totalHeight(for: pathological))
            completion.signal()
        }

        let finished = completion.wait(timeout: .now() + 1) == .success
        expect(finished, "pathological expanded geometry returns within one second")
        expect(
            measuredHeight.get() == ExpandedTextLayoutMetrics.maxTotalHeight,
            "pathological expanded geometry uses the maximum shell height"
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
            documentHeight == 627,
            "native text layout keeps initial top and final-line spacing"
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
        let cap = ExpandedTextLayoutMetrics.maximumDocumentHeight
        expect(cap.isFinite && cap > viewportHeight,
               "native text document-height cap is not finite")
        expect(
            ExpandedTextLayoutMetrics.documentHeight(
                viewportHeight: viewportHeight,
                usedTextMaxY: cap * 2
            ) == cap,
            "native text document height exceeds the 65,536-derived cap"
        )
    }

    private static func expandedWindowKeepsContentTopAlignedAndReservesShadowOutset() {
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
            expandedSize == NSSize(width: 428, height: 213),
            "expanded window reserves horizontal and bottom shadow room"
        )
        let hostingFrame = ExpandedWindowLayoutMetrics.hostingFrame(
            for: contentSize,
            isExpanded: true
        )
        expect(
            hostingFrame == NSRect(x: 16, y: 16, width: 396, height: 197),
            "expanded content keeps its size and moves inward as one surface"
        )
        expect(
            hostingFrame.maxY == expandedSize.height,
            "expanded content top stays aligned with the window top"
        )
    }

    private static func expandedTextTopCornersFollowLayerGeometry() {
        expect(
            ExpandedTextCornerPolicy.topCorners(isGeometryFlipped: true)
                == [.layerMinXMinYCorner, .layerMaxXMinYCorner],
            "geometry-flipped layers use minY for the visual top"
        )
        expect(
            ExpandedTextCornerPolicy.topCorners(isGeometryFlipped: false)
                == [.layerMinXMaxYCorner, .layerMaxXMaxYCorner],
            "non-flipped layers use maxY for the visual top"
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
        expect(
            controller.contains("if self.isMouseInsideWindow() {\n                    self.pauseDismissTimer()"),
            "collapse completion pauses dismissal while the pointer remains inside"
        )
        expect(
            controller.contains("} else {\n                    self.startDismissTimer()"),
            "collapse completion restarts dismissal after the pointer leaves"
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
        expect(controller.contains("bottomBarControlsHosting"), "bottom controls keep their own command host")
        expect(!controller.contains("bottomBarGlassHosting"), "bottom controls have no separate background")
        expect(
            controller.contains("scrollView.layer?.cornerRadius = innerCornerRadius"),
            "native text top corners follow the card outline"
        )
        expect(
            controller.contains("ToastView.cardCornerRadius - ExpandedTextLayoutMetrics.horizontalInset"),
            "native text corner radius accounts for its horizontal inset"
        )
        expect(
            controller.contains("textView.textContainerInset = NSSize("),
            "initial text spacing lives inside the scrollable document"
        )
        expect(view.contains("y: cardFrame.minY,"), "native text viewport starts at the card edge")
        expect(controller.contains("private func focusExpandedText()"), "expanded text has one focus entry point")
        expect(controller.contains("window.makeFirstResponder(textView)"), "expanded text becomes first responder")
        expect(controller.contains("window.makeKey()"), "expanded panel becomes key")
        expect(controller.contains("window?.resignKey()"), "collapse releases expanded focus")
        expect(view.contains("Button(\"关闭\")"), "expanded controls expose an explicit close button")
        expect(view.contains(".buttonStyle(.bordered)"), "expanded controls use the native macOS bordered style")
        expect(!view.contains(".buttonStyle(.glass"), "expanded controls do not force Liquid Glass")
        expect(!view.contains(".onTapGesture"), "SwiftUI uses explicit buttons instead of tap gestures")
        expect(!view.contains(".textSelection(.enabled)"), "expanded selection is not hosted by root SwiftUI")
        expect(!view.contains("onPreviewHoverChanged"), "preview hover is visual only")
        expect(!view.contains("onPrimaryActionHoverChanged"), "primary hover is visual only")
        expect(!view.contains("onExpandedActionHoverChanged"), "expanded hover is visual only")
        expect(
            view.components(separatedBy: "onCommand(.performPrimary)").count == 2
                && view.contains("private var primaryButton:")
                && view.contains("resultOverlay.copyText != nil"),
            "shared primary/result button emits the primary command"
        )
    }
}
