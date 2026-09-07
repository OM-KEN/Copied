import AppKit
import Foundation
import CoreGraphics

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func section(in source: String, from start: String, to end: String) -> String? {
    guard let startRange = source.range(of: start),
          let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex)
    else {
        return nil
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}

private func appearsInOrder(_ needles: [String], in source: String) -> Bool {
    var searchStart = source.startIndex
    for needle in needles {
        guard let range = source.range(
            of: needle,
            range: searchStart..<source.endIndex
        ) else {
            return false
        }
        searchStart = range.upperBound
    }
    return true
}

@main
struct InteractionWiringTests {
    static func main() throws {
        try clipboardMarkerPreservesLitheRequestID()
        try supportedLitheFilesPreserveOrder()
        try invalidLitheSelectionsAreRejected()
        try litheGeneratedFilesAndMissingAppAreRejected()
        injectedLitheClientReceivesExactInvocation()

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

        let appSource = try! String(contentsOfFile: "CopiedApp.swift", encoding: .utf8)
        expect(
            appSource.contains("Text(Image(systemName: \"arrow.up.circle.fill\"))"),
            "menu update indicator embeds the trailing symbol in text"
        )
        expect(
            !appSource.contains("Image(systemName: \"circle.fill\")"),
            "menu update indicator does not use the leading dot"
        )
        expect(
            appSource.contains("func applicationShouldHandleReopen("),
            "reopening an already running app is handled"
        )
        expect(
            appSource.contains("SettingsNavigation.requestSettings()"),
            "the reopen handler requests the SwiftUI settings scene"
        )
        expect(
            appSource.contains("@Environment(\\.openSettings) private var openSettings"),
            "the persistent menu bar label owns the native settings action"
        )
        expect(
            appSource.contains("for: SettingsNavigation.showSettingsNotification"),
            "the menu bar label receives settings requests while the menu is closed"
        )
        expect(
            !appSource.contains("showSettingsWindow:"),
            "settings opening does not use the ineffective AppKit selector"
        )
        expect(
            appSource.contains("NSWorkspace.didActivateApplicationNotification")
                && appSource.contains("com.apple.systempreferences")
                && appSource.contains("suspendForSystemSettings()")
                && appSource.contains("resumeAfterSystemSettings()"),
            "System Settings activation suspends the active mouse event filter"
        )
        let launchSource = section(
            in: appSource,
            from: "func applicationDidFinishLaunching(",
            to: "@objc private func handleGlobalMouseEventTapBecameUnavailable"
        )
        expect(launchSource != nil, "application launch wiring exists")
        expect(
            launchSource.map {
                appearsInOrder(
                    [
                        "DetectionRegistry.shared.registerBuiltInDetectors()",
                        "loader.loadAllPlugins()",
                        "monitor?.start()",
                        "FirstResponseWarmUp.perform(using: toastController!)",
                    ],
                    in: $0
                )
            } == true,
            "first-response warm-up runs after detector/plugin setup and clipboard baseline capture"
        )
        expect(
            appSource.contains("EntityDetectorWarmUp.perform()")
                && appSource.contains("let source = SourceAppDetector.detect()")
                && appSource.contains("toastController.showStartupNotice(using: source)"),
            "first-response warm-up primes production detectors and source icon before the startup notice"
        )
        expect(
            launchSource?.contains("NSWorkspace.didActivateApplicationNotification") == true
                && appSource.contains("SourceAppDetector.prepareIcon(for: application)"),
            "newly activated source app icons are prepared before the next copy"
        )

        let sourceDetectorSource = try! String(
            contentsOfFile: "SourceAppDetector.swift",
            encoding: .utf8
        )
        expect(
            sourceDetectorSource.contains("iconCache.object(forKey: cacheKey)")
                && sourceDetectorSource.contains("iconCache.setObject(icon, forKey: cacheKey)"),
            "source app icons are reused after their first materialization"
        )

        let toastControllerSource = try! String(
            contentsOfFile: "ToastWindowController.swift",
            encoding: .utf8
        )
        let startupNoticeSource = section(
            in: toastControllerSource,
            from: "func showStartupNotice(using source: SourceAppInfo)",
            to: "func show(content: ClipboardContent, source: SourceAppInfo)"
        )
        expect(startupNoticeSource != nil, "one-shot startup notice entry point exists")
        expect(
            startupNoticeSource?.contains("guard !hasShownStartupNotice else { return }") == true
                && startupNoticeSource?.contains("viewModel.configureStartupNotice(source: source)") == true
                && startupNoticeSource?.contains("currentContent = nil") == true
                && startupNoticeSource?.contains("autoDismissAfter: startupNoticeDuration") == true
                && startupNoticeSource?.contains("pausesDismissWhileHovered: false") == true
                && startupNoticeSource?.contains("quickTriggerCoordinator.start") == false,
            "startup notice is one-shot, actionless, and uses its fixed one-second presentation policy"
        )
        expect(
            startupNoticeSource?.contains("NSPasteboard") == false
                && startupNoticeSource?.contains("CopySoundFeedback") == false
                && startupNoticeSource?.contains("ActionResolver") == false
                && startupNoticeSource?.contains("quickTriggerCoordinator.start") == false,
            "startup notice does not touch the clipboard, sound, action resolver, or quick trigger"
        )
        let productionShowSource = section(
            in: toastControllerSource,
            from: "func show(content: ClipboardContent, source: SourceAppInfo)",
            to: "private func presentConfiguredToast("
        )
        expect(
            productionShowSource?.contains("pauseDismissTimer()") == true
                && productionShowSource?.contains("viewModel.configure(with: content, source: source)") == true
                && productionShowSource?.contains("currentContent = content") == true
                && productionShowSource?.contains("quickTriggerCoordinator.start") == false,
            "classified low-interruption content installs without enabling Quick Trigger before Action readiness"
        )
        let pendingSource = section(
            in: toastControllerSource,
            from: "func showPending(revision:",
            to: "func applyBaseContent"
        )
        expect(
            pendingSource?.contains("viewModel.configurePending") == true
                && pendingSource?.contains(".now() + 0.05") == true
                && pendingSource?.contains("quickTriggerCoordinator.start") == false,
            "new revisions synchronously show non-interactive Pending then transition to loading"
        )
        let actionReadySource = section(
            in: toastControllerSource,
            from: "func applyActions(",
            to: "func showFailure"
        )
        expect(
            actionReadySource?.contains("refreshQuickTriggerContextIfEligible()") == true
                && actionReadySource?.contains("ensureMinimumActionableTime()") == true,
            "Action readiness starts Quick Trigger and guarantees its minimum usable lifetime"
        )
        let sharedPresentationSource = section(
            in: toastControllerSource,
            from: "private func presentConfiguredToast(",
            to: "private func makeToastView()"
        )
        expect(
            sharedPresentationSource?.contains("dismissGeneration += 1") == true
                && sharedPresentationSource?.contains("window?.orderOut(nil)") == true
                && sharedPresentationSource?.contains("createWindow()") == true
                && sharedPresentationSource?.contains("makeToastView()") == true
                && sharedPresentationSource?.contains("ToastHostingView(") == true
                && sharedPresentationSource?.contains("installExpandedTextSurface()") == false
                && toastControllerSource.contains("        installExpandedTextSurface()\n        let expandedText = viewModel.expandedText")
                && sharedPresentationSource?.contains("layoutSubtreeIfNeeded()") == true
                && sharedPresentationSource?.contains("fittingSize") == true
                && sharedPresentationSource?.contains("window?.orderFront(nil)") == true,
            "startup and real-copy presentations share the production panel, layout, fitting, and visible orderFront path"
        )
        expect(
            appearsInOrder(
                ["dismissGeneration += 1", "window?.orderOut(nil)", "createWindow()"],
                in: sharedPresentationSource ?? ""
            ),
            "every replacement advances the generation before rebuilding the window"
        )
        expect(
            toastControllerSource.contains("private let startupNoticeDuration: TimeInterval = 1.0")
                && toastControllerSource.contains("guard !isDismissing, pausesDismissWhileHovered else { return }")
                && toastControllerSource.contains("self.dismissTimerGeneration == generation")
                && toastControllerSource.contains("self.dismissGeneration == gen")
                && toastControllerSource.contains("self.releasePresentation()")
                && toastControllerSource.contains("viewModel = ToastViewModel()"),
            "startup notice releases its window/model state after one second and cannot close a replacement"
        )

        let toastViewModelSource = try! String(
            contentsOfFile: "ToastViewModel.swift",
            encoding: .utf8
        )
        let startupConfigurationSource = section(
            in: toastViewModelSource,
            from: "func configureStartupNotice(source: SourceAppInfo)",
            to: "func cancelAsyncThumbnail()"
        )
        expect(
            startupConfigurationSource?.contains("resetForNewPresentation()") == true
                && startupConfigurationSource?.contains("phase = .startup") == true
                && startupConfigurationSource?.contains("ActionResolver") == false,
            "startup notice receives a dedicated configuration without clipboard actions"
        )
        let startupToastViewSource = try! String(
            contentsOfFile: "ToastView.swift",
            encoding: .utf8
        )
        expect(
            startupToastViewSource.contains("guard viewModel.canExpand else { return }")
                && startupToastViewSource.contains("if !viewModel.isStartupNotice {")
                && startupToastViewSource.contains(".allowsHitTesting(viewModel.canExpand)")
                && startupToastViewSource.contains("if viewModel.isContentReady"),
            "startup notice cannot expand and hides source metadata and usable context-menu content"
        )
        let localizationSource = try! String(
            contentsOfFile: "Localizable.xcstrings",
            encoding: .utf8
        )
        expect(
            localizationSource.contains("\"Copied 已启动\"")
                && localizationSource.contains("\"Copied is ready\"")
                && localizationSource.contains("\"Copied 已啟動\""),
            "startup notice is localized in all supported languages"
        )
        let mouseCoordinatorSource = try! String(
            contentsOfFile: "GlobalMouseEventCoordinator.swift",
            encoding: .utf8
        )
        expect(
            mouseCoordinatorSource.contains("isSuspendedForSystemSettings")
                && mouseCoordinatorSource.contains(
                    "if isSuspendedForSystemSettings { return true }"
                ),
            "listeners stay registered while the physical event tap is suspended"
        )
        let menuSource = section(
            in: appSource,
            from: "private struct MenuBarContent",
            to: "@main"
        )
        expect(menuSource != nil, "menu bar content exists")
        expect(
            menuSource?.contains("Toggle(\"轻打扰模式\"") == true
                && menuSource?.contains("PopupPresentationPreferences.modeKey") == true,
            "menu bar toggles the popup presentation mode"
        )
        expect(
            menuSource?.contains("lightReminderEnabled") == false,
            "menu bar does not bind the icon-only reminder setting"
        )

        let infoData = try! Data(contentsOf: URL(fileURLWithPath: "Info.plist"))
        let info = try! PropertyListSerialization.propertyList(
            from: infoData,
            format: nil
        ) as! [String: Any]
        expect(
            info["CFBundleIconFile"] as? String == "Copied",
            "Finder has the legacy macOS icon file declaration"
        )

        let settingsSource = try! String(contentsOfFile: "SettingsView.swift", encoding: .utf8)
        expect(
            settingsSource.contains("private var quitFooter: some View"),
            "settings exposes a persistent quit footer"
        )
        expect(
            settingsSource.contains("Button(\"退出 Copied\")"),
            "the settings footer provides an explicit quit action"
        )
        expect(
            settingsSource.contains(".background(.bar)"),
            "the settings footer uses the native bar background style"
        )
        expect(
            settingsSource.contains("Section(\"支持与反馈\")")
                && settingsSource.contains("Label(\"问题反馈…\"")
                && settingsSource.contains("Button(\"发送邮件\")")
                && settingsSource.contains("Button(\"提交 GitHub Issue\")"),
            "About offers email and GitHub feedback channels"
        )
        expect(
            settingsSource.contains("Picker(\"弹窗模式\"")
                && settingsSource.contains("Button(\"自定义…\")")
                && settingsSource.contains("Picker(\"声音\""),
            "copy feedback exposes popup mode customization and keeps sound selection"
        )
        expect(
            settingsSource.contains("DisclosureGroup(isExpanded: $isAdvancedExpanded)")
                && settingsSource.contains("Text(\"高级\")")
                && settingsSource.contains("Toggle(\"仅提醒模式\"")
                && settingsSource.contains(
                    "开启后，只把符合条件的完整弹窗替换为鼠标旁的短暂图标。"
                ),
            "icon-only reminder mode lives in the advanced disclosure"
        )
        expect(
            settingsSource.contains("isAdvancedExpanded.toggle()")
                && settingsSource.contains(
                    ".frame(maxWidth: .infinity, alignment: .leading)"
                )
                && settingsSource.contains(".contentShape(Rectangle())")
                && settingsSource.contains(".buttonStyle(.plain)"),
            "the whole advanced disclosure label is an accessible click target"
        )
        expect(
            !settingsSource.contains("Toggle(\"轻提醒模式\""),
            "the former top-level light-reminder toggle is removed"
        )

        let toastViewSource = try! String(
            contentsOfFile: "ToastView.swift",
            encoding: .utf8
        )
        let metadataRowsSource = section(
            in: toastViewSource,
            from: "                    if !viewModel.isStartupNotice {\n                        VStack(alignment: .leading, spacing: 4) {",
            to: "\n                // ── Right: Action Button"
        )
        expect(metadataRowsSource != nil, "metadata rows remain in the collapsed toast")
        expect(
            metadataRowsSource?.components(separatedBy: "AutoScrollingMetadataRow(").count == 3,
            "source and detail each use an independent auto-scrolling row"
        )
        expect(
            metadataRowsSource?.contains("if !viewModel.metadataDetailText.isEmpty") == true,
            "an empty detail does not create a second metadata row"
        )
        expect(
            metadataRowsSource?.contains(".allowsHitTesting(false)") == true,
            "metadata rows continue to pass clicks through to the card background"
        )
        let autoScrollSource = section(
            in: toastViewSource,
            from: "private struct AutoScrollingMetadataRow<Content: View>",
            to: "struct ToastView: View"
        )
        expect(autoScrollSource != nil, "the private metadata scrolling component exists")
        expect(
            autoScrollSource?.contains(".clipped()") == true
                && autoScrollSource?.contains(".lineLimit(1)") == true,
            "metadata content stays on one clipped line"
        )
        expect(
            autoScrollSource?.contains(".mask") == true
                && toastViewSource.contains("private struct MetadataOverflowMask")
                && toastViewSource.contains("LinearGradient("),
            "overflowing metadata uses a position-aware gradient mask"
        )
        expect(
            autoScrollSource?.contains("if overflow > 0, viewportWidth > 0") == true
                && autoScrollSource?.contains("Rectangle().fill(.white)") == true,
            "non-overflowing metadata keeps a fully opaque mask"
        )
        expect(
            autoScrollSource?.contains("MetadataWidthReader") == true
                && !toastViewSource.contains("PreferenceKey"),
            "each metadata row owns instance-local geometry measurements"
        )
        expect(
            autoScrollSource?.contains("ScrollView") == false,
            "metadata overflow does not add a scroll view"
        )
        expect(
            autoScrollSource?.contains(".onTapGesture") == false
                && autoScrollSource?.contains("Button") == false,
            "metadata overflow adds no click path"
        )
        expect(
            appearsInOrder(
                ["isCardHovered = hovering", "onHoverChanged(hovering)"],
                in: toastViewSource
            ),
            "card hover drives metadata without replacing dismiss-timer forwarding"
        )
        let generalFormSource = section(
            in: settingsSource,
            from: "            Form {",
            to: "            .formStyle(.grouped)"
        )
        expect(generalFormSource != nil, "general settings form exists")
        expect(
            generalFormSource.map {
                appearsInOrder(
                    [
                        "Text(\"快速触发\")",
                        "DisclosureGroup(isExpanded: $isAdvancedExpanded)",
                    ],
                    in: $0
                )
            } == true,
            "advanced disclosure follows the final standard general section"
        )
        if let generalFormSource,
           let advancedRange = generalFormSource.range(
               of: "DisclosureGroup(isExpanded: $isAdvancedExpanded)"
           ) {
            expect(
                !generalFormSource[advancedRange.upperBound...]
                    .contains("\n                Section {"),
                "advanced disclosure is at the bottom of the general form"
            )
        }

        let clipboardSource = try! String(contentsOfFile: "ClipboardMonitor.swift", encoding: .utf8)
        let enrichmentSource = try! String(
            contentsOfFile: "ClipboardContentEnrichment.swift",
            encoding: .utf8
        )
        expect(
            !clipboardSource.contains("preview=\\(content.preview"),
            "clipboard diagnostics never interpolate preview text"
        )
        expect(
            !clipboardSource.contains("rawText=\\(content.rawText"),
            "clipboard diagnostics never interpolate raw clipboard text"
        )
        expect(
            clipboardSource.contains("firstResponsePollInterval: TimeInterval = 0.025")
                && clipboardSource.contains("steadyStatePollInterval: TimeInterval = 0.075")
                && clipboardSource.contains(
                    "scheduleTimer(withTimeInterval: firstResponsePollInterval)"
                )
                && clipboardSource.contains(
                    "scheduleTimer(withTimeInterval: steadyStatePollInterval)"
                ),
            "clipboard polling boosts the first response before returning to the 75ms interval"
        )
        expect(
            enrichmentSource.contains("LitheClipboardMetadata(pasteboard: pasteboard)"),
            "clipboard parsing records Lithe's private marker and request ID"
        )
        expect(
            appearsInOrder(
                [
                    "AppFilterSettings.shared.shouldShowPopup",
                    "candidateDecision != .allDenied",
                    "toastController?.showPending",
                    "submitBaseRead(session: session)",
                    "CopySoundFeedback.play(selection:",
                    "tryPresentLowInterruption(session: session)",
                ],
                in: clipboardSource
            ),
            "blacklist, visual candidate policy, first frame, successful-read sound, and filtering stay ordered"
        )
        expect(
            clipboardSource.contains("textLength: content.textLength")
                && clipboardSource.contains("primaryKindID: content.contentKind?.id"),
            "low-interruption policy receives base text length and the async primary kind ID"
        )
        expect(
            enrichmentSource.contains("values.isRegularFile == true")
                && enrichmentSource.contains("classificationIsComplete")
                && clipboardSource.contains("shouldPresentFiles("),
            "async whole-selection image-file classification fails closed when incomplete"
        )

        let popupFilterSource = try! String(
            contentsOfFile: "PopupFilterSettingsView.swift",
            encoding: .utf8
        )
        expect(
            popupFilterSource.contains("DetectionRegistry.shared.allRegisteredKinds")
                && popupFilterSource.contains("AppLanguage.isContentKindAvailable")
                && popupFilterSource.contains("$0.id != \"colorRGB\"")
                && popupFilterSource.contains("$0.id != \"colorHSL\""),
            "popup customization lists available kinds with one color preference"
        )
        expect(
            popupFilterSource.contains("let window = NSWindow(")
                && popupFilterSource.contains("styleMask: [.titled, .closable]")
                && popupFilterSource.contains("window.level = .normal")
                && !popupFilterSource.contains("NSPanel"),
            "popup customization uses an ordinary reusable window"
        )

        let buildSource = try! String(contentsOfFile: "build.sh", encoding: .utf8)
        let testRunnerSource = try! String(contentsOfFile: "run-tests.sh", encoding: .utf8)
        let productionWiring = [
            appSource,
            settingsSource,
            clipboardSource,
            buildSource,
            testRunnerSource,
        ].joined(separator: "\n")
        expect(
            !productionWiring.contains("Onboarding"),
            "popup presentation ships without onboarding wiring"
        )
        let projectEntries = try! FileManager.default.contentsOfDirectory(atPath: ".")
        expect(
            !projectEntries.contains { $0.hasPrefix("Onboarding") },
            "popup presentation adds no onboarding source files"
        )

        let actionSource = try! String(contentsOfFile: "ClipboardAction.swift", encoding: .utf8)
        expect(
            actionSource.contains("struct CompressImagesAction: ClipboardAction"),
            "Lithe compression is a built-in action rather than a plugin capability"
        )
        expect(
            actionSource.contains("primary = compressAction"),
            "eligible image files place Lithe on the primary button"
        )
        expect(
            actionSource.contains("menu.append(compressAction)"),
            "eligible image files also place Lithe in the context menu"
        )

        print("InteractionWiringTests: PASS")
    }

