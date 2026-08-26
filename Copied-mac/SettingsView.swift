import SwiftUI
import AppKit
import ServiceManagement

private enum PendingAccessibilityAction: Equatable {
    case copyGesture
    case boundMouseButton
    case mouseButtonRecording
    case manualAccessibilitySettings
}

struct SettingsView: View {
    // ── Launch at Login ────────────────────────────────────
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("lightReminderEnabled") private var lightReminderEnabled = false
    @AppStorage(PopupPresentationPreferences.modeKey)
    private var popupPresentationMode = PopupPresentationMode.all.rawValue
    @AppStorage(CopySoundFeedback.defaultsKey)
    private var copyFeedbackSound = CopySoundFeedback.defaultSoundName
    @State private var loginItemError: String? = nil
    @State private var isAdvancedExpanded = false

    // ── Quick Trigger ─────────────────────────────────────
    @AppStorage(QuickTriggerSettings.keyboardModifierKey)
    private var keyboardQuickTriggerModifier = KeyboardQuickTriggerModifier.control.rawValue
    @AppStorage(QuickTriggerSettings.keyboardModeKey)
    private var keyboardQuickTriggerMode = KeyboardQuickTriggerMode.doubleTap.rawValue
    @State private var mouseQuickTriggerButton: Int? = QuickTriggerSettings.current().mouseButton
    @State private var mouseRecordingState = MouseButtonRecordingStateMachine()
    @State private var mouseRecordingListenerToken: UUID?

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
    @State private var showPermissionRequestAlert = false
    @State private var showAccessibilityRestartAlert = false
    @State private var pendingAccessibilityAction: PendingAccessibilityAction?
    @State private var restartAccessibilityAction: PendingAccessibilityAction?
    @State private var accessibilityRequestGeneration = 0
    @State private var showRelaunchErrorAlert = false
    @State private var relaunchErrorMessage = ""
    @State private var showFeedbackOptions = false
    @State private var feedbackOpenErrorMessage: String?
    @AppStorage(AppUpdateService.automaticRemindersKey)
    private var automaticUpdateRemindersEnabled = true
    @ObservedObject private var updateService = AppUpdateService.shared

