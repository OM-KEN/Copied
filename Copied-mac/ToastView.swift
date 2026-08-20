import SwiftUI

private struct MetadataWidthReader: View {
    let onWidthChanged: (CGFloat) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    onWidthChanged(proxy.size.width)
                }
                .onChange(of: proxy.size.width) { _, newWidth in
                    onWidthChanged(newWidth)
                }
        }
    }
}

private struct AutoScrollingMetadataViewportLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let naturalSize = subview.sizeThatFits(.unspecified)
        let width = proposal.width.map { min(naturalSize.width, max(0, $0)) }
            ?? naturalSize.width
        return CGSize(width: width, height: naturalSize.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: .unspecified
        )
    }
}

private struct MetadataOverflowMask: View, Animatable {
    var progress: CGFloat
    let edgeFadeFraction: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let clampedProgress = min(max(progress, 0), 1)
        LinearGradient(
            stops: [
                .init(
                    color: .white.opacity(Double(1 - clampedProgress)),
                    location: 0
                ),
                .init(color: .white, location: edgeFadeFraction),
                .init(color: .white, location: 1 - edgeFadeFraction),
                .init(
                    color: .white.opacity(Double(clampedProgress)),
                    location: 1
                ),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

private struct AutoScrollingMetadataRow<Content: View>: View {
    let isCardHovered: Bool
    let resetToken: AnyHashable
    private let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var fadeProgress: CGFloat = 0
    @State private var animationTask: Task<Void, Never>?
    @State private var animationGeneration = 0
    @State private var completedCurrentHover = false

    init(
        isCardHovered: Bool,
        resetToken: AnyHashable,
        @ViewBuilder content: () -> Content
    ) {
        self.isCardHovered = isCardHovered
        self.resetToken = resetToken
        self.content = content()
    }

    var body: some View {
        AutoScrollingMetadataViewportLayout {
            content
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
                .background {
                    MetadataWidthReader { newWidth in
                        updateMeasurements(
                            contentWidth: newWidth,
                            viewportWidth: viewportWidth
                        )
                    }
                }
                .offset(x: -scrollOffset)
        }
        .background {
            MetadataWidthReader { newWidth in
                updateMeasurements(
                    contentWidth: contentWidth,
                    viewportWidth: newWidth
                )
            }
        }
        .clipped()
        .mask {
            let overflow = MetadataAutoScrollMetrics.overflow(
                contentWidth: contentWidth,
                viewportWidth: viewportWidth
            )
            if overflow > 0, viewportWidth > 0 {
                MetadataOverflowMask(
                    progress: fadeProgress,
                    edgeFadeFraction: MetadataAutoScrollMetrics.edgeFadeFraction(
                        viewportWidth: viewportWidth
                    )
                )
            } else {
                Rectangle().fill(.white)
            }
        }
        .onChange(of: isCardHovered) { _, hovering in
            if hovering {
                completedCurrentHover = false
                scheduleAnimationIfNeeded()
            } else {
                cancelAndReset(animated: !reduceMotion)
            }
        }
        .onChange(of: resetToken) {
            restartForChangedLayout()
        }
        .onChange(of: reduceMotion) {
            restartForChangedLayout()
        }
        .onAppear {
            if isCardHovered {
                completedCurrentHover = false
                scheduleAnimationIfNeeded()
            }
        }
        .onDisappear {
            cancelAnimationTask()
            scrollOffset = 0
            fadeProgress = 0
        }
    }

    private func updateMeasurements(contentWidth: CGFloat, viewportWidth: CGFloat) {
        guard abs(self.contentWidth - contentWidth) > 0.001
                || abs(self.viewportWidth - viewportWidth) > 0.001 else { return }
        self.contentWidth = contentWidth
        self.viewportWidth = viewportWidth
        restartForChangedLayout()
    }

    private func restartForChangedLayout() {
        cancelAnimationTask()
        completedCurrentHover = false
        withAnimation(nil) {
            scrollOffset = 0
            fadeProgress = 0
        }
        if isCardHovered {
            scheduleAnimationIfNeeded()
        }
    }

    private func scheduleAnimationIfNeeded() {
        let overflow = MetadataAutoScrollMetrics.overflow(
            contentWidth: contentWidth,
            viewportWidth: viewportWidth
        )
        guard isCardHovered, !completedCurrentHover, overflow > 0 else { return }

        cancelAnimationTask()
        let generation = animationGeneration
        animationTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 600_000_000)
            } catch {
                return
            }
            guard isCurrentAnimation(generation) else { return }

            let currentOverflow = MetadataAutoScrollMetrics.overflow(
                contentWidth: contentWidth,
                viewportWidth: viewportWidth
            )
            guard currentOverflow > 0 else { return }
            if reduceMotion {
                scrollOffset = currentOverflow
                fadeProgress = 1
                completedCurrentHover = true
                animationTask = nil
                return
            }

            let duration = MetadataAutoScrollMetrics.travelDuration(for: currentOverflow)
            withAnimation(.linear(duration: duration)) {
                scrollOffset = currentOverflow
                fadeProgress = 1
            }
            do {
                try await Task.sleep(nanoseconds: nanoseconds(for: duration))
                try await Task.sleep(nanoseconds: 800_000_000)
            } catch {
                return
            }
            guard isCurrentAnimation(generation) else { return }

            withAnimation(.linear(duration: duration)) {
                scrollOffset = 0
                fadeProgress = 0
            }
            do {
                try await Task.sleep(nanoseconds: nanoseconds(for: duration))
            } catch {
                return
            }
            guard isCurrentAnimation(generation) else { return }
            completedCurrentHover = true
            animationTask = nil
        }
    }

