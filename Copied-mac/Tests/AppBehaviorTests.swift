import AppKit
import Foundation
import SwiftUI

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private final class ReplayClock {
    var now: TimeInterval = 10_000
}

private final class ReplayFixture {
    let suite = "CopiedReplayTests.\(UUID().uuidString)"
    let clock = ReplayClock()
    let defaults: UserDefaults
    let filter: AppFilterSettings
    let store: LastToastStore
    let controller: ToastWindowController
    let source = SourceAppInfo(name: "Synthetic original source", icon: nil, bundleIdentifier: "test.replay-source")

    init() {
        defaults = UserDefaults(suiteName: suite)!
        filter = AppFilterSettings(defaults: defaults)
        let clock = clock
        store = LastToastStore(defaults: defaults, filterSettings: filter, now: { clock.now })
        controller = ToastWindowController(lastToastStore: store)
    }

    deinit {
        controller.dismissToast(animated: false)
        store.clear()
        defaults.removePersistentDomain(forName: suite)
    }

    func content(_ generation: UInt64 = 100, text: String = "Synthetic copied text") -> ClipboardContent {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(text, forType: .string)
        let revision = ClipboardRevision(generation: generation, changeCount: pasteboard.changeCount)
        guard case let .content(_, content) = ClipboardBaseReader.read(
            session: ClipboardLoadSession(revision: revision, backingScale: 2), pasteboard: pasteboard
        ) else { fatalError("synthetic replay fixture read failed") }
        return content
    }

    func budgetContent(
        _ generation: UInt64 = 900, rawText: String? = nil,
        fullText: String = "", displayText: String = "",
        fileURLs: [URL]? = nil, imageFormat: String? = nil
    ) -> ClipboardContent {
        let base = content(generation)
        return ClipboardContent(
            revision: base.revision, type: .text, preview: "", detail: "", detailIsLoading: false,
            thumbnail: nil, fileURLs: fileURLs, rawText: rawText, contentKind: nil, detections: [],
            imageFormat: imageFormat, litheMetadata: base.litheMetadata, textLength: 0,
            fileURLCount: fileURLs?.count ?? 0, fileSelectionWasTruncated: false, allFilesAreImages: nil,
            displayTypeLabel: "", displayIconSymbolName: "", expandedDisplayText: displayText,
            expandedFullText: fullText, expandedTextWasTruncated: false
        )
    }
}

private final class ToastTransitionTestRunner: NSObject, NSApplicationDelegate {
    private var footerProbeWindow: NSWindow?
    private var footerProbe: ToastHostingView?
    private struct Sample {
        let expanded: Bool
        let appKitAlpha: Double
        let serverAlpha: Double
        let visible: Bool
        let key: Bool
    }

    private struct FooterImage {
        let pixels: Data
        let width: Int
        let height: Int

        func averageDifference(from other: FooterImage) -> Double {
            guard width == other.width, height == other.height,
                  pixels.count == other.pixels.count else { return .infinity }
            return zip(pixels, other.pixels).reduce(0.0) {
                $0 + abs(Double($1.0) - Double($1.1))
            } / Double(pixels.count)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            await verifyTransitions()
            print("ToastTransitionTests: PASS")
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private func verifyTransitions() async {
        expect(NSApp.isRunning, "transition tests require a running native AppKit application")
        let fixture = ReplayFixture()
        let controller = fixture.controller
        let probe = ToastHostingView(rootView: AnyView(ExpandedBottomBarControlsView(
            viewModel: controller.testingViewModel,
            onHoverChanged: { _ in }, onCommand: { _ in }
        )))
        probe.frame = NSRect(x: 0, y: 0, width: 360, height: 54)
        let probeWindow = NSWindow(
            contentRect: probe.frame, styleMask: .borderless,
            backing: .buffered, defer: false
        )
        probeWindow.contentView = probe
        footerProbeWindow = probeWindow
        footerProbe = probe
        for cycle in 0..<3 {
            let content = fixture.content(UInt64(1_000 + cycle), text: "Synthetic transition\nSecond synthetic line")
            controller.show(content: content, source: fixture.source)
            controller.startDismissTimer(after: 10)
            try? await Task.sleep(for: .milliseconds(450))

            controller.testingPerformCommand(.expand)
            controller.testingPerformCommand(.collapse)
            controller.testingPerformCommand(.dismiss)
            controller.testingPerformCommand(.editInTextEdit)
            let expanding = await samples(from: controller, captureFooter: { sample in
                sample.expanded && sample.serverAlpha > 0.25 && sample.serverAlpha < 0.75
            })
            verifyFade(expanding.values.filter(\.expanded), name: "expanded text")
            expect(controller.testingWindow?.isKeyWindow == true,
                   "expanded text did not acquire native key ownership")
            guard let firstVisibleFooter = expanding.footer,
                  let settledFooter = footerImage() else {
                fatalError("expanded footer was not rendered during the visible fade-in")
            }
            let expansionDifference = firstVisibleFooter.averageDifference(from: settledFooter)
            expect(expansionDifference < 0.5,
                   "expanded footer changed appearance after becoming visible")

            controller.testingPerformCommand(.collapse)
            controller.testingPerformCommand(.dismiss)
            controller.testingPerformCommand(.editInTextEdit)
            let collapsing = await samples(from: controller, captureFooter: { sample in
                sample.expanded && sample.serverAlpha > 0.25 && sample.serverAlpha < 0.75
            })
            let collapsed = collapsing.values.filter { !$0.expanded }
            verifyFade(collapsed, name: "collapsed card")
            guard let fadingOutFooter = collapsing.footer else {
                fatalError("expanded footer was not rendered during fade-out")
            }
            let collapseDifference = fadingOutFooter.averageDifference(from: settledFooter)
            expect(collapseDifference < 0.5,
                   "expanded footer changed appearance before fading out")
            expect(!collapsed.isEmpty && collapsed.allSatisfy { !$0.key },
                   "collapsed card retained native key ownership during fade-in")
            expect(controller.testingWindow?.isKeyWindow == false,
                   "collapsed card retained native key ownership after fade-in")
        }
        let longContent = fixture.content(2_000, text: String(repeating: "x", count: 2_200))
        controller.show(content: longContent, source: fixture.source)
        controller.startDismissTimer(after: 10)
        try? await Task.sleep(for: .milliseconds(450))
        expect(controller.testingViewModel.expandedText.utf16.count > 2_048,
               "synthetic long preview did not reach the deferred-layout path")
        controller.testingPerformCommand(.expand)
        let longExpansion = await samples(from: controller, captureFooter: { sample in
            sample.expanded && controller.testingViewModel.isExpandedTextLoading
                && sample.serverAlpha > 0.25 && sample.serverAlpha < 0.75
        })
        verifyFade(longExpansion.values.filter(\.expanded), name: "long expanded text")
        expect(!controller.testingViewModel.isExpandedTextLoading,
               "long text remained in the loading state after layout")
        guard let loadingFooter = longExpansion.footer,
              let readyFooter = footerImage() else {
            fatalError("long expanded footer did not render in both loading states")
        }
        let loadingDifference = loadingFooter.averageDifference(from: readyFooter)
        expect(loadingDifference > 2,
               "long expanded footer did not appear disabled while loading")
        controller.dismissToast(animated: false)
    }

    @MainActor
    private func samples(
        from controller: ToastWindowController,
        captureFooter: (Sample) -> Bool
    ) async -> (values: [Sample], footer: FooterImage?) {
        var values: [Sample] = []
        var footer: FooterImage?
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard let window = controller.testingWindow,
                  let windows = CGWindowListCopyWindowInfo(
                    .optionIncludingWindow, CGWindowID(window.windowNumber)
                  ) as? [[String: Any]],
                  let info = windows.first,
                  let alpha = info[kCGWindowAlpha as String] as? Double else {
                fatalError("transition window is unavailable from WindowServer")
            }
            let sample = Sample(
                expanded: controller.testingViewModel.isExpanded,
                appKitAlpha: Double(window.alphaValue), serverAlpha: alpha,
                visible: window.isVisible, key: window.isKeyWindow
            )
            values.append(sample)
            if footer == nil && captureFooter(sample) {
                if controller.testingExpandedBottomBarControlsHostingView?.isHidden == false {
                    footer = footerImage()
                }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return (values, footer)
    }

    private func footerImage() -> FooterImage? {
        guard let hosting = footerProbe,
              let bitmap = hosting.bitmapImageRepForCachingDisplay(
                in: NSRect(x: 0, y: 0, width: 150, height: 54)
              ) else {
            return nil
        }
        hosting.layoutSubtreeIfNeeded()
        hosting.cacheDisplay(in: NSRect(x: 0, y: 0, width: 150, height: 54), to: bitmap)
        guard let bytes = bitmap.bitmapData else { return nil }
        return FooterImage(
            pixels: Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh),
            width: bitmap.pixelsWide, height: bitmap.pixelsHigh
        )
    }

    private func verifyFade(_ samples: [Sample], name: String) {
        expect(samples.contains { $0.serverAlpha < 0.02 },
               "\(name) did not start its visible transition from transparent")
        expect(samples.filter { $0.visible && $0.serverAlpha > 0.02 && $0.serverAlpha < 0.98 }.count >= 2,
               "\(name) skipped the actual WindowServer fade-in frames")
        expect(samples.contains { $0.appKitAlpha > 0.02 && $0.appKitAlpha < 0.98 },
               "\(name) skipped the AppKit fade-in frames")
        expect(samples.last.map { $0.visible && $0.serverAlpha > 0.98 && $0.appKitAlpha > 0.98 } == true,
               "\(name) did not finish fully visible")
    }
}

private struct ReplayProbeAction: ClipboardAction {
    let id: String
    let onPerform: () -> Void
    var title: String { "Synthetic" }
    var systemImage: String { "checkmark" }
    var menuTitle: String { "Synthetic action" }
    func perform(content: ClipboardContent, controller: ToastWindowController?) { onPerform() }
}

private struct LongTitleLayoutAction: ClipboardAction {
    let id = "synthetic.long-title-layout"
    let title = String(repeating: "Long plugin action title ", count: 8)
    let systemImage = "wand.and.stars"
    var menuTitle: String { title }
    func perform(content: ClipboardContent, controller: ToastWindowController?) {}
}

private struct ActionLayoutSample {
    let text: NSSize
    let button: NSSize
    let preview: NSSize
    let sourceViewport: NSSize
    let fitting: NSSize
}

@main
struct AppBehaviorTests {
    static func main() throws {
        if CommandLine.arguments.contains("--toast-transitions") {
            let app = NSApplication.shared
            let runner = ToastTransitionTestRunner()
            app.setActivationPolicy(.accessory)
            app.delegate = runner
            withExtendedLifetime(runner) { app.run() }
            return
        }
        settingsRequestsSurviveAbsentMenu()
        pauseControlsMonitorLifetime()
        try reminderRejectsCopiedContent()
        closingReminderPreservesCopySoundWork()
        searchPreservesQuery()
        emptyResultsHaveNoCopyAction()
        inlineResultsFitProductionWindow()
        inlineActionButtonsKeepReadableTitle()
        try textFallbackPreservesUnicodeBoundary()
        try pluginReplacementIsValidatedBeforeInstallation()
        replayRequiresShownReadyContent()
        replayKeepsContentActionsAndResults()
        replayExpirationDoesNotRenew()
        replayExpirationReleasesContentInTrackingMode()
        replayHonorsCurrentPrivacySettings()
        replayRejectsOldCallbacksAndYieldsToNewCopy()
        replayPreservesExpandedCardAndRestartsCollapsedLifetime()
        replayIgnoresFilteredCopies()
        try replayHasNoAutomaticClipboardOrSoundWork()
        replayBudgetHasExactUTF8Boundaries()
        replayBudgetCountsRetainedFieldsAndAllActions()
        replayBudgetRejectsIndependentActionPayloads()
        replayBudgetResultOverflowReleasesAndCannotRevive()
        try replayBudgetCountsThumbnailRepresentations()
        print("AppBehaviorTests: PASS")
    }

