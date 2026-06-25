import SwiftUI
import AppKit
@preconcurrency import Translation

// MARK: - 翻译会话注册视图

/// 包裹菜单栏内容的视图，附加 `.translationTask` 以注册翻译会话。
/// 用户点击菜单栏图标时触发，若模型未下载则弹出系统授权。
private struct MenuBarContent: View {
    @AppStorage("isPaused") private var isPaused = false
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
            SettingsLink {
                Text("设置…")
            }
            Button("退出") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .translationTask(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: "zh_Hans")
        ) { session in
            TranslationService.shared.registerSession(
                session,
                source: Locale.Language(identifier: "en"),
                target: Locale.Language(identifier: "zh_Hans")
            )
        }
        .translationTask(
            source: Locale.Language(identifier: "zh_Hans"),
            target: Locale.Language(identifier: "en")
        ) { session in
            TranslationService.shared.registerSession(
                session,
                source: Locale.Language(identifier: "zh_Hans"),
                target: Locale.Language(identifier: "en")
            )
        }
    }
}

@main
struct CopiedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("isPaused") private var isPaused = false

    var body: some Scene {
        MenuBarExtra("Copied", systemImage: "doc.on.clipboard") {
            MenuBarContent(onPauseToggle: { appDelegate.setPaused($0) })
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Copied: applicationDidFinishLaunching")

        // 注册默认值：翻译开关默认开启
        UserDefaults.standard.register(defaults: ["translationEnabled": true])

        // Pre-warm NSDataDetector (lazy init ~20ms — do it now, not on first copy)
        _ = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

        // Register all built-in content detectors
        DetectionRegistry.shared.registerBuiltInDetectors()

        // Load installed plugins + install examples on first launch
        let loader = PluginLoader()
        loader.loadAllPlugins()
        loader.installExamplePluginsIfNeeded()

        toastController = ToastWindowController()
        monitor = ClipboardMonitor(toastController: toastController!)
        monitor?.start()
        NSLog("Copied: monitor started")
    }

    func setPaused(_ paused: Bool) {
        if paused { monitor?.stop() } else { monitor?.start() }
    }
}
