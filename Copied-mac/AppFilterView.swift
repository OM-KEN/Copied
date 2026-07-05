import SwiftUI
import AppKit

/// Blacklist management — apps whose clipboard changes won't trigger popups.
struct AppFilterView: View {
    @State private var blockedApps: [AppFilterEntry] = AppFilterSettings.shared.blockedApps
    @State private var showAppPicker = false

    var body: some View {
        Form {
            Section {
                if blockedApps.isEmpty {
                    Text("未添加任何应用")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(blockedApps) { entry in
                        HStack {
                            appIconView(for: entry.bundleID)
                            Text(entry.displayName)
                                .font(.system(size: 13))
                            Spacer()
                            Button {
                                removeApp(entry)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button {
                    showAppPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                        Text("添加运行中应用…")
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("黑名单")
                    Text("在黑名单中的应用复制时不会有弹窗。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.none)
                }
            }
        }
        .formStyle(.grouped)
        .popover(isPresented: $showAppPicker) {
            RunningAppPicker { entry in
                addApp(entry)
                showAppPicker = false
            }
        }
    }

    // ── Helpers ────────────────────────────────────────────

    @ViewBuilder
    private func appIconView(for bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 14))
                .frame(width: 16, height: 16)
        }
    }

    private func addApp(_ entry: AppFilterEntry) {
        AppFilterSettings.shared.addToBlocked(entry)
        blockedApps = AppFilterSettings.shared.blockedApps
    }

    private func removeApp(_ entry: AppFilterEntry) {
        AppFilterSettings.shared.removeFromBlocked(bundleID: entry.bundleID)
        blockedApps = AppFilterSettings.shared.blockedApps
    }
}

// MARK: - Running App Picker

private struct RunningAppPicker: View {
    let onSelect: (AppFilterEntry) -> Void

    @State private var apps: [AppFilterEntry] = []
    @State private var searchText = ""

    private var filteredApps: [AppFilterEntry] {
        if searchText.isEmpty { return apps }
        return apps.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("选择应用")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            if apps.isEmpty {
                Text("正在加载…")
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(width: 260, height: 200)
            } else {
                TextField("搜索…", text: $searchText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                Divider()

                List(filteredApps) { app in
                    Button {
                        onSelect(app)
                    } label: {
                        HStack {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable()
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "app.dashed")
                                    .font(.system(size: 14))
                                    .frame(width: 16, height: 16)
                            }
                            Text(app.displayName)
                                .font(.system(size: 13))
                                .lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .frame(width: 280, height: 280)
            }
        }
        .padding(.bottom, 8)
        .task {
            apps = AppFilterSettings.shared.runningApplications()
        }
    }
}