    private static func settingsRequestsSurviveAbsentMenu() {
        SettingsNavigation.requestSettings()
        var opens = 0
        SettingsNavigation.installSettingsOpener { opens += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        expect(opens == 1, "request before scene registration was lost")
        SettingsNavigation.requestSettings()
        expect(opens == 2, "registered settings action cannot reopen without menu")
        SettingsNavigation.installSettingsOpener { opens += 10 }
        expect(opens == 2, "installing commands opened Settings on cold launch")
        SettingsNavigation.requestSettings()
        expect(opens == 12, "new scene action was not retained")
        SettingsNavigation.installSettingsOpener {}
    }

    private static func pauseControlsMonitorLifetime() {
        let controller = ToastWindowController()
        let monitor = ClipboardMonitor(toastController: controller)
        let delegate = AppDelegate(monitor: monitor)
        delegate.setPaused(false)
        expect(monitor.isRunning, "resume did not start the production monitor timer")
        delegate.setPaused(true)
        expect(!monitor.isRunning, "pause left the production monitor timer running")
        delegate.setPaused(false)
        expect(monitor.isRunning, "resume after pause did not restart monitoring")
        delegate.setPaused(true)
    }

    private static func reminderRejectsCopiedContent() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Synthetic private copied content", forType: .string)
        let oldRevision = ClipboardRevision(generation: 10, changeCount: pasteboard.changeCount)
        guard case let .content(_, content) = ClipboardBaseReader.read(
            session: ClipboardLoadSession(revision: oldRevision, backingScale: 2),
            pasteboard: pasteboard
        ) else { fatalError("synthetic reminder fixture read failed") }
        let source = SourceAppInfo(name: "Synthetic source", icon: nil, bundleIdentifier: "test.synthetic")
        let model = ToastViewModel()
        model.configure(with: content, source: source)
        model.showsUpdateReminder = true
        model.thumbnailImage = NSImage(size: NSSize(width: 1, height: 1))
        model.detectedColor = .red
        model.resultOverlay = ResultOverlay(displayText: "Synthetic result", copyText: "Synthetic result")
        let action = SearchTextAction(text: "synthetic")
        model.applyActions(primary: action, menu: [action])
        for revision in [oldRevision, ClipboardRevision(generation: 11, changeCount: 999)] {
            model.configureReminderNotice(revision: revision)
            expect(!model.acceptsContentUpdate(revision: revision), "base read can overwrite reminder")
            expect(!model.acceptsContentUpdate(revision: oldRevision), "stale base read can overwrite reminder")
            model.applyEnrichment(content)
            model.applyActions(primary: action, menu: [action])
            model.showLoadingIfPending()
            model.configureFailure()
            expect(model.phase == .reminder && model.previewText == String(localized: "已复制"),
                   "late update changed generic reminder")
            expect(model.sourceAppName.isEmpty && model.sourceBundleID == nil && model.sourceAppIcon == nil,
                   "reminder leaked source identity")
            expect(model.rawContent == nil && model.thumbnailImage == nil && model.detailInfo.isEmpty && model.detectedColor == nil && model.resultOverlay == nil,
                   "reminder retained content or thumbnail")
            expect(model.primaryAction == nil && model.menuActions.isEmpty && model.blacklistAction == nil,
                   "reminder exposes an action")
            expect(!model.canExpand && !model.showsUpdateReminder && model.expandedText.isEmpty,
                   "reminder exposes expanded content or update")
            expect(model.iconSymbolName == "checkmark.circle.fill", "reminder lost generic icon")
        }
        model.configurePending(revision: oldRevision, source: source)
        expect(model.acceptsContentUpdate(revision: oldRevision), "switching back to full card is blocked")
        model.configure(with: content, source: source)
        expect(model.isContentReady && model.rawContent != nil, "full card no longer accepts real content")
    }

