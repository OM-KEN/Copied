import SwiftUI

/// Actions the toast can trigger beyond the existing callbacks.
enum ToastAction: Equatable { case expand, collapse, editInTextEdit }

struct ToastView: View {
    let viewModel: ToastViewModel
    let onHoverChanged: (Bool) -> Void
    let onPreviewHoverChanged: (Bool) -> Void
    let onPrimaryActionHoverChanged: (Bool) -> Void
    let onExpandedActionHoverChanged: (ToastAction, Bool) -> Void
    let onTap: () -> Void
    let onPerformAction: ((any ClipboardAction)?) -> Void
    let onNeedsLayout: (() -> Void)?
    let onAction: (ToastAction) -> Void
    let onOpenUpdateAbout: () -> Void

    @State private var animateIn = false
    @State private var isActionButtonHovered = false
    @State private var isActionButtonPressed = false
    @State private var hoverDebounceTask: Task<Void, Never>?
    @State private var isPreviewHovered = false
    @State private var isResultHovered = false
    @State private var fallbackMaterialReady = false

    private static let cardCornerRadius: CGFloat = 32

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 降级材质背景（pre-macOS 26，延迟显示避免首帧灰色闪烁）
            if fallbackMaterialReady {
                RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            }

            // Transparent background captures taps outside the button
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onTap() }

            if viewModel.isExpanded {
                ExpandedTextView(
                    rawText: viewModel.expandedText,
                    onEditInTextEdit: { onAction(.editInTextEdit) },
                    onCollapse: { onAction(.collapse) },
                    onActionHoverChanged: onExpandedActionHoverChanged
                )
            } else {
                HStack(spacing: 12) {
                // ── Left: Icon or Color Swatch ──────────────────
                if let color = viewModel.detectedColor {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: color))
                        .frame(width: 32, height: 32)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(.white.opacity(0.2), lineWidth: 0.5)
                        }
                        .shadow(color: Color(nsColor: color).opacity(0.3), radius: 4, y: 1)
                } else if let thumbnail = viewModel.thumbnailImage {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else if let asyncThumb = viewModel.asyncThumbnail {
                    Image(nsImage: asyncThumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .transition(.opacity)
                } else if viewModel.iconSymbolName == "textformat" {
                    Image(systemName: viewModel.iconSymbolName)
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.secondary)
                        .environment(\.locale, Locale(identifier: "en"))
                } else {
                    Image(systemName: viewModel.iconSymbolName)
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    // ── Preview or Result (crossfade) ──────────
                    ZStack(alignment: .leading) {
                        Text(viewModel.previewText)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .opacity(viewModel.resultOverlay == nil ? 1.0 : 0)
                            .background {
                                if isPreviewHovered && viewModel.resultOverlay == nil {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.primary.opacity(0.1))
                                }
                            }
                            .onHover { hovering in
                                isPreviewHovered = hovering
                                onPreviewHoverChanged(hovering)
                            }
                            .animation(.easeInOut(duration: 0.15), value: isPreviewHovered)

                        if let overlay = viewModel.resultOverlay {
                            let lines = overlay.displayText.components(separatedBy: "\n")
                            ScrollView(.vertical) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(lines.indices, id: \.self) { i in
                                        Text(lines[i])
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .frame(maxHeight: 200)
                            .opacity(viewModel.resultOverlay != nil ? 1.0 : 0)
                            .background {
                                if isResultHovered && viewModel.resultOverlay != nil {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.primary.opacity(0.1))
                                }
                            }
                            .onHover { hovering in
                                isResultHovered = hovering
                                onPreviewHoverChanged(hovering)
                            }
                            .animation(.easeInOut(duration: 0.15), value: isResultHovered)
                            .onTapGesture { onAction(.expand) }
                        }
                    }
                    .animation(
                        .interpolatingSpring(mass: 1.2, stiffness: 120, damping: 14, initialVelocity: 3),
                        value: viewModel.resultOverlay != nil
                    )
                    .onTapGesture { onAction(.expand) }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(String(localized: "复制自"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            if let icon = viewModel.sourceAppIcon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 16, height: 16)
                            }
                            Text(viewModel.sourceAppName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        if !viewModel.detailInfo.isEmpty {
                            Text(viewModel.detailInfo)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // ── Right: Action Button ──────────────────────────
                if let overlay = viewModel.resultOverlay {
                    // Result mode: "复制" button
                    Button {
                        onPerformAction(CopyTextAction(text: overlay.copyText))
                    } label: {
                        HStack(spacing: 4) {
                            ZStack {
                                Image(systemName: "doc.on.doc")
                                    .opacity(isActionButtonHovered ? 0 : 1)
                                Image(systemName: viewModel.triggerModifierIcon)
                                    .opacity(isActionButtonHovered ? 1 : 0)
                            }
                            .font(.system(size: 12, weight: .medium))
                            .frame(height: 14)
                            Text("复制")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(actionButtonBackground)
                    }
                    .buttonStyle(PressTrackingButtonStyle(isPressed: $isActionButtonPressed))
                    .overlay(quickTriggerWaitingHighlight)
                    .scaleEffect((viewModel.quickTriggerVisualState == .pressed || isActionButtonPressed) ? 0.92 : 1.0)
                    .opacity(viewModel.quickTriggerVisualState == .waitingForSecondTap ? 0.82 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: viewModel.quickTriggerVisualState)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isActionButtonPressed)
                    .onHover { hovering in
                        onPrimaryActionHoverChanged(hovering)
                        if hovering {
                            hoverDebounceTask?.cancel()
                            isActionButtonHovered = true
                        } else {
                            hoverDebounceTask?.cancel()
                            hoverDebounceTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                if !Task.isCancelled {
                                    isActionButtonHovered = false
                                }
                            }
                        }
                    }
                } else if let action = viewModel.primaryAction {
                    Button {
                        onPerformAction(action)
                    } label: {
                        HStack(spacing: 4) {
                            ZStack {
                                Image(systemName: action.systemImage)
                                    .opacity(isActionButtonHovered ? 0 : 1)
                                Image(systemName: viewModel.triggerModifierIcon)
                                    .opacity(isActionButtonHovered ? 1 : 0)
                            }
                            .font(.system(size: 12, weight: .medium))
                            .frame(height: 14)
                            Text(action.title)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(actionButtonBackground)
                    }
                    .buttonStyle(PressTrackingButtonStyle(isPressed: $isActionButtonPressed))
                    .overlay(quickTriggerWaitingHighlight)
                    .scaleEffect((viewModel.quickTriggerVisualState == .pressed || isActionButtonPressed) ? 0.92 : 1.0)
                    .opacity(viewModel.quickTriggerVisualState == .waitingForSecondTap ? 0.82 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: viewModel.quickTriggerVisualState)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isActionButtonPressed)
                    .onHover { hovering in
                        onPrimaryActionHoverChanged(hovering)
                        if hovering {
                            hoverDebounceTask?.cancel()
                            isActionButtonHovered = true
                        } else {
                            hoverDebounceTask?.cancel()
                            hoverDebounceTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                if !Task.isCancelled {
                                    isActionButtonHovered = false
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
            }

            if viewModel.showsUpdateReminder, !viewModel.isExpanded {
                Button(action: onOpenUpdateAbout) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.green)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("有新版本")
                .padding(.top, 6)
                .padding(.trailing, 6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius))
        .glassEffectIfAvailable(cornerRadius: Self.cardCornerRadius)
        .frame(maxWidth: 360)
        .overlay {
            RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                .stroke(.primary.opacity(0.15), lineWidth: 0.8)
        }
        .entranceAnimation(animateIn: $animateIn, fallbackMaterialReady: $fallbackMaterialReady)
        .onHover { hovering in
            onHoverChanged(hovering)
        }
        .contextMenu { ToastContextMenuContent(viewModel: viewModel, onPerformAction: onPerformAction, searchText: searchContextText) }
        .onChange(of: viewModel.asyncThumbnail) {
            onNeedsLayout?()
        }
        .onChange(of: viewModel.resultOverlay) {
            onNeedsLayout?()
        }
    }

    // ── Helpers ────────────────────────────────────────────

    /// 按钮背景：macOS 26+ 液态玻璃，旧系统 .quaternary fill。
    @ViewBuilder
    private var actionButtonBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if #available(macOS 26, *) {
            shape.fill(.clear)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
        } else {
            shape.fill(.quaternary)
        }
    }

    @ViewBuilder
    private var quickTriggerWaitingHighlight: some View {
        if viewModel.quickTriggerVisualState == .waitingForSecondTap {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.tint.opacity(0.7), lineWidth: 1.5)
        }
    }

    /// Text to use for search context menu item.
    private var searchContextText: String {
        if let raw = viewModel.rawContent?.rawText {
            return String(raw.prefix(100))
        }
        return viewModel.previewText
    }
}