    private static func clipboardMarkerPreservesLitheRequestID() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("Copied.LitheIntegrationTests.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        let requestID = UUID()
        expect(
            pasteboard.setString(
                "generated",
                forType: LitheIntegrationContract.generatedFilesPasteboardType
            ),
            "Lithe marker is written to the test pasteboard"
        )
        expect(
            pasteboard.setString(
                requestID.uuidString,
                forType: LitheIntegrationContract.requestIDPasteboardType
            ),
            "Lithe request ID is written to the test pasteboard"
        )

        let metadata = LitheClipboardMetadata(pasteboard: pasteboard)
        expect(metadata.isGeneratedByLithe, "Lithe marker is recognized")
        expect(metadata.requestID == requestID, "Lithe request ID is preserved")
        pasteboard.clearContents()
    }

    private static func supportedLitheFilesPreserveOrder() throws {
        try withTemporarySelection { directory in
            let first = try makeFile(named: "first.PNG", in: directory)
            let second = try makeFile(named: "second.jpeg", in: directory)
            let third = try makeFile(named: "third.jpg", in: directory)
            let applicationURL = URL(fileURLWithPath: "/Applications/Lithe.app")
            var lookupCount = 0
            let client = LitheApplicationClient(
                locateApplication: {
                    lookupCount += 1
                    return applicationURL
                },
                openFiles: { _ in }
            )

            let invocation = LitheCompressionEligibility.invocation(
                for: [first, second, third],
                isGeneratedByLithe: false,
                client: client
            )
            expect(invocation?.applicationURL == applicationURL, "installed Lithe is selected")
            expect(invocation?.fileURLs == [first, second, third], "file order is preserved")
            expect(lookupCount == 1, "Lithe lookup happens once for a valid selection")
        }
    }