    private var popupPresentationModeBinding: Binding<PopupPresentationMode> {
        Binding(
            get: {
                PopupPresentationMode(rawValue: popupPresentationMode) ?? .all
            },
            set: { popupPresentationMode = $0.rawValue }
        )
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // ── General + Search ─────────────────────────
            Form {
                Section {
                    Picker("弹窗模式", selection: popupPresentationModeBinding) {
                        ForEach(PopupPresentationMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    if popupPresentationModeBinding.wrappedValue == .lowInterruption {
                        Button("自定义…") {
                            PopupFilterWindowController.shared.show()
                        }
                    }

                    Picker("声音", selection: Binding(
                        get: { CopySoundFeedback.resolvedSelection(copyFeedbackSound) },
                        set: { selection in
                            copyFeedbackSound = selection
                            CopySoundFeedback.play(selection: selection)
                        }
                    )) {
                        Text("无").tag(CopySoundFeedback.disabledValue)
                        ForEach(CopySoundFeedback.availableSoundNames, id: \.self) { soundName in
                            Text(verbatim: soundName).tag(soundName)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("复制反馈")
                }

                Section {
                    Toggle("开机自启", isOn: Binding(
                        get: { launchAtLogin },
                        set: { toggle in
                            let success = setLoginItem(enabled: toggle)
                            if success {
                                launchAtLogin = toggle
                                loginItemError = nil
                            } else {
                                loginItemError = String(localized: "需要将 Copied 移到 Applications 文件夹")
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

                Section {
                    Picker("键盘修饰键", selection: $keyboardQuickTriggerModifier) {
                        ForEach(KeyboardQuickTriggerModifier.allCases, id: \.rawValue) { modifier in
                            Text(modifier.displayName).tag(modifier.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    if keyboardQuickTriggerModifier != KeyboardQuickTriggerModifier.disabled.rawValue {
                        Picker("触发方式", selection: $keyboardQuickTriggerMode) {
                            ForEach(KeyboardQuickTriggerMode.allCases, id: \.rawValue) { mode in
                                Text(mode.displayName).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    HStack {
                        Text("鼠标侧键")
                        Spacer()
                        if let button = mouseQuickTriggerButton {
                            Text(String(localized: "按钮 \(button)"))
                                .foregroundStyle(.secondary)
                            Button("清除") { clearMouseQuickTriggerButton() }
                        } else {
                            Button(mouseRecordingState.isRecording ? "取消录制" : "录制侧键…") {
                                if mouseRecordingState.isRecording {
                                    stopMouseButtonRecording(reason: "userCancelled")
                                } else {
                                    startMouseButtonRecording()
                                }
                            }
                        }
                    }

                    if mouseQuickTriggerButton != nil, !isGestureTrusted {
                        Button("请求辅助功能权限…") {
                            requestAccessibilityAndRetry(for: .boundMouseButton)
                        }
                        Text("鼠标侧键快速触发需要辅助功能权限。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("快速触发")
                }

                Section {
                    DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("仅提醒模式", isOn: $lightReminderEnabled)
                            Text("开启后，只把符合条件的完整弹窗替换为鼠标旁的短暂图标。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    } label: {
                        Button {
                            withAnimation {
                                isAdvancedExpanded.toggle()
                            }
                        } label: {
                            Text("高级")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
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
                    Label("智能识别", systemImage: "rectangle.grid.1x2")
                }
                .tag("types")

            // ── Gesture ───────────────────────────────────
            gestureTab
                .tabItem {
                    Label("手势", systemImage: "hand.tap")
                }
                .tag("gesture")

            // ── Blacklist ───────────────────────────────
            AppFilterView()
                .tabItem {
                    Label("黑名单", systemImage: "hand.raised.slash")
                }
                .tag("blacklist")

            aboutTab
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
                .tag("about")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                quitFooter
            }
            .background(.bar)
        }
        .frame(width: 400, height: 480)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            refreshGesturePermission(clearUnavailableIntent: true)
            mouseQuickTriggerButton = QuickTriggerSettings.current().mouseButton
            if SettingsNavigation.requestedTab == "about" {
                selectedTab = "about"
                SettingsNavigation.clearRequest()
            }
        }
        .onDisappear {
            stopMouseButtonRecording(reason: "settingsDisappeared")
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsNavigation.showAboutNotification)) { _ in
            selectedTab = "about"
            SettingsNavigation.clearRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            resolveGesturePermissionAfterActivation()
        }
        .alert("需要辅助功能权限", isPresented: $showPermissionRequestAlert) {
            Button("请求权限") {
                copyGestureEnabled = true
                requestAccessibilityAndRetry(for: .copyGesture)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此功能需要系统辅助功能权限来监听鼠标事件。")
        }
        .alert("辅助功能权限已开启", isPresented: $showAccessibilityRestartAlert) {
            Button("退出并重新打开") {
                restartAccessibilityAction = nil
                ApplicationRelauncher.shared.relaunch { error in
                    relaunchErrorMessage = error.localizedDescription
                    showRelaunchErrorAlert = true
                }
            }
            Button("稍后", role: .cancel) {
                restartAccessibilityAction = nil
            }
        } message: {
            Text(accessibilityRestartMessage)
        }
        .alert("无法重新打开 Copied", isPresented: $showRelaunchErrorAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(verbatim: relaunchErrorMessage)
        }
        .confirmationDialog(
            "选择反馈方式",
            isPresented: $showFeedbackOptions,
            titleVisibility: .visible
        ) {
            Button("发送邮件") { openFeedbackEmail() }
            Button("提交 GitHub Issue") { openGitHubFeedback() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("邮件适合不便公开的信息；GitHub Issue 适合公开追踪的问题和建议。")
        }
        .alert(
            "无法打开反馈渠道",
            isPresented: Binding(
                get: { feedbackOpenErrorMessage != nil },
                set: { if !$0 { feedbackOpenErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(verbatim: feedbackOpenErrorMessage ?? "")
        }
    }

    private var quitFooter: some View {
        HStack {
            Spacer()
            Button("退出 Copied") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Copied")
                        .font(.title2.weight(.semibold))
                    HStack(spacing: 4) {
                        Text("版本")
                        Text(verbatim: AppVersion.currentString)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            Form {
                Section("软件更新") {
                    HStack {
                        Image(systemName: updateStatusSymbol)
                            .foregroundStyle(updateStatusColor)
                        Text(updateStatusText)
                        Spacer()
                        Button(updateService.status == .checking ? "正在检查…" : "检查更新") {
                            updateService.checkManually()
                        }
                        .disabled(updateService.status == .checking)
                    }

                    if let release = updateService.availableRelease {
                        Button("前往 GitHub 更新") {
                            NSWorkspace.shared.open(release.pageURL)
                        }
                    }

                    Toggle("更新提醒", isOn: Binding(
                        get: { automaticUpdateRemindersEnabled },
                        set: { enabled in
                            automaticUpdateRemindersEnabled = enabled
                            updateService.setAutomaticRemindersEnabled(enabled)
                        }
                    ))
                }

                Section("支持与反馈") {
                    Button {
                        showFeedbackOptions = true
                    } label: {
                        HStack {
                            Label("问题反馈…", systemImage: "exclamationmark.bubble")
                            Spacer()
                            Text("邮件或 GitHub")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func openFeedbackEmail() {
        let environment = FeedbackEnvironment.current(appVersion: AppVersion.currentString)
        guard let url = FeedbackSupport.emailURL(for: environment),
              NSWorkspace.shared.open(url) else {
            feedbackOpenErrorMessage = String(
                format: String(localized: "无法打开邮件应用，请手动发送至 %@。"),
                FeedbackSupport.recipient
            )
            return
        }
    }

    private func openGitHubFeedback() {
        guard NSWorkspace.shared.open(FeedbackSupport.githubIssueChooserURL) else {
            feedbackOpenErrorMessage = String(localized: "无法打开 GitHub，请稍后重试。")
            return
        }
    }

    private var updateStatusText: String {
        switch updateService.status {
        case .idle:
            String(localized: "尚未检查更新")
        case .checking:
            String(localized: "正在检查更新…")
        case .upToDate:
            String(localized: "已是最新版本")
        case .noStableRelease:
            String(localized: "当前没有稳定版本")
        case let .updateAvailable(version):
            String(localized: "发现新版本 \(version.description)")
        case let .manualFailure(message):
            String(localized: "检查更新失败：") + message
        }
    }

    private var updateStatusSymbol: String {
        switch updateService.status {
        case .updateAvailable: "arrow.up.circle.fill"
        case .manualFailure: "exclamationmark.triangle.fill"
        case .checking: "arrow.triangle.2.circlepath"
        default: "checkmark.circle.fill"
        }
    }

    private var updateStatusColor: Color {
        switch updateService.status {
        case .updateAvailable: .green
        case .manualFailure: .yellow
        case .checking, .idle: .secondary
        default: .green
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
                                showPermissionRequestAlert = true
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
                    Image(systemName: isGestureTrusted
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(isGestureTrusted ? .green : .yellow)
                    Text(isGestureTrusted
                         ? String(localized: "已授权")
                         : String(localized: "未授权"))
                    Spacer()
                    if !isGestureTrusted {
                        Button("打开辅助功能设置…") {
                            openAccessibilityPrefs(for: .manualAccessibilitySettings)
                        }
                    }
                }
            } header: {
                Text("权限")
            }
        }
        .formStyle(.grouped)
    }

    private var accessibilityRestartMessage: String {
        if restartAccessibilityAction == .mouseButtonRecording {
            return String(localized: "重新打开 Copied 后，请再次点击“录制侧键…”。")
        }
        return String(localized: "重新打开 Copied 后，辅助功能相关功能会自动恢复。")
    }

    private func requestAccessibilityAndRetry(for action: PendingAccessibilityAction) {
        _ = beginAccessibilityRequest(for: action, prompt: true)
    }

    @discardableResult
    private func beginAccessibilityRequest(
        for action: PendingAccessibilityAction,
        prompt: Bool
    ) -> Int? {
        guard pendingAccessibilityAction == nil else { return nil }

        accessibilityRequestGeneration &+= 1
        let generation = accessibilityRequestGeneration
        pendingAccessibilityAction = action
        let trusted: Bool
        if prompt {
            let options = [
                kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true,
            ] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(options)
        } else {
            trusted = AXIsProcessTrusted()
        }
        resolveAccessibilityRequest(
            action: action,
            generation: generation,
            trusted: trusted,
            finalizeIfDenied: false
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            resolveAccessibilityRequest(
                action: action,
                generation: generation,
                trusted: AXIsProcessTrusted(),
                finalizeIfDenied: false
            )
        }
        return pendingAccessibilityAction == action ? generation : nil
    }

    private func refreshGesturePermission(clearUnavailableIntent: Bool) {
        let trusted = AXIsProcessTrusted()
        isGestureTrusted = trusted
        guard clearUnavailableIntent, copyGestureEnabled, !trusted else { return }
        copyGestureEnabled = false
        CopyGestureManager.shared.stop()
    }

    private func resolveGesturePermissionAfterActivation() {
        let trusted = AXIsProcessTrusted()
        isGestureTrusted = trusted

        if let action = pendingAccessibilityAction {
            resolveAccessibilityRequest(
                action: action,
                generation: accessibilityRequestGeneration,
                trusted: trusted,
                finalizeIfDenied: true
            )
        } else if copyGestureEnabled, !trusted {
            copyGestureEnabled = false
            CopyGestureManager.shared.stop()
        }
    }

    private func resolveAccessibilityRequest(
        action: PendingAccessibilityAction,
        generation: Int,
        trusted: Bool,
        finalizeIfDenied: Bool
    ) {
        isGestureTrusted = trusted
        guard pendingAccessibilityAction == action,
              accessibilityRequestGeneration == generation else { return }

        if trusted {
            pendingAccessibilityAction = nil
            restartAccessibilityAction = action
            showAccessibilityRestartAlert = true
        } else if finalizeIfDenied {
            pendingAccessibilityAction = nil
            handleAccessibilityRequestDenied(for: action)
        }
    }

    private func handleAccessibilityRequestDenied(for action: PendingAccessibilityAction) {
        switch action {
        case .copyGesture:
            copyGestureEnabled = false
            CopyGestureManager.shared.stop()
        case .mouseButtonRecording:
            stopMouseButtonRecording(reason: "accessibilityDenied")
        case .boundMouseButton, .manualAccessibilitySettings:
            break
        }
    }

    private func openAccessibilityPrefs(for action: PendingAccessibilityAction) {
        guard let generation = beginAccessibilityRequest(for: action, prompt: false) else {
            return
        }
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ), NSWorkspace.shared.open(url) else {
            resolveAccessibilityRequest(
                action: action,
                generation: generation,
                trusted: false,
                finalizeIfDenied: true
            )
            return
        }
    }

    private func startMouseButtonRecording() {
        let trusted = AXIsProcessTrusted()
        stopMouseButtonRecording(reason: "restartRecording")
        guard mouseRecordingState.start(accessibilityTrusted: trusted) else {
            requestAccessibilityAndRetry(for: .mouseButtonRecording)
            return
        }

        mouseRecordingListenerToken = GlobalMouseEventCoordinator.shared.addListener(
            promptForAccessibility: false
        ) { type, event in
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            guard type == .otherMouseDown else { return false }
            switch mouseRecordingState.handleOtherMouseDown(button: button) {
            case .ignore:
                return false
            case let .bind(recordedButton):
                UserDefaults.standard.set(recordedButton, forKey: QuickTriggerSettings.mouseButtonKey)
                mouseQuickTriggerButton = recordedButton
                DispatchQueue.main.async {
                    stopMouseButtonRecording(reason: "bindingCompleted")
                }
                return true
            }
        }
        guard mouseRecordingListenerToken != nil else {
            mouseRecordingState.cancel()
            requestAccessibilityAndRetry(for: .mouseButtonRecording)
            return
        }
    }

    private func clearMouseQuickTriggerButton() {
        UserDefaults.standard.removeObject(forKey: QuickTriggerSettings.mouseButtonKey)
        mouseQuickTriggerButton = nil
        stopMouseButtonRecording(reason: "bindingCleared")
    }

    private func stopMouseButtonRecording(reason _: String) {
        GlobalMouseEventCoordinator.shared.removeListener(mouseRecordingListenerToken)
        mouseRecordingListenerToken = nil
        mouseRecordingState.cancel()
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
            let msg = error.localizedDescription
            NSLog("Copied: SMAppService error: \(msg)")
            loginItemError = String(localized: "无法设置开机自启：") + msg
            return false
        }
    }
}