    private func cancelAndReset(animated: Bool) {
        cancelAnimationTask()
        completedCurrentHover = false
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                scrollOffset = 0
                fadeProgress = 0
            }
        } else {
            scrollOffset = 0
            fadeProgress = 0
        }
    }

    private func cancelAnimationTask() {
        animationGeneration &+= 1
        animationTask?.cancel()
        animationTask = nil
    }

    private func isCurrentAnimation(_ generation: Int) -> Bool {
        !Task.isCancelled
            && generation == animationGeneration
            && isCardHovered
    }

    private func nanoseconds(for duration: TimeInterval) -> UInt64 {
        UInt64(duration * 1_000_000_000)
    }
}

struct ToastView: View {
    let viewModel: ToastViewModel
    let onHoverChanged: (Bool) -> Void
    let onCommand: (ToastCommand<any ClipboardAction>) -> Void
    let onExpandedTextFrameChanged: (CGRect?) -> Void
    let onNeedsLayout: (() -> Void)?

    @State private var animateIn = false
    @State private var isActionButtonHovered = false
    @State private var isActionButtonPressed = false
    @State private var hoverDebounceTask: Task<Void, Never>?
    @State private var isPreviewHovered = false
    @State private var isResultHovered = false
    @State private var fallbackMaterialReady = false
    @State private var isCardHovered = false

    static let cardCornerRadius: CGFloat = 32

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 降级材质背景（pre-macOS 26，延迟显示避免首帧灰色闪烁）
            if fallbackMaterialReady {
                RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            }