    private static func invalidLitheSelectionsAreRejected() throws {
        try withTemporarySelection { directory in
            let png = try makeFile(named: "image.png", in: directory)
            let gif = try makeFile(named: "animation.gif", in: directory)
            let folder = directory.appendingPathComponent("folder.png", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            var lookupCount = 0
            let client = installedClient(lookupCount: { lookupCount += 1 })

            expect(
                LitheCompressionEligibility.invocation(
                    for: [png],
                    selectionIsComplete: false,
                    isGeneratedByLithe: false,
                    client: client
                ) == nil,
                "truncated file selections never produce a partial Lithe action"
            )
            expect(
                LitheCompressionEligibility.invocation(
                    for: [png, gif],
                    isGeneratedByLithe: false,
                    client: client
                ) == nil,
                "mixed supported and unsupported file types are rejected"
            )
            expect(
                LitheCompressionEligibility.invocation(
                    for: [folder],
                    isGeneratedByLithe: false,
                    client: client
                ) == nil,
                "directories with image-looking names are rejected"
            )
            expect(
                LitheCompressionEligibility.invocation(
                    for: [URL(string: "https://example.com/image.png")!],
                    isGeneratedByLithe: false,
                    client: client
                ) == nil,
                "non-file URLs are rejected"
            )
            expect(
                LitheCompressionEligibility.invocation(
                    for: nil,
                    isGeneratedByLithe: false,
                    client: client
                ) == nil,
                "clipboard bitmap data without file URLs is rejected"
            )
            expect(lookupCount == 0, "invalid selections do not query installed apps")
        }
    }

    private static func litheGeneratedFilesAndMissingAppAreRejected() throws {
        try withTemporarySelection { directory in
            let png = try makeFile(named: "image.png", in: directory)
            var generatedLookupCount = 0
            expect(
                LitheCompressionEligibility.invocation(
                    for: [png],
                    isGeneratedByLithe: true,
                    client: installedClient(lookupCount: { generatedLookupCount += 1 })
                ) == nil,
                "Lithe-generated files suppress the compression action"
            )
            expect(generatedLookupCount == 0, "marker suppression avoids app lookup")

            let missingClient = LitheApplicationClient(
                locateApplication: { nil },
                openFiles: { _ in }
            )
            expect(
                LitheCompressionEligibility.invocation(
                    for: [png],
                    isGeneratedByLithe: false,
                    client: missingClient
                ) == nil,
                "the action is unavailable when Lithe is not installed"
            )
        }
    }

    private static func injectedLitheClientReceivesExactInvocation() {
        let first = URL(fileURLWithPath: "/tmp/first.png")
        let second = URL(fileURLWithPath: "/tmp/second.jpg")
        let applicationURL = URL(fileURLWithPath: "/Applications/Lithe.app")
        let invocation = LitheInvocation(
            applicationURL: applicationURL,
            fileURLs: [first, second]
        )
        var openedInvocation: LitheInvocation?
        let client = LitheApplicationClient(
            locateApplication: { applicationURL },
            openFiles: { openedInvocation = $0 }
        )

        client.openFiles(invocation)
        expect(openedInvocation == invocation, "the injected opener receives the exact invocation")
        let configuration = LitheApplicationClient.makeOpenConfiguration()
        expect(!configuration.activates, "opening Lithe does not activate it")
        expect(!configuration.addsToRecentItems, "opening Lithe does not add recent items")
        expect(
            LitheIntegrationContract.applicationBundleIdentifier == "com.lithe.app",
            "the Lithe bundle identifier has one stable contract value"
        )
    }

    private static func installedClient(lookupCount: @escaping () -> Void) -> LitheApplicationClient {
        LitheApplicationClient(
            locateApplication: {
                lookupCount()
                return URL(fileURLWithPath: "/Applications/Lithe.app")
            },
            openFiles: { _ in }
        )
    }

    private static func withTemporarySelection(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Copied-LitheIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private static func makeFile(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("test".utf8).write(to: url, options: .atomic)
        return url
    }
}