    private static func closingReminderPreservesCopySoundWork() {
        let controller = ToastWindowController()
        let revision = ClipboardRevision(generation: 12, changeCount: 1000)
        var cancelled: [ClipboardRevision] = []
        controller.onRevisionResourcesShouldCancel = { cancelled.append($0) }
        controller.showReminder(revision: revision)
        controller.dismissSilently(revision: revision)
        expect(cancelled.isEmpty, "closing a reminder cancelled the base read and copy sound timeout")

        let source = SourceAppInfo(name: "Synthetic source", icon: nil, bundleIdentifier: "test.synthetic")
        controller.showPending(revision: revision, source: source)
        controller.dismissSilently(revision: revision)
        expect(cancelled == [revision], "closing a full card no longer cancels its content work")
    }

    private static func searchPreservesQuery() {
        for engine in ["google", "baidu", "bing", "duckduckgo", "unknown"] {
            for text in ["a&b#c+d=e", "空 格 %20 /?", "👨‍👩‍👧‍👦\nSwift"] {
                let url = SearchTextAction.url(for: text, engine: engine)!
                let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                expect(parts.queryItems?.count == 1, "search introduced extra query parameters")
                expect(parts.queryItems?.first?.value == text, "search changed the copied query")
                expect(parts.queryItems?.first?.name == (engine == "baidu" ? "wd" : "q"),
                       "search engine query parameter changed")
                expect(parts.fragment == nil, "search query escaped into a fragment")
                expect(!parts.percentEncodedQuery!.contains("+"), "literal plus may be decoded as space")
            }
        }
    }

    private static func emptyResultsHaveNoCopyAction() {
        expect(ResultOverlay(displayText: "empty", copyText: "").copyText == nil,
               "empty transform still offers Copy")
        expect(ResultOverlay(displayText: "error", copyText: nil).copyText == nil,
               "error result offers Copy")
        expect(ResultOverlay(displayText: "space", copyText: " ").copyText == " ",
               "nonempty whitespace result changed")
    }

    private static func inlineResultsFitProductionWindow() {
        let pluginResult = "Synthetic first line\nSynthetic second line\nSynthetic third line"
        let transform = PluginAction(
            detection: ContentDetection(kind: .plain, value: "seed"),
            template: PluginActionTemplate(
                type: .transform, title: "转换", icon: "arrow.triangle.2.circlepath",
                template: nil, transformPattern: "^seed$",
                transformReplacement: pluginResult, menuOnly: true
            )
        )
        let emptyTransform = PluginAction(
            detection: ContentDetection(kind: .plain, value: "seed"),
            template: PluginActionTemplate(
                type: .transform, title: "转换", icon: "arrow.triangle.2.circlepath",
                template: nil, transformPattern: "^seed$",
                transformReplacement: "", menuOnly: true
            )
        )
        let cases: [(text: String, action: any ClipboardAction, copyText: String?, expanded: Bool)] = [
            ("1+1", CalculateAction(expression: "1+1"), "2", false),
            ("1/3", CalculateAction(expression: "1/3"), "0.333333333333", false),
            ("1/0", CalculateAction(expression: "1/0"), nil, false),
            ("中", ShowPinyinAction(character: "中"), "zhōng", false),
            ("seed", transform, pluginResult, false),
            ("seed", emptyTransform, nil, false),
            ("synthetic word", LookupAction(definition: pluginResult), pluginResult, false),
            ("seed", transform, pluginResult, true),
        ]
        let source = SourceAppInfo(name: "S", icon: nil, bundleIdentifier: "test.synthetic")
        for (index, testCase) in cases.enumerated() {
            let fixture = ReplayFixture()
            let controller = fixture.controller
            let content = fixture.content(UInt64(800 + index), text: testCase.text)
            let usesMenu = testCase.action is PluginAction
            controller.show(content: content, source: source)
            controller.applyActions(primary: usesMenu ? nil : testCase.action,
                                    menu: [testCase.action], revision: content.revision)
            RunLoop.main.run(until: Date().addingTimeInterval(0.40))
            if testCase.expanded {
                controller.testingPerformCommand(.expand)
                RunLoop.main.run(until: Date().addingTimeInterval(0.60))
            }
            let originalWindow = controller.testingWindow!
            let originalHosting = originalWindow.contentView!.subviews.first!
            let originalContentTop = originalWindow.frame.minY + originalHosting.frame.maxY
            controller.testingPerformCommand(usesMenu ? .performAction(testCase.action) : .performPrimary)
            RunLoop.main.run(until: Date().addingTimeInterval(0.40))
            guard let result = controller.testingViewModel.resultOverlay,
                  let window = controller.testingWindow,
                  let hosting = window.contentView?.subviews.first else {
                fatalError("production inline action did not present a result")
            }
            expect(result.copyText == testCase.copyText,
                   "production inline action changed its copy payload")
            let fittingSize = hosting.fittingSize
            expect(abs(hosting.frame.width - fittingSize.width) < 0.5
                   && abs(hosting.frame.height - fittingSize.height) < 0.5,
                   "inline action resized the panel without fitting its production hosting view")
            let windowSize = ExpandedWindowLayoutMetrics.windowSize(
                for: fittingSize, isExpanded: testCase.expanded
            )
            expect(abs(window.frame.width - windowSize.width) < 0.5
                   && abs(window.frame.height - windowSize.height) < 0.5,
                   "inline result panel lost its content or expanded shadow dimensions")
            expect(abs(window.frame.minY + hosting.frame.maxY - originalContentTop) < 0.5,
                   "inline action moved the card's content away from its screen anchor")
            if testCase.expanded {
                let scrollView = window.contentView?.subviews
                    .compactMap { $0 as? ToastExpandedTextScrollView }.first
                let textView = scrollView?.documentView as? NSTextView
                expect(textView?.string == result.displayText,
                       "expanded inline result did not update the native text surface")
            }
        }
    }

