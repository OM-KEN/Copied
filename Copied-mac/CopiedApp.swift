import SwiftUI
import AppKit
import ServiceManagement

enum SettingsNavigation {
    static let showAboutNotification = Notification.Name("CopiedShowAboutSettings")
    static let showSettingsNotification = Notification.Name("CopiedShowSettings")
    private(set) static var requestedTab: String?

    static func requestAboutTab() {
        requestedTab = "about"
        NotificationCenter.default.post(name: showAboutNotification, object: nil)
    }

    static func clearRequest() {
        requestedTab = nil
    }

    static func requestSettings() {
        NotificationCenter.default.post(name: showSettingsNotification, object: nil)
    }

    static func openAboutFromToast() {
        requestAboutTab()
        requestSettings()
    }
}

private struct MenuBarLabel: View {
    @Environment(\.openSettings) private var openSettings
    let icon: NSImage

    var body: some View {
        Image(nsImage: icon)
            .onReceive(
                NotificationCenter.default.publisher(
                    for: SettingsNavigation.showSettingsNotification
                )
            ) { _ in
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
    }
}

private struct MenuBarContent: View {
    @Environment(\.openSettings) private var openSettings
    @AppStorage("isPaused") private var isPaused = false
    @AppStorage("lightReminderEnabled") private var lightReminderEnabled = false
    @ObservedObject private var updateService = AppUpdateService.shared
    let onPauseToggle: (Bool) -> Void

    var body: some View {
        Group {
            Toggle("暂停", isOn: Binding(
                get: { isPaused },
                set: { newValue in
                    isPaused = newValue
                    onPauseToggle(newValue)
                }
            ))
            Toggle("轻提醒模式", isOn: $lightReminderEnabled)
            Divider()
            SettingsLink {
                Text("设置…")
            }
            Button {
                SettingsNavigation.requestAboutTab()
                openSettings()
            } label: {
                if updateService.showsMenuUpdateIndicator {
                    Text(verbatim: MenuVersionTextFormatter.string(
                        version: AppVersion.currentString,
                        hasUpdate: true
                    ))
                    + Text(" ")
                    + Text(Image(systemName: "arrow.up.circle.fill"))
                        .foregroundColor(.green)
                } else {
                    Text(verbatim: MenuVersionTextFormatter.string(
                        version: AppVersion.currentString,
                        hasUpdate: false
                    ))
                }
            }
            Divider()
            Button("退出") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

@main
struct CopiedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("isPaused") private var isPaused = false

    private let menuBarIcon: NSImage = {
        let icon = Bundle.main.url(forResource: "Copied-menu", withExtension: "svg")
            .flatMap { NSImage(contentsOf: $0) }
        icon?.isTemplate = true
        icon?.size = NSSize(width: 18, height: 18)
        return icon ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Copied")!
    }()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(onPauseToggle: { appDelegate.setPaused($0) })
        } label: {
            MenuBarLabel(icon: menuBarIcon)
        }

        Settings {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: ClipboardMonitor?
    private var toastController: ToastWindowController?
    @AppStorage("copyGestureEnabled") private var copyGestureEnabled = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        SettingsNavigation.requestSettings()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Copied: applicationDidFinishLaunching")

        // Pre-warm DictionaryServices asynchronously with synthetic input.
        DictionaryLookupService.scheduleWarmUp()

        // Pre-warm NSDataDetector (lazy init ~20ms — do it now, not on first copy)
        _ = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

        // Register all built-in content detectors
        DetectionRegistry.shared.registerBuiltInDetectors()

        // Load installed plugins
        let loader = PluginLoader()
        loader.loadAllPlugins()

        toastController = ToastWindowController()
        monitor = ClipboardMonitor(toastController: toastController!)
        monitor?.start()
        NSLog("Copied: monitor started")

        // Sync login item with system state
        // Rebuild 后签名变化可能使 macOS 清掉注册记录，此时 UserDefaults 仍为 true
        syncLoginItem()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGlobalMouseEventTapBecameUnavailable),
            name: GlobalMouseEventCoordinator.eventTapBecameUnavailableNotification,
            object: GlobalMouseEventCoordinator.shared
        )

        // Copy gesture — restore only a prior user request backed by current permission.
        let gestureTrusted = AXIsProcessTrusted()
        let shouldEnableGesture = CopyGesturePermissionPolicy.reconciledEnabled(
            requested: copyGestureEnabled,
            accessibilityTrusted: gestureTrusted
        )
        if shouldEnableGesture {
            CopyGestureManager.shared.start()
        } else if copyGestureEnabled {
            NSLog("Copied: gesture toggle was ON but AX not trusted — resetting to OFF")
        }
        copyGestureEnabled = shouldEnableGesture

        AppUpdateService.shared.startAutomaticChecks()
    }

    @objc private func handleGlobalMouseEventTapBecameUnavailable() {
        guard copyGestureEnabled || CopyGestureManager.shared.isRunning else { return }
        copyGestureEnabled = false
        CopyGestureManager.shared.stop()
    }

    /// 确保 UserDefaults 中的 launchAtLogin 与 SMAppService 实际状态一致
    private func syncLoginItem() {
        let launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        let status = SMAppService.mainApp.status
        NSLog("Copied: syncLoginItem launchAtLogin=\(launchAtLogin) SMAppService.status=\(status.rawValue)")

        if launchAtLogin && status != .enabled {
            NSLog("Copied: state mismatch — attempting re-register")
            do {
                try SMAppService.mainApp.register()
                NSLog("Copied: SMAppService re-register succeeded")
            } catch {
                NSLog("Copied: SMAppService re-register failed: \(error.localizedDescription)")
                // 注册失败，重置 UserDefaults 使其与实际状态一致
                UserDefaults.standard.set(false, forKey: "launchAtLogin")
            }
        }
    }

    func setPaused(_ paused: Bool) {
        if paused { monitor?.stop() } else { monitor?.start() }
    }

    func setCopyGestureEnabled(_ enabled: Bool) {
        if enabled {
            CopyGestureManager.shared.start()
        } else {
            CopyGestureManager.shared.stop()
        }
    }
}
