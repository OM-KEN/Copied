import AppKit
import Foundation
import SwiftUI

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private final class WorkerResult<Value> {
    var value: Value?
}

private func onCopyWorker<Value>(_ work: @escaping () -> Value) -> Value {
    let result = WorkerResult<Value>()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        result.value = work()
        done.signal()
    }
    done.wait()
    return result.value!
}

private func readBaseOnWorker(session: ClipboardLoadSession, pasteboard: NSPasteboard) -> ClipboardBaseReadOutcome {
    onCopyWorker { ClipboardBaseReader.read(session: session, pasteboard: pasteboard) }
}

private final class ReplayClock {
    var now: TimeInterval = 10_000
}

private final class CopyReuseCounter {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private final class CopyReuseDetector: ContentDetectorProtocol {
    let kind = ContentKind(id: "test.copy-reuse", category: .entity, source: .builtIn,
                           label: "Synthetic recognized type", icon: "link")
    let priority = 10_000
    let calls = CopyReuseCounter()

    func detect(in text: String) -> ContentDetection? {
        calls.increment()
        return ContentDetection(kind: kind, value: text)
    }
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
        guard case let .content(_, content) = readBaseOnWorker(
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
            if CommandLine.arguments.contains("--held-repeat-native") {
                await verifyHeldRepeatedRevisions()
            } else if CommandLine.arguments.contains("--combo-cycle-native") {
                await verifyCompleteComboCycle()
            } else if CommandLine.arguments.contains("--combo-exit") {
                await verifyComboDismissalGeometry()
            } else {
                await verifyTransitions()
            }
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
        await verifyHeldRepeatedRevisions()
        await verifyCompleteComboCycle()
        await verifyComboMotionContinuity()
        await verifyCoalescedLazyMotion()
        await verifyComboDismissalGeometry()
    }

    @MainActor
    private func verifyCoalescedLazyMotion() async {
        let fixture = ReplayFixture()
        let controller = fixture.controller
        let monitor = ClipboardMonitor(toastController: controller, defaults: fixture.defaults)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let preferences = PopupPresentationPreferences(mode: .lowInterruption, showShortPlainText: true,
            showLongPlainText: true, showImages: true, showFiles: true, disabledKindIDs: [])
        var originalWindow: ToastPanel?
        for generation in 1...2 {
            board.clearContents()
            board.setString("Synthetic coalesced lazy animation", forType: .string)
            let revision = ClipboardRevision(generation: UInt64(generation), changeCount: board.changeCount)
            let session = ClipboardLoadSession(revision: revision, backingScale: 2,
                                               comparisonIdentity: controller.copyIdentityForComparison)
            guard case let .content(_, content) = readBaseOnWorker(session: session, pasteboard: board)
            else { fatalError("coalesced native fixture read failed") }
            monitor.testingPresentLowInterruption(content: content, source: fixture.source,
                preferences: preferences, analysisIsReady: true, copyIdentity: session.takeCopyIdentity())
            if generation == 1 {
                originalWindow = controller.testingWindow
                expect(controller.testingCopyCombo.testingEchoGraphInstallCount == 0,
                       "a first coalesced presentation installed the residual graph")
            }
        }
        expect(controller.testingWindow === originalWindow && controller.testingCopyCombo.count == 2
               && !controller.testingCopyCombo.isVisible,
               "a matching second copy replaced its coalesced host or displayed a premature badge")
        try? await Task.sleep(for: .milliseconds(80))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            expect(controller.testingCopyCombo.testingEchoGraphInstallCount > 0
                   && abs(controller.testingCopyCombo.motion.swing) > 0.01,
                   "the old coalesced host lost its initial motion response")
        }
        controller.dismissToast(animated: false)
    }