    private static func inlineActionButtonsKeepReadableTitle() {
        let cases: [(name: String, source: String, icon: Bool, detail: String, longAction: Bool)] = [
            ("short", "S", false, "", false),
            ("normal", "TextEdit", true, "数学表达式", false),
            ("long-source", String(repeating: "Source", count: 20), false, "", false),
            ("long-action", "S", false, "", true),
            ("both-long", String(repeating: "Source", count: 20), false, "", true),
        ]
        var samples: [String: ActionLayoutSample] = [:]
        defer { ToastActionGeometryProbe.onMeasure = nil }

        for (index, testCase) in cases.enumerated() {
            let fixture = ReplayFixture()
            let controller = fixture.controller
            var content = fixture.content(UInt64(2_100 + index), text: "1+1")
            content.detail = testCase.detail
            content.displayTypeLabel = ""
            let icon = testCase.icon ? NSImage(size: NSSize(width: 16, height: 16)) : nil
            let source = SourceAppInfo(
                name: testCase.source, icon: icon, bundleIdentifier: "test.action-layout"
            )
            let action: any ClipboardAction = testCase.longAction
                ? LongTitleLayoutAction() : CalculateAction(expression: "1+1")
            var measured: [String: NSSize] = [:]
            ToastActionGeometryProbe.onMeasure = { metric, size in measured[metric] = size }

            controller.show(content: content, source: source)
            controller.applyActions(primary: action, menu: [], revision: content.revision)
            RunLoop.main.run(until: Date().addingTimeInterval(0.40))
            guard let title = measured["actionTitle"],
                  let button = measured["button"],
                  let preview = measured["preview"],
                  let sourceViewport = measured["sourceViewport"],
                  let fitting = controller.testingWindow?.contentView?.subviews.first?.fittingSize else {
                fatalError("production action title did not render in \(testCase.name) card")
            }
            samples["\(testCase.name)-action"] = ActionLayoutSample(
                text: title, button: button, preview: preview,
                sourceViewport: sourceViewport, fitting: fitting
            )

            if !testCase.longAction {
                measured.removeAll()
                controller.testingPerformCommand(.performPrimary)
                RunLoop.main.run(until: Date().addingTimeInterval(0.40))
                guard controller.testingViewModel.resultOverlay?.copyText == "2",
                      let copyText = measured["copyText"],
                      let copyButton = measured["button"],
                      let copyFitting = controller.testingWindow?.contentView?.subviews.first?.fittingSize else {
                    fatalError("production calculate-to-copy button did not render in \(testCase.name) card")
                }
                samples["\(testCase.name)-copy"] = ActionLayoutSample(
                    text: copyText, button: copyButton, preview: preview,
                    sourceViewport: sourceViewport, fitting: copyFitting
                )
            }
            controller.dismissToast(animated: false)
        }

        guard let shortAction = samples["short-action"],
              let shortCopy = samples["short-copy"],
              let normalAction = samples["normal-action"],
              let normalCopy = samples["normal-copy"],
              let longSourceAction = samples["long-source-action"],
              let longSourceCopy = samples["long-source-copy"],
              let longAction = samples["long-action-action"],
              let bothLong = samples["both-long-action"] else {
            fatalError("production action layout matrix is incomplete")
        }
        expect(abs(shortAction.text.width - normalAction.text.width) < 0.5,
               "short card compressed Calculate title: \(shortAction.text.width) vs \(normalAction.text.width)")
        expect(abs(shortCopy.text.width - normalCopy.text.width) < 0.5
               && abs(shortCopy.text.height - normalCopy.text.height) < 0.5,
               "short card wrapped Copy title: \(shortCopy.text) vs \(normalCopy.text)")
        expect(abs(shortAction.button.width - normalAction.button.width) < 0.5
               && abs(shortCopy.button.height - normalCopy.button.height) < 0.5,
               "short card compressed its production action button")
        expect(abs(longSourceAction.text.width - normalAction.text.width) < 0.5
               && abs(longSourceCopy.text.width - normalCopy.text.width) < 0.5,
               "long source changed the action title layout")
        expect(normalAction.fitting.width > shortAction.fitting.width
               && longSourceAction.fitting.width <= 396.5
               && longSourceCopy.fitting.width <= 396.5
               && longAction.fitting.width <= 396.5
               && bothLong.fitting.width <= 396.5,
               "content fitting lost its natural width or 360pt card cap")
        let intrinsicLongTitleWidth = (LongTitleLayoutAction().title as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
        ).width
        expect(longAction.text.height <= normalAction.text.height + 0.5
               && longAction.text.width < intrinsicLongTitleWidth
               && longAction.preview.width >= shortAction.preview.width - 0.5
               && longAction.sourceViewport.width >= shortAction.sourceViewport.width - 0.5
               && bothLong.text.height <= normalAction.text.height + 0.5
               && bothLong.preview.width >= shortAction.preview.width - 0.5
               && bothLong.sourceViewport.width > 0,
               "long action lost single-line truncation or displaced the preview: text=\(longAction.text), natural=\(intrinsicLongTitleWidth), preview=\(longAction.preview), shortPreview=\(shortAction.preview)")

        for (index, variant) in ["no-action", "thumbnail", "color", "reminder"].enumerated() {
            let fixture = ReplayFixture()
            let controller = fixture.controller
            var content = fixture.content(UInt64(2_200 + index), text: "1+1")
            if variant == "thumbnail" {
                content.thumbnail = NSImage(size: NSSize(width: 64, height: 64))
            } else if variant == "color" {
                content.detections = [ContentDetection(kind: .colorHex, value: "#ff0000", color: .red)]
            }
            var measured: [String: NSSize] = [:]
            ToastActionGeometryProbe.onMeasure = { metric, size in measured[metric] = size }
            if variant == "reminder" {
                controller.showReminder(revision: content.revision)
            } else {
                controller.show(content: content, source: fixture.source)
                if variant != "no-action" {
                    controller.applyActions(
                        primary: CalculateAction(expression: "1+1"), menu: [], revision: content.revision
                    )
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.40))
            guard let icon = measured["icon"], let left = measured["leftColumn"],
                  let fitting = controller.testingWindow?.contentView?.subviews.first?.fittingSize else {
                fatalError("production \(variant) card did not produce layout measurements")
            }
            expect(icon.width.isFinite && icon.height.isFinite && left.width.isFinite
                   && fitting.width.isFinite && fitting.height.isFinite
                   && icon.width > 0 && left.width >= 0 && fitting.width > 0
                   && fitting.width <= 396.5,
                   "production \(variant) card lost finite icon, text, or capped window geometry")
            if variant == "thumbnail" || variant == "color" {
                let expectedIconWidth: CGFloat = variant == "thumbnail" ? 64 : 32
                expect(abs(icon.width - expectedIconWidth) < 0.5,
                       "production \(variant) icon changed its width: \(icon.width)")
                expect(abs((measured["actionTitle"]?.width ?? 0) - normalAction.text.width) < 0.5,
                       "production \(variant) card compressed its action title")
            } else {
                expect(measured["button"] == nil,
                       "production \(variant) card unexpectedly laid out an action button")
            }
            controller.dismissToast(animated: false)
        }
    }

    private static func replayRequiresShownReadyContent() {
        let fixture = ReplayFixture()
        let controller = fixture.controller
        let content = fixture.content()
        expect(!fixture.store.canReplay && !controller.replayLastToast(), "empty replay cache was enabled")
        controller.showStartupNotice(using: fixture.source)
        expect(!fixture.store.canReplay, "startup notice created a content snapshot")
        controller.showReminder(revision: content.revision)
        controller.applyBaseContent(content, source: fixture.source, revision: content.revision)
        expect(!fixture.store.canReplay, "reminder created a content snapshot")
        controller.showPending(revision: content.revision, source: fixture.source)
        expect(!fixture.store.canReplay, "pending content created a snapshot")
        controller.showFailure(revision: content.revision)
        expect(!fixture.store.canReplay, "failure created a content snapshot")
        controller.dismissToast(animated: false)
        controller.applyBaseContent(content, source: fixture.source, revision: content.revision)
        expect(!fixture.store.canReplay, "unshown base content created a snapshot")

        controller.show(content: content, source: fixture.source)
        expect(fixture.store.canReplay, "shown ready card was not retained")
        let newer = fixture.content(101)
        controller.showPending(revision: newer.revision, source: fixture.source)
        expect(!fixture.store.canReplay && !controller.replayLastToast(), "old replay covered a new pending copy")
        controller.showFailure(revision: newer.revision)
        expect(!fixture.store.canReplay, "new failure re-enabled the previous snapshot")
    }

