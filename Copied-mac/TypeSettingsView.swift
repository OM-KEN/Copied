import SwiftUI
import Observation

/// 类型设置视图 — 管理 ContentKind 优先级、启用/禁用、插件。
struct TypeSettingsView: View {

    /// 列表结构版本（仅在安装/移除插件时递增，toggle 不触发）。
    @State private var listVersion = 0

    /// 所有已知的 ContentKind（内置 + 已加载插件），含已禁用的。
    private var allKinds: [ContentKind] {
        _ = listVersion  // 读取以建立依赖
        return DetectionRegistry.shared.allRegisteredKinds
    }

    private var languageKinds: [ContentKind] {
        allKinds.filter { $0.isBuiltIn && $0.category == .language && $0.id != "plain" }
    }

    private var entityKinds: [ContentKind] {
        allKinds.filter { $0.isBuiltIn && $0.category == .entity }
    }

    private var installedPluginIDs: [String] {
        _ = listVersion
        return PluginLoader().installedPluginIDs
    }

    private func pluginKind(for pluginID: String) -> ContentKind? {
        allKinds.first { $0.id == pluginID }
    }

    var body: some View {
        Form {
            // ── Language Types ──────────────────────────────
            if !languageKinds.isEmpty {
                Section {
                    ForEach(languageKinds, id: \.id) { kind in
                        KindRow(kind: kind)
                    }
                } header: {
                    Text("语言类型")
                }
            }

            // ── Entity Types ────────────────────────────────
            if !entityKinds.isEmpty {
                Section {
                    ForEach(entityKinds, id: \.id) { kind in
                        KindRow(kind: kind)
                    }
                } header: {
                    Text("内容类型")
                }
            }

            // ── Plugins ─────────────────────────────────────
            Section {
                if installedPluginIDs.isEmpty {
                    Text("暂无插件")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(installedPluginIDs, id: \.self) { pluginID in
                        let kind = pluginKind(for: pluginID)
                        let name = kind?.pluginName ?? kind?.label ?? pluginID
                        PluginRow(pluginID: pluginID, name: name, onRemoved: {
                            listVersion += 1
                        })
                    }
                }

                Button("安装插件…") {
                    installPlugin()
                }
            } header: {
                Text("插件")
            } footer: {
                Text("插件为 .copiedplugin 文件夹，包含 manifest.json 和 rules.json。仅支持声明式（JSON + 正则），不执行代码。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Install Plugin

    private func installPlugin() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.message = "选择 .copiedplugin 文件夹"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension == "copiedplugin" else {
            showAlert(message: "请选择有效的 .copiedplugin 文件夹")
            return
        }

        do {
            _ = try PluginLoader().installPlugin(from: url)
            listVersion += 1
        } catch {
            showAlert(message: error.localizedDescription)
        }
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "插件安装"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Kind Row

private struct KindRow: View {
    let kind: ContentKind

    /// 本地开关状态，从 Registry 初始化一次，之后独立管理。
    @State private var enabled: Bool

    init(kind: ContentKind) {
        self.kind = kind
        self._enabled = State(initialValue: DetectionRegistry.shared.isEnabled(kindID: kind.id))
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.icon.isEmpty ? "questionmark" : kind.icon)
                .frame(width: 20)
                .foregroundStyle(enabled ? .secondary : .tertiary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(kind.label.isEmpty ? kind.id : kind.label)
                        .font(.system(size: 13))
                        .foregroundStyle(enabled ? .primary : .tertiary)
                    if let src = kind.sourceLabel {
                        Text("(\(src))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(kind.id)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Toggle("", isOn: $enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: enabled) {
                    DetectionRegistry.shared.setEnabled(enabled, kindID: kind.id)
                }
        }
        .padding(.vertical, 2)
        .opacity(enabled ? 1.0 : 0.5)
        .animation(.easeInOut(duration: 0.15), value: enabled)
    }
}

// MARK: - Plugin Row

private struct PluginRow: View {
    let pluginID: String
    let name: String
    let onRemoved: () -> Void

    @State private var enabled: Bool

    init(pluginID: String, name: String, onRemoved: @escaping () -> Void) {
        self.pluginID = pluginID
        self.name = name
        self.onRemoved = onRemoved
        self._enabled = State(initialValue: DetectionRegistry.shared.isEnabled(kindID: pluginID))
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .frame(width: 20)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13))
                Text(pluginID)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: $enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: enabled) {
                    DetectionRegistry.shared.setEnabled(enabled, kindID: pluginID)
                }

            Button("移除") {
                PluginLoader().uninstallPlugin(identifier: pluginID)
                onRemoved()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .foregroundStyle(.red)
        }
        .padding(.vertical, 2)
    }
}
