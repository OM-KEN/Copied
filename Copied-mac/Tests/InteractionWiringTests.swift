import AppKit
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

        let clipboardSource = try! String(contentsOfFile: "ClipboardMonitor.swift", encoding: .utf8)
        expect(
            !clipboardSource.contains("preview=\\(content.preview"),
            "clipboard diagnostics never interpolate preview text"
        )
        expect(
            !clipboardSource.contains("rawText=\\(content.rawText"),
            "clipboard diagnostics never interpolate raw clipboard text"
        )
        expect(
            clipboardSource.contains("pollInterval: TimeInterval = 0.075"),
            "clipboard polling uses the 75ms responsiveness interval"
        )
        expect(
            clipboardSource.contains("LitheClipboardMetadata(pasteboard: pasteboard)"),
            "clipboard parsing records Lithe's private marker and request ID"
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
