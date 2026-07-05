import SwiftUI

struct ToastView: View {
    let viewModel: ToastViewModel
    let onHoverChanged: (Bool) -> Void
    let onTap: () -> Void
    let onPerformAction: ((any ClipboardAction)?) -> Void
    let onNeedsLayout: (() -> Void)?

    @State private var animateIn = false
    @State private var isActionButtonHovered = false
    @State private var isActionButtonPressed = false
    @State private var hoverDebounceTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            // Transparent background captures taps outside the button
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onTap() }

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
                            .opacity(viewModel.resultOverlay == nil ? 1 : 0)

                        if let overlay = viewModel.resultOverlay {
                            let lines = overlay.displayText.components(separatedBy: "\n")
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(lines.indices, id: \.self) { i in
                                    Text(lines[i])
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                            }
                            .opacity(viewModel.resultOverlay != nil ? 1 : 0)
                        }
                    }
                    .animation(
                        .interpolatingSpring(mass: 1.2, stiffness: 120, damping: 14, initialVelocity: 3),
                        value: viewModel.resultOverlay != nil
                    )

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
                let isHighlighted = viewModel.isCommandPressed || isActionButtonHovered

                if let overlay = viewModel.resultOverlay {
                    // Result mode: "复制" button
                    Button {
                        onPerformAction(CopyTextAction(text: overlay.copyText))
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isActionButtonHovered ? "command" : "doc.on.doc")
                                .font(.system(size: 12, weight: .medium))
                                .frame(height: 14)
                            Text("复制")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.white.opacity(isHighlighted ? 0.2 : 0.12))
                        )
                        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isHighlighted)
                    }
                    .buttonStyle(PressTrackingButtonStyle(isPressed: $isActionButtonPressed))
                    .scaleEffect((viewModel.isCommandPressed || isActionButtonPressed) ? 0.92 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: viewModel.isCommandPressed)
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
                } else if let action = viewModel.primaryAction {
                    Button {
                        onPerformAction(action)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isActionButtonHovered ? "command" : action.systemImage)
                                .font(.system(size: 12, weight: .medium))
                                .frame(height: 14)
                            Text(action.title)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.white.opacity(isHighlighted ? 0.2 : 0.12))
                        )
                        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isHighlighted)
                    }
                    .buttonStyle(PressTrackingButtonStyle(isPressed: $isActionButtonPressed))
                    .scaleEffect((viewModel.isCommandPressed || isActionButtonPressed) ? 0.92 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: viewModel.isCommandPressed)
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
        .frame(maxWidth: 360)
        .glassEffect(in: .rect(cornerRadius: 32))
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(.white.opacity(0.25), lineWidth: 0.8)
        }
        // ── Entry spring ─────────────────────────────────────
        .scaleEffect(animateIn ? 1 : 0.2)
        .offset(y: animateIn ? 0 : -56)
        .blur(radius: animateIn ? 0 : 12)
        .opacity(animateIn ? 1 : 0)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .padding(.horizontal, 18)
        .onHover { hovering in
            onHoverChanged(hovering)
        }
        .contextMenu {
            // Search — always available for text
            if viewModel.rawContent?.type == .text {
                Button("搜索", systemImage: "magnifyingglass") {
                    onPerformAction(SearchTextAction(text: searchContextText))
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

            // ── Content-specific menu actions ──────────────────
            if !viewModel.menuActions.isEmpty {
                Divider()
                ForEach(viewModel.menuActions, id: \.id) { action in
                    Button(action.menuTitle, systemImage: action.systemImage) {
                        onPerformAction(action)
                    }
                }
            }

            // ── Blacklist source app ──────────────────────────
            if let action = viewModel.blacklistAction {
                Divider()
                Button(action.menuTitle, systemImage: action.systemImage) {
                    onPerformAction(action)
                }
            }
        }
        .onAppear {
            withAnimation(.interpolatingSpring(
                mass: 1.2,
                stiffness: 120,
                damping: 14,
                initialVelocity: 3
            )) {
                animateIn = true
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

    /// Text to use for search context menu item.
    private var searchContextText: String {
        if let raw = viewModel.rawContent?.rawText {
            return String(raw.prefix(100))
        }
        return viewModel.previewText
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