    private static func replayKeepsContentActionsAndResults() {
        let fixture = ReplayFixture()
        let controller = fixture.controller
        var content = fixture.content(text: "1+2")
        let thumbnail = NSImage(size: NSSize(width: 2, height: 2))
        content.thumbnail = thumbnail
        content.detail = "Synthetic lower bound"
        content.detailIsLoading = true
        controller.show(content: content, source: fixture.source)
        let calculation = CalculateAction(expression: "1+2")
        let translation = LookupAction(definition: "Synthetic translation")
        controller.applyActions(primary: calculation, menu: [translation], revision: content.revision)
        controller.testingPerformCommand(.performPrimary)
        let calculationResult = controller.testingViewModel.resultOverlay
        expect(calculationResult?.copyText == "3", "production calculation result was not displayed")
        controller.testingPerformCommand(.expand)
        RunLoop.main.run(until: Date().addingTimeInterval(0.60))
        let expandedWindow = controller.testingWindow!
        expect(controller.testingViewModel.isExpanded
               && expandedWindow.firstResponder is ToastExpandedTextView,
               "calculated content did not enter the selectable expanded state")
        controller.testingPerformCommand(.collapse)
        RunLoop.main.run(until: Date().addingTimeInterval(0.60))
        expect(!controller.testingViewModel.isExpanded && expandedWindow.isVisible,
               "calculated content did not return to the collapsed state")
        controller.testingPerformCommand(.dismiss)
        RunLoop.main.run(until: Date().addingTimeInterval(0.30))
        expect(controller.testingWindow == nil && fixture.store.canReplay, "normal close discarded replay content")
        expect(controller.replayLastToast(), "closed ready card could not be restored")
        expect(controller.testingEntranceStyle == .replay,
               "replay uses copy's elastic entrance")
        expect(controller.testingViewModel.rawContent?.rawText == "1+2"
               && controller.testingViewModel.sourceAppName == fixture.source.name
               && controller.testingViewModel.sourceBundleID == fixture.source.bundleIdentifier,
               "replay changed content or original source")
        expect(controller.testingViewModel.thumbnailImage === thumbnail
               && controller.testingViewModel.detailInfo == "Synthetic lower bound"
               && !controller.testingViewModel.detailIsLoading,
               "replay lost thumbnail/detail or retained stopped loading")
        expect(controller.testingViewModel.primaryAction?.id == calculation.id
               && controller.testingViewModel.menuActions.map(\.id) == [translation.id]
               && controller.testingViewModel.resultOverlay == calculationResult,
               "replay lost ready buttons or calculation result")
        RunLoop.main.run(until: Date().addingTimeInterval(0.30))
        let replayWindow = controller.testingWindow!
        let replayHosting = replayWindow.contentView!.subviews.first!
        expect(abs(replayHosting.frame.width - replayHosting.fittingSize.width) < 0.5
               && abs(replayHosting.frame.height - replayHosting.fittingSize.height) < 0.5,
               "replaying a collapsed calculation restored a clipped result")
        controller.testingPerformCommand(.performAction(translation))
        expect(controller.testingViewModel.resultOverlay?.copyText == "Synthetic translation", "restored translation action failed")
        controller.dismissToast(animated: false)
        expect(controller.replayLastToast()
               && controller.testingViewModel.resultOverlay?.copyText == "Synthetic translation",
               "displayed translation result was not retained")
    }

    private static func replayExpirationDoesNotRenew() {
        let fixture = ReplayFixture()
        let controller = fixture.controller
        var content = fixture.content()
        controller.showPending(revision: content.revision, source: fixture.source)
        fixture.clock.now += 100
        controller.applyBaseContent(content, source: fixture.source, revision: content.revision)
        fixture.clock.now += 499
        content.detail = "Synthetic enrichment"
        controller.applyEnrichment(content, revision: content.revision)
        controller.dismissToast(animated: false)
        expect(controller.replayLastToast(), "snapshot expired before the 600-second boundary")
        let presentation = controller.resultPresentation(for: content.revision)!
        controller.showInlineResult(displayText: "Synthetic result", copyText: "Synthetic result",
                                    revision: content.revision, presentation: presentation)
        fixture.clock.now += 1
        expect(!controller.replayLastToast() && !fixture.store.canReplay,
               "base content, enrichment, inline result or replay renewed the first pending deadline")
        fixture.clock.now -= 100
        expect(!controller.replayLastToast(), "expired cache was revived by moving the injected clock back")
    }

    private static func replayExpirationReleasesContentInTrackingMode() {
        let fixture = ReplayFixture()
        weak var retainedThumbnail: NSImage?
        do {
            var content = fixture.content()
            let thumbnail = NSImage(size: NSSize(width: 2, height: 2))
            retainedThumbnail = thumbnail
            content.thumbnail = thumbnail
            fixture.store.beginPresentation(revision: content.revision)
            fixture.clock.now += 599.98
            let model = ToastViewModel()
            model.configure(with: content, source: fixture.source)
            fixture.store.record(LastToastSnapshot(viewModel: model)!)
        }
        expect(retainedThumbnail != nil, "store failed to retain its snapshot")
        fixture.clock.now += 0.02
        let deadline = Date().addingTimeInterval(0.08)
        while fixture.store.canReplay, Date() < deadline {
            RunLoop.main.run(mode: .eventTracking, before: deadline)
        }
        expect(!fixture.store.canReplay && retainedThumbnail == nil,
               "expiry did not release content and disable replay during menu tracking")

        let content = fixture.content(110)
        fixture.controller.show(content: content, source: fixture.source)
        fixture.clock.now += 600
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        expect(!fixture.store.canReplay, "wake did not expire a retained snapshot")
    }

    private static func replayHonorsCurrentPrivacySettings() {
        let fixture = ReplayFixture()
        let content = fixture.content()
        fixture.controller.show(content: content, source: fixture.source)
        fixture.controller.dismissToast(animated: false)
        fixture.defaults.set(true, forKey: "lightReminderEnabled")
        fixture.store.refreshAvailability()
        expect(!fixture.store.canReplay && !fixture.controller.replayLastToast(), "reminder mode restored copied text")
        fixture.defaults.set(false, forKey: "lightReminderEnabled")
        fixture.store.refreshAvailability()
        expect(fixture.store.canReplay, "leaving reminder mode lost an unexpired snapshot")
        fixture.filter.addToBlocked(AppFilterEntry(bundleID: fixture.source.bundleIdentifier!, displayName: fixture.source.name))
        fixture.store.refreshAvailability()
        expect(!fixture.store.canReplay && !fixture.controller.replayLastToast(), "blocked original source was restored")
        fixture.filter.removeFromBlocked(bundleID: fixture.source.bundleIdentifier!)
        fixture.store.refreshAvailability()
        expect(fixture.store.canReplay, "source removal did not refresh availability")
        let delegate = AppDelegate(monitor: ClipboardMonitor(toastController: fixture.controller))
        delegate.setPaused(true)
        expect(!fixture.store.canReplay && !fixture.controller.replayLastToast(), "production pause did not clear replay")
        fixture.controller.show(content: content, source: fixture.source)
        fixture.defaults.set(true, forKey: "isPaused")
        fixture.store.refreshAvailability()
        fixture.defaults.set(false, forKey: "isPaused")
        fixture.store.refreshAvailability()
        expect(!fixture.store.canReplay, "resuming revived paused content")
    }

    private static func replayRejectsOldCallbacksAndYieldsToNewCopy() {
        let fixture = ReplayFixture()
        let controller = fixture.controller
        var old = fixture.content()
        controller.show(content: old, source: fixture.source)
        let oldPresentation = controller.resultPresentation(for: old.revision)!
        controller.testingPerformCommand(.dismiss)
        expect(controller.replayLastToast(), "replay during old dismissal failed")
        old.preview = "Stale enrichment"
        controller.applyEnrichment(old, revision: old.revision)
        controller.applyActions(primary: CalculateAction(expression: "9+9"), menu: [], revision: old.revision)
        controller.applyBaseContent(old, source: fixture.source, revision: old.revision)
        controller.showFailure(revision: old.revision)
        controller.dismissSilently(revision: old.revision)
        controller.showInlineResult(displayText: "Stale result", copyText: "Stale result",
                                    revision: old.revision, presentation: oldPresentation)
        RunLoop.main.run(until: Date().addingTimeInterval(0.30))
        expect(controller.testingWindow?.isVisible == true && controller.testingViewModel.isContentReady
               && controller.testingViewModel.previewText == "Synthetic copied text"
               && controller.testingViewModel.resultOverlay == nil && controller.testingViewModel.primaryAction == nil,
               "old dismissal, base/enrichment/action or inline result changed replay")

        let newer = fixture.content(101, text: "Synthetic new copy")
        controller.showPending(revision: newer.revision, source: fixture.source)
        expect(!controller.replayLastToast(), "replay displaced a newer pending revision")
        controller.applyBaseContent(newer, source: fixture.source, revision: newer.revision)
        controller.applyEnrichment(old, revision: old.revision)
        controller.showResultOverlay(displayText: "Stale result", copyText: "Stale result",
                                     revision: old.revision, presentation: oldPresentation)
        RunLoop.main.run(until: Date().addingTimeInterval(0.30))
        expect(controller.testingWindow?.isVisible == true
               && controller.testingViewModel.revision == newer.revision
               && controller.testingViewModel.previewText == "Synthetic new copy"
               && fixture.store.snapshotForReplay()?.content.revision == newer.revision,
               "new real copy was lost or its snapshot rolled back")
    }

