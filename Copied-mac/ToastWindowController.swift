import SwiftUI
import AppKit

final class ToastWindowController {
    private var window: NSWindow?
    private var contentView: NSView?
    private var hostingView: NSHostingView<AnyView>?
    private var dismissTimer: Timer?
    private let viewModel = ToastViewModel()

    private var isDismissing = false
    private var dismissGeneration = 0
    private var localMouseMonitor: Any?
    private var localCmdMonitor: Any?
    private var localOtherEventMonitor: Any?  // 监听 ⌘ 按下期间的其他按键/鼠标事件
    private var cmdKeyDownCount: UInt32 = 0
    private var cmdIsPreExisting = false  // ⌘ was already held when toast appeared
    private var cmdCancelledByOtherEvent = false  // ⌘ 按下期间有其他按键/鼠标事件
    private let displayDuration: TimeInterval = 3.0

    private var currentContent: ClipboardContent?

    func show(content: ClipboardContent, source: SourceAppInfo) {
        NSLog("Copied: show() entry — preview=\(content.preview.prefix(40)), isDismissing=\(isDismissing), windowExists=\(window != nil)")
        viewModel.configure(with: content, source: source)
        currentContent = content

        isDismissing = false
        dismissGeneration += 1
        contentView?.layer?.filters = nil
        // Always recreate window for fresh Space association.
        // Fullscreen Spaces can lose track of reused windows after
        // extended use, causing the toast to silently not appear.
        window?.orderOut(nil)
        window = nil
        contentView = nil
        createWindow()

        let toastCard = ToastView(
            viewModel: viewModel,
            onHoverChanged: { [weak self] hovering in self?.handleHoverChanged(hovering) },
            onTap: { [weak self] in self?.handleTap() },
            onPerformAction: { [weak self] action in self?.handlePerformAction(action) },
            onNeedsLayout: { [weak self] in DispatchQueue.main.async { self?.updateWindowSize() } }
        )

        let newHosting = NSHostingView(rootView: AnyView(toastCard))
        newHosting.wantsLayer = true
        newHosting.layer?.backgroundColor = NSColor.clear.cgColor
        newHosting.translatesAutoresizingMaskIntoConstraints = false

        hostingView?.removeFromSuperview()
        hostingView = newHosting
        contentView?.addSubview(newHosting)
        newHosting.layoutSubtreeIfNeeded()

        guard let screen = NSScreen.main else {
            NSLog("Copied: NSScreen.main is nil — cannot position window!")
            return
        }
        let panelSize = newHosting.fittingSize
        let x = screen.visibleFrame.midX - panelSize.width / 2
        let y = screen.frame.maxY - panelSize.height + 20
        NSLog("Copied: positioning — screen.frame=\(screen.frame), visibleFrame=\(screen.visibleFrame), panelSize=\(panelSize), target=(\(x), \(y))")
        window?.setFrame(NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height), display: true, animate: false)
        window?.alphaValue = 1.0
        window?.orderFront(nil)
        NSLog("Copied: after orderFront — isVisible=\(window?.isVisible ?? false), alpha=\(window?.alphaValue ?? -1), frame=\(window?.frame ?? .zero), hostingInSuperview=\(newHosting.superview != nil)")

