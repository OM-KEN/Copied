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

    // ── Copy Gesture ───────────────────────────────────────
    @AppStorage("copyGestureEnabled") private var copyGestureEnabled = false
    @State private var selectedTab = "general"
    @State private var isGestureTrusted = AXIsProcessTrusted()
    @State private var showRestartAlert = false

    var body: some View {
        TabView(selection: $selectedTab) {
            // ── General + Search ─────────────────────────
            Form {
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
            .tabItem {
                Label("通用", systemImage: "gearshape")
            }
            .tag("general")

            // ── Types ─────────────────────────────────────
            TypeSettingsView()
                .tabItem {
                    Label("类型", systemImage: "rectangle.grid.1x2")
                }
                .tag("types")

            // ── Gesture ───────────────────────────────────
            gestureTab
                .tabItem {
                    Label("手势", systemImage: "hand.tap")
                }
                .tag("gesture")
        }
        .frame(width: 380, height: 400)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Gesture Tab

    private var gestureTab: some View {
        Form {
            Section {
                Toggle("左右键快捷复制", isOn: Binding(
                    get: { copyGestureEnabled && isGestureTrusted },
                    set: { enabled in
                        if enabled {
                            if isGestureTrusted {
                                copyGestureEnabled = true
                                CopyGestureManager.shared.start()
                            } else {
                                showRestartAlert = true
                            }
                        } else {
                            copyGestureEnabled = false
                            CopyGestureManager.shared.stop()
                        }
                    }
                ))

                Text("按住左键时点击右键 → 自动 ⌘C 复制")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("功能")
            }

            Section {
                HStack {
                    Image(systemName: CopyGestureManager.shared.isRunning
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(CopyGestureManager.shared.isRunning ? .green : .yellow)
                    Text(CopyGestureManager.shared.isRunning ? "运行中" : "未运行")
                    if !CopyGestureManager.shared.isRunning {
                        Button("打开辅助功能设置…") {
                            openAccessibilityPrefs()
                        }
                    }
                }
                if !CopyGestureManager.shared.lastDiagnostic.isEmpty {
                    Text(CopyGestureManager.shared.lastDiagnostic)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("此功能需要辅助功能权限来监听鼠标事件。授权或撤销后需重启 Copied。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("权限")
            }
        }
        .formStyle(.grouped)
        .alert("需要辅助功能权限", isPresented: $showRestartAlert) {
            Button("请求权限") {
                requestAccessibilityAndRetry()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此功能需要系统辅助功能权限来监听鼠标事件。授权后请重启 Copied 使权限生效。")
        }
        .onAppear {
            isGestureTrusted = AXIsProcessTrusted()
        }
    }

    private func requestAccessibilityAndRetry() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        // 给系统弹窗一点时间，然后刷新状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            isGestureTrusted = AXIsProcessTrusted()
        }
    }

    private func openAccessibilityPrefs() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
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
