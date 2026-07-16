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
    private var globalTriggerModifierMonitor: Any?
    private var localTriggerModifierMonitor: Any?
    private var localOtherEventMonitor: Any?
    private var localEscapeMonitor: Any?     // 展开态 Escape 收起
    private var localCopyMonitor: Any?      // 展开态 ⌘C 复制全文
    private var mouseEventListenerToken: UUID?
    private var keyboardQuickTrigger = KeyboardQuickTriggerStateMachine(mode: .doubleTap)
    private var mouseQuickTrigger = MouseQuickTriggerStateMachine()
    private var keyboardTargetIsDown = false
    private var quickTriggerContextGeneration = 0
    private var quickTriggerTimeout: DispatchWorkItem?
    private var quickTriggerHIDPoll: DispatchWorkItem?
    private let displayDuration: TimeInterval = 3.0

    private var isExpandingOrCollapsing = false
    private var currentContent: ClipboardContent?

    func show(content: ClipboardContent, source: SourceAppInfo) {
        removeAllMonitors()
        viewModel.configure(with: content, source: source)
        viewModel.showsUpdateReminder = AppUpdateService.shared
            .shouldAttachUpdateReminderToStandardToast()
        currentContent = content

        isDismissing = false
        isExpandingOrCollapsing = false
        dismissGeneration += 1
        quickTriggerContextGeneration += 1
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
            onNeedsLayout: { [weak self] in DispatchQueue.main.async { self?.updateWindowSize() } },
            onAction: { [weak self] action in
                switch action {
                case .expand: self?.handleExpand()
                case .collapse: self?.handleCollapse()
                case .editInTextEdit: self?.handleEditInTextEdit()
                }
            },
            onOpenUpdateAbout: {
                SettingsNavigation.openAboutFromToast()
            }
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
        if viewModel.showsUpdateReminder {
            AppUpdateService.shared.recordUpdateReminderDisplayed()
        }

        if isMouseInsideWindow() {} else { startDismissTimer() }

        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let window = self.window, window.isVisible, !self.isDismissing else { return event }
                if window.frame.contains(NSEvent.mouseLocation) { self.handleTap() }
                return event
            }
        }

        installQuickTriggerMonitors()

        if localEscapeMonitor == nil {
            localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.viewModel.isExpanded, event.keyCode == 53 else { return event }
                self.handleCollapse()
                return nil
            }
        }
        if localCopyMonitor == nil {
            localCopyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      self.viewModel.isExpanded,
                      event.modifierFlags.contains(.command),
                      event.charactersIgnoringModifiers == "c" else { return event }
                if let textView = self.findTextView(in: self.window?.contentView) {
                    textView.copy(nil)
                    return nil
                }
                return event
            }
        }
    }

    // MARK: - Quick trigger

    private func installQuickTriggerMonitors() {
        guard quickTriggerAction() != nil else { return }
        let settings = QuickTriggerSettings.current()
        keyboardQuickTrigger = KeyboardQuickTriggerStateMachine(mode: settings.keyboardMode)

        if settings.keyboardModifier != .disabled {
            let triggerFlags = settings.keyboardModifier.nseventFlags
            keyboardTargetIsDown = NSEvent.modifierFlags.contains(triggerFlags)
            keyboardQuickTrigger.appeared(preExisting: keyboardTargetIsDown)

            globalTriggerModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
                [weak self] event in self?.handleModifierFlagsChanged(event)
            }
            localTriggerModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
                [weak self] event in
                self?.handleModifierFlagsChanged(event)
                return event
            }
        }

        localOtherEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            self?.cancelKeyboardQuickTrigger()
            self?.mouseQuickTrigger.cancelPendingTrigger()
            return event
        }

        mouseEventListenerToken = GlobalMouseEventCoordinator.shared.addListener(
            promptForAccessibility: false
        ) { [weak self] type, event in
            self?.handleGlobalMouseEvent(type: type, event: event) ?? false
        }
    }

    private func handleModifierFlagsChanged(_ event: NSEvent) {
        guard let window, window.isVisible, !isDismissing, quickTriggerAction() != nil else {
            cancelKeyboardQuickTrigger()
            return
        }
        let settings = QuickTriggerSettings.current()
        guard settings.keyboardModifier != .disabled else {
            cancelKeyboardQuickTrigger()
            return
        }

        let triggerFlags = settings.keyboardModifier.nseventFlags
        if QuickTriggerModifierPolicy.hasInterferingModifier(
            eventFlags: event.modifierFlags,
            triggerFlags: triggerFlags
        ) {
            cancelKeyboardQuickTrigger()
            mouseQuickTrigger.cancelPendingTrigger()
            return
        }

        let isDown = event.modifierFlags.contains(triggerFlags)
        guard isDown != keyboardTargetIsDown else { return }
        keyboardTargetIsDown = isDown
        mouseQuickTrigger.cancelPendingTrigger()

        if isDown {
            let shouldTrigger = keyboardQuickTrigger.targetChanged(
                isDown: true,
                at: event.timestamp,
                counters: captureQuickTriggerEventCounters(),
                context: quickTriggerContextGeneration
            )
            updateQuickTriggerVisualState()
            if shouldTrigger { performQuickTriggerAction() }
        } else {
            let capturedContext = quickTriggerContextGeneration
            let timestamp = event.timestamp
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      !self.isDismissing,
                      capturedContext == self.quickTriggerContextGeneration else { return }
                let shouldTrigger = self.keyboardQuickTrigger.targetChanged(
                    isDown: false,
                    at: timestamp,
                    counters: self.captureQuickTriggerEventCounters(),
                    context: capturedContext
                )
                self.updateQuickTriggerVisualState()
                if shouldTrigger { self.performQuickTriggerAction() }
            }
        }
    }

    private func handleGlobalMouseEvent(type: CGEventType, event: CGEvent) -> Bool {
        cancelKeyboardQuickTrigger()
        let settings = QuickTriggerSettings.current()
        guard let configuredButton = settings.mouseButton else {
            mouseQuickTrigger.cancelPendingTrigger()
            return false
        }
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        switch type {
        case .otherMouseDown where button == configuredButton:
            let consume = mouseQuickTrigger.mouseDown(
                button: button,
                configuredButton: configuredButton,
                context: quickTriggerContextGeneration,
                canPerform: window?.isVisible == true && !isDismissing && quickTriggerAction() != nil
            )
            if consume {
                DispatchQueue.main.async { [weak self] in
                    self?.viewModel.quickTriggerVisualState = .pressed
                }
            }
            return consume
        case .otherMouseUp where button == configuredButton:
            let result = mouseQuickTrigger.mouseUp(
                button: button,
                context: quickTriggerContextGeneration
            )
            if result.consume {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.viewModel.quickTriggerVisualState = .idle
                    if result.trigger { self.performQuickTriggerAction() }
                }
            }
            return result.consume
        default:
            mouseQuickTrigger.cancelPendingTrigger()
            return false
        }
    }

    private func captureQuickTriggerEventCounters() -> QuickTriggerEventCounters {
        func count(_ type: CGEventType) -> UInt32 {
            CGEventSource.counterForEventType(.hidSystemState, eventType: type)
        }
        return QuickTriggerEventCounters(
            keyDown: count(.keyDown),
            leftMouseDown: count(.leftMouseDown),
            leftMouseUp: count(.leftMouseUp),
            rightMouseDown: count(.rightMouseDown),
            rightMouseUp: count(.rightMouseUp),
            otherMouseDown: count(.otherMouseDown),
            otherMouseUp: count(.otherMouseUp),
            scrollWheel: count(.scrollWheel)
        )
    }

    private func updateQuickTriggerVisualState() {
        quickTriggerTimeout?.cancel()
        viewModel.quickTriggerVisualState = keyboardQuickTrigger.visualState
        scheduleQuickTriggerHIDValidation()
        guard keyboardQuickTrigger.visualState == .waitingForSecondTap else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.keyboardQuickTrigger.tick(at: ProcessInfo.processInfo.systemUptime)
            self.viewModel.quickTriggerVisualState = self.keyboardQuickTrigger.visualState
        }
        quickTriggerTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(351), execute: work)
    }

    private func scheduleQuickTriggerHIDValidation() {
        quickTriggerHIDPoll?.cancel()
        quickTriggerHIDPoll = nil
        guard keyboardQuickTrigger.visualState != .idle else { return }
        let capturedContext = quickTriggerContextGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  capturedContext == self.quickTriggerContextGeneration else { return }
            let isValid = self.keyboardQuickTrigger.validate(
                counters: self.captureQuickTriggerEventCounters(),
                context: capturedContext
            )
            self.viewModel.quickTriggerVisualState = self.keyboardQuickTrigger.visualState
            if isValid { self.scheduleQuickTriggerHIDValidation() }
        }
        quickTriggerHIDPoll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20), execute: work)
    }

    private func cancelKeyboardQuickTrigger() {
        quickTriggerTimeout?.cancel()
        quickTriggerTimeout = nil
        quickTriggerHIDPoll?.cancel()
        quickTriggerHIDPoll = nil
        keyboardQuickTrigger.cancel()
        viewModel.quickTriggerVisualState = .idle
    }

    private func invalidateQuickTriggerContext() {
        quickTriggerContextGeneration += 1
        keyboardQuickTrigger.contextChanged()
        mouseQuickTrigger.cancelPendingTrigger()
        quickTriggerTimeout?.cancel()
        quickTriggerTimeout = nil
        quickTriggerHIDPoll?.cancel()
        quickTriggerHIDPoll = nil
        viewModel.quickTriggerVisualState = .idle
    }

    private func quickTriggerAction() -> (any ClipboardAction)? {
        viewModel.resultOverlay.map { CopyTextAction(text: $0.copyText) }
            ?? viewModel.primaryAction
    }

    private func performQuickTriggerAction() {
        guard let action = quickTriggerAction(), !isDismissing else { return }
        handlePerformAction(action)
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

    private func handleExpand() {
        guard !viewModel.isExpanded, !isExpandingOrCollapsing else { return }
        isExpandingOrCollapsing = true
        cancelDismiss()
        pauseDismissTimer()

        // Phase 1: blur + fade out (same as dismissToast)
        applyWindowBlur()
        animateWindowAlpha(to: 0, easeIn: true) { [weak self] in
            guard let self else { return }
            // Switch content while invisible
            self.viewModel.isExpanded = true
            self.updateWindowSize(animated: false)

            // Phase 2: deblur + fade in (reverse of dismissToast)
            self.animateWindowAlpha(to: 1, easeIn: false) { [weak self] in
                self?.removeWindowBlur()
                self?.isExpandingOrCollapsing = false
            }
        }
    }

    private func handleCollapse() {
        guard viewModel.isExpanded, !isExpandingOrCollapsing else { return }
        isExpandingOrCollapsing = true

        // Phase 1: blur + fade out
        applyWindowBlur()
        animateWindowAlpha(to: 0, easeIn: true) { [weak self] in
            guard let self else { return }
            // Switch content while invisible
            self.viewModel.isExpanded = false
            self.updateWindowSize(animated: false)

            // Phase 2: deblur + fade in
            self.animateWindowAlpha(to: 1, easeIn: false) { [weak self] in
                self?.removeWindowBlur()
                self?.isExpandingOrCollapsing = false
                if self?.isMouseInsideWindow() == false { self?.startDismissTimer() }
            }
        }
    }

    // MARK: - Window blur helpers

    private func applyWindowBlur() {
        guard let layer = contentView?.layer,
              let filter = CIFilter(name: "CIGaussianBlur") else { return }
        filter.setDefaults()
        filter.setValue(0.0, forKey: kCIInputRadiusKey)
        filter.name = "expandBlur"
        layer.filters = (layer.filters ?? []) + [filter]
    }

    private func removeWindowBlur() {
        contentView?.layer?.filters = nil
    }

    private func animateWindowAlpha(to alpha: CGFloat, easeIn: Bool, completion: @escaping () -> Void) {
        let gen = dismissGeneration
        let blurKeyPath = "filters.expandBlur.inputRadius"
        let fromRadius: CGFloat = alpha == 0 ? 0 : 4
        let toRadius: CGFloat = alpha == 0 ? 4 : 0

        if let layer = contentView?.layer {
            let anim = CABasicAnimation(keyPath: blurKeyPath)
            anim.fromValue = fromRadius
            anim.toValue = toRadius
            anim.duration = 0.2
            anim.timingFunction = CAMediaTimingFunction(name: easeIn ? .easeIn : .easeOut)
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
            layer.add(anim, forKey: "expandBlurAnim")
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: easeIn ? .easeIn : .easeOut)
            window?.animator().alphaValue = alpha
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.dismissGeneration == gen else { return }
            self.contentView?.layer?.removeAnimation(forKey: "expandBlurAnim")
            completion()
        }
    }

    private func handleEditInTextEdit() {
        let text = viewModel.expandedText
        guard !text.isEmpty else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Copied-\(UUID().uuidString).txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
        // Dismiss toast after opening in editor
        if !isDismissing {
            isDismissing = true
            viewModel.cancelAsyncThumbnail()
            dismissToast(animated: true)
        }
    }

    private func handleHoverChanged(_ hovering: Bool) {
        guard !isDismissing else { return }
        if hovering { pauseDismissTimer() } else { startDismissTimer() }
    }

    private func handleTap() {
        guard !isDismissing, !isExpandingOrCollapsing else { return }
        if isUpdateReminderHitRegion() { return }
        if viewModel.isExpanded {
            // Tap on button-bar blank area (between the two buttons) → dismiss.
            // Taps on the actual buttons are handled by SwiftUI (collapse / edit).
            if let w = window {
                let distFromBottom = NSEvent.mouseLocation.y - w.frame.minY
                let xInWindow = NSEvent.mouseLocation.x - w.frame.minX
                let isInSpacerArea = xInWindow > w.frame.width * 0.42
                                  && xInWindow < w.frame.width * 0.78
                if distFromBottom < 60 && isInSpacerArea {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.isDismissing else { return }
                        self.isDismissing = true
                        self.viewModel.cancelAsyncThumbnail()
                        self.dismissToast(animated: true)
                    }
                }
            }
            return
        }
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
        invalidateQuickTriggerContext()
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

    /// Recursively search the view hierarchy for an NSTextView so we can copy its selection.
    private func findTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews {
            if let found = findTextView(in: sub) { return found }
        }
        return nil
    }

    private func isMouseInsideWindow() -> Bool {
        guard let windowFrame = window?.frame else { return false }
        return windowFrame.contains(NSEvent.mouseLocation)
    }

    private func isUpdateReminderHitRegion() -> Bool {
        guard viewModel.showsUpdateReminder,
              !viewModel.isExpanded,
              let window else { return false }
        let point = NSEvent.mouseLocation
        guard window.frame.contains(point) else { return false }
        let x = point.x - window.frame.minX
        let y = point.y - window.frame.minY
        return x >= window.frame.width - 56 && y >= window.frame.height - 56
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

    func updateWindowSize(animated: Bool = false) {
        guard !isDismissing, let hosting = hostingView, let screen = NSScreen.main else { return }
        hosting.layoutSubtreeIfNeeded()
        let panelSize = hosting.fittingSize
        var h = panelSize.height
        if viewModel.isExpanded {
            // Safety cap: expanded view should never exceed content + outer padding
            let maxH: CGFloat = 340
            if h > maxH { h = maxH }
        }
        let x = screen.visibleFrame.midX - panelSize.width / 2
        let y = screen.frame.maxY - h + 20
        let rect = NSRect(x: x, y: y, width: panelSize.width, height: h)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.0, 0.22, 1.0)
                ctx.allowsImplicitAnimation = true
                window?.animator().setFrame(rect, display: true)
            }
        } else {
            window?.setFrame(rect, display: true, animate: false)
        }
    }

    func dismissToast(animated: Bool) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        invalidateQuickTriggerContext()
        removeAllMonitors()
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
        if let m = globalTriggerModifierMonitor { NSEvent.removeMonitor(m); globalTriggerModifierMonitor = nil }
        if let m = localTriggerModifierMonitor  { NSEvent.removeMonitor(m); localTriggerModifierMonitor = nil }
        if let m = localOtherEventMonitor { NSEvent.removeMonitor(m); localOtherEventMonitor = nil }
        if let m = localEscapeMonitor  { NSEvent.removeMonitor(m); localEscapeMonitor = nil }
        if let m = localCopyMonitor    { NSEvent.removeMonitor(m); localCopyMonitor = nil }
        GlobalMouseEventCoordinator.shared.removeListener(mouseEventListenerToken)
        mouseEventListenerToken = nil
        quickTriggerTimeout?.cancel()
        quickTriggerTimeout = nil
        quickTriggerHIDPoll?.cancel()
        quickTriggerHIDPoll = nil
        keyboardTargetIsDown = false
        keyboardQuickTrigger.cancel()
        mouseQuickTrigger.reset()
        viewModel.quickTriggerVisualState = .idle
    }
}