// MARK: - Menu Action Button

private struct MenuActionButton: View {
    let action: any ClipboardAction
    let onPerformAction: ((any ClipboardAction)?) -> Void

    var body: some View {
        Button(action.menuTitle, systemImage: action.systemImage) {
            onPerformAction(action)
        }
    }
}

// MARK: - Context Menu Content

private struct ToastContextMenuContent: View {
    let viewModel: ToastViewModel
    let onPerformAction: ((any ClipboardAction)?) -> Void
    let searchText: String

    var body: some View {
        // Search — always available for text
        if viewModel.rawContent?.type == .text {
            Button("搜索", systemImage: "magnifyingglass") {
                onPerformAction(SearchTextAction(text: searchText))
            }
        } else {
            Button("搜索", systemImage: "magnifyingglass") { }
                .disabled(true)
        }
        Divider()

        // Save — always available for text
        if let rawText = viewModel.rawContent?.rawText, !rawText.isEmpty {
            Button("另存为…", systemImage: "arrow.down.doc") {
                onPerformAction(SaveFileAction(text: rawText, defaultName: "clipboard.txt"))
            }
        } else {
            Button("另存为…", systemImage: "arrow.down.doc") { }
                .disabled(true)
        }

        // Content-specific menu actions
        if !viewModel.menuActions.isEmpty {
            Divider()
            ForEach(viewModel.menuActions, id: \.id) { action in
                MenuActionButton(action: action, onPerformAction: onPerformAction)
            }
        }

        // Blacklist source app
        if let action = viewModel.blacklistAction {
            Divider()
            Button(action.menuTitle, systemImage: action.systemImage) {
                onPerformAction(action)
            }
        }
    }
}

