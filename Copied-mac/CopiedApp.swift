import SwiftUI
import AppKit
import ServiceManagement

enum SettingsNavigation {
    static let showAboutNotification = Notification.Name("CopiedShowAboutSettings")
    private(set) static var requestedTab: String?

    static func requestAboutTab() {
        requestedTab = "about"
        NotificationCenter.default.post(name: showAboutNotification, object: nil)
    }

    static func clearRequest() {
        requestedTab = nil
    }

    static func openAboutFromToast() {
        requestAboutTab()
        NSApp.activate(ignoringOtherApps: true)
        let opened = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        if !opened {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
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
                HStack(spacing: 4) {
                    if updateService.showsMenuUpdateIndicator {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(.green)
                    }
                    Text(verbatim: MenuVersionTextFormatter.string(
                        version: AppVersion.currentString,
                        hasUpdate: updateService.showsMenuUpdateIndicator
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
            Image(nsImage: menuBarIcon)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Copied: applicationDidFinishLaunching")

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

        // Copy gesture — enabled via Settings
        // 如果上次开关 ON 但权限丢失（更新后签名不匹配），自动置 OFF
        if copyGestureEnabled {
            if AXIsProcessTrusted() {
                CopyGestureManager.shared.start()
            } else {
                NSLog("Copied: gesture toggle was ON but AX not trusted — resetting to OFF")
                copyGestureEnabled = false
            }
        }

        AppUpdateService.shared.startAutomaticChecks()
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
