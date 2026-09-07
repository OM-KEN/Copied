import Foundation

private enum Failure: Error { case failed(String) }

private struct IconRegressionPluginManifest: Decodable {
    let icon: String
    let label: String
}

private struct IconRegressionPluginRules: Decodable {
    struct Rule: Decodable { let pattern: String }
    let rules: [Rule]
}

@main
enum InstantClipboardFeedbackTests {
    static func main() throws {
        try firstFrameHasNoContentAccess()
        try revisionAndPresentationOrdering()
        try lifecycleAndInteractionWiring()
        try remediationInvariants()
        try secondRemediationInvariants()
        try boundedContentPaths()
        try deferredExpandedTextPreviewInvariants()
        try emptyPluginPresentationFactsPreserveTheBaseIcon()
        try diagnosticCodeWasRemoved()
        print("InstantClipboardFeedbackTests: PASS")
    }

    private static func emptyPluginPresentationFactsPreserveTheBaseIcon() throws {
        let pluginRoot = "Example Plugins/remove-empty-lines.copiedplugin"
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: "\(pluginRoot)/manifest.json"))
        let rulesData = try Data(contentsOf: URL(fileURLWithPath: "\(pluginRoot)/rules.json"))
        let manifest = try JSONDecoder().decode(
            IconRegressionPluginManifest.self,
            from: manifestData
        )
        let rules = try JSONDecoder().decode(IconRegressionPluginRules.self, from: rulesData)
        let syntheticText = "也就去了。\n\n老殘洗完了臉，"
        let regex = try NSRegularExpression(pattern: rules.rules[0].pattern)
        let sampleRange = NSRange(syntheticText.startIndex..., in: syntheticText)
        try expect(
            manifest.icon.isEmpty
                && manifest.label.isEmpty
                && regex.firstMatch(in: syntheticText, range: sampleRange) != nil,
            "the synthetic empty-line sample no longer reproduces the iconless plugin match"
        )

        let monitor = try source("ClipboardMonitor.swift")
        let analysis = try section(
            monitor,
            from: "case let .analysis(_, detections):",
            to: "analysisIsReady = true"
        )
        try expect(
            analysis.contains("if !facts.typeLabel.isEmpty")
                && analysis.contains("if !facts.iconSymbolName.isEmpty"),
            "empty plugin presentation facts can erase the base text icon"
        )
    }

    private static func firstFrameHasNoContentAccess() throws {
        let monitor = try source("ClipboardMonitor.swift")
        let begin = try section(
            monitor,
            from: "private func beginRevision(_ revision: ClipboardRevision)",
            to: "private func resetActiveRevisionState()"
        )
        guard let pending = begin.range(of: "toastController?.showPending") else {
            throw Failure.failed("default/all-allowed path has no synchronous Pending")
        }
        let preFirstFrame = String(begin[..<pending.lowerBound])
        let prohibited = [
            ".types", ".pasteboardItems", "data(forType:", "resourceValues",
            "DetectionRegistry.shared.detectAll", "ActionResolver.resolve",
            "visualHashValue", "CGImageSource", "generateThumbnail",
            "SourceAppDetector.detect(",
        ]
        for token in prohibited {
            try expect(
                occurrences(of: token, in: preFirstFrame) == 0,
                "pre-first-frame access count for \(token) was not zero"
            )
        }
        try expect(
            !preFirstFrame.contains("DispatchQueue.main.async"),
            "Pending was deferred to a second main-queue turn"
        )

        let sourceDetector = try source("SourceAppDetector.swift")
        let cachedSnapshot = try section(
            sourceDetector,
            from: "static func cachedSnapshot()",
            to: "private static func cachedIcon(for"
        )
        try expect(cachedSnapshot.contains("latestSource"), "first frame does not read the source cache")
        try expect(!cachedSnapshot.contains("NSWorkspace.shared"), "first frame queries NSWorkspace")
        try expect(!cachedSnapshot.contains("localizedName"), "first frame resolves an app name")
        try expect(!cachedSnapshot.contains("cachedIcon"), "first frame performs icon lookup")
    }

    private static func revisionAndPresentationOrdering() throws {
        let monitor = try source("ClipboardMonitor.swift")
        let check = try section(
            monitor,
            from: "private func checkClipboard()",
            to: "private func beginRevision"
        )
        try expect(
            index(of: "lastObservedChangeCount = currentCount", in: check)
                < index(of: "beginRevision(revision)", in: check),
            "lastObserved advances after revision work starts"
        )
        let begin = try section(
            monitor,
            from: "private func beginRevision(_ revision: ClipboardRevision)",
            to: "private func resetActiveRevisionState()"
        )
        try expect(
            !begin.contains("CopySoundFeedback.play"),
            "changeCount-only first frame plays sound before content is readable"
        )
        let receive = try section(
            monitor,
            from: "private func receiveBaseRead",
            to: "private func handleLoadFailure"
        )
        try expect(
            index(of: "case let .content", in: receive)
                < index(of: "playActiveCopySoundIfNeeded()", in: receive),
            "sound is not gated by a successful clipboard read"
        )
        try expect(
            index(of: "playActiveCopySoundIfNeeded()", in: receive)
                < index(of: "tryPresentLowInterruption", in: receive),
            "visual filtering precedes sound"
        )
        try expect(
            index(of: "if activeLightReminderWasPresented", in: receive)
                < index(of: "session.storePayload(content)", in: receive),
            "hidden/all-denied base content is retained after validation"
        )
        try expect(!begin.contains("visualHashValue"),
                   "default first-frame path still deduplicates repeated content")
        try expect(
            index(of: "LightReminderController.shared.show()", in: begin)
                < index(of: "submitBaseRead(session: session)", in: begin),
            "safe only-reminder path does not show before background reading starts"
        )
        try expect(
            begin.contains("preferences.mode == .all || candidateDecision == .allAllowed"),
            "safe low-interruption all-allowed path is not immediate"
        )
        try expect(
            index(of: "toastController?.showPending", in: begin)
                < index(of: "submitBaseRead(session: session)", in: begin),
            "base reading starts before Pending"
        )
        try expect(monitor.contains("revisionGate.accept(update.revision)"), "reducer lacks revision gate")
        try expect(monitor.contains("session.attemptCount < 3"), "three-attempt retry is not wired")
        try expect(monitor.contains("session.scheduleRetry"), "25ms session retry is not wired")
        try expect(occurrences(of: "ClipboardLatestOnlyLane(label:", in: monitor) == 4,
                   "base/analysis/file/image lanes are not independently bounded")
        try expect(
            monitor.contains("analysisSoftDeadline: TimeInterval = 3")
                && monitor.contains("fileSoftDeadline: TimeInterval = 30")
                && monitor.contains("imageSoftDeadline: TimeInterval = 2")
                && monitor.contains("updateIsWithinDeadline(update)"),
            "late lane results are not bounded and rejected"
        )
        let lowPresentation = try section(
            monitor,
            from: "private func tryPresentLowInterruption",
            to: "private func lowInterruptionDecision"
        )
        try expect(lowPresentation.contains("content.visualHashValue")
                   && lowPresentation.contains("dedupWindow"),
                   "500ms visual dedup is not isolated to low-interruption presentation")
    }

    private static func lifecycleAndInteractionWiring() throws {
        let controller = try source("ToastWindowController.swift")
        let pending = try section(
            controller,
            from: "func showPending(revision:",
            to: "func applyBaseContent"
        )
        try expect(!pending.contains("quickTriggerCoordinator.start"), "Pending starts Quick Trigger")
        let presentation = try section(controller, from: "private func presentConfiguredToast(", to: "private func makeToastView()")
        try expect(!presentation.contains("quickTriggerCoordinator.start"),
                   "Shared presentation starts Quick Trigger before Action readiness")
        try expect(pending.contains(".now() + 0.05"), "50ms loading transition is absent")
        guard let pendingPresentation = pending.range(of: "presentConfiguredToast(") else {
            throw Failure.failed("Pending presentation call is absent")
        }
        let afterPendingPresentation = String(pending[pendingPresentation.lowerBound...])
        try expect(
            index(of: "pauseDismissTimer()", in: afterPendingPresentation)
                < index(of: "DispatchQueue.main.asyncAfter", in: afterPendingPresentation),
            "Pending starts an independent auto-dismiss lifetime"
        )
        let base = try section(controller, from: "func applyBaseContent", to: "func applyEnrichment")
        try expect(base.contains("startDismissTimer(after: displayDuration)"),
                   "base-ready does not reset the full readable lifetime")
        let actions = try section(controller, from: "func applyActions(", to: "func showFailure")
        try expect(actions.contains("ensureMinimumActionableTime"),
                   "late Action has no minimum actionable lifetime")
        try expect(actions.contains("refreshQuickTriggerContextIfEligible"),
                   "Quick Trigger is not started at Action readiness")
        try expect(controller.contains("displayDuration: TimeInterval = 3.0"),
                   "ordinary feedback lifetime is not three seconds")
        try expect(controller.contains("quickTriggerContextGeneration"),
                   "dismissGeneration is still the Quick Trigger identity")

        let view = try source("ToastView.swift")
        try expect(view.contains(".allowsHitTesting(viewModel.canExpand)"), "Pending can expand")
        try expect(view.contains("if viewModel.isContentReady"), "Pending exposes a context menu")
        try expect(view.contains("reduceMotion ? nil"), "Reduce Motion does not disable loading transitions")
        try expect(!view.contains("width: 328")
                   && !view.contains("height: viewModel.resultOverlay == nil ? 64 : nil")
                   && !view.contains(".frame(maxWidth: 96)"),
                   "collapsed content is forced away from its native intrinsic geometry")
        try expect(!view.contains(".id(\"primary-action-")
                   && !view.contains(".id(\"result-action-"),
                   "interactive Action buttons are recreated during content enrichment")
        try expect(!view.contains(".id(viewModel.contentTransitionID)")
                   && view.contains(".id(\"preview-\\(viewModel.previewText)\")")
                   && view.contains(".id(\"detail-\\(viewModel.metadataDetailText)\")"),
                   "unrelated toast content still rebuilds on every enrichment update")
        try expect(view.contains(".contentTransition(.opacity)")
                   && !view.contains(".contentTransition(.symbolEffect(.replace))"),
                   "icon updates are not using the native opacity content transition")
        let viewModel = try source("ToastViewModel.swift")
        try expect(viewModel.contains("var metadataDetailText: String")
                   && viewModel.contains("[typeLabel, detailInfo]")
                   && view.contains("Text(viewModel.metadataDetailText)"),
                   "the detected type label is still disconnected from toast metadata")
        try expect(view.contains(".onChange(of: viewModel.contentTransitionID)"),
                   "intrinsic content changes do not request a panel relayout")
        try expect(view.contains("viewModel.currentExpandedTextWasTruncated"),
                   "current expanded-content truncation hint is missing")

        let quickTrigger = try source("QuickTriggerCoordinator.swift")
        try expect(quickTrigger.contains("keyboardState.appeared(preExisting: targetIsDown)"),
                   "Action-ready start can accept a pre-held modifier release")
    }

    private static func remediationInvariants() throws {
        let monitor = try source("ClipboardMonitor.swift")
        let failure = try section(
            monitor,
            from: "private func handleLoadFailure",
            to: "private func handleLoadTimeout"
        )
        let timeout = try section(
            monitor,
            from: "private func handleLoadTimeout",
            to: "private func scheduleEnrichment"
        )
        try expect(failure.contains("toastController?.showFailure")
                   && failure.contains("toastController?.dismissSilently"),
                   "retry exhaustion lacks default-visible and low-silent terminal states")
        try expect(timeout.contains("toastController?.showFailure")
                   && timeout.contains("toastController?.dismissSilently"),
                   "load timeout lacks default-visible and low-silent terminal states")
        try expect(failure.contains("playActiveCopySoundIfNeeded()"),
                   "retry exhaustion does not play the copy sound")
        try expect(timeout.contains("playActiveCopySoundIfNeeded()"),
                   "load timeout does not play the copy sound")
        try expect(
            index(of: "session.cancel()", in: failure)
                < index(of: "playActiveCopySoundIfNeeded()", in: failure),
            "retry exhaustion does not terminate the load session before feedback"
        )
        try expect(
            index(of: "session.cancel()", in: timeout)
                < index(of: "playActiveCopySoundIfNeeded()", in: timeout),
            "load timeout does not terminate the load session before feedback"
        )
        try expect(monitor.contains("CopySoundDispatchGate"),
                   "clipboard sound dispatch has no per-copy once-only gate")
        try expect(monitor.contains("activeLightReminderEnabled = lightReminderEnabled"),
                   "light-reminder choice is not captured per revision")
        let receive = try section(
            monitor,
            from: "private func receiveBaseRead",
            to: "private func handleLoadFailure"
        )
        try expect(!receive.contains("cachedLightReminderEnabled"),
                   "base reducer reads mutable global light-reminder settings")

        let controller = try source("ToastWindowController.swift")
        let showFailure = try section(
            controller,
            from: "func showFailure",
            to: "func dismissSilently"
        )
        try expect(showFailure.contains("startDismissTimer(after: displayDuration)"),
                   "default failure does not use the ordinary readable lifetime")
        try expect(!controller.contains("failureDuration"),
                   "default failure still has a separate shorter lifetime")

        let failureViewModel = try source("ToastViewModel.swift")
        let failureConfiguration = try section(
            failureViewModel,
            from: "func configureFailure()",
            to: "func configure(with content:"
        )
        try expect(failureConfiguration.contains("String(localized: \"已复制\")")
                   && !failureConfiguration.contains("无法显示内容")
                   && !failureViewModel.contains("exclamationmark.circle"),
                   "unreadable clipboard feedback is not the ordinary copied confirmation")
        let applyActions = try section(
            failureViewModel,
            from: "func applyActions(",
            to: "func configureStartupNotice"
        )
        try expect(!applyActions.contains("contentTransitionID"),
                   "Action readiness still rebuilds unrelated content views")

        let toastView = try source("ToastView.swift")
        let accessibilityStatus = try section(
            toastView,
            from: "private var accessibilityStatus",
            to: "// MARK: - Menu Action Button"
        )
        try expect(!accessibilityStatus.contains("无法显示内容"),
                   "unreadable clipboard accessibility still announces an error")
        let localization = try source("Localizable.xcstrings")
        try expect(!localization.contains("已复制，但 Copied 无法显示内容")
                   && !localization.contains("正在计算文件夹大小…")
                   && !localization.contains("正在计算文件大小…"),
                   "retired copy-feedback strings remain in the active catalog")

        let detection = try source("ClipboardDetectionDisplayFacts.swift")
        try expect(detection.contains("ClipboardDetectionDisplayFacts"),
                   "detection display facts are not derived from detections")
        try expect(detection.contains("primary.kind.label")
                   && detection.contains("primary.kind.icon")
                   && detection.contains("RelativeDateDescription.string"),
                   "detection label, icon, or relative date detail is missing")

        let registry = try source("DetectionRegistry.swift")
        try expect(registry.contains("private let stateLock = NSLock()"),
                   "DetectionRegistry has no state lock")
        try expect(registry.contains("let detectorSnapshot = stateLock.withLock"),
                   "DetectionRegistry does not snapshot detector state")
        let detectionLoop = try section(
            registry,
            from: "func detectAll(in text: String)",
            to: "// MARK: - Built-in Registration"
        )
        try expect(detectionLoop.contains("detector.detect(in: trimmed)"),
                   "DetectionRegistry no longer executes detectors")
        try expect(!detectionLoop.contains("withLock { detector.detect"),
                   "DetectionRegistry holds its state lock while executing a detector")

        let sourceDetector = try source("SourceAppDetector.swift")
        let prepare = try section(
            sourceDetector,
            from: "static func prepareIcon",
            to: "static func detect"
        )
        try expect(prepare.contains("storeCachedSnapshot(source)"),
                   "activation warm-up does not refresh the cached source snapshot")

        let enrichment = try source("ClipboardContentEnrichment.swift")
        let fileEnricher = try section(
            enrichment,
            from: "enum ClipboardFileEnricher",
            to: "private static func formattedByteCount"
        )
        try expect(!fileEnricher.contains("CGImageSourceCreateWithURL"),
                   "file classification still blocks on ImageIO metadata")
        try expect(monitor.contains("ClipboardImageEnricher.enrichImageFile"),
                   "image-file metadata was not moved to the image lane")

        let view = try source("ToastView.swift")
        try expect(view.contains("ProgressView()")
                   && view.contains("|| viewModel.detailIsLoading) && !reduceMotion"),
                   "loading lacks a Reduce-Motion-aware native progress indicator")
        let progress = try section(
            view,
            from: "if showsProgress {",
            to: ".accessibilityHidden(true)"
        )
        try expect(view.contains("@Environment(\\.colorScheme)")
                   && progress.contains("if colorScheme == .dark")
                   && progress.contains(".colorInvert()"),
                   "loading progress does not compensate for the dark-mode macOS spinner")
        try expect(view.contains(".transition(.opacity)")
                   && view.contains(".easeInOut(duration: 0.14)"),
                   "content enrichment lacks a real 140ms opacity transition")
        try expect(view.contains(".truncationMode(.tail)"),
                   "Action title does not tail-truncate")
        try expect(view.contains("style == .standard")
                   && view.contains(".easeOut(duration: 0.08)"),
                   "rapid replacements still use the standard spring entrance")

        let viewModel = try source("ToastViewModel.swift")
        try expect(viewModel.contains("ClipboardExpandedTextPolicy.displayText(for: displayText)"),
                   "result overlay bypasses expanded-text display bounds")
        try expect(viewModel.contains("return overlay.displayText"),
                   "TextEdit no longer receives the full result overlay text")
        try expect(enrichment.contains("permitsGeneratedThumbnail"),
                   "generated bitmap thumbnail dimensions are not revalidated")
    }

    private static func secondRemediationInvariants() throws {
        let pipeline = try source("ClipboardPipeline.swift")
        let expandedPolicy = try section(
            pipeline,
            from: "enum ClipboardExpandedTextPolicy",
            to: "enum ClipboardDirectorySizeResult"
        )
        try expect(!expandedPolicy.contains("fullText.utf16.count")
                   && !expandedPolicy.contains("fullText.reduce"),
                   "expanded-text policy still performs a full pre-scan")
        try expect(expandedPolicy.contains("return (end, true, examinedGraphemeCount)"),
                   "expanded-text scan does not return at the first rejected grapheme")

        let enrichment = try source("ClipboardContentEnrichment.swift")
        let readText = try section(
            enrichment,
            from: "private static func readText(",
            to: "private static func formattedByteCount"
        )
        try expect(occurrences(of: "text.count", in: readText) == 1,
                   "text character count is scanned more than once")

        let temporaryExport = try source("TemporaryTextExport.swift")
        try expect(temporaryExport.contains("static func prepare(text:")
                   && !temporaryExport.contains("NSWorkspace"),
                   "background export preparation still opens TextEdit itself")

        let controller = try source("ToastWindowController.swift")
        let textExport = try section(
            controller,
            from: "private func handleEditInTextEdit()",
            to: "private func handleHoverChanged"
        )
        try expect(textExport.contains("textExportToken == nil")
                   && textExport.contains("let token = UUID()")
                   && textExport.contains("self.textExportToken == token")
                   && textExport.contains("self.currentRevision == exportRevision"),
                   "TextEdit export lacks reentry or stale-revision guards")
        try expect(
            index(of: "self.currentRevision == exportRevision", in: textExport)
                < index(of: "NSWorkspace.shared.open(url)", in: textExport),
            "TextEdit is opened before controller token/revision validation"
        )
        try expect(textExport.contains("TemporaryTextExport.remove(url)"),
                   "stale or failed TextEdit exports are not removed")

        let execute = try section(
            controller,
            from: "private func executeCommand",
            to: "private func handlePerformAction"
        )
        try expect(
            index(of: "cancelResourcesForCurrentRevision()", in: execute)
                < index(of: "switch command", in: execute),
            "ToastCommand starts before revision resources are cancelled"
        )
        let cancelHelper = try section(
            controller,
            from: "private func cancelResourcesForCurrentRevision()",
            to: "private func isMouseInsideWindow"
        )
        try expect(cancelHelper.contains("resourcesCancelledRevision != revision")
                   && cancelHelper.contains("onRevisionResourcesShouldCancel?(revision)"),
                   "resource cancellation helper is not semantic and idempotent")

        let monitor = try source("ClipboardMonitor.swift")
        try expect(monitor.contains("onRevisionResourcesShouldCancel")
                   && monitor.contains("session.cancel()"),
                   "Monitor does not connect command cancellation to the load session")
        let monitorStop = try section(
            monitor,
            from: "func stop()",
            to: "private func installDefaultsObserverIfNeeded"
        )
        try expect(monitorStop.contains("ClipboardDirectorySizeCoordinator.shared.cancelAll()")
                   && !monitorStop.contains("ClipboardDirectorySizeCache.reset()"),
                   "pausing monitoring does not stop active tasks or unexpectedly clears the cache")
        let baseRead = try section(
            monitor,
            from: "private func submitBaseRead",
            to: "private func receiveBaseRead"
        )
        try expect(baseRead.contains("NSPasteboard(name: .general)")
                   && baseRead.contains("pasteboard: pasteboard"),
                   "base worker reuses the shared NSPasteboard.general object")

        let analysis = try section(
            monitor,
            from: "private func scheduleAnalysis",
            to: "private func scheduleFileEnrichment"
        )
        try expect(
            index(of: "DetectionRegistry.shared.detectAll", in: analysis)
                < index(of: "guard session.accepts(session.revision)", in: analysis)
                && index(of: "guard session.accepts(session.revision)", in: analysis)
                    < index(of: "ActionResolver.resolve", in: analysis),
            "analysis does not recheck cancellation between detection and Action resolution"
        )
        let fileSchedule = try section(
            monitor,
            from: "private func scheduleFileEnrichment",
            to: "private func scheduleBitmapEnrichment"
        )
        try expect(fileSchedule.contains("shouldCancel: { !session.accepts(session.revision) }"),
                   "file enrichment is not cooperatively cancellable")
        try expect(fileSchedule.contains("registerDirectorySizeObservation")
                   && fileSchedule.contains("session.cancelSoftDeadline(deadlineToken)")
                   && fileSchedule.contains("session.clearDirectorySizeObservation()"),
                   "background directory terminal does not close its session deadline/observation")
        guard let enrichmentCall = fileSchedule.range(of: "ClipboardFileEnricher.enrich(") else {
            throw Failure.failed("file enrichment call is absent")
        }
        let afterEnrichmentCall = String(fileSchedule[enrichmentCall.lowerBound...])
        try expect(afterEnrichmentCall.contains("finish()"),
                   "fileLane remains occupied by a detached background directory task")

        let fileEnricher = try section(
            enrichment,
            from: "enum ClipboardFileEnricher",
            to: "private static func formattedByteCount"
        )
        try expect(fileEnricher.contains("shouldCancel")
                   && fileEnricher.contains("case .cancelled:"),
                   "file/directory loops do not stop without emitting after cancellation")
        let classification = try section(
            fileEnricher,
            from: "for (index, url) in urls.enumerated()",
            to: "let imageClassification"
        )
        try expect(!classification.contains(".fileSizeKey")
                   && !classification.contains(".totalFileSizeKey"),
                   "multi-file classification requests size keys for every URL")
        try expect(fileEnricher.contains("values.isPackage == true, size == nil")
                   && fileEnricher.components(separatedBy: "enrichDirectorySize(").count == 4,
                   "folders and packages do not share bounded size enrichment")
        let sharedDirectoryPath = try section(
            fileEnricher,
            from: "func enrichDirectorySize(",
            to: "if values.isDirectory == true && values.isPackage != true"
        )
        try expect(sharedDirectoryPath.contains("case let .cached(size, isPartial, isRefreshing)")
                   && sharedDirectoryPath.contains("emitCachedFileSize"),
                   "directory enrichment does not distinguish historical size")
        try expect(sharedDirectoryPath.contains("directorySizeCoordinator.calculate")
                   && sharedDirectoryPath.contains("shouldCancel: shouldCancel"),
                   "saturated directory fallback is not bounded by session cancellation")

        let bitmapTimeout = try section(
            monitor,
            from: "private func handleBitmapSoftDeadline",
            to: "private func applyDegradedDetail"
        )
        let fileThumbnailTimeout = try section(
            monitor,
            from: "private func handleFileThumbnailSoftDeadline",
            to: "private func applyDegradedDetail"
        )
        try expect(bitmapTimeout.contains("图片无法预览")
                   && bitmapTimeout.contains("handleFileThumbnailSoftDeadline")
                   && !fileThumbnailTimeout.contains("applyDegradedDetail("),
                   "file thumbnail timeout overwrites file detail with an image error")
        let fileSizeTimeout = try section(
            monitor,
            from: "private func handleFileSoftDeadline",
            to: "private func handleBitmapSoftDeadline"
        )
        try expect(fileSizeTimeout.contains("content.detailIsLoading")
                   && fileSizeTimeout.contains("content.detailIsLoading = false")
                   && fileSizeTimeout.contains("session.storePayload(content)")
                   && fileSizeTimeout.contains("toastController?.applyEnrichment"),
                   "file-size timeout discards its last numeric lower bound")
        let refresh = try section(
            monitor,
            from: "private func refreshCachedSettings()",
            to: "private func scheduleTimer"
        )
        try expect(refresh.contains("DetectionRegistry.shared.allRegisteredKinds"),
                   "runtime plugin kind IDs are not refreshed outside the first frame")

        let view = try source("ToastView.swift")
        try expect(view.contains("viewModel.detailIsLoading")
                   && view.contains(".accessibilityHidden(true)")
                   && view.contains("if showsProgress")
                   && !view.contains(".frame(width: 12, height: 12)"),
                   "detail loading permanently reserves space after loading finishes")
        try expect(index(of: "Text(viewModel.metadataDetailText)", in: view)
                   < index(of: "if showsProgress", in: view),
                   "detail progress still shifts the final size text away from its native leading edge")

        try expect(!fileEnricher.contains("正在计算文件夹大小")
                   && !fileEnricher.contains("正在计算文件大小")
                   && fileEnricher.contains("progressUpdateInterval"),
                   "file-size enrichment still uses prose placeholders instead of bounded numeric progress")

        let reducer = try section(
            monitor,
            from: "private func reduce(",
            to: "private func updateIsWithinDeadline"
        )
        let actionUpdate = try section(reducer, from: "case let .actions", to: "case let .fileFacts")
        try expect(actionUpdate.contains("toastController?.applyActions(")
                   && actionUpdate.contains("return")
                   && !actionUpdate.contains("session.storePayload")
                   && !actionUpdate.contains("applyEnrichment"),
                   "Action updates must return without rewriting content or applying enrichment")

        let panel = try source("ToastPanel.swift")
        try expect(panel.contains("maximumDocumentHeight")
                   && panel.contains("ClipboardExpandedTextPolicy.maximumUTF16Count")
                   && !panel.contains("greatestFiniteMagnitude"),
                   "expanded text layout still has an unbounded document height")
        try expect(!controller.contains("greatestFiniteMagnitude"),
                   "native NSTextView/textContainer still uses an infinite height")

        let actionDismiss = try section(
            controller,
            from: "private func handlePerformAction",
            to: "private func handleExpand"
        )
        let textEditDismiss = try section(
            controller,
            from: "private func handleEditInTextEdit",
            to: "private func finishTextExportIfCurrent"
        )
        let manualDismiss = try section(
            controller,
            from: "private func handleDismiss()",
            to: "// MARK: - Dismiss"
        )
        let timerDismiss = try section(
            controller,
            from: "func startDismissTimer",
            to: "private func ensureMinimumActionableTime"
        )
        for (name, path) in [
            ("action", actionDismiss),
            ("TextEdit", textEditDismiss),
            ("manual", manualDismiss),
            ("timer", timerDismiss),
        ] {
            try expect(path.contains("dismissToast(animated: true)"),
                       "\(name) path no longer animates dismissal")
            try expect(!path.contains("cancelAsyncThumbnail()"),
                       "\(name) path clears the thumbnail before dismissal completes")
        }
        let dismissToast = try section(
            controller,
            from: "func dismissToast(animated: Bool)",
            to: "private func releasePresentation"
        )
        let animatedDismissCompletion = try section(
            dismissToast,
            from: "DispatchQueue.main.asyncAfter(deadline: .now() + 0.25)",
            to: "} else {"
        )
        try expect(
            index(of: "self.window?.orderOut(nil)", in: animatedDismissCompletion)
                < index(of: "self.viewModel.cancelAsyncThumbnail()", in: animatedDismissCompletion),
            "animated dismissal clears the thumbnail before the window is hidden"
        )
        let immediateDismiss = try section(
            dismissToast,
            from: "} else {\n            dismissGeneration += 1",
            to: "    }"
        )
        try expect(
            index(of: "window?.orderOut(nil)", in: immediateDismiss)
                < index(of: "viewModel.cancelAsyncThumbnail()", in: immediateDismiss),
            "immediate dismissal clears the thumbnail before the window is hidden"
        )
    }

    private static func deferredExpandedTextPreviewInvariants() throws {
        let panel = try source("ToastPanel.swift")
        try expect(
            panel.contains("deferredLoadingUTF16Threshold = 2_048")
                && panel.contains("requiresDeferredLoading(for text: String)"),
            "expanded text has no conservative deferred-loading geometry gate"
        )

        let controller = try source("ToastWindowController.swift")
        let expand = try section(
            controller,
            from: "private func handleExpand()",
            to: "private func scheduleDeferredExpandedTextLayout"
        )
        try expect(
            index(of: "isExpandedTextLoading = requiresDeferredLayout", in: expand)
                < index(of: "scheduleDeferredExpandedTextLayout", in: expand),
            "deferred native layout starts before the loading shell"
        )
        let deferred = try section(
            controller,
            from: "private func scheduleDeferredExpandedTextLayout",
            to: "private func handleCollapse"
        )
        try expect(
            deferred.contains("DispatchQueue.main.async")
                && !deferred.contains("DispatchQueue.global")
                && !deferred.contains("DispatchQueue(label:"),
            "deferred expanded layout is not one later main-queue turn"
        )
        try expect(
            index(of: "layoutExpandedTextSurface(allowWhileLoading: true)", in: deferred)
                < index(of: "isExpandedTextLoading = false", in: deferred),
            "loading ends before the native text has finished preparing"
        )
        try expect(
            controller.contains("deferredExpandedTextGeneration")
                && controller.contains("preparedExpandedText")
                && controller.contains("preparedExpandedTextDocumentHeight"),
            "deferred expanded layout lacks stale-work and duplicate-layout guards"
        )
        try expect(
            controller.contains("|| viewModel.isExpandedTextLoading")
                && controller.contains("expandedBottomBarControlsHostingView?.isHidden = !visible"),
            "loading does not hide only the native text surface"
        )

        let view = try source("ToastView.swift")
        let loading = try section(
            view,
            from: "private struct ExpandedTextLoadingView",
            to: "private struct ExpandedTextView"
        )
        try expect(
            loading.contains("ProgressView()")
                && loading.contains("正在准备预览…")
                && loading.contains("if colorScheme == .dark")
                && loading.contains(".colorInvert()")
                && loading.contains("@Environment(\\.accessibilityReduceMotion)")
                && loading.contains("if !reduceMotion"),
            "expanded shell lacks a readable native loading presentation"
        )
        try expect(
            !view.contains("预览已截断")
                && view.contains("在文本编辑中查看全部")
                && view.contains(".buttonStyle(.borderedProminent)")
                && view.contains(
                    ".disabled(viewModel.isExpandedTextLoading || viewModel.isExpandedTransitioning)"
                ),
            "expanded TextEdit affordance does not replace the truncation hint"
        )
        let truncatedTextEditButton = try section(
            view,
            from: "if viewModel.currentExpandedTextWasTruncated {",
            to: "} else {"
        )
        try expect(
            truncatedTextEditButton.contains("Button(\"在文本编辑中查看全部\")")
                && !truncatedTextEditButton.contains("systemImage:"),
            "emphasized TextEdit button content differs from the ordinary text-only button"
        )
        let viewModel = try source("ToastViewModel.swift")
        try expect(
            viewModel.contains("var isExpandedTransitioning = false")
                && controller.contains("viewModel.isExpandedTransitioning = true")
                && controller.contains("viewModel.isExpandedTransitioning = false"),
            "expanded controls do not mirror the controller transition guard"
        )

        let catalog = try source("Localizable.xcstrings")
        try expect(
            !catalog.contains("\"预览已截断\"")
                && !catalog.contains("预览已截断，文本编辑中可查看全文")
                && catalog.contains("\"正在准备预览…\"")
                && catalog.contains("\"在文本编辑中查看全部\""),
            "expanded loading and TextEdit strings are not synchronized"
        )
        try expect(
            !controller.contains("expanded-text-debug")
                && !view.contains("expanded-text-debug")
                && !panel.contains("expanded-text-debug"),
            "temporary expanded-text diagnostics remain in production"
        )
    }

    private static func boundedContentPaths() throws {
        let enrichment = try source("ClipboardContentEnrichment.swift")
        try expect(enrichment.contains("maximumFileURLCount = 4_096"), "file URL cap is absent")
        try expect(enrichment.contains("maximumImageDataByteCount = 64 * 1_024 * 1_024"),
                   "bitmap cooperative cap is absent")
        try expect(
            index(of: "types.contains(.png)", in: enrichment)
                < index(of: "types.contains(.tiff)", in: enrichment),
            "TIFF is preferred over PNG"
        )
        try expect(!enrichment.contains("NSImage(contentsOf:"), "file images use synchronous NSImage loading")
        try expect(enrichment.contains("CGImageSourceCreateWithURL"), "file image metadata bypasses ImageIO")

        let pipeline = try source("ClipboardPipeline.swift")
        try expect(pipeline.contains("options: []")
                   && !pipeline.contains(".skipsHiddenFiles")
                   && !pipeline.contains(".skipsPackageDescendants"),
                   "directory traversal still skips hidden/package descendants")
        try expect(pipeline.contains("if values.isDirectory == true { continue }"),
                   "directory nodes are counted instead of only their leaf descendants")
        try expect(pipeline.contains("values.totalFileSize ?? values.fileSize"),
                   "leaf sizing does not prefer total size with a file-size fallback")
        try expect(!pipeline.contains("maximumEntryCount"), "directory traversal still has an entry budget")
        try expect(pipeline.contains("maximumDuration: TimeInterval = 30"), "directory time budget is absent")
        try expect(pipeline.contains("slowDirectoryThreshold: TimeInterval = 1")
                   && pipeline.contains("cacheLifetime: TimeInterval = 30")
                   && pipeline.contains("maximumCachedResultCount = 32"),
                   "adaptive directory cache bounds are absent")
        try expect(pipeline.contains("maximumDetachedTaskCount = 2")
                   && pipeline.contains("maximumDuration: TimeInterval = 30")
                   && pipeline.contains("progressUpdateInterval: TimeInterval = 0.25"),
                   "detached directory task bounds are absent")

        let preview = try source("FilePreviewGenerator.swift")
        try expect(preview.contains("let request: QLThumbnailGenerator.Request"),
                   "original QL request is not retained")
        try expect(preview.contains("backend.cancel(request)"), "QL cancel does not use retained request")

        let export = try source("TemporaryTextExport.swift")
        try expect(export.contains("S_IRUSR | S_IWUSR"), "TextEdit export is not mode 0600")
        try expect(export.contains("for byte in text.utf8"), "TextEdit export is not streamed")
        try expect(export.contains("7 * 24 * 60 * 60"), "seven-day owned-file cleanup is absent")
    }

    private static func diagnosticCodeWasRemoved() throws {
        let formerLoggerType = ["InstantClipboardFeedback", "Diagnostics"].joined()
        let formerRevisionField = ["diagnostic", "Revision"].joined()
        let regressionLoggerType = ["ClipboardRegression", "Diagnostics"].joined()
        let longTextLoggerType = ["LongTextExpansion", "Diagnostics"].joined()
        let longTextEnvironmentKey = [
            "COPIED_LONG_TEXT", "EXPANSION_DIAGNOSTIC",
        ].joined(separator: "_")
        let iconLoggerType = ["ClipboardIconRegression", "Diagnostics"].joined()
        let iconEnvironmentKey = ["COPIED_ICON", "REGRESSION_DIAGNOSTIC"].joined(separator: "_")
        let files = [
            "ClipboardMonitor.swift", "CopySoundFeedback.swift", "DetectionRegistry.swift",
            "ClipboardAction.swift", "ClipboardDetectionDisplayFacts.swift",
            "ToastView.swift", "ToastViewModel.swift",
            "ToastWindowController.swift", "ToastPanel.swift", "FilePreviewGenerator.swift",
            "CopiedApp.swift", "build.sh",
        ]
        for file in files {
            let text = try source(file)
            try expect(!text.contains(iconLoggerType)
                       && !text.contains(iconEnvironmentKey),
                       "temporary icon diagnostics remain in \(file)")
            try expect(!text.contains(longTextLoggerType)
                       && !text.contains(longTextEnvironmentKey),
                       "temporary long-text diagnostics remain in \(file)")
            try expect(!text.contains(regressionLoggerType),
                       "temporary clipboard regression diagnostics remain in \(file)")
            try expect(!text.contains(formerLoggerType),
                       "temporary diagnostics remain in \(file)")
            try expect(!text.contains(formerRevisionField),
                       "temporary diagnostic revision remains in \(file)")
            try expect(!text.contains("ToastLayoutDiagnostics"),
                       "temporary toast layout diagnostics remain in \(file)")
        }
        try expect(!FileManager.default.fileExists(
            atPath: ["InstantClipboardFeedback", "Diagnostics.swift"].joined()
        ),
                   "temporary logger file remains")
        try expect(!FileManager.default.fileExists(atPath: "Tests/InstantClipboardFeedbackDiagnosticHarness.swift"),
                   "temporary diagnostic harness remains")
        try expect(!FileManager.default.fileExists(atPath: "Tests/IconRegressionDiagnostic.swift"),
                   "temporary icon diagnostic harness remains")
        try expect(!FileManager.default.fileExists(
            atPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("Copied-toast-layout-diagnostics.log").path
        ),
                   "temporary toast layout log remains")
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private static func section(_ source: String, from start: String, to end: String) throws -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            throw Failure.failed("cannot locate section \(start) … \(end)")
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private static func index(of token: String, in source: String) -> Int {
        source.range(of: token).map { source.distance(from: source.startIndex, to: $0.lowerBound) }
            ?? Int.max
    }

    private static func occurrences(of token: String, in source: String) -> Int {
        source.components(separatedBy: token).count - 1
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.failed(message) }
    }
}