// MARK: - Expanded Text View

/// Expanded text area. Uses a unified layout: VStack with a height-capped ScrollView
/// on top and the button bar below. Short text fills its natural height (no scroll);
/// long text is capped and scrolls within the ScrollView.
private struct ExpandedTextView: View {
    let rawText: String
    let onEditInTextEdit: () -> Void
    let onCollapse: () -> Void
    let onActionHoverChanged: (ToastAction, Bool) -> Void

    private let maxTotalHeight: CGFloat = 300

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.vertical) {
                Text(rawText)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 52)
            }
            .frame(maxHeight: maxTotalHeight)

            HStack {
                Button("在文本编辑中打开") { onEditInTextEdit() }
                    .onHover { onActionHoverChanged(.editInTextEdit, $0) }
                Spacer()
                Button("收起") { onCollapse() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .onHover { onActionHoverChanged(.collapse, $0) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
        .frame(width: 360)
    }
}

// MARK: - Press-Tracking Button Style

private struct PressTrackingButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, newValue in
                isPressed = newValue
            }
    }
}

// MARK: - View Modifiers

extension View {
    /// Toast 入场弹性动画 + 旧系统材质延迟激活。
    @ViewBuilder
    fileprivate func entranceAnimation(
        animateIn: Binding<Bool>,
        fallbackMaterialReady: Binding<Bool>
    ) -> some View {
        self
            .scaleEffect(animateIn.wrappedValue ? 1 : 0.2)
            .offset(y: animateIn.wrappedValue ? 0 : -56)
            .blur(radius: animateIn.wrappedValue ? 0 : 12)
            .opacity(animateIn.wrappedValue ? 1 : 0)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .padding(.horizontal, 18)
            .onAppear {
                withAnimation(.interpolatingSpring(
                    mass: 1.2, stiffness: 120, damping: 14, initialVelocity: 3
                )) {
                    animateIn.wrappedValue = true
                }
                if #available(macOS 26, *) { return }  // glassEffect 已处理，无需材质降级
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        fallbackMaterialReady.wrappedValue = true
                    }
                }
            }
    }
}

extension View {
    /// macOS 26+ 液态玻璃；旧系统无操作（降级材质在 ZStack 内部）。
    @ViewBuilder
    fileprivate func glassEffectIfAvailable(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            self
        }
    }
}
