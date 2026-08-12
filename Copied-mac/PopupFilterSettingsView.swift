import SwiftUI
import AppKit

final class PopupFilterWindowController: NSWindowController {
    static let shared = PopupFilterWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "轻打扰模式")
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func show() {
        window?.contentView = NSHostingView(rootView: PopupFilterSettingsView())
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct PopupFilterSettingsView: View {
    private let defaults: UserDefaults

    @State private var showShortPlainText: Bool
    @State private var showLongPlainText: Bool
    @State private var showImages: Bool
    @State private var showFiles: Bool
    @State private var disabledKindIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let preferences = PopupPresentationPreferences.current(defaults: defaults)
        _showShortPlainText = State(initialValue: preferences.showShortPlainText)
        _showLongPlainText = State(initialValue: preferences.showLongPlainText)
        _showImages = State(initialValue: preferences.showImages)
        _showFiles = State(initialValue: preferences.showFiles)
        _disabledKindIDs = State(initialValue: preferences.disabledKindIDs)
    }

    private var availableKinds: [ContentKind] {
        DetectionRegistry.shared.allRegisteredKinds
            .filter { AppLanguage.isContentKindAvailable($0) }
            .filter { $0.id != "colorRGB" && $0.id != "colorHSL" }
            .sorted { $0.id < $1.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("普通内容") {
                    Toggle(
                        String(localized: "普通短文本（少于\(ClipboardTextPolicy.longTextThreshold)字符）"),
                        isOn: Binding(
                            get: { showShortPlainText },
                            set: { newValue in
                                showShortPlainText = newValue
                                defaults.set(
                                    newValue,
                                    forKey: PopupPresentationPreferences.showShortPlainTextKey
                                )
                            }
                        )
                    )
                    Toggle(
                        String(localized: "普通长文本（\(ClipboardTextPolicy.longTextThreshold)字符及以上）"),
                        isOn: Binding(
                            get: { showLongPlainText },
                            set: { newValue in
                                showLongPlainText = newValue
                                defaults.set(
                                    newValue,
                                    forKey: PopupPresentationPreferences.showLongPlainTextKey
                                )
                            }
                        )
                    )
                    Toggle("图片", isOn: Binding(
                        get: { showImages },
                        set: { newValue in
                            showImages = newValue
                            defaults.set(
                                newValue,
                                forKey: PopupPresentationPreferences.showImagesKey
                            )
                        }
                    ))
                    Toggle("文件", isOn: Binding(
                        get: { showFiles },
                        set: { newValue in
                            showFiles = newValue
                            defaults.set(
                                newValue,
                                forKey: PopupPresentationPreferences.showFilesKey
                            )
                        }
                    ))
                }

                Section {
                    if availableKinds.isEmpty {
                        Text("暂无可用类型")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(availableKinds, id: \.id) { kind in
                            kindRow(kind)
                        }
                    }
                } header: {
                    Text("识别类型")
                } footer: {
                    Text("这些设置只决定是否显示弹窗，不会关闭内容识别。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("恢复默认") {
                    restoreDefaults()
                }
            }
            .padding()
        }
        .frame(width: 440, height: 520)
    }

    @ViewBuilder
    private func kindRow(_ kind: ContentKind) -> some View {
        let displayName = kind.label.isEmpty ? kind.id : kind.label
        HStack(spacing: 10) {
            Image(systemName: kind.icon.isEmpty ? "questionmark" : kind.icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .environment(
                    \.locale,
                    kind.forceEnglishLocale ? Locale(identifier: "en") : Locale.current
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                HStack(spacing: 4) {
                    Text(kind.id)
                    Text(verbatim: "·")
                    Text(sourceName(for: kind))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: kindBinding(for: kind.id))
                .labelsHidden()
                .accessibilityLabel(
                    String(localized: "显示“\(displayName)”弹窗")
                )
        }
    }

    private func kindBinding(for kindID: String) -> Binding<Bool> {
        Binding(
            get: { !disabledKindIDs.contains(kindID) },
            set: { enabled in
                if enabled {
                    disabledKindIDs.remove(kindID)
                } else {
                    disabledKindIDs.insert(kindID)
                }
                defaults.set(
                    disabledKindIDs.sorted(),
                    forKey: PopupPresentationPreferences.disabledKindIDsKey
                )
            }
        )
    }

    private func sourceName(for kind: ContentKind) -> String {
        switch kind.source {
        case .builtIn:
            String(localized: "内置")
        case let .plugin(identifier):
            kind.pluginName ?? identifier
        }
    }

    private func restoreDefaults() {
        PopupPresentationPreferences.restoreDefaults(defaults: defaults)
        let preferences = PopupPresentationPreferences.current(defaults: defaults)
        showShortPlainText = preferences.showShortPlainText
        showLongPlainText = preferences.showLongPlainText
        showImages = preferences.showImages
        showFiles = preferences.showFiles
        disabledKindIDs = preferences.disabledKindIDs
    }
}
