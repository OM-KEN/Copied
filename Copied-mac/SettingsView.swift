import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    // ── Launch at Login ────────────────────────────────────
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @State private var loginItemError: String? = nil

    // ── Search Engine ──────────────────────────────────────
    @AppStorage("searchEngine") private var searchEngine = "google"

    private let searchEngineNames: [(id: String, label: String)] = [
        ("google",    "Google"),
        ("baidu",     "Baidu"),
        ("bing",      "Bing"),
        ("duckduckgo", "DuckDuckGo"),
    ]

    var body: some View {
        Form {
            // ── General ────────────────────────────────────
            Section {
                Toggle("开机自启", isOn: Binding(
                    get: { launchAtLogin },
                    set: { toggle in
                        let success = setLoginItem(enabled: toggle)
                        if success {
                            launchAtLogin = toggle
                            loginItemError = nil
                        } else {
                            loginItemError = "需要将 Copied 移到 Applications 文件夹"
                        }
                    }
                ))
                if let error = loginItemError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("通用")
            }

            // ── Search ─────────────────────────────────────
            Section {
                Picker("搜索引擎", selection: $searchEngine) {
                    ForEach(searchEngineNames, id: \.id) { engine in
                        Text(engine.label).tag(engine.id)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("搜索")
            }
        }
        .formStyle(.grouped)
        .frame(width: 280)
        .fixedSize()
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Login Item

    private func setLoginItem(enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("Copied: SMAppService error: \(error.localizedDescription)")
            return false
        }
    }
}