    private static func replayPreservesExpandedCardAndRestartsCollapsedLifetime() {
        let fixture = ReplayFixture()
        let controller = fixture.controller
        let content = fixture.content()
        controller.show(content: content, source: fixture.source)
        controller.startDismissTimer(after: 0.5)
        let oldDeadline = controller.testingDismissDeadline!
        expect(controller.replayLastToast() && controller.testingDismissDeadline! > oldDeadline,
               "visible collapsed replay did not restart its three-second lifetime")
        controller.testingPerformCommand(.expand)
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        let expandedWindow = controller.testingWindow
        expect(controller.testingViewModel.isExpanded && controller.testingDismissDeadline == nil,
               "production expansion did not suspend dismissal")
        expect(controller.replayLastToast() && controller.testingViewModel.isExpanded
               && controller.testingWindow === expandedWindow && controller.testingDismissDeadline == nil,
               "replay changed an already expanded card")
        controller.dismissToast(animated: false)
        expect(controller.replayLastToast() && !controller.testingViewModel.isExpanded
               && !controller.testingViewModel.isExpandedTextLoading
               && controller.testingViewModel.quickTriggerVisualState == .idle,
               "closed expanded card did not restore a clean collapsed state")
    }

    private static func replayIgnoresFilteredCopies() {
        let fixture = ReplayFixture()
        let original = fixture.content()
        fixture.controller.show(content: original, source: fixture.source)
        let monitor = ClipboardMonitor(toastController: fixture.controller)
        let preferences = PopupPresentationPreferences(mode: .lowInterruption,
            showShortPlainText: false, showLongPlainText: true, showImages: true, showFiles: true,
            disabledKindIDs: [])
        let filtered = fixture.content(120, text: "short")
        monitor.testingPresentLowInterruption(content: filtered, source: fixture.source,
                                              preferences: preferences, analysisIsReady: true)
        expect(fixture.store.snapshotForReplay()?.content.revision == original.revision,
               "filtered low-interruption copy replaced a truly shown snapshot")
        monitor.testingPresentLowInterruption(content: fixture.content(121), source: fixture.source,
                                              preferences: preferences, analysisIsReady: false)
        expect(fixture.store.snapshotForReplay()?.content.revision == original.revision,
               "unclassified low-interruption copy created a snapshot")
    }

    private static func replayHasNoAutomaticClipboardOrSoundWork() throws {
        let fixture = ReplayFixture()
        let content = fixture.content()
        var actionCalls = 0
        var resourceCancellations = 0
        let action = CompressImagesAction(
            invocation: LitheInvocation(applicationURL: URL(fileURLWithPath: "/Synthetic.app"),
                                        fileURLs: [URL(fileURLWithPath: "/synthetic.png")]),
            client: LitheApplicationClient(locateApplication: { nil }, openFiles: { _ in actionCalls += 1 })
        )
        fixture.controller.show(content: content, source: fixture.source)
        fixture.controller.applyActions(primary: action, menu: [action], revision: content.revision)
        fixture.controller.dismissToast(animated: false)
        fixture.controller.onRevisionResourcesShouldCancel = { _ in resourceCancellations += 1 }
        let changeCount = NSPasteboard.general.changeCount
        expect(fixture.controller.replayLastToast(), "synthetic replay failed")
        expect(NSPasteboard.general.changeCount == changeCount
               && actionCalls == 0 && resourceCancellations == 0,
               "replay changed clipboard, performed an action or re-entered monitor resources")
        let source = try String(contentsOfFile: "ToastWindowController.swift", encoding: .utf8)
        let replay = source.components(separatedBy: "func replayLastToast() -> Bool {")[1]
            .components(separatedBy: "func clearLastToast()")[0]
        for forbidden in ["NSPasteboard", "SourceAppDetector", "CopySound", "ClipboardMonitor", "ActionResolver", "DetectionRegistry", ".perform("] {
            expect(!replay.contains(forbidden), "replay gained automatic work: \(forbidden)")
        }
        expect(replay.contains("isReplay: true") && source.contains("animateWindowAlpha(to: 1, easeIn: false)"),
               "replay stopped using the existing detail fade-in")
        let view = try String(contentsOfFile: "ToastView.swift", encoding: .utf8)
        expect(view.contains("let usesStandardMotion = style == .standard")
               && view.contains(".opacity(animateIn.wrappedValue || style == .replay ? 1 : 0)")
               && view.contains("reduceMotion || style == .replay"),
               "replay regained a separate SwiftUI spring or opacity entrance")
    }

    private static func budgetSnapshot(
        _ content: ClipboardContent,
        source: SourceAppInfo = SourceAppInfo(name: "", icon: nil, bundleIdentifier: nil),
        primary: (any ClipboardAction)? = nil, menu: [any ClipboardAction] = [],
        result: ResultOverlay? = nil
    ) -> LastToastSnapshot {
        let model = ToastViewModel()
        model.configure(with: content, source: source)
        model.applyActions(primary: primary, menu: menu)
        model.resultOverlay = result
        return LastToastSnapshot(viewModel: model)!
    }

    private static func replayBudgetHasExactUTF8Boundaries() {
        let fixture = ReplayFixture()
        let limit = LastToastStore.maximumContentBytes
        expect(limit == 8 * 1_024 * 1_024, "replay content budget changed")
        let exact = fixture.budgetContent(rawText: String(repeating: "a", count: limit))
        expect(budgetSnapshot(exact).contentByteCost() == limit, "exact budget was not accepted")
        fixture.store.beginPresentation(revision: exact.revision)
        fixture.store.record(budgetSnapshot(exact))
        expect(fixture.store.canReplay, "exactly 8 MiB could not be retained")
        let excessive = fixture.budgetContent(rawText: String(repeating: "a", count: limit + 1))
        expect(budgetSnapshot(excessive).contentByteCost() == nil, "one byte over budget was accepted")
        fixture.store.beginPresentation(revision: excessive.revision)
        fixture.store.record(budgetSnapshot(excessive))
        expect(!fixture.store.canReplay && fixture.store.snapshotForReplay() == nil,
               "oversized real content left an older snapshot available")

        let unicode = "中🙂e\u{301}"
        let unicodeBytes = unicode.utf8.count
        let unicodeSnapshot = budgetSnapshot(fixture.budgetContent(rawText: unicode))
        expect(unicodeSnapshot.contentByteCost(limit: unicodeBytes) == unicodeBytes
               && unicodeSnapshot.contentByteCost(limit: unicodeBytes - 1) == nil,
               "non-ASCII content was charged as characters or UTF-16 units")
        let foreign = NSString(string: String(repeating: "中", count: 64)) as String
        expect(foreign.utf8.withContiguousStorageIfAvailable({ $0.count }) == nil,
               "bridged fixture does not exercise the bounded UTF-8 fallback")
        let foreignSnapshot = budgetSnapshot(fixture.budgetContent(rawText: foreign))
        expect(foreignSnapshot.contentByteCost(limit: 192) == 192
               && foreignSnapshot.contentByteCost(limit: 191) == nil,
               "bridged non-ASCII text bypassed exact UTF-8 accounting")
        let enormousForeign = NSString(string: String(repeating: "中", count: limit + 1)) as String
        expect(enormousForeign.utf16.count > limit
               && budgetSnapshot(fixture.budgetContent(rawText: enormousForeign)).contentByteCost() == nil,
               "foreign text larger than the UTF-16 lower bound was retained")
    }

