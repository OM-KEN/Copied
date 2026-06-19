import SwiftUI
import AppKit

@main
struct CopiedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("isPaused") private var isPaused = false

    var body: some Scene {
        MenuBarExtra("Copied", systemImage: "doc.on.clipboard") {
            Toggle("暂停", isOn: Binding(
                get: { isPaused },
                set: { newValue in
                    isPaused = newValue
                    appDelegate.setPaused(newValue)
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
        toastController = ToastWindowController()
        monitor = ClipboardMonitor(toastController: toastController!)
        monitor?.start()
        NSLog("Copied: monitor started")
    }

    func setPaused(_ paused: Bool) {
        if paused { monitor?.stop() } else { monitor?.start() }
    }
}
