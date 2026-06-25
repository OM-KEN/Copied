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
    private(set) var translationGeneration = 0
    var isTranslating = false  // 翻译进行中，阻止 toast 关闭
    private var localMouseMonitor: Any?
    private var localCmdMonitor: Any?
    private var cmdKeyDownCount: UInt32 = 0
    private var cmdIsPreExisting = false  // ⌘ was already held when toast appeared
    private let displayDuration: TimeInterval = 3.0

    private var currentContent: ClipboardContent?

    func show(content: ClipboardContent, source: SourceAppInfo) {
        viewModel.configure(with: content, source: source)
        currentContent = content
        translationGeneration += 1  // 使进行中的翻译过期

        isDismissing = false
        dismissToast(animated: false)
        if window == nil { createWindow() }

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

        guard let screen = NSScreen.main else { return }
        let panelSize = newHosting.fittingSize
        let x = screen.visibleFrame.midX - panelSize.width / 2
        let y = screen.frame.maxY - panelSize.height + 20
        window?.setFrame(NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height), display: true, animate: false)
        window?.alphaValue = 1.0
        window?.orderFront(nil)

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
                if isCmd {
                    self.cmdIsPreExisting = false
                    self.cmdKeyDownCount = CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown)
                    self.viewModel.isCommandPressed = true
                } else {
                    self.viewModel.isCommandPressed = false
                    if self.cmdIsPreExisting {
                        self.cmdIsPreExisting = false
                        return
                    }
                    let newCount = CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown)
                    if newCount == self.cmdKeyDownCount,
                       !self.isDismissing {
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
        guard !isDismissing, !isTranslating else { return }
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

    func nextTranslationGeneration() -> Int {
        translationGeneration += 1
        return translationGeneration
    }

    func startDismissTimer() {
        guard !isTranslating else { return }
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
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window?.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self, self.dismissGeneration == gen else { return }
                self.window?.orderOut(nil)
                self.isDismissing = false
                self.removeAllMonitors()
            }
        } else {
            dismissGeneration += 1
            window?.orderOut(nil)
            isDismissing = false
        }
    }

    private func removeAllMonitors() {
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
        if let m = localCmdMonitor  { NSEvent.removeMonitor(m); localCmdMonitor = nil }
        cmdIsPreExisting = false
        viewModel.isCommandPressed = false
    }
}