    private static func replayBudgetCountsRetainedFieldsAndAllActions() {
        let fixture = ReplayFixture()
        let kind = ContentKind(id: "kind", category: .entity, source: .plugin("plugin.id"),
                               label: "标签", icon: "icon", pluginName: "Plugin")
        let template = PluginActionTemplate(type: .transform, title: "执行", icon: "symbol",
                                           template: "{value}", transformPattern: ".+",
                                           transformReplacement: "$0", menuOnly: false)
        var detection = ContentDetection(kind: kind, value: "值")
        detection.metadata = ["ruleId": "rule", "metadata": "内容"]
        detection.pluginActionTemplate = template
        detection.color = NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1)
        let urls = [URL(fileURLWithPath: "/synthetic/文件.txt"), URL(string: "https://example.invalid/test")!]
        var content = fixture.budgetContent(rawText: "raw", fullText: "完整文本", displayText: "展开",
                                            fileURLs: urls, imageFormat: "PNG")
        content.preview = "预览"
        content.detail = "详情"
        content.displayTypeLabel = "类型"
        content.displayIconSymbolName = "symbol"
        content.contentKind = kind
        content.detections = [detection]
        let icon = NSImage(size: NSSize(width: 4_096, height: 4_096))
        let source = SourceAppInfo(name: "Source", icon: icon, bundleIdentifier: "source.id")
        let strings = ["raw", "完整文本", "展开", "预览", "详情", "类型", "symbol", "PNG", "Source", "source.id"]
        let kindBytes = [kind.id, kind.label, kind.icon, kind.pluginName!, "plugin.id"].reduce(0) { $0 + $1.utf8.count }
        let templateBytes = [template.title, template.icon, template.template!, template.transformPattern!,
                             template.transformReplacement!].reduce(0) { $0 + $1.utf8.count }
        let metadataBytes = detection.metadata.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        let expected = strings.reduce(0) { $0 + $1.utf8.count } + kindBytes * 2 + "值".utf8.count
            + templateBytes + metadataBytes + urls.reduce(0) { $0 + $1.absoluteString.utf8.count }
        let snapshot = budgetSnapshot(content, source: source)
        expect(snapshot.contentByteCost(limit: expected) == expected
               && snapshot.contentByteCost(limit: expected - 1) == nil,
               "content, source, paths, detection metadata or template escaped the combined budget")

        let invocation = LitheInvocation(applicationURL: URL(fileURLWithPath: "/Synthetic.app"), fileURLs: urls)
        let plugin = PluginAction(detection: detection, template: template)
        let character: Character = "👨‍👩‍👧‍👦"
        let actions: [(any ClipboardAction, Int)] = [
            (OpenURLAction(url: urls[1]), urls[1].absoluteString.utf8.count),
            (RevealFileAction(path: "/文件"), "/文件".utf8.count),
            (CompressImagesAction(invocation: invocation,
                                  client: LitheApplicationClient(locateApplication: { nil }, openFiles: { _ in })),
             invocation.applicationURL.absoluteString.utf8.count + urls.reduce(0) { $0 + $1.absoluteString.utf8.count }),
            (CalculateAction(expression: "1+2"), 3), (SearchTextAction(text: "搜索"), 6),
            (ShowPinyinAction(character: character), String(character).utf8.count),
            (CallPhoneAction(phoneNumber: "123"), 3), (ComposeEmailAction(email: "a@b.test"), 8),
            (SaveFileAction(text: "保存", defaultName: "a.txt"), 11), (CopyTextAction(text: "复制"), 6),
            (OpenCalendarAction(date: Date(timeIntervalSince1970: 0)), 0),
            (LookupAction(definition: "释义"), 6),
            (plugin, kindBytes + "值".utf8.count + metadataBytes + templateBytes * 2),
            (BlacklistSourceAppAction(bundleID: "app.id", appName: "来源"), 12)
        ]
        let empty = fixture.budgetContent()
        for (action, bytes) in actions {
            let snapshot = budgetSnapshot(empty, primary: action)
            expect(snapshot.contentByteCost(limit: bytes) == bytes, "known action payload not accounted: \(action.id)")
            if bytes > 0 {
                expect(snapshot.contentByteCost(limit: bytes - 1) == nil, "known action escaped its byte cost: \(action.id)")
            }
        }
        let menuBytes = actions.reduce(0) { $0 + $1.1 }
        expect(budgetSnapshot(empty, menu: actions.map { $0.0 }).contentByteCost(limit: menuBytes) == menuBytes,
               "menu action payloads were not added together")
        let unknown = ReplayProbeAction(id: "unknown", onPerform: {})
        fixture.store.beginPresentation(revision: empty.revision)
        fixture.store.record(budgetSnapshot(empty))
        fixture.store.record(budgetSnapshot(empty, menu: [unknown]))
        expect(!fixture.store.canReplay, "unknown action was silently treated as zero bytes")
    }

    private static func replayBudgetRejectsIndependentActionPayloads() {
        let fixture = ReplayFixture()
        let content = fixture.content(text: "Original complete synthetic content")
        let large = String(repeating: "x", count: LastToastStore.maximumContentBytes + 1)
        let template = PluginActionTemplate(type: .transform, title: "执行", icon: "symbol", template: nil,
                                           transformPattern: ".", transformReplacement: "$0", menuOnly: false)
        var detection = ContentDetection(kind: .plain, value: large)
        let actions: [any ClipboardAction] = [
            SaveFileAction(text: large, defaultName: "synthetic.txt"), LookupAction(definition: large),
            PluginAction(detection: detection, template: template)
        ]
        fixture.controller.show(content: content, source: fixture.source)
        expect(fixture.store.canReplay, "small original content was not cached before action enrichment")
        for action in actions {
            expect(budgetSnapshot(fixture.budgetContent(), primary: action).contentByteCost() == nil,
                   "independent oversized action payload bypassed the budget")
            fixture.controller.applyActions(primary: action, menu: [], revision: content.revision)
            expect(!fixture.store.canReplay && fixture.controller.testingViewModel.rawContent?.rawText == content.rawText,
                   "large independent action was cached or changed the original content")
            if let save = fixture.controller.testingViewModel.primaryAction as? SaveFileAction {
                expect(save.text == large, "save payload was truncated to meet the cache budget")
            } else if let lookup = fixture.controller.testingViewModel.primaryAction as? LookupAction {
                expect(lookup.definition == large, "translation payload was truncated to meet the cache budget")
            } else if let plugin = fixture.controller.testingViewModel.primaryAction as? PluginAction {
                expect(plugin.detection.value == large, "plugin payload was truncated to meet the cache budget")
            }
        }
        fixture.controller.applyActions(primary: SearchTextAction(text: "small"), menu: [], revision: content.revision)
        fixture.controller.applyEnrichment(content, revision: content.revision)
        expect(!fixture.store.canReplay, "a later partial result revived a budget-rejected revision")

        let hugeTemplate = PluginActionTemplate(type: .transform, title: "执行", icon: "symbol", template: nil,
                                               transformPattern: ".", transformReplacement: large, menuOnly: false)
        detection = ContentDetection(kind: .plain, value: "small")
        expect(budgetSnapshot(fixture.budgetContent(), primary: PluginAction(detection: detection, template: hugeTemplate))
               .contentByteCost() == nil, "independent plugin template bypassed the budget")
        detection.metadata = ["payload": large]
        expect(budgetSnapshot(fixture.budgetContent(), primary: PluginAction(detection: detection, template: template))
               .contentByteCost() == nil, "independent plugin metadata bypassed the budget")
        let newer = fixture.content(901, text: "Next small copy")
        fixture.controller.show(content: newer, source: fixture.source)
        expect(fixture.store.canReplay && fixture.store.snapshotForReplay()?.content.rawText == newer.rawText,
               "next small real popup could not replace a budget refusal")
    }

