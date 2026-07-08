import SwiftUI
import AppKit

private struct MenuBarContent: View {
    @AppStorage("isPaused") private var isPaused = false
    @AppStorage("lightReminderEnabled") private var lightReminderEnabled = false
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
            Divider()
            Toggle("轻提醒模式", isOn: $lightReminderEnabled)
            Divider()
            SettingsLink {
                Text("设置…")
            }
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
