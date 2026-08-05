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

        print("InteractionWiringTests: PASS")
    }
}