    private static func replayBudgetResultOverflowReleasesAndCannotRevive() {
        let fixture = ReplayFixture()
        let small = fixture.budgetContent()
        let large = String(repeating: "x", count: LastToastStore.maximumContentBytes)
        for result in [ResultOverlay(displayText: "ok", copyText: large),
                       ResultOverlay(displayText: large, copyText: nil)] {
            weak var oldThumbnail: NSImage?
            fixture.store.beginPresentation(revision: small.revision)
            do {
                var old = small
                old.thumbnail = NSImage(size: NSSize(width: 2, height: 2))
                oldThumbnail = old.thumbnail
                fixture.store.record(budgetSnapshot(old))
            }
            expect(fixture.store.canReplay && oldThumbnail != nil, "old small snapshot was not retained")
            fixture.store.record(budgetSnapshot(small, result: result))
            expect(!fixture.store.canReplay && fixture.store.snapshotForReplay() == nil && oldThumbnail == nil,
                   "result display/copy overflow retained old or partial snapshot data")
            fixture.store.record(budgetSnapshot(small))
            expect(!fixture.store.canReplay, "small late result revived a rejected snapshot")
        }

        let content = fixture.content(902)
        fixture.controller.show(content: content, source: fixture.source)
        let presentation = fixture.controller.resultPresentation(for: content.revision)!
        fixture.controller.showInlineResult(displayText: "Complete result", copyText: large,
                                            revision: content.revision, presentation: presentation)
        expect(!fixture.store.canReplay && fixture.controller.testingViewModel.resultOverlay?.copyText == large,
               "result overflow truncated the displayed card's copy payload")
    }

    private static func replayBudgetCountsThumbnailRepresentations() throws {
        let fixture = ReplayFixture()
        let empty = fixture.budgetContent()
        for planar in [false, true] {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: planar,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let image = NSImage(size: NSSize(width: 2, height: 2))
            image.addRepresentation(bitmap)
            var content = empty
            content.thumbnail = image
            let bytes = bitmap.bytesPerRow * bitmap.pixelsHigh * bitmap.numberOfPlanes
            expect(!planar || bitmap.numberOfPlanes == 4, "planar fixture lost its four planes")
            expect(budgetSnapshot(content).contentByteCost(limit: bytes) == bytes
                   && budgetSnapshot(content).contentByteCost(limit: bytes - 1) == nil,
                   "bitmap rows or planes escaped the image budget")
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        var content = empty
        content.thumbnail = NSImage(cgImage: bitmap.cgImage!, size: NSSize(width: 8, height: 8))
        expect(budgetSnapshot(content).contentByteCost(limit: 8 * 8 * 4) == 8 * 8 * 4,
               "normal CG raster thumbnail was refused")
        content.thumbnail = NSImage(size: .zero)
        expect(budgetSnapshot(content).contentByteCost(limit: 0) == 0, "truly empty image costs content bytes")
        for width in [0, Int.max] {
            let representation = NSImageRep()
            representation.bitsPerSample = 8
            representation.pixelsWide = width
            representation.pixelsHigh = width == 0 ? 0 : 2
            let image = NSImage(size: .zero)
            image.addRepresentation(representation)
            content.thumbnail = image
            expect(budgetSnapshot(content).contentByteCost() == nil,
                   "existing zero-pixel representation or overflowing pixel product was accepted")
        }
        content.thumbnail = NSImage(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: 2))
        expect(budgetSnapshot(content).contentByteCost() == nil, "unbounded empty-image dimensions were accepted")

        // Encoding belongs only to the synthetic QL fixture; the estimator never encodes an image.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Copied-replay-budget-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        bitmap.bitmapData!.initialize(repeating: 0x80, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        let generator = FilePreviewGenerator()
        var finished = false
        var preview: NSImage?
        let token = generator.generateThumbnail(for: url, size: CGSize(width: 64, height: 64), scale: 2,
                                                 revision: empty.revision) { _, _, image in
            preview = image
            finished = true
        }
        defer { generator.cancel(token: token) }
        let deadline = Date().addingTimeInterval(FilePreviewGenerator.resultDeadline + 1)
        while !finished, Date() < deadline {
            RunLoop.main.run(until: min(Date().addingTimeInterval(0.01), deadline))
        }
        expect(finished && preview != nil, "synthetic production Quick Look fixture did not return a thumbnail")
        content.thumbnail = preview
        expect(budgetSnapshot(content).contentByteCost() != nil, "normal Quick Look raster thumbnail was refused")
        print("Replay QL fixture representations: \(preview!.representations.map { String(describing: type(of: $0)) })")
    }

    private static func textFallbackPreservesUnicodeBoundary() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for character in ["中", "👨‍👩‍👧‍👦", "e\u{301}"] {
            for length in [49, 50] {
                let text = String(repeating: character, count: length)
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                let revision = ClipboardRevision(generation: 1, changeCount: pasteboard.changeCount)
                guard case var .content(_, content) = ClipboardBaseReader.read(
                    session: ClipboardLoadSession(revision: revision, backingScale: 2),
                    pasteboard: pasteboard
                ) else { fatalError("synthetic text read failed") }
                content.detections = [ContentDetection(kind: .swift, value: text)]
                let result = ActionResolver.resolve(for: content)
                expect(content.textLength == length, "base reader character count changed")
                expect(length == 49 ? result.primary is SearchTextAction : result.primary is SaveFileAction,
                       "pure code lost its Unicode-aware fallback action")
            }
        }
    }

    private static func pluginReplacementIsValidatedBeforeInstallation() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("Copied-plugin-test-\(UUID().uuidString)")
        let source = base.appendingPathComponent("source/Synthetic.copiedplugin")
        let installed = base.appendingPathComponent("installed")
        let suite = "CopiedPluginTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? manager.removeItem(at: base)
        }
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = #"{"name":"Synthetic","identifier":"com.copied.synthetic-test","version":"1.0.0","category":"entity","icon":"","label":"","priority":100}"#
        let rules = #"{"version":"1","rules":[{"id":"synthetic","pattern":"^synthetic$"}]}"#
        try manifest.write(to: source.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try rules.write(to: source.appendingPathComponent("rules.json"), atomically: true, encoding: .utf8)
        let registry = DetectionRegistry(defaults: defaults)
        let loader = PluginLoader(directory: installed, registry: registry, defaults: defaults)
        for _ in 0..<2 { _ = try loader.installPlugin(from: source) }
        expect(registry.detectAll(in: "synthetic").count == 1, "reinstall duplicated a detector")
        expect(loader.installedPluginIDs.count == 1, "reinstall duplicated preferences")
        let destination = loader.scanPlugins().first!
        _ = try loader.installPlugin(from: destination)
        let renamed = source.deletingLastPathComponent().appendingPathComponent("Renamed.copiedplugin")
        try manager.copyItem(at: source, to: renamed)
        _ = try loader.installPlugin(from: renamed)
        expect(loader.scanPlugins() == [destination], "same identifier created multiple installed directories")
        try "invalid".write(to: source.appendingPathComponent("rules.json"), atomically: true, encoding: .utf8)
        do {
            _ = try loader.installPlugin(from: source)
            fatalError("invalid update accepted")
        } catch {}
        let retainedRules = try String(contentsOf: destination.appendingPathComponent("rules.json"), encoding: .utf8)
        expect(retainedRules == rules,
               "invalid update destroyed the old plugin")
        expect(registry.detectAll(in: "synthetic").count == 1, "invalid update changed active detection")
        let link = base.appendingPathComponent("Link.copiedplugin")
        try manager.createSymbolicLink(at: link, withDestinationURL: renamed)
        do { _ = try loader.installPlugin(from: link); fatalError("symbolic-link plugin accepted") } catch {}
        loader.uninstallPlugin(identifier: "com.copied.synthetic-test")
        expect(loader.scanPlugins().isEmpty && registry.detectAll(in: "synthetic").isEmpty,
               "uninstall left active plugin state")
        let residue = try manager.contentsOfDirectory(atPath: installed.path)
        expect(residue.isEmpty, "staging residue remains")
    }
}