            // Explicit background control owns dismissal without coordinate hit-testing.
            Button {
                onCommand(.dismiss)
            } label: {
                Color.clear
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if viewModel.isExpanded {
                ExpandedTextView(
                    rawText: viewModel.expandedText,
                    onTextFrameChanged: onExpandedTextFrameChanged
                )
            } else {
                HStack(spacing: 12) {
                // ── Left: Icon or Color Swatch ──────────────────
                Group {
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
                }
                .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 8) {
                    // ── Preview or Result (crossfade) ──────────
                    Button {
                        guard !viewModel.isStartupNotice else { return }
                        onCommand(.expand)
                    } label: {
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
                            }
                        }
                        .animation(
                            .interpolatingSpring(mass: 1.2, stiffness: 120, damping: 14, initialVelocity: 3),
                            value: viewModel.resultOverlay != nil
                        )
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(!viewModel.isStartupNotice)
                    .onHover { hovering in
                        isPreviewHovered = hovering
                        isResultHovered = hovering
                    }
                    .animation(.easeInOut(duration: 0.15), value: isPreviewHovered)
                    .animation(.easeInOut(duration: 0.15), value: isResultHovered)

                    if !viewModel.isStartupNotice {
                        VStack(alignment: .leading, spacing: 4) {
                            AutoScrollingMetadataRow(
                                isCardHovered: isCardHovered,
                                resetToken: AnyHashable(viewModel.sourceAppName)
                            ) {
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
                            }

                            if !viewModel.detailInfo.isEmpty {
                                AutoScrollingMetadataRow(
                                    isCardHovered: isCardHovered,
                                    resetToken: AnyHashable(viewModel.detailInfo)
                                ) {
                                    Text(viewModel.detailInfo)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }

                // ── Right: Action Button ──────────────────────────
                if let resultOverlay = viewModel.resultOverlay {
                    if resultOverlay.copyText != nil {
                        // Successful inline result: expose the copy action.
                        Button {
                            onCommand(.performPrimary)
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
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressTrackingButtonStyle(isPressed: $isActionButtonPressed))
                        .overlay(quickTriggerWaitingHighlight)
                        .scaleEffect((viewModel.quickTriggerVisualState == .pressed || isActionButtonPressed) ? 0.92 : 1.0)
                        .opacity(viewModel.quickTriggerVisualState == .waitingForSecondTap ? 0.82 : 1.0)
                        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: viewModel.quickTriggerVisualState)
                        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isActionButtonPressed)
                        .onHover { hovering in
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
                } else if let action = viewModel.primaryAction {
                    Button {
                        onCommand(.performPrimary)
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
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressTrackingButtonStyle(isPressed: $isActionButtonPressed))
                    .overlay(quickTriggerWaitingHighlight)
                    .scaleEffect((viewModel.quickTriggerVisualState == .pressed || isActionButtonPressed) ? 0.92 : 1.0)
                    .opacity(viewModel.quickTriggerVisualState == .waitingForSecondTap ? 0.82 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: viewModel.quickTriggerVisualState)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isActionButtonPressed)
                    .onHover { hovering in
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
                Button {
                    onCommand(.openUpdateAbout)
                } label: {
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
        .entranceAnimation(
            animateIn: $animateIn,
            fallbackMaterialReady: $fallbackMaterialReady,
            onDismiss: { onCommand(.dismiss) }
        )
        .onHover { hovering in
            isCardHovered = hovering
            onHoverChanged(hovering)
        }
        .coordinateSpace(name: "ToastRoot")
        .contextMenu {
            if !viewModel.isStartupNotice {
                ToastContextMenuContent(
                    viewModel: viewModel,
                    onCommand: onCommand,
                    searchText: searchContextText
                )
            }
        }
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
    let onCommand: (ToastCommand<any ClipboardAction>) -> Void

    var body: some View {
        Button(action.menuTitle, systemImage: action.systemImage) {
            onCommand(.performAction(action))
        }
    }
}

// MARK: - Context Menu Content

private struct ToastContextMenuContent: View {
    let viewModel: ToastViewModel
    let onCommand: (ToastCommand<any ClipboardAction>) -> Void
    let searchText: String

    var body: some View {
        // Search — always available for text
        if viewModel.rawContent?.type == .text {
            Button("搜索", systemImage: "magnifyingglass") {
                onCommand(.performAction(SearchTextAction(text: searchText)))
            }
        } else {
            Button("搜索", systemImage: "magnifyingglass") { }
                .disabled(true)
        }
        Divider()

        // Save — always available for text
        if let rawText = viewModel.rawContent?.rawText, !rawText.isEmpty {
            Button("另存为…", systemImage: "arrow.down.doc") {
                onCommand(.performAction(SaveFileAction(text: rawText, defaultName: "clipboard.txt")))
            }
        } else {
            Button("另存为…", systemImage: "arrow.down.doc") { }
                .disabled(true)
        }

        // Content-specific menu actions
        if !viewModel.menuActions.isEmpty {
            Divider()
            ForEach(viewModel.menuActions, id: \.id) { action in
                MenuActionButton(action: action, onCommand: onCommand)
            }
        }

        // Blacklist source app
        if let action = viewModel.blacklistAction {
            Divider()
            Button(action.menuTitle, systemImage: action.systemImage) {
                onCommand(.performAction(action))
            }
        }
    }
}

// MARK: - Expanded Text View

/// Expanded controls remain SwiftUI-owned. The transparent body reserves the
/// exact layout used by the sibling AppKit text surface in ToastWindowController.
private struct ExpandedTextView: View {
    let rawText: String
    let onTextFrameChanged: (CGRect?) -> Void

    var body: some View {
        Color.clear
            .frame(
                width: ExpandedTextLayoutMetrics.cardWidth,
                height: ExpandedTextLayoutMetrics.totalHeight(for: rawText)
            )
            .overlay {
                GeometryReader { proxy in
                    let cardFrame = proxy.frame(in: .named("ToastRoot"))
                    let frame = CGRect(
                        x: cardFrame.midX - ExpandedTextLayoutMetrics.textWidth / 2,
                        y: cardFrame.minY,
                        width: ExpandedTextLayoutMetrics.textWidth,
                        height: ExpandedTextLayoutMetrics.viewportHeight(for: rawText)
                    )
                    Color.clear
                        .onAppear { onTextFrameChanged(frame) }
                        .onChange(of: frame) { _, newFrame in
                            onTextFrameChanged(newFrame)
                        }
                        .onDisappear { onTextFrameChanged(nil) }
                }
            }
    }
}

struct ExpandedBottomBarControlsView: View {
    let onHoverChanged: (Bool) -> Void
    let onCommand: (ToastCommand<any ClipboardAction>) -> Void

    var body: some View {
        controls
            .buttonStyle(.bordered)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button("在文本编辑中打开") { onCommand(.editInTextEdit) }
                .buttonBorderShape(.roundedRectangle(radius: 8))
            Spacer(minLength: 8)
            Button("收起") { onCommand(.collapse) }
                .buttonBorderShape(.roundedRectangle(radius: 8))
            Button("关闭") { onCommand(.dismiss) }
                .buttonBorderShape(.roundedRectangle(radius: 8))
        }
        .padding(.horizontal, 16)
        .frame(
            width: ExpandedTextLayoutMetrics.cardWidth,
            height: ExpandedTextLayoutMetrics.bottomBarVisualHeight
        )
        .onHover(perform: onHoverChanged)
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
        fallbackMaterialReady: Binding<Bool>,
        onDismiss: @escaping () -> Void
    ) -> some View {
        self
            .scaleEffect(animateIn.wrappedValue ? 1 : 0.2)
            .offset(y: animateIn.wrappedValue ? 0 : -56)
            .blur(radius: animateIn.wrappedValue ? 0 : 12)
            .opacity(animateIn.wrappedValue ? 1 : 0)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .padding(.horizontal, 18)
            .background {
                Button(action: onDismiss) {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
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