    @MainActor
    private func verifyHeldRepeatedRevisions() async {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fixture = ReplayFixture()
        let controller = fixture.controller
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); controller.dismissToast(animated: false) }
        var activeWindow: ToastPanel?
        var activeOwner = 0
        var graphInstalls = 0
        var tailPositions: [Double] = []
        let started = ProcessInfo.processInfo.systemUptime
        for generation in 1...46 {
            if generation > 1 { try? await Task.sleep(for: .milliseconds(75)) }
            if generation > 2 {
                for _ in 0..<(generation.isMultiple(of: 2) ? 1 : 2) { board.clearContents() }
            }
            let (content, identity) = AppBehaviorTests.comboRead(
                board, generation: UInt64(generation), text: "Synthetic held native copy"
            )
            controller.observeCopyRevision(content.revision)
            controller.showPending(revision: content.revision, source: fixture.source)
            controller.applyBaseContent(content, source: fixture.source, revision: content.revision,
                                        copyIdentity: identity, reusingActions: true)
            controller.confirmCopyIdentity(identity, revision: content.revision)
            if generation == 2 {
                activeWindow = controller.testingWindow
                activeOwner = controller.testingCopyCombo.owner
                try? await Task.sleep(for: .milliseconds(20))
                graphInstalls = controller.testingCopyCombo.testingEchoGraphInstallCount
            }
            if generation > 2 {
                expect(controller.testingCopyCombo.count == 1 && controller.testingCopyCombo.motionActive
                       && controller.testingWindow === activeWindow && activeWindow?.isVisible == true
                       && controller.testingCopyCombo.owner == activeOwner
                       && controller.testingCopyCombo.testingEchoGraphInstallCount == graphInstalls,
                       "held skipped revisions counted as contiguous, lost their host, or stopped responding")
                if generation >= 30 {
                    tailPositions.append(controller.testingCopyCombo.sample().motion.swing)
                }
            }
        }
        expect(ProcessInfo.processInfo.systemUptime - started > 3
               && tailPositions.max()! - tailPositions.min()! > 2,
               "held input longer than the ordinary lifetime froze or dismissed the card")
        controller.startDismissTimer(after: 3)
        try? await Task.sleep(for: .milliseconds(1250))
        expect(!controller.testingCopyCombo.motionActive && controller.testingWindow?.isVisible == true,
               "release did not settle before the ordinary card lifetime elapsed")
        try? await Task.sleep(for: .milliseconds(2150))
        expect(controller.testingWindow == nil,
               "a held card failed to dismiss at the ordinary lifetime after input stopped")
    }

    @MainActor
    private func verifyCompleteComboCycle() async {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fixture = ReplayFixture()
        let controller = fixture.controller
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); controller.dismissToast(animated: false) }
        func observe(_ generation: UInt64, skippingWrite: Bool = false) -> (ClipboardContent, ClipboardCopyIdentity) {
            if skippingWrite { board.clearContents() }
            let read = AppBehaviorTests.comboRead(board, generation: generation, text: "Synthetic responsive native")
            controller.observeCopyRevision(read.0.revision)
            controller.showPending(revision: read.0.revision, source: fixture.source)
            return read
        }
        func confirm(_ read: (ClipboardContent, ClipboardCopyIdentity)) {
            controller.applyBaseContent(read.0, source: fixture.source, revision: read.0.revision,
                                        copyIdentity: read.1, reusingActions: true)
            controller.confirmCopyIdentity(read.1, revision: read.0.revision)
        }
        confirm(observe(1))
        expect(controller.testingCopyCombo.testingEchoGraphInstallCount == 0,
               "a first ordinary copy installed its responsive timeline")
        confirm(observe(2))
        let window = controller.testingWindow
        let owner = controller.testingCopyCombo.owner
        let trigger = controller.testingCopyCombo.testingResponseCount
        try? await Task.sleep(for: .milliseconds(80))
        expect(abs(controller.testingCopyCombo.motion.swing) > 0.01,
               "the responsive fixture did not render a real system spring")
        let installs = controller.testingCopyCombo.testingEchoGraphInstallCount
        for generation in 3...5 {
            let read = observe(UInt64(generation))
            try? await Task.sleep(for: .milliseconds(120))
            let oldFuture = controller.testingCopyCombo.sample(at: ProcessInfo.processInfo.systemUptime + 0.05)
            confirm(read)
            expect(controller.testingWindow === window && controller.testingCopyCombo.owner == owner
                   && controller.testingCopyCombo.testingResponseCount == trigger + generation - 2
                   && controller.testingCopyCombo.testingEchoGraphInstallCount == installs,
                   "a rapid copy replaced its host/graph or failed to respond")
            try? await Task.sleep(for: .milliseconds(50))
            expect(abs(controller.testingCopyCombo.motion.swing - oldFuture.motion.swing) > 0.05
                   && controller.testingCopyCombo.testingEntranceProjection == .identity,
                   "a retargeted native frame ignored input or restored its ordinary entrance")
        }
        try? await Task.sleep(for: .milliseconds(800))
        expect(controller.testingCopyCombo.motionActive,
               "busy input did not extend its final settle deadline")
        try? await Task.sleep(for: .milliseconds(400))
        expect(!controller.testingCopyCombo.motionActive && controller.testingCopyCombo.count == 5
               && controller.testingCopyCombo.motion == CopyEchoMotion(),
               "stopping input did not settle the responsive animation")
        let settledTrigger = controller.testingCopyCombo.testingResponseCount
        try? await Task.sleep(for: .milliseconds(160))
        expect(!controller.testingCopyCombo.motionActive && controller.testingCopyCombo.testingResponseCount == settledTrigger,
               "stopping input started a queued response")
        confirm(observe(6))
        expect(controller.testingWindow !== window && controller.testingCopyCombo.motionActive,
               "a new responsive presentation did not recreate its native panel")
        let delayed = observe(7)
        let activeTrigger = controller.testingCopyCombo.testingResponseCount
        try? await Task.sleep(for: .milliseconds(1300))
        confirm(delayed)
        expect(!controller.testingCopyCombo.motionActive && controller.testingCopyCombo.testingResponseCount == activeTrigger,
               "a late confirmation replayed input after its prior motion ended")
        confirm(observe(8))
        let finalWindow = controller.testingWindow
        let beforeGapTrigger = controller.testingCopyCombo.testingResponseCount
        let reset = observe(9, skippingWrite: true)
        confirm(reset)
        expect(controller.testingWindow === finalWindow && controller.testingCopyCombo.count == 1
               && controller.testingCopyCombo.motionActive && controller.testingCopyCombo.hasEcho
               && controller.testingCopyCombo.testingResponseCount == beforeGapTrigger + 1,
               "a missing revision counted as contiguous or ignored its strictly identical active response")
        try? await Task.sleep(for: .milliseconds(1250))
        expect(!controller.testingCopyCombo.motionActive && !controller.testingCopyCombo.hasEcho,
               "a broken logical sequence retained its finished timeline")

        let lowFixture = ReplayFixture()
        let lowController = lowFixture.controller
        let monitor = ClipboardMonitor(toastController: lowController, defaults: lowFixture.defaults)
        defer { monitor.stop() }
        let preferences = PopupPresentationPreferences(mode: .lowInterruption, showShortPlainText: true,
            showLongPlainText: true, showImages: true, showFiles: true, disabledKindIDs: [])
        var lowWindow: ToastPanel?
        var lowTrigger = 0
        for generation in 1...3 {
            let (content, identity) = AppBehaviorTests.comboRead(board, generation: UInt64(generation), text: "Synthetic low responsive")
            monitor.testingPresentLowInterruption(content: content, source: lowFixture.source,
                preferences: preferences, analysisIsReady: true, copyIdentity: identity)
            if generation == 2 {
                lowWindow = lowController.testingWindow
                lowTrigger = lowController.testingCopyCombo.testingResponseCount
                try? await Task.sleep(for: .milliseconds(620))
            }
        }
        expect(lowController.testingWindow === lowWindow && lowController.testingCopyCombo.count == 3
               && lowController.testingViewModel.revision?.generation == 3
               && lowController.testingCopyCombo.testingResponseCount == lowTrigger + 1,
               "a noncoalesced light-interruption copy replaced its host or ignored retargeting")
        try? await Task.sleep(for: .milliseconds(650))
        expect(lowController.testingCopyCombo.motionActive,
               "a noncoalesced response lost its updated settle deadline")
        try? await Task.sleep(for: .milliseconds(600))
        expect(!lowController.testingCopyCombo.motionActive,
               "the final light-interruption response failed to stop")
    }

    @MainActor
    private func verifyComboDismissalGeometry() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        for (count, command, delay) in [(3, false, 1250), (2, true, 1250), (3, true, 80)] {
            let fixture = ReplayFixture()
            let controller = fixture.controller
            for generation in 1...count {
                let (content, identity) = AppBehaviorTests.comboRead(
                    board, generation: UInt64(generation), text: "Synthetic combo dismissal card"
                )
                controller.observeCopyRevision(content.revision)
                controller.showPending(revision: content.revision, source: fixture.source)
                controller.applyBaseContent(content, source: fixture.source, revision: content.revision, copyIdentity: identity)
                controller.applyActions(primary: SearchTextAction(text: "Synthetic exit action"), menu: [], revision: content.revision)
                controller.confirmCopyIdentity(identity, revision: content.revision)
            }
            try? await Task.sleep(for: .milliseconds(delay))
            controller.updateWindowSize()
            guard let window = controller.testingWindow,
                  let hosting = window.contentView?.subviews.first as? ToastHostingView else {
                fatalError("synthetic dismissal panel is missing")
            }
            expect(controller.testingCopyCombo.count == count
                   && controller.testingCopyCombo.isVisible == (count >= 3),
                   "second-copy motion and third-copy badge do not use separate thresholds")
            let frame = window.frame
            let hostingFrame = hosting.frame
            let fitting = hosting.fittingSize
            let motion = controller.testingCopyCombo.motion
            controller.onRevisionResourcesShouldCancel = { [weak controller] _ in
                controller?.interruptCopyCombo()
            }
            if command { controller.testingPerformCommand(.dismiss) }
            else { controller.startDismissTimer(after: 0.03) }
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(20))
                expect(window.frame == frame && hosting.frame == hostingFrame && hosting.fittingSize == fitting,
                       "combo dismissal changed the content layout inside an unchanged window")
                expect(controller.testingCopyCombo.count == count && controller.testingCopyCombo.motion == motion,
                       "combo dismissal cleared or moved its presentation before the window disappeared")
            }
            try? await Task.sleep(for: .milliseconds(160))
            expect(controller.testingWindow == nil && controller.testingCopyCombo.count == 0,
                   "finished dismissal retained its panel or combo presentation")
        }
    }

    @MainActor
    private func verifyComboMotionContinuity() async {
        let fixture = ReplayFixture()
        let controller = fixture.controller
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var retired: [ToastPanel] = []
        controller.testingBeforeRetiringWindow = { old, new in
            expect(old.isVisible && new.isVisible,
                   "window handoff retired its old panel before preparing the new panel")
            retired.append(old)
        }
        func copy(_ generation: UInt64, frames: Int = 6) async {
            pasteboard.clearContents()
            pasteboard.setString("Synthetic native combo motion", forType: .string)
            let revision = ClipboardRevision(generation: generation, changeCount: pasteboard.changeCount)
            let session = ClipboardLoadSession(revision: revision, backingScale: 2,
                                               comparisonIdentity: controller.copyIdentityForComparison)
            controller.observeCopyRevision(revision)
            let previousWindow = controller.testingWindow
            let confirmedCount = controller.testingCopyCombo.count
            let savedMotion = controller.testingCopyCombo.motion
            controller.showPending(revision: revision, source: fixture.source)
            let continuation = previousWindow != nil && controller.testingWindow === previousWindow
            expect(controller.testingCopyCombo.motion == savedMotion,
                   "checking identity reset the residual position")
            for _ in 0..<frames {
                try? await Task.sleep(for: .milliseconds(20))
                if continuation {
                    if confirmedCount >= 2 {
                        expect(controller.testingCopyCombo.testingEntranceProjection == .identity,
                               "an asynchronous identity check exposed the background")
                    }
                    expect(controller.testingCopyCombo.count == confirmedCount,
                           "pending advanced or erased the already-confirmed badge")
                }
                expect(continuation ? controller.testingViewModel.isContentReady
                       : controller.testingViewModel.rawContent == nil,
                       "an identity check replaced the existing card or exposed new unconfirmed content")
            }
            guard case let .content(_, content) = readBaseOnWorker(session: session, pasteboard: pasteboard)
            else { fatalError("native combo fixture read failed") }
            let identity = session.takeCopyIdentity()
            if generation == 1 {
                expect(identity?.testingDigestComputationCount == 0,
                       "the initial native copy computed an unnecessary digest")
            }
            let retainsPlayingHost = continuation && controller.testingCopyCombo.motionActive
            let graphInstalls = controller.testingCopyCombo.testingEchoGraphInstallCount
            controller.applyBaseContent(content, source: fixture.source, revision: revision, copyIdentity: identity)
            controller.confirmCopyIdentity(identity, revision: revision)
            if retainsPlayingHost {
                expect(controller.testingCopyCombo.testingEchoGraphInstallCount == graphInstalls,
                       "a busy confirmation rebuilt its active echo graph")
            }
            if generation == 1 {
                expect(controller.testingCopyCombo.testingEchoGraphInstallCount == 0,
                       "the initial native copy installed an echo graph")
            }
            expect(retainsPlayingHost ? controller.testingWindow === previousWindow
                   : controller.testingWindow !== previousWindow,
                   "a confirmed copy did not preserve only its playing native host")
            expect(retainsPlayingHost ? previousWindow?.isVisible == true : previousWindow?.isVisible != true,
                   "window handoff left the wrong panel visible")
        }
        await copy(1)
        try? await Task.sleep(for: .milliseconds(800))
        await copy(2, frames: 4)
        try? await Task.sleep(for: .milliseconds(80))
        expect(controller.testingCopyCombo.hasEcho && !controller.testingCopyCombo.isVisible,
               "the second native copy did not separate echo motion from its later badge")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            expect(controller.testingCopyCombo.testingEchoGraphInstallCount > 0
                   && abs(controller.testingCopyCombo.motion.swing) > 0.01,
                   "installing the responsive timeline lost the second-copy animation trigger")
        }
        try? await Task.sleep(for: .milliseconds(800))
        await copy(3, frames: 7)
        expect(controller.testingCopyCombo.count == 3, "visible copies more than 500 ms apart did not combine")
        try? await Task.sleep(for: .milliseconds(80))
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            expect(!controller.testingCopyCombo.motionActive, "Reduce Motion enabled residual work")
        }
        expect(controller.testingCopyCombo.testingEntranceProjection == .identity,
               "ordinary entrance remained visible under the residual animation")
        await copy(4)
        expect(controller.testingCopyCombo.count == 4, "quick replacement did not continue the residual animation")
        try? await Task.sleep(for: .milliseconds(1250))
        expect(controller.testingCopyCombo.count == 4 && !controller.testingCopyCombo.motionActive
               && controller.testingCopyCombo.motion == CopyEchoMotion(),
               "animation completion cleared the visible card's combo or retained motion")
        controller.testingHover(true)
        try? await Task.sleep(for: .milliseconds(2000))
        expect(controller.testingWindow?.isVisible == true, "hover did not keep the production panel alive")
        await copy(5)
        expect(controller.testingCopyCombo.count == 5, "hover-extended visibility lost its combo")
        controller.dismissToast(animated: true)
        await copy(6)
        expect(!controller.testingCopyCombo.isVisible,
               "a copy arriving after dismissal began continued the old sequence")
        try? await Task.sleep(for: .milliseconds(350))
        expect(controller.testingWindow?.isVisible == true && controller.testingViewModel.revision?.generation == 6,
               "a retired panel's callback removed its successor")
        expect(retired.count >= 3 && retired.allSatisfy { !$0.isVisible },
               "window handoff left an old panel visible")
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
        if CommandLine.arguments.contains("--combo-cycle") {
            copyComboHeldRevisionsKeepMoving()
            copyComboRetargetsEveryConfirmedCopy()
            copyComboBusyCopiesTransferRevision()
            copyComboNewPresentationEndsOldMotion()
            print("CopyComboCycleTests: PASS")
            return
        }
        if CommandLine.arguments.contains("--copy-reuse") {
            copyComboLazyWorkerComparisons()
            copyComboKeepsRecognizedCardWhileChecking()
            copyComboReusesCompletedRecognition()
            copyComboFinishesIncompleteRecognition()
            try copyComboBitmapStaysOrdinary()
            try copyComboContinuesFileSizeProgress()
            print("CopyReuseTests: PASS")
            return
        }
        if CommandLine.arguments.contains("--toast-transitions") || CommandLine.arguments.contains("--combo-exit")
            || CommandLine.arguments.contains("--combo-cycle-native")
            || CommandLine.arguments.contains("--held-repeat-native") {
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
        copyComboPreservesWindowAndContentContracts()
        copyComboRetargetsEveryConfirmedCopy()
        copyComboBusyCopiesTransferRevision()
        copyComboNewPresentationEndsOldMotion()
        copyComboHeldRevisionsKeepMoving()
        copyComboUsesOnlyResidualMotion()
        copyComboThresholdAndDelayedConfirmation()
        try copyComboSettingsAndBadge()
        copyComboHonorsClassificationAndCoalescing()
        copyComboCleansUpAfterInteractionAndInactivity()
        copyComboLazyWorkerComparisons()
        copyComboKeepsRecognizedCardWhileChecking()
        copyComboReusesCompletedRecognition()
        copyComboFinishesIncompleteRecognition()
        try copyComboBitmapStaysOrdinary()
        try copyComboContinuesFileSizeProgress()
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

    fileprivate static func comboRead(
        _ pasteboard: NSPasteboard, generation: UInt64, text: String
    ) -> (ClipboardContent, ClipboardCopyIdentity) {
        pasteboard.clearContents()
        expect(pasteboard.setString(text, forType: .string), "synthetic combo write failed")
        let revision = ClipboardRevision(generation: generation, changeCount: pasteboard.changeCount)
        let session = ClipboardLoadSession(revision: revision, backingScale: 2)
        guard case let .content(_, content) = readBaseOnWorker(session: session, pasteboard: pasteboard),
              let identity = session.confirmedCopyIdentity else {
            fatalError("synthetic combo base read failed")
        }
        onCopyWorker { identity.prepareComparison(with: identity) }
        return (content, identity)
    }

    private static func copyComboPreservesWindowAndContentContracts() {
        let fixture = ReplayFixture()
        let controller = fixture.controller
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let text = String(repeating: "Synthetic preview ", count: 20) + "A"
        var previousWindow: ToastPanel?
        var ordinarySize = NSSize.zero
        for generation in 1...4 {
            let (content, identity) = comboRead(pasteboard, generation: UInt64(generation), text: text)
            controller.observeCopyRevision(content.revision)
            controller.showPending(revision: content.revision, source: fixture.source)
            expect(generation == 1 ? controller.testingWindow !== previousWindow
                   : controller.testingWindow === previousWindow,
                   "checking a repeat replaced the visible card before identity confirmation")
            expect(controller.testingViewModel.phase == (generation == 1 ? .pending : .ready)
                   && controller.testingCopyCombo.count == (generation > 2 ? generation - 1 : 0),
                   "an identity check changed the confirmed content or count")
            let retainsPlayingHost = controller.testingCopyCombo.motionActive && generation >= 3
            controller.applyBaseContent(content, source: fixture.source, revision: content.revision, copyIdentity: identity)
            expect(retainsPlayingHost ? controller.testingWindow === previousWindow
                   : controller.testingWindow !== previousWindow,
                   "a confirmed copy used the wrong active-round handoff")
            previousWindow = controller.testingWindow
            controller.confirmCopyIdentity(identity, revision: content.revision)
            let count = generation >= 2 ? generation : 0
            expect(controller.testingCopyCombo.count == count
                   && controller.testingCopyCombo.hasEcho == (generation >= 2)
                   && controller.testingCopyCombo.isVisible == (generation >= 3),
                   "second-copy motion and third-copy badge did not activate independently")
            expect(controller.testingCopyCombo.entranceSuppressed == (generation >= 2),
                   "ordinary copies or confirmed combos selected the wrong entrance motion")
            controller.confirmCopyIdentity(identity, revision: content.revision)
            controller.applyEnrichment(content, revision: content.revision)
            controller.applyActions(primary: SearchTextAction(text: text), menu: [], revision: content.revision)
            expect(controller.testingCopyCombo.count == count, "an async update incremented the count")
            controller.updateWindowSize()
            if generation == 1 { ordinarySize = controller.testingWindow!.frame.size }
            if generation >= 2 {
                let size = controller.testingWindow!.frame.size
                expect(abs(size.width - ordinarySize.width - 60) < 1
                       && abs(size.height - ordinarySize.height - 32) < 1,
                       "combo drawing did not reserve its own padding around the intrinsic card")
            }
        }
        let (different, identity) = comboRead(pasteboard, generation: 5, text: String(text.dropLast()) + "B")
        expect(different.preview == controller.testingViewModel.previewText,
               "the same-preview fixture no longer shares a preview")
        controller.observeCopyRevision(different.revision)
        controller.showPending(revision: different.revision, source: fixture.source)
        controller.applyBaseContent(different, source: fixture.source, revision: different.revision, copyIdentity: identity)
        controller.confirmCopyIdentity(identity, revision: different.revision)
        expect(!controller.testingCopyCombo.isVisible && !controller.testingCopyCombo.entranceSuppressed,
               "different full bodies inherited the combo or lost their ordinary entrance")
    }

    private static func copyComboKeepsRecognizedCardWhileChecking() {
        let fixture = ReplayFixture()
        let controller = fixture.controller
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let (first, identity) = comboRead(board, generation: 1, text: "Synthetic recognized copy")
        controller.observeCopyRevision(first.revision)
        controller.showPending(revision: first.revision, source: fixture.source)
        controller.applyBaseContent(first, source: fixture.source, revision: first.revision)
        controller.confirmCopyIdentity(identity, revision: first.revision)
        let action = SearchTextAction(text: first.rawText!)
        controller.applyActions(primary: action, menu: [], revision: first.revision)
        let window = controller.testingWindow
        let (second, _) = comboRead(board, generation: 2, text: "Synthetic recognized copy")
        controller.observeCopyRevision(second.revision)
        controller.showPending(revision: second.revision, source: fixture.source)
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        expect(controller.testingWindow === window && controller.testingViewModel.isContentReady
               && controller.testingViewModel.previewText == first.preview
               && controller.testingViewModel.primaryAction?.id == action.id
               && controller.testingViewModel.revision == first.revision,
               "checking a possible repeat replaced the recognized card with a generic placeholder")
    }

    private static func copyComboLazyWorkerComparisons() {
        let fixture = ReplayFixture()
        fixture.defaults.set(CopySoundFeedback.disabledValue, forKey: CopySoundFeedback.defaultsKey)
        let controller = fixture.controller
        let monitor = ClipboardMonitor(toastController: controller, defaults: fixture.defaults)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); monitor.stop() }
        var identities: [ClipboardCopyIdentity] = []
        for generation in 1...3 {
            board.clearContents()
            board.setString("Synthetic production lazy comparison", forType: .string)
            let session = monitor.testingBeginCopy(
                .init(generation: UInt64(generation), changeCount: board.changeCount), source: fixture.source
            )!
            let outcome = readBaseOnWorker(session: session, pasteboard: board)
            let identity = session.confirmedCopyIdentity!
            identities.append(identity)
            expect(identity.testingDigestComputationCount == (generation == 1 ? 0 : 1),
                   "the production base path computed SHA before it needed a comparison")
            monitor.testingFinishCopy(outcome, session: session)
            if generation == 1 {
                expect(!controller.testingCopyCombo.hasEcho
                       && controller.testingCopyCombo.testingEchoGraphInstallCount == 0
                       && identity.testingDigestComputationCount == 0,
                       "first confirmation installed residual work or hashed its body")
            }
        }
        expect(identities.map(\.testingDigestComputationCount) == [1, 1, 1],
               "the production reducer or controller recalculated a memo on the main thread")
        controller.dismissToast(animated: false)
        board.clearContents()
        board.setString("Synthetic copy after dismissal", forType: .string)
        let fresh = monitor.testingBeginCopy(.init(generation: 4, changeCount: board.changeCount), source: fixture.source)!
        let outcome = readBaseOnWorker(session: fresh, pasteboard: board)
        expect(fresh.confirmedCopyIdentity?.testingDigestComputationCount == 0,
               "a missing visible card caused an eager comparison")
        monitor.testingFinishCopy(outcome, session: fresh)

        let lowFixture = ReplayFixture()
        let lowController = lowFixture.controller
        let lowMonitor = ClipboardMonitor(toastController: lowController, defaults: lowFixture.defaults)
        let preferences = PopupPresentationPreferences(mode: .lowInterruption, showShortPlainText: true,
            showLongPlainText: true, showImages: true, showFiles: true, disabledKindIDs: [])
        let prefix = String(repeating: "Synthetic identical preview ", count: 20)
        var lowIdentities: [ClipboardCopyIdentity] = []
        for generation in 1...3 {
            board.clearContents()
            board.setString(prefix + (generation == 1 ? "A" : "B"), forType: .string)
            let revision = ClipboardRevision(generation: UInt64(generation), changeCount: board.changeCount)
            let session = ClipboardLoadSession(revision: revision, backingScale: 2,
                                               comparisonIdentity: lowController.copyIdentityForComparison)
            guard case let .content(_, content) = readBaseOnWorker(session: session, pasteboard: board),
                  let identity = session.takeCopyIdentity() else { fatalError("synthetic low comparison read failed") }
            lowIdentities.append(identity)
            lowMonitor.testingPresentLowInterruption(content: content, source: lowFixture.source,
                preferences: preferences, analysisIsReady: true, copyIdentity: identity)
        }
        expect(lowIdentities.map(\.testingDigestComputationCount) == [1, 1, 1]
               && lowIdentities[0] != lowIdentities[1] && lowIdentities[1] == lowIdentities[2],
               "coalescing failed to prepare a previous reducer identity distinct from the visible card")
        expect(lowController.testingViewModel.rawContent?.rawText == prefix + "A"
               && !lowController.testingCopyCombo.hasEcho,
               "a same-preview different full body took over the visible card or its animation")
    }

    private static func waitForCopy(_ message: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        expect(condition(), message)
    }

    private static func copyComboReusesCompletedRecognition() {
        let fixture = ReplayFixture()
        fixture.defaults.set(CopySoundFeedback.disabledValue, forKey: CopySoundFeedback.defaultsKey)
        let controller = fixture.controller
        let monitor = ClipboardMonitor(toastController: controller, defaults: fixture.defaults)
        monitor.testingObserveDefaults()
        let detector = CopyReuseDetector()
        DetectionRegistry.shared.register(detector)
        let resolves = CopyReuseCounter()
        ActionResolver.testingOnResolve = { resolves.increment() }
        let board = NSPasteboard.withUniqueName()
        defer {
            board.releaseGlobally()
            DetectionRegistry.shared.unregister(kind: detector.kind)
            ActionResolver.testingOnResolve = nil
        }
        let text = String(repeating: "Synthetic repeated clipboard content ", count: 10) + "A"
        func begin(_ generation: UInt64, text: String, source: SourceAppInfo? = nil) -> ClipboardLoadSession {
            board.clearContents()
            board.setString(text, forType: .string)
            let revision = ClipboardRevision(generation: generation, changeCount: board.changeCount)
            return monitor.testingBeginCopy(revision, source: source ?? fixture.source)!
        }
        func finish(_ session: ClipboardLoadSession) {
            monitor.testingFinishCopy(readBaseOnWorker(session: session, pasteboard: board), session: session)
        }
        finish(begin(1, text: text))
        waitForCopy("initial text recognition did not complete") { controller.testingViewModel.primaryAction != nil }
        let detectionID = controller.testingViewModel.rawContent!.detections.first!.id
        let firstIcon = controller.testingViewModel.iconSymbolName
        let firstType = controller.testingViewModel.typeLabel
        let actionID = controller.testingViewModel.primaryAction!.id
        for generation in 2...3 {
            let source = SourceAppInfo(name: "Synthetic fresh source", icon: nil, bundleIdentifier: "test.new-source")
            let session = begin(UInt64(generation), text: text, source: source)
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            expect(controller.testingViewModel.isContentReady
                   && controller.testingViewModel.iconSymbolName == firstIcon
                   && controller.testingViewModel.primaryAction?.id == actionID,
                   "a repeat's identity check erased the recognized presentation")
            finish(session)
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            expect(controller.testingViewModel.typeLabel == firstType
                   && controller.testingViewModel.rawContent?.detections.first?.id == detectionID
                   && controller.testingViewModel.primaryAction?.id == actionID
                   && controller.testingViewModel.revision == session.revision
                   && controller.testingViewModel.sourceBundleID == source.bundleIdentifier,
                   "a confirmed repeat lost its recognized facts, Action, revision, or fresh source")
        }
        expect(detector.calls.count == 1 && resolves.count == 1 && controller.testingCopyCombo.count == 3,
               "identical copies repeated detection or Action resolution")
        let changed = begin(4, text: String(text.dropLast()) + "B")
        finish(changed)
        waitForCopy("changed text did not receive fresh recognition") { detector.calls.count == 2 && resolves.count == 2 && controller.testingViewModel.primaryAction != nil }
        expect(controller.testingViewModel.rawContent?.rawText != text && !controller.testingCopyCombo.isVisible,
               "same-preview different content reused the old copy")
        fixture.defaults.set("bing", forKey: "searchEngine")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: fixture.defaults)
        finish(begin(5, text: String(text.dropLast()) + "B"))
        waitForCopy("changed settings did not invalidate recognition reuse") { detector.calls.count == 3 && resolves.count == 3 && controller.testingViewModel.primaryAction != nil }

        let late = begin(6, text: String(text.dropLast()) + "B")
        let outcome = readBaseOnWorker(session: late, pasteboard: board)
        controller.dismissToast(animated: false)
        monitor.testingFinishCopy(outcome, session: late)
        expect(!late.accepts(late.revision) && controller.testingWindow == nil,
               "a late repeat revived the dismissed card")

        finish(begin(7, text: text))
        waitForCopy("the interaction fixture did not finish recognition") { controller.testingViewModel.primaryAction != nil }
        let visibleRevision = controller.testingViewModel.revision!
        controller.applyActions(primary: CalculateAction(expression: "2+2"), menu: [], revision: visibleRevision)
        let interrupted = begin(8, text: text)
        let interruptedOutcome = readBaseOnWorker(session: interrupted, pasteboard: board)
        controller.testingPerformCommand(.performPrimary)
        monitor.testingFinishCopy(interruptedOutcome, session: interrupted)
        expect(!interrupted.accepts(interrupted.revision)
               && controller.testingViewModel.revision == visibleRevision
               && controller.testingViewModel.resultOverlay?.copyText == "4",
               "acting on the retained card failed to cancel its unconfirmed successor")
    }

    private static func copyComboFinishesIncompleteRecognition() {
        let fixture = ReplayFixture()
        fixture.defaults.set(CopySoundFeedback.disabledValue, forKey: CopySoundFeedback.defaultsKey)
        let monitor = ClipboardMonitor(toastController: fixture.controller, defaults: fixture.defaults)
        let calls = CopyReuseCounter()
        let release = DispatchSemaphore(value: 0)
        ActionResolver.testingOnResolve = {
            calls.increment()
            if calls.count == 1 { release.wait() }
        }
        let board = NSPasteboard.withUniqueName()
        defer { release.signal(); board.releaseGlobally(); ActionResolver.testingOnResolve = nil }
        func copy(_ generation: UInt64) {
            board.clearContents()
            board.setString("Synthetic unfinished recognition", forType: .string)
            let revision = ClipboardRevision(generation: generation, changeCount: board.changeCount)
            let session = monitor.testingBeginCopy(revision, source: fixture.source)!
            monitor.testingFinishCopy(readBaseOnWorker(session: session, pasteboard: board), session: session)
        }
        copy(1)
        waitForCopy("initial Action work did not start") { calls.count == 1 }
        copy(2)
        expect(fixture.controller.testingViewModel.isContentReady,
               "an unfinished repeat reverted to a generic placeholder")
        release.signal()
        waitForCopy("unfinished recognition was treated as a completed reusable result") {
            fixture.controller.testingViewModel.primaryAction != nil
        }
        expect(fixture.controller.testingViewModel.revision?.generation == 2,
               "the cancelled recognition worker replaced its successor")
    }

    private static func copyComboBitmapStaysOrdinary() throws {
        let fixture = ReplayFixture()
        fixture.defaults.set(CopySoundFeedback.disabledValue, forKey: CopySoundFeedback.defaultsKey)
        let monitor = ClipboardMonitor(toastController: fixture.controller, defaults: fixture.defaults)
        let board = NSPasteboard.withUniqueName()
        let decodes = CopyReuseCounter()
        ClipboardImageEnricher.testingOnBitmapEnrich = { decodes.increment() }
        defer {
            board.releaseGlobally()
            ClipboardImageEnricher.testingOnBitmapEnrich = nil
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = bitmap.representation(using: .png, properties: [:])!
        func copy(_ generation: UInt64, bitmap: Bool) -> ClipboardLoadSession {
            board.clearContents()
            if bitmap { board.setData(data, forType: .png) }
            else { board.setString("Synthetic text interrupted by a bitmap", forType: .string) }
            let revision = ClipboardRevision(generation: generation, changeCount: board.changeCount)
            let session = monitor.testingBeginCopy(revision, source: fixture.source)!
            let outcome = readBaseOnWorker(session: session, pasteboard: board)
            if bitmap { expect(session.confirmedCopyIdentity == nil, "a bitmap created a combo identity") }
            monitor.testingFinishCopy(outcome, session: session)
            return session
        }
        _ = copy(1, bitmap: false)
        waitForCopy("text fixture did not finish") { fixture.controller.testingViewModel.primaryAction != nil }
        _ = copy(2, bitmap: false)
        expect(fixture.controller.testingCopyCombo.count == 2, "text fixture did not establish a chain")
        for generation in 3...4 {
            let session = copy(UInt64(generation), bitmap: true)
            waitForCopy("a repeated bitmap did not decode normally") {
                decodes.count == generation - 2 && fixture.controller.testingViewModel.thumbnailImage != nil
            }
            expect(!fixture.controller.testingCopyCombo.hasEcho && session.takeImageData() == nil,
                   "a bitmap participated in a combo or retained a second encoded-data cache")
        }
        _ = copy(5, bitmap: false)
        expect(!fixture.controller.testingCopyCombo.hasEcho, "a bitmap failed to interrupt the text chain")
    }

    private static func copyComboContinuesFileSizeProgress() throws {
        let fixture = ReplayFixture()
        fixture.defaults.set(CopySoundFeedback.disabledValue, forKey: CopySoundFeedback.defaultsKey)
        let advance = DispatchSemaphore(value: 0)
        let complete = DispatchSemaphore(value: 0)
        let traversals = CopyReuseCounter()
        let coordinator = ClipboardDirectorySizeCoordinator(calculator: { _, _, shouldCancel, _, progress in
            traversals.increment()
            progress(1_024)
            advance.wait()
            guard !shouldCancel() else { return .cancelled }
            progress(4_096)
            complete.wait()
            return shouldCancel() ? .cancelled : .exact(8_192)
        })
        let monitor = ClipboardMonitor(toastController: fixture.controller, defaults: fixture.defaults,
                                       directorySizeCoordinator: coordinator)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Copied-reuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let board = NSPasteboard.withUniqueName()
        defer {
            advance.signal(); complete.signal(); coordinator.cancelAll()
            board.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
        func copy(_ generation: UInt64) {
            board.clearContents()
            board.writeObjects([root as NSURL])
            let revision = ClipboardRevision(generation: generation, changeCount: board.changeCount)
            let previous = fixture.controller.testingViewModel.detailInfo
            let session = monitor.testingBeginCopy(revision, source: fixture.source)!
            if generation > 1 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                expect(fixture.controller.testingViewModel.detailInfo == previous,
                       "a file repeat cleared its existing size while checking identity")
            }
            monitor.testingFinishCopy(readBaseOnWorker(session: session, pasteboard: board), session: session)
            if generation > 1 {
                expect(fixture.controller.testingViewModel.detailInfo == previous,
                       "a confirmed file repeat reset its size to base facts")
            }
        }
        copy(1)
        let lower = String(localized: "至少 \(ByteCountFormatter.string(fromByteCount: 1_024, countStyle: .file))")
        waitForCopy("initial directory progress did not appear") { fixture.controller.testingViewModel.detailIsLoading && fixture.controller.testingViewModel.detailInfo == lower }
        copy(2)
        advance.signal()
        let higher = String(localized: "至少 \(ByteCountFormatter.string(fromByteCount: 4_096, countStyle: .file))")
        waitForCopy("directory progress did not continue after repeat") { fixture.controller.testingViewModel.detailInfo == higher }
        copy(3)
        let transition = fixture.controller.testingViewModel.contentTransitionID
        waitForCopy("the repeated directory did not reconnect to its running task") {
            fixture.controller.testingViewModel.contentTransitionID > transition
        }
        complete.signal()
        waitForCopy("directory size did not complete after repeat") { !fixture.controller.testingViewModel.detailIsLoading }
        expect(traversals.count == 1 && fixture.controller.testingCopyCombo.count == 3
               && fixture.controller.testingViewModel.detailInfo == ByteCountFormatter.string(fromByteCount: 8_192, countStyle: .file),
               "file-size progress restarted, stopped advancing, or failed to finish during a combo")
    }

    private static func copyComboUsesOnlyResidualMotion() {
        var combo = ClipboardCopyCombo()
        let identity = ClipboardCopyIdentity.text("Synthetic motion exclusivity")
        var hit: ClipboardCopyCombo.Hit!
        for index in 1...3 {
            let revision = ClipboardRevision(generation: UInt64(index), changeCount: index)
            combo.observe(revision, at: Double(index) * 0.125)
            hit = combo.confirm(identity, revision: revision)
        }
        let presentation = ToastCopyComboPresentation()
        let ordinary = ToastEntranceMotion(progress: 0.25, style: .standard, presentation: presentation, owner: 0)
        expect(ordinary.projection.scale < 1 && ordinary.projection.offsetY < 0
               && ordinary.projection.blur > 0 && ordinary.projection.opacity == 0.25,
               "the ordinary entrance lost its spring projection")
        let rapid = ToastEntranceMotion(progress: 0.25, style: .rapidReplacement, presentation: presentation, owner: 0)
        expect(rapid.projection.scale == 1 && rapid.projection.offsetY == 0
               && rapid.projection.blur == 0 && rapid.projection.opacity == 0.25,
               "ordinary rapid replacement lost its existing fade")
        presentation.activate(hit, reduceMotion: false)
        for progress in [CGFloat(0), 0.25, 0.9, 1.1] {
            for style in [ToastEntranceStyle.standard, .rapidReplacement, .replay] {
                let entrance = ToastEntranceMotion(progress: progress, style: style,
                                                   presentation: presentation, owner: 0)
                expect(entrance.projection == .identity,
                       "a confirmed combo retained an old spring or fade projection")
            }
        }
        presentation.clear()
        expect(ordinary.projection == .identity, "ending a combo resumed its superseded entrance")
        let reduced = ToastCopyComboPresentation()
        reduced.activate(hit, reduceMotion: true)
        expect(reduced.count == 3 && reduced.entranceSuppressed && !reduced.motionActive && reduced.testingResponseCount == 0,
               "Reduce Motion scheduled a residual animation or left the old entrance active")
    }

    private static func copyComboHeldRevisionsKeepMoving() {
        let clock = ReplayClock()
        clock.now = 0
        let presentation = ToastCopyComboPresentation(now: { clock.now })
        var combo = ClipboardCopyCombo()
        let identity = ClipboardCopyIdentity.text("Synthetic held skipped revisions")
        var changeCount = 0
        var tailPositions: [Double] = []
        var tailVelocity = 0.0
        for generation in 1...102 {
            clock.now = Double(generation - 1) * 0.075
            changeCount += generation <= 2 ? 1 : (generation.isMultiple(of: 2) ? 2 : 3)
            let revision = ClipboardRevision(generation: UInt64(generation), changeCount: changeCount)
            combo.observe(revision, at: clock.now)
            let hit = combo.confirm(identity, revision: revision)!
            if generation > 2 {
                expect(hit.count == 1, "held input loosened strict missing-revision counting")
            }
            guard hit.count >= 2 || presentation.motionActive else { continue }
            let before = presentation.sample()
            expect(presentation.activate(hit, reduceMotion: false), "a confirmed held input was ignored")
            let after = presentation.sample()
            for (a, b) in [(before.motion.swing, after.motion.swing), (before.motion.trail, after.motion.trail),
                           (before.motion.spread, after.motion.spread), (before.velocity.swing, after.velocity.swing),
                           (before.velocity.trail, after.velocity.trail), (before.velocity.spread, after.velocity.spread)] {
                expect(abs(a - b) < 1e-9, "held retargeting broke position or velocity continuity")
            }
            if generation >= 80 {
                let sample = presentation.sample(at: clock.now + 0.03)
                tailPositions.append(sample.motion.swing)
                tailVelocity = max(tailVelocity, abs(sample.velocity.swing))
            }
        }
        expect(tailPositions.max()! - tailPositions.min()! > 2 && tailVelocity > 10,
               "held skipped revisions pinned the spring to a fixed target")
        let settled = presentation.sample(at: clock.now + ToastCopyComboPresentation.displayDuration)
        expect(abs(settled.motion.swing) < 1e-7 && abs(settled.velocity.swing) < 1e-5,
               "held input did not naturally return to center after release")
    }

    private static func copyComboRetargetsEveryConfirmedCopy() {
        let clock = ReplayClock()
        clock.now = 0
        let presentation = ToastCopyComboPresentation(now: { clock.now })
        expect(presentation.sample().motion == CopyEchoMotion() && !presentation.motionActive,
               "an ordinary presentation prepared motion before its first combo")
        expect(presentation.activate(.init(count: 2, impulse: 0.8, direction: 1), reduceMotion: false),
               "the initial combo did not start motion")
        let trigger = presentation.testingResponseCount
        func matches(_ a: CopyEchoMotion, _ b: CopyEchoMotion, tolerance: Double = 1e-9) -> Bool {
            abs(a.swing - b.swing) < tolerance && abs(a.trail - b.trail) < tolerance
                && abs(a.spread - b.spread) < tolerance
        }
        for count in 3...80 {
            clock.now += [0.016, 0.037, 0.08][count % 3]
            let before = presentation.sample()
            let oldFuture = presentation.sample(at: clock.now + 0.04)
            expect(presentation.activate(.init(count: count, impulse: 0.8,
                       direction: count.isMultiple(of: 2) ? 1 : -1), reduceMotion: false),
                   "a busy confirmed copy was ignored instead of retargeting")
            let after = presentation.sample()
            expect(matches(before.motion, after.motion) && matches(before.velocity, after.velocity),
                   "retargeting jumped position, opacity, spread, or velocity")
            let newFuture = presentation.sample(at: clock.now + 0.04)
            expect(!matches(oldFuture.motion, newFuture.motion, tolerance: 1e-4),
                   "an accepted copy failed to change the following animation frames")
            expect(presentation.count == count && presentation.testingResponseCount == trigger + count - 2,
                   "a confirmed copy did not publish exactly one responsive update")
        }
        let release = clock.now + 0.08
        let beforeRelease = presentation.sample(at: release - 1e-8)
        let afterRelease = presentation.sample(at: release + 1e-8)
        expect(matches(beforeRelease.motion, afterRelease.motion, tolerance: 1e-5)
               && matches(beforeRelease.velocity, afterRelease.velocity, tolerance: 0.001),
               "returning to center broke the target pulse's C1 continuity")
        for count in 81...1_080 {
            clock.now += 0.008
            presentation.activate(.init(count: count, impulse: 0.8,
                direction: count % 4 < 2 ? 1 : -1), reduceMotion: false)
            for step in 0...3 {
                let sample = presentation.sample(at: clock.now + Double(step) * 0.002)
                expect(abs(sample.motion.swing) < 12 && abs(sample.motion.trail) < 1.05
                       && abs(sample.motion.spread) < 1.05,
                       "rapid retargeting accumulated unbounded motion")
            }
        }
        let settled = presentation.sample(at: clock.now + ToastCopyComboPresentation.displayDuration)
        expect(matches(settled.motion, CopyEchoMotion(), tolerance: 1e-7)
               && matches(settled.velocity, CopyEchoMotion(), tolerance: 1e-5),
               "stopping input did not naturally settle position and velocity")
        let finalTrigger = presentation.testingResponseCount
        presentation.stopMotion()
        expect(!presentation.activate(.init(count: 1_081, impulse: 0.8, direction: 1),
                    reduceMotion: false, mayStartMotion: false)
               && presentation.testingResponseCount == finalTrigger && !presentation.motionActive,
               "a late confirmation replayed input after motion stopped")
        expect(!presentation.activate(.init(count: 1_082, impulse: 0.8, direction: 1), reduceMotion: true)
               && !presentation.motionActive && presentation.sample().motion == CopyEchoMotion(),
               "Reduce Motion retained a trajectory or scheduled responsive work")
    }

    private static func copyComboBusyCopiesTransferRevision() {
        let fixture = ReplayFixture()
        let controller = fixture.controller
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var busyWindow: ToastPanel?
        var busyPresentation: Int?
        var busyTrigger = 0
        var firstCommand: ((ToastCommand<any ClipboardAction>) -> Void)?
        var playingCommand: ((ToastCommand<any ClipboardAction>) -> Void)?
        var previous: ClipboardContent?
        let action = SearchTextAction(text: "Synthetic latest cycle action")
        for generation in 1...4 {
            let (content, identity) = comboRead(board, generation: UInt64(generation), text: "Synthetic complete-cycle card")
            let source = SourceAppInfo(name: "Synthetic source \(generation)", icon: nil,
                                       bundleIdentifier: "test.cycle-source-\(generation)")
            controller.observeCopyRevision(content.revision)
            controller.showPending(revision: content.revision, source: source)
            controller.applyBaseContent(content, source: source, revision: content.revision,
                                        copyIdentity: identity, reusingActions: generation > 1)
            controller.confirmCopyIdentity(identity, revision: content.revision)
            if generation == 1 {
                controller.applyActions(primary: action, menu: [], revision: content.revision)
                firstCommand = controller.testingCommandCallback
            }
            if generation == 2 {
                busyWindow = controller.testingWindow
                busyPresentation = controller.resultPresentation(for: content.revision)
                busyTrigger = controller.testingCopyCombo.testingResponseCount
                playingCommand = controller.testingCommandCallback
            }
            if generation >= 3 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                expect(controller.testingWindow === busyWindow
                       && controller.resultPresentation(for: content.revision) == busyPresentation
                       && controller.testingCopyCombo.testingResponseCount == busyTrigger + generation - 2,
                       "a confirmed busy copy replaced its active host or failed to retarget")
                expect(controller.testingViewModel.revision == content.revision
                       && controller.testingViewModel.sourceAppName == source.name
                       && controller.testingViewModel.sourceBundleID == source.bundleIdentifier
                       && controller.testingViewModel.primaryAction?.id == action.id,
                       "an in-place copy lost its latest revision, source, or resolved action")
                let snapshot = fixture.store.snapshotForReplay()
                expect(snapshot?.content.revision == content.revision
                       && snapshot?.primaryAction?.id == action.id,
                       "an in-place copy failed to record the latest replay snapshot")
                if let previous, let busyPresentation {
                    controller.showResultOverlay(displayText: "Synthetic stale result", copyText: nil,
                        revision: previous.revision, presentation: busyPresentation)
                    controller.applyEnrichment(previous, revision: previous.revision)
                    controller.applyActions(primary: nil, menu: [], revision: previous.revision)
                    expect(controller.testingViewModel.revision == content.revision
                           && controller.testingViewModel.resultOverlay == nil
                           && controller.testingViewModel.primaryAction?.id == action.id,
                           "an old revision callback changed an in-place successor")
                }
            }
            previous = content
        }
        var cancelledRevision: ClipboardRevision?
        controller.onRevisionResourcesShouldCancel = { cancelledRevision = $0 }
        firstCommand?(.dismiss)
        expect(cancelledRevision == nil && controller.testingWindow?.isVisible == true,
               "a retired native host's command callback affected its successor")
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            controller.testingCommandCallback?(.dismiss)
        } else {
            playingCommand?(.dismiss)
        }
        expect(cancelledRevision == previous?.revision,
               "the playing host's actual command callback lost the latest revision")
    }

    private static func copyComboNewPresentationEndsOldMotion() {
        for hasPending in [false, true] {
            let fixture = ReplayFixture()
            let controller = fixture.controller
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            for generation in 1...2 {
                let (content, identity) = comboRead(board, generation: UInt64(generation), text: "Synthetic invalidated cycle")
                controller.observeCopyRevision(content.revision)
                controller.showPending(revision: content.revision, source: fixture.source)
                controller.applyBaseContent(content, source: fixture.source, revision: content.revision, copyIdentity: identity)
                controller.confirmCopyIdentity(identity, revision: content.revision)
            }
            let oldWindow = controller.testingWindow
            let trigger = controller.testingCopyCombo.testingResponseCount
            let (content, identity) = comboRead(board, generation: 3, text: "Synthetic invalidated cycle")
            controller.observeCopyRevision(content.revision)
            controller.invalidateCopyReuse()
            if hasPending {
                controller.showPending(revision: content.revision, source: fixture.source)
            } else {
                controller.show(content: content, source: fixture.source, copyIdentity: identity)
            }
            expect(controller.testingWindow !== oldWindow && !controller.testingCopyCombo.motionActive
                   && controller.testingCopyCombo.motion == CopyEchoMotion(),
                   "a fresh presentation inherited an active motion flag without its old timeline")
            if hasPending {
                controller.applyBaseContent(content, source: fixture.source, revision: content.revision, copyIdentity: identity)
            }
            controller.confirmCopyIdentity(identity, revision: content.revision)
            expect(!controller.testingCopyCombo.motionActive && controller.testingCopyCombo.testingResponseCount == trigger,
                   "an invalidated busy copy replayed the cancelled old round on a new host")
        }
    }

    private static func copyComboThresholdAndDelayedConfirmation() {
        for gap in [0.5, 0.8, 2.9, 60] {
            let fixture = ReplayFixture()
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            for index in 0..<3 {
                let (content, identity) = comboRead(pasteboard, generation: UInt64(index + 1), text: "Synthetic threshold")
                fixture.controller.observeCopyRevision(content.revision, at: 1 + Double(index) * gap)
                fixture.controller.showPending(revision: content.revision, source: fixture.source)
                fixture.controller.applyBaseContent(content, source: fixture.source, revision: content.revision)
                fixture.controller.confirmCopyIdentity(identity, revision: content.revision)
            }
            expect(fixture.controller.testingCopyCombo.count == 3
                   && fixture.controller.testingCopyCombo.entranceSuppressed,
                   "elapsed time broke a still-visible presentation's combo")
        }
        let fixture = ReplayFixture()
        let controller = fixture.controller
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for generation in 1...2 {
            let (content, identity) = comboRead(pasteboard, generation: UInt64(generation), text: "Synthetic delayed confirmation")
            controller.observeCopyRevision(content.revision, at: Double(generation) * 0.125)
            controller.showPending(revision: content.revision, source: fixture.source)
            controller.applyBaseContent(content, source: fixture.source, revision: content.revision)
            controller.confirmCopyIdentity(identity, revision: content.revision)
        }
        let (delayed, identity) = comboRead(pasteboard, generation: 3, text: "Synthetic delayed confirmation")
        controller.observeCopyRevision(delayed.revision, at: 0.375)
        controller.showPending(revision: delayed.revision, source: fixture.source)
        RunLoop.main.run(until: Date().addingTimeInterval(2.05))
        expect(controller.testingViewModel.isContentReady && controller.testingViewModel.revision != delayed.revision
               && !controller.testingCopyCombo.isVisible,
               "the delayed identity check replaced its confirmed card")
        controller.applyBaseContent(delayed, source: fixture.source, revision: delayed.revision, copyIdentity: identity)
        controller.confirmCopyIdentity(identity, revision: delayed.revision)
        expect(controller.testingCopyCombo.count == 3 && controller.testingCopyCombo.entranceSuppressed
               && !controller.testingCopyCombo.motionActive && controller.testingCopyCombo.testingResponseCount == 1,
               "a copy observed during playback queued a late animation after its round ended")
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        expect(controller.testingCopyCombo.count == 3,
               "the confirmed animation lost its count")
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        expect(controller.testingCopyCombo.count == 3 && !controller.testingCopyCombo.motionActive
               && controller.testingCopyCombo.entranceSuppressed,
               "settling the motion cleared the visible presentation's sequence")
        controller.confirmCopyIdentity(identity, revision: delayed.revision)
        expect(controller.testingCopyCombo.count == 3 && !controller.testingCopyCombo.motionActive,
               "a duplicate confirmation restarted the residual animation")
    }

    private static func copyComboSettingsAndBadge() throws {
        let fixture = ReplayFixture()
        let controller = fixture.controller
        let monitor = ClipboardMonitor(toastController: controller, defaults: fixture.defaults)
        monitor.testingObserveDefaults()
        expect(monitor.testingRecordsCopyIdentity, "the default-enabled combo skipped identity work")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        func copy(_ generation: UInt64) {
            pasteboard.clearContents()
            pasteboard.setString("Synthetic combo setting", forType: .string)
            let revision = ClipboardRevision(generation: generation, changeCount: pasteboard.changeCount)
            let session = ClipboardLoadSession(revision: revision, backingScale: 2,
                                               recordsCopyIdentity: monitor.testingRecordsCopyIdentity,
                                               comparisonIdentity: controller.copyIdentityForComparison)
            controller.observeCopyRevision(revision)
            controller.showPending(revision: revision, source: fixture.source)
            guard case let .content(_, content) = readBaseOnWorker(session: session, pasteboard: pasteboard)
            else { fatalError("synthetic settings fixture read failed") }
            if !monitor.testingRecordsCopyIdentity {
                expect(session.confirmedCopyIdentity == nil, "the disabled combo calculated an identity")
            }
            controller.applyBaseContent(content, source: fixture.source, revision: revision)
            controller.confirmCopyIdentity(session.takeCopyIdentity(), revision: revision)
        }
        for generation in 1...3 { copy(UInt64(generation)) }
        expect(controller.testingCopyCombo.badgeText == "连击×3", "badge omitted its localized combo label")
        fixture.defaults.set(false, forKey: ClipboardCopyCombo.enabledKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: fixture.defaults)
        expect(!monitor.testingRecordsCopyIdentity && !controller.testingCopyCombo.isVisible
               && !controller.testingCopyCombo.motionActive,
               "the production defaults observer did not immediately disable the combo")
        for generation in 4...6 { copy(UInt64(generation)) }
        expect(!controller.testingCopyCombo.isVisible, "disabled copies accumulated a combo")
        fixture.defaults.set(true, forKey: ClipboardCopyCombo.enabledKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: fixture.defaults)
        for generation in 7...9 {
            copy(UInt64(generation))
            expect(controller.testingCopyCombo.count == (generation >= 8 ? generation - 6 : 0),
                   "re-enabling resumed an old sequence")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: "Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let strings = catalog["strings"] as! [String: Any]
        for (language, prefix) in [("en", "Combo ×"), ("zh-Hant", "連擊×")] {
            let entry = strings["连击×%lld"] as! [String: Any]
            let translations = entry["localizations"] as! [String: Any]
            let translation = translations[language] as! [String: Any]
            let unit = translation["stringUnit"] as! [String: Any]
            expect((unit["value"] as! String).hasPrefix(prefix), "badge translation lost its combo label")
        }
    }

    private static func copyComboHonorsClassificationAndCoalescing() {
        let fixture = ReplayFixture()
        let controller = fixture.controller
        let monitor = ClipboardMonitor(toastController: controller)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let allowed = PopupPresentationPreferences(mode: .lowInterruption, showShortPlainText: true,
            showLongPlainText: true, showImages: true, showFiles: true, disabledKindIDs: [])
        let denied = PopupPresentationPreferences(mode: .lowInterruption, showShortPlainText: false,
            showLongPlainText: false, showImages: true, showFiles: true, disabledKindIDs: [])
        let text = String(repeating: "Synthetic preview ", count: 20) + "A"
        var originalWindow: ToastPanel?
        var originalRevision: ClipboardRevision?
        let action = SearchTextAction(text: "Synthetic original action")
        for generation in 1...3 {
            let (content, identity) = comboRead(pasteboard, generation: UInt64(generation), text: text)
            if generation == 1 {
                monitor.testingPresentLowInterruption(content: content, source: fixture.source,
                    preferences: allowed, analysisIsReady: false, copyIdentity: identity)
                expect(controller.testingWindow == nil && !controller.testingCopyCombo.isVisible,
                       "unclassified content displayed a combo")
            }
            monitor.testingPresentLowInterruption(content: content, source: fixture.source,
                preferences: allowed, analysisIsReady: true, copyIdentity: identity)
            if generation == 1 {
                originalWindow = controller.testingWindow
                originalRevision = content.revision
                controller.applyActions(primary: action, menu: [], revision: content.revision)
            }
        }
        expect(controller.testingCopyCombo.count == 3, "allowed visual duplicates lost their combo")
        expect(controller.testingCopyCombo.entranceSuppressed,
               "a low-interruption combo left its original card entrance running")
        expect(controller.testingWindow === originalWindow
               && controller.testingViewModel.revision == originalRevision
               && controller.testingViewModel.primaryAction?.id == action.id,
               "visual coalescing transferred content or Action ownership to another revision")

        let (different, differentIdentity) = comboRead(pasteboard, generation: 4, text: String(text.dropLast()) + "B")
        expect(different.visualHashValue == controller.testingViewModel.rawContent?.visualHashValue,
               "the strict-identity fixture no longer shares its visual hash")
        monitor.testingPresentLowInterruption(content: different, source: fixture.source,
            preferences: allowed, analysisIsReady: true, copyIdentity: differentIdentity)
        expect(!controller.testingCopyCombo.isVisible && controller.testingViewModel.revision == originalRevision,
               "same-preview content decorated or replaced an unrelated visible revision")

        let (blocked, blockedIdentity) = comboRead(pasteboard, generation: 5, text: text)
        monitor.testingPresentLowInterruption(content: blocked, source: fixture.source,
            preferences: denied, analysisIsReady: true, copyIdentity: blockedIdentity)
        for generation in 6...8 {
            let (content, identity) = comboRead(pasteboard, generation: UInt64(generation), text: text)
            monitor.testingPresentLowInterruption(content: content, source: fixture.source,
                preferences: allowed, analysisIsReady: true, copyIdentity: identity)
            expect(controller.testingCopyCombo.count == (generation >= 7 ? generation - 5 : 0),
                   "a filtered revision connected two combo sequences")
        }
        let (unknown, _) = comboRead(pasteboard, generation: 9, text: text)
        monitor.testingPresentLowInterruption(content: unknown, source: fixture.source,
            preferences: allowed, analysisIsReady: true, copyIdentity: nil)
        expect(!controller.testingCopyCombo.isVisible && controller.testingViewModel.revision == originalRevision,
               "an unknown coalesced identity retained decoration or changed content ownership")
        controller.dismissToast(animated: false)
        for generation in 10...12 {
            let (content, identity) = comboRead(pasteboard, generation: UInt64(generation), text: text)
            monitor.testingPresentLowInterruption(content: content, source: fixture.source,
                preferences: allowed, analysisIsReady: true, copyIdentity: identity)
        }
        expect(controller.testingWindow == nil && !controller.testingCopyCombo.isVisible,
               "a dismissed card's identity revived its decoration")
        let (fresh, freshIdentity) = comboRead(pasteboard, generation: 13, text: "Synthetic fresh card")
        monitor.testingPresentLowInterruption(content: fresh, source: fixture.source,
            preferences: allowed, analysisIsReady: true, copyIdentity: freshIdentity)
        expect(controller.testingWindow !== originalWindow && controller.testingViewModel.revision == fresh.revision
               && !controller.testingCopyCombo.isVisible,
               "a new card inherited the dismissed card's identity or combo")
    }

    private static func copyComboCleansUpAfterInteractionAndInactivity() {
        let fixture = ReplayFixture()
        let controller = fixture.controller
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        func copy(_ generation: UInt64) -> (ClipboardContent, ClipboardCopyIdentity) {
            let result = comboRead(pasteboard, generation: generation, text: "Synthetic combo cleanup")
            controller.observeCopyRevision(result.0.revision)
            controller.showPending(revision: result.0.revision, source: fixture.source)
            controller.applyBaseContent(result.0, source: fixture.source, revision: result.0.revision)
            controller.confirmCopyIdentity(result.1, revision: result.0.revision)
            return result
        }
        for generation in 1...3 { _ = copy(UInt64(generation)) }
        expect(controller.testingCopyCombo.count == 3, "cleanup fixture did not activate")
        controller.testingPerformCommand(.expand)
        expect(!controller.testingCopyCombo.isVisible && !controller.testingCopyCombo.motionActive,
               "expansion left combo motion or decoration active")
        for generation in 4...6 { _ = copy(UInt64(generation)) }
        expect(controller.testingCopyCombo.count == 3, "expansion did not start a fresh sequence")
        expect(controller.replayLastToast() && !controller.testingCopyCombo.isVisible,
               "replay retained the real-copy decoration")
        for generation in 7...9 { _ = copy(UInt64(generation)) }
        controller.showReminder(revision: ClipboardRevision(generation: 10, changeCount: 100))
        expect(!controller.testingCopyCombo.isVisible && controller.testingViewModel.isReminderNotice,
               "a reminder displayed copied-content decoration")
        for generation in 10...12 { _ = copy(UInt64(generation)) }
        RunLoop.main.run(until: Date().addingTimeInterval(2.1))
        expect(controller.testingCopyCombo.count == 3 && !controller.testingCopyCombo.motionActive
               && controller.testingCopyCombo.motion == CopyEchoMotion(),
               "inactivity lost the visible count or retained active animation values")
        for generation in 13...15 { _ = copy(UInt64(generation)) }
        let monitor = ClipboardMonitor(toastController: controller)
        monitor.stop()
        expect(!controller.testingCopyCombo.isVisible && controller.testingWindow == nil,
               "pausing left combo decoration or its panel alive")
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
        guard case let .content(_, content) = readBaseOnWorker(
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
        for progress in [CGFloat(0), 0.5, 1.1] {
            let entrance = ToastEntranceMotion(
                progress: progress, style: fixture.controller.testingEntranceStyle,
                presentation: fixture.controller.testingCopyCombo, owner: 0
            )
            expect(entrance.projection == .identity,
                   "replay regained a separate SwiftUI spring or opacity entrance")
        }
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
                guard case var .content(_, content) = readBaseOnWorker(
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