        if isMouseInsideWindow() {} else { startDismissTimer() }

        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let window = self.window, window.isVisible, !self.isDismissing else { return event }
                if window.frame.contains(NSEvent.mouseLocation) { self.handleTap() }
                return event
            }
        }

        if localCmdMonitor == nil, viewModel.primaryAction != nil || viewModel.resultOverlay != nil {
            localCmdMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self,
                      let window = self.window,
                      window.isVisible,
                      !self.isDismissing else { return }
                let isCmd = event.modifierFlags.contains(.command)
                let wasCmdPressed = self.viewModel.isCommandPressed
                if isCmd {
                    self.cmdIsPreExisting = false
                    // 仅在 ⌘ 从未按下到按下的「转换」时重置取消标志，而非每次
                    // flagsChanged 都重置。避免其他修饰键变化（Shift 等）在
                    // ⌘ 按住期间错误地清除已设置的取消标志。
                    if !wasCmdPressed {
                        self.cmdCancelledByOtherEvent = false
                    }
                    self.cmdKeyDownCount = CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown)
                    self.viewModel.isCommandPressed = true
                } else {
                    self.viewModel.isCommandPressed = false
                    if self.cmdIsPreExisting {
                        self.cmdIsPreExisting = false
                        return
                    }
                    // 双保险：本地事件取消标志 + HID 计数器（延迟到下一个 runloop
                    // 让 HID 计数器有足够时间反映 ⌘+key 组合键的 keyDown 事件）。
                    let capturedCmdKeyDownCount = self.cmdKeyDownCount
                    let capturedCancelled = self.cmdCancelledByOtherEvent
                    let capturedDismissGen = self.dismissGeneration
                    self.cmdCancelledByOtherEvent = false
                    DispatchQueue.main.async { [weak self] in
                        guard let self,
                              !self.isDismissing,
                              self.dismissGeneration == capturedDismissGen,
                              !capturedCancelled else { return }
                        let newCount = CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown)
                        guard newCount == capturedCmdKeyDownCount else { return }
                        // In result mode, ⌘ triggers copy; otherwise primary action.
                        let action: (any ClipboardAction)? = self.viewModel.resultOverlay.map {
                            CopyTextAction(text: $0.copyText)
                        } ?? self.viewModel.primaryAction
                        if let action {
                            self.handlePerformAction(action)
                        }
                    }
                }
            }
        }

        // ⌘ 按下期间有其他按键或鼠标事件 → 取消触发。
        // 本地监听器能看到 ⌘+key 组合（全局监听器会被 macOS 过滤），
        // 作为 HID 计数器之外的「双保险」安全网。
        if localOtherEventMonitor == nil {
            localOtherEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                guard let self else { return event }
                if self.viewModel.isCommandPressed {
                    self.cmdCancelledByOtherEvent = true
                }
                return event
            }
        }

        if NSEvent.modifierFlags.contains(.command) {
            cmdIsPreExisting = true
        }
    }

    // MARK: - Action execution

    /// 替换已有 overlay 的文本，不调整窗口大小。
    /// 用于异步操作的结果替换。窗口大小由首次 showResultOverlay 确定。
    func updateResultText(displayText: String, copyText: String) {
        cancelDismiss()
        viewModel.resultOverlay = ResultOverlay(displayText: displayText, copyText: copyText)
        if !isMouseInsideWindow() { startDismissTimer() }
    }

    func showResultOverlay(displayText: String, copyText: String, keepAlive: Bool = false) {
        cancelDismiss()
        viewModel.resultOverlay = ResultOverlay(displayText: displayText, copyText: copyText)

        if !isDismissing, let hosting = hostingView, let screen = NSScreen.main {
            hosting.layoutSubtreeIfNeeded()
            let panelSize = hosting.fittingSize
            let x = screen.visibleFrame.midX - panelSize.width / 2
            let y = screen.frame.maxY - panelSize.height + 20

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                window?.animator().setFrame(
                    NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height),
                    display: true
                )
            }
        }

        if keepAlive {
            pauseDismissTimer()
        } else if !isMouseInsideWindow() {
            startDismissTimer()
        }
    }

    // MARK: - Interaction handlers

    private func handlePerformAction(_ action: (any ClipboardAction)?) {
        guard let action, let content = currentContent else { return }
        if action.performsInlineUpdate {
            // Inline-update actions (Calculate, Pinyin, Plugin transform):
            // perform updates popup content in-place, do not dismiss.
            action.perform(content: content, controller: self)
        } else {
            // Regular actions: perform then dismiss.
            action.perform(content: content, controller: self)
            if !isDismissing {
                isDismissing = true
                viewModel.cancelAsyncThumbnail()
                dismissToast(animated: true)
            }
        }
    }

    private func handleHoverChanged(_ hovering: Bool) {
        guard !isDismissing else { return }
        if hovering { pauseDismissTimer() } else { startDismissTimer() }
    }

    private func handleTap() {
        guard !isDismissing else { return }
        isDismissing = true
        viewModel.cancelAsyncThumbnail()
        // Defer dismiss to next run loop — gives button handler a chance
        // to call cancelDismiss() for inline-update actions (Calculate / Pinyin).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isDismissing else { return }
            self.dismissToast(animated: true)
        }
    }

    // MARK: - Dismiss

    private func cancelDismiss() {
        isDismissing = false
        dismissGeneration += 1
        contentView?.layer?.filters = nil
        contentView?.layer?.removeAnimation(forKey: "dismissBlurAnim")
        window?.alphaValue = 1.0
        window?.orderFront(nil)
    }

    /// 异步 inline action 的统一入口。处理 dismiss 竞态 + 非动画窗口 resize。
    /// 公式（同步）和翻译（异步）都走这个方法展示结果。
    func showInlineResult(displayText: String, copyText: String) {
        cancelDismiss()
        viewModel.resultOverlay = ResultOverlay(displayText: displayText, copyText: copyText)
        updateWindowSize()
        if !isMouseInsideWindow() { startDismissTimer() }
    }

    /// 异步操作开始前调用：阻止按钮点击触发的 handleTap 异步关闭。
    func prepareForAsyncInlineAction() {
        cancelDismiss()
        pauseDismissTimer()
    }

    func startDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: displayDuration, repeats: false) { [weak self] _ in
            guard let self, !self.isDismissing else { return }
            self.isDismissing = true
            self.viewModel.cancelAsyncThumbnail()
            self.dismissToast(animated: true)
        }
    }

    private func pauseDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    private func isMouseInsideWindow() -> Bool {
        guard let windowFrame = window?.frame else { return false }
        return windowFrame.contains(NSEvent.mouseLocation)
    }

    // MARK: - Window

    private func createWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        w.level = .floating
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.isMovableByWindowBackground = false
        w.isExcludedFromWindowsMenu = true
        w.ignoresMouseEvents = false
        let cv = NSView()
        cv.wantsLayer = true
        cv.layerUsesCoreImageFilters = true
        cv.layer?.backgroundColor = NSColor.clear.cgColor
        w.contentView = cv
        window = w
        contentView = cv
    }

    func updateWindowSize() {
        guard !isDismissing, let hosting = hostingView, let screen = NSScreen.main else { return }
        hosting.layoutSubtreeIfNeeded()
        let panelSize = hosting.fittingSize
        let x = screen.visibleFrame.midX - panelSize.width / 2
        let y = screen.frame.maxY - panelSize.height + 20
        window?.setFrame(
            NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height),
            display: true,
            animate: false
        )
    }

    func dismissToast(animated: Bool) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        if animated {
            let gen = dismissGeneration

            // 原生模糊退场动画
            if let layer = contentView?.layer, let blurFilter = CIFilter(name: "CIGaussianBlur") {
                blurFilter.setDefaults()
                blurFilter.setValue(0.0, forKey: kCIInputRadiusKey)
                blurFilter.name = "dismissBlur"
                layer.filters = [blurFilter]

                let anim = CABasicAnimation(keyPath: "filters.dismissBlur.inputRadius")
                anim.fromValue = 0.0
                anim.toValue = 4.0
                anim.duration = 0.2
                anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
                anim.fillMode = .forwards
                anim.isRemovedOnCompletion = false
                layer.add(anim, forKey: "dismissBlurAnim")
            }

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window?.animator().alphaValue = 0
            }
            // 用 GCD timer 替代 completionHandler — 不依赖 AppKit 动画回调，
            // 避免长时间运行后回调丢失导致窗口残留 alpha=0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.dismissGeneration == gen else { return }
                self.contentView?.layer?.filters = nil
                self.contentView?.layer?.removeAnimation(forKey: "dismissBlurAnim")
                self.window?.orderOut(nil)
                self.isDismissing = false
                self.removeAllMonitors()
            }
        } else {
            dismissGeneration += 1
            contentView?.layer?.filters = nil
            window?.orderOut(nil)
            isDismissing = false
        }
    }

    private func removeAllMonitors() {
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
        if let m = localCmdMonitor  { NSEvent.removeMonitor(m); localCmdMonitor = nil }
        if let m = localOtherEventMonitor { NSEvent.removeMonitor(m); localOtherEventMonitor = nil }
        cmdIsPreExisting = false
        cmdCancelledByOtherEvent = false
        viewModel.isCommandPressed = false
    }
}
