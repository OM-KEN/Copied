import SwiftUI
import AppKit

final class ToastWindowController {
    private var window: ToastPanel?
    private var contentView: NSView?
    private var hostingView: NSHostingView<AnyView>?
    private var expandedTextScrollView: ToastExpandedTextScrollView?
    private var expandedTextView: ToastExpandedTextView?
    private var expandedBottomBarControlsHostingView: ToastHostingView?
    private var expandedTextFrameInHosting: CGRect?
    private var expandedTextSurfaceRequestedVisible = false
    private var dismissTimer: Timer?
    private let viewModel = ToastViewModel()
    private let commandDispatcher = ToastCommandDispatcher<any ClipboardAction>()

    private var isDismissing = false
    private var dismissGeneration = 0
    private lazy var quickTriggerCoordinator: QuickTriggerCoordinator = {
        let coordinator = QuickTriggerCoordinator()
        coordinator.onPerformPrimary = { [weak self] in
            self?.handleCommand(.performPrimary)
        }
        coordinator.onVisualStateChanged = { [weak self] state in
            self?.viewModel.quickTriggerVisualState = state
        }
        return coordinator
    }()
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
        contentView?.layer?.filters = nil
        // Always recreate window for fresh Space association.
        // Fullscreen Spaces can lose track of reused windows after
        // extended use, causing the toast to silently not appear.
        window?.orderOut(nil)
        window = nil
        contentView = nil
        expandedTextScrollView = nil
        expandedTextView = nil
        expandedBottomBarControlsHostingView = nil
        expandedTextFrameInHosting = nil
        expandedTextSurfaceRequestedVisible = false
        createWindow()

        let toastCard = ToastView(
            viewModel: viewModel,
            onHoverChanged: { [weak self] hovering in self?.handleHoverChanged(hovering) },
            onCommand: { [weak self] command in self?.handleCommand(command) },
            onExpandedTextFrameChanged: { [weak self] frame in
                DispatchQueue.main.async { self?.updateExpandedTextFrame(frame) }
            },
            onNeedsLayout: { [weak self] in DispatchQueue.main.async { self?.updateWindowSize() } },
        )

        let newHosting = ToastHostingView(rootView: AnyView(toastCard))
        newHosting.wantsLayer = true
        newHosting.layer?.backgroundColor = NSColor.clear.cgColor
        newHosting.translatesAutoresizingMaskIntoConstraints = true

        hostingView?.removeFromSuperview()
        hostingView = newHosting
        contentView?.addSubview(newHosting)
        installExpandedTextSurface()
        newHosting.layoutSubtreeIfNeeded()

        guard let screen = NSScreen.main else {
            NSLog("Copied: NSScreen.main is nil — cannot position window!")
            return
        }
        let panelSize = newHosting.fittingSize
        let windowSize = ExpandedWindowLayoutMetrics.windowSize(
            for: panelSize,
            isExpanded: false
        )
        let x = screen.visibleFrame.midX - windowSize.width / 2
        let y = screen.frame.maxY - windowSize.height + 20
        NSLog("Copied: positioning — screen.frame=\(screen.frame), visibleFrame=\(screen.visibleFrame), panelSize=\(panelSize), target=(\(x), \(y))")
        window?.setFrame(
            NSRect(origin: NSPoint(x: x, y: y), size: windowSize),
            display: true,
            animate: false
        )
        newHosting.frame = ExpandedWindowLayoutMetrics.hostingFrame(
            for: panelSize,
            isExpanded: false
        )
        window?.alphaValue = 1.0
        window?.orderFront(nil)
        if viewModel.showsUpdateReminder {
            AppUpdateService.shared.recordUpdateReminderDisplayed()
        }

        if isMouseInsideWindow() {} else { startDismissTimer() }

        quickTriggerCoordinator.start(context: makeQuickTriggerContext())
    }

    // MARK: - Quick trigger

    private func quickTriggerAction() -> (any ClipboardAction)? {
        if let overlay = viewModel.resultOverlay {
            guard let copyText = overlay.copyText else { return nil }
            return CopyTextAction(text: copyText)
        }
        return viewModel.primaryAction
    }

    private func makeQuickTriggerContext() -> QuickTriggerCoordinator.Context {
        let generation = dismissGeneration
        return QuickTriggerCoordinator.Context(
            id: generation,
            isValid: { [weak self] in
                self?.dismissGeneration == generation
            },
            canPerform: { [weak self] in
                guard let self else { return false }
                return self.window?.isVisible == true
                    && !self.isDismissing
                    && !self.isExpandingOrCollapsing
                    && !self.viewModel.isExpanded
                    && self.quickTriggerAction() != nil
            }
        )
    }

    private func refreshQuickTriggerContextIfEligible() {
        guard window?.isVisible == true,
              !isDismissing,
              !isExpandingOrCollapsing,
              !viewModel.isExpanded else { return }
        quickTriggerCoordinator.start(context: makeQuickTriggerContext())
    }

    // MARK: - Action execution

    /// 替换已有 overlay 的文本，不调整窗口大小。
    /// 用于异步操作的结果替换。窗口大小由首次 showResultOverlay 确定。
    func updateResultText(displayText: String, copyText: String?) {
        cancelDismiss()
        viewModel.resultOverlay = ResultOverlay(displayText: displayText, copyText: copyText)
        refreshQuickTriggerContextIfEligible()
        if !isMouseInsideWindow() { startDismissTimer() }
    }

    func showResultOverlay(displayText: String, copyText: String?, keepAlive: Bool = false) {
        cancelDismiss()
        viewModel.resultOverlay = ResultOverlay(displayText: displayText, copyText: copyText)
        refreshQuickTriggerContextIfEligible()

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

    private func handleCommand(_ command: ToastCommand<any ClipboardAction>) {
        commandDispatcher.dispatch(command) { [weak self] command in
            self?.executeCommand(command)
        }
    }

    private func executeCommand(_ command: ToastCommand<any ClipboardAction>) {
        switch command {
        case .performPrimary:
            handlePerformAction(quickTriggerAction())
        case let .performAction(action):
            handlePerformAction(action)
        case .expand:
            handleExpand()
        case .collapse:
            handleCollapse()
        case .dismiss:
            handleDismiss()
        case .editInTextEdit:
            handleEditInTextEdit()
        case .openUpdateAbout:
            SettingsNavigation.openAboutFromToast()
        }
    }

    private func handlePerformAction(_ action: (any ClipboardAction)?) {
        guard let action, let content = currentContent else { return }
        action.perform(content: content, controller: self)
        switch ToastActionDisposition(performsInlineUpdate: action.performsInlineUpdate) {
        case .keepPresented:
            // Inline-update actions (Calculate, Pinyin, Plugin transform):
            // perform updates popup content in-place, do not dismiss.
            break
        case .dismiss:
            // Regular actions: perform then dismiss.
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
        quickTriggerCoordinator.suspend()
        cancelDismiss()
        pauseDismissTimer()

        // Phase 1: blur + fade out (same as dismissToast)
        applyWindowBlur()
        animateWindowAlpha(to: 0, easeIn: true) { [weak self] in
            guard let self else { return }
            // Switch content while invisible
            self.viewModel.isExpanded = true
            self.updateWindowSize(animated: false)
            self.setExpandedTextSurfaceVisible(true)

            // Phase 2: deblur + fade in (reverse of dismissToast)
            self.animateWindowAlpha(to: 1, easeIn: false) { [weak self] in
                guard let self else { return }
                self.removeWindowBlur()
                self.isExpandingOrCollapsing = false
                self.focusExpandedText()
            }
        }
    }

    private func handleCollapse() {
        guard viewModel.isExpanded, !isExpandingOrCollapsing else { return }
        isExpandingOrCollapsing = true
        window?.resignKey()

        // Phase 1: blur + fade out
        applyWindowBlur()
        animateWindowAlpha(to: 0, easeIn: true) { [weak self] in
            guard let self else { return }
            // Switch content while invisible
            self.setExpandedTextSurfaceVisible(false)
            self.viewModel.isExpanded = false
            self.updateWindowSize(animated: false)

            // Phase 2: deblur + fade in
            self.animateWindowAlpha(to: 1, easeIn: false) { [weak self] in
                guard let self else { return }
                self.removeWindowBlur()
                self.isExpandingOrCollapsing = false
                if self.isMouseInsideWindow() {
                    self.pauseDismissTimer()
                } else {
                    self.startDismissTimer()
                }
                self.quickTriggerCoordinator.resume(context: self.makeQuickTriggerContext())
            }
        }
    }

    private func focusExpandedText() {
        guard viewModel.isExpanded,
              let window,
              let textView = expandedTextView else { return }
        window.makeKey()
        window.makeFirstResponder(textView)
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
        guard !isDismissing, !isExpandingOrCollapsing else { return }
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

    private func handleDismiss() {
        guard !isDismissing, !isExpandingOrCollapsing else { return }
        isDismissing = true
        viewModel.cancelAsyncThumbnail()
        dismissToast(animated: true)
    }

    // MARK: - Dismiss

    private func cancelDismiss() {
        isDismissing = false
        dismissGeneration += 1
        contentView?.layer?.filters = nil
        contentView?.layer?.removeAnimation(forKey: "dismissBlurAnim")
        window?.alphaValue = 1.0
        window?.orderFront(nil)
        refreshQuickTriggerContextIfEligible()
    }

    /// 异步 inline action 的统一入口。处理 dismiss 竞态 + 非动画窗口 resize。
    /// 公式（同步）和翻译（异步）都走这个方法展示结果。
    func showInlineResult(displayText: String, copyText: String?) {
        cancelDismiss()
        viewModel.resultOverlay = ResultOverlay(displayText: displayText, copyText: copyText)
        refreshQuickTriggerContextIfEligible()
        updateWindowSize()
        if !isMouseInsideWindow() { startDismissTimer() }
    }

    /// 异步操作开始前调用：阻止自动关闭并保持结果展示。
    func prepareForAsyncInlineAction() {
        cancelDismiss()
        pauseDismissTimer()
    }

    func startDismissTimer() {
        dismissTimer?.invalidate()
        guard !viewModel.isExpanded else {
            dismissTimer = nil
            return
        }
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

    private func installExpandedTextSurface() {
        guard let contentView else { return }

        let scrollView = ToastExpandedTextScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.isHidden = true
        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = true
        scrollView.onHoverChanged = { [weak self] hovering in
            self?.handleHoverChanged(hovering)
        }

        let textView = ToastExpandedTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(
            width: 0,
            height: ExpandedTextLayoutMetrics.topInset
        )
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView

        let bottomBarControls = ExpandedBottomBarControlsView(
            onHoverChanged: { [weak self] hovering in
                self?.handleHoverChanged(hovering)
            },
            onCommand: { [weak self] command in
                self?.handleCommand(command)
            }
        )
        let bottomBarControlsHosting = ToastHostingView(rootView: AnyView(bottomBarControls))
        bottomBarControlsHosting.wantsLayer = true
        bottomBarControlsHosting.layer?.backgroundColor = NSColor.clear.cgColor
        bottomBarControlsHosting.translatesAutoresizingMaskIntoConstraints = true
        bottomBarControlsHosting.isHidden = true

        contentView.addSubview(scrollView, positioned: .above, relativeTo: hostingView)
        contentView.addSubview(
            bottomBarControlsHosting,
            positioned: .above,
            relativeTo: scrollView
        )

        expandedTextScrollView = scrollView
        expandedTextView = textView
        expandedBottomBarControlsHostingView = bottomBarControlsHosting
    }

    private func layoutExpandedTextSurface() {
        guard viewModel.isExpanded,
              let contentView,
              let hostingView,
              let frameInHosting = expandedTextFrameInHosting,
              let scrollView = expandedTextScrollView,
              let textView = expandedTextView,
              let bottomBarControlsHosting = expandedBottomBarControlsHostingView else { return }

        textView.textStorage?.setAttributedString(
            ExpandedTextLayoutMetrics.attributedText(viewModel.expandedText)
        )
        scrollView.frame = hostingView.convert(frameInHosting, to: contentView).integral
        let cardTop = frameInHosting.minY
        let bottomBarFrameInHosting = CGRect(
            x: frameInHosting.minX - ExpandedTextLayoutMetrics.horizontalInset,
            y: cardTop + ExpandedTextLayoutMetrics.totalHeight(for: viewModel.expandedText)
                - ExpandedTextLayoutMetrics.bottomBarVisualHeight,
            width: ExpandedTextLayoutMetrics.cardWidth,
            height: ExpandedTextLayoutMetrics.bottomBarVisualHeight
        )
        let bottomBarFrame = hostingView.convert(bottomBarFrameInHosting, to: contentView).integral
        bottomBarControlsHosting.frame = bottomBarFrame
        let innerCornerRadius = max(
            0,
            ToastView.cardCornerRadius - ExpandedTextLayoutMetrics.horizontalInset
        )
        scrollView.layer?.cornerRadius = innerCornerRadius
        scrollView.layer?.maskedCorners = ExpandedTextCornerPolicy.topCorners(
            isGeometryFlipped: scrollView.layer?.isGeometryFlipped ?? scrollView.isFlipped
        )

        let viewportSize = scrollView.contentSize
        textView.setFrameSize(NSSize(width: viewportSize.width, height: viewportSize.height))
        if let textContainer = textView.textContainer {
            textContainer.containerSize = NSSize(
                width: viewportSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
            textContainer.widthTracksTextView = true
            textView.layoutManager?.ensureLayout(for: textContainer)
        }
        let usedTextRect = textView.textContainer.flatMap {
            textView.layoutManager?.usedRect(for: $0)
        } ?? .zero
        let documentHeight = ExpandedTextLayoutMetrics.documentHeight(
            viewportHeight: viewportSize.height,
            usedTextMaxY: usedTextRect.maxY
        )
        textView.setFrameSize(NSSize(width: viewportSize.width, height: documentHeight))
        scrollView.hasVerticalScroller = documentHeight > viewportSize.height + 0.5
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func updateExpandedTextFrame(_ frame: CGRect?) {
        expandedTextFrameInHosting = frame
        guard frame != nil else {
            expandedTextScrollView?.isHidden = true
            expandedBottomBarControlsHostingView?.isHidden = true
            return
        }
        if expandedTextSurfaceRequestedVisible && viewModel.isExpanded {
            layoutExpandedTextSurface()
            expandedTextScrollView?.isHidden = false
            expandedBottomBarControlsHostingView?.isHidden = false
        }
    }

    private func setExpandedTextSurfaceVisible(_ visible: Bool) {
        expandedTextSurfaceRequestedVisible = visible
        if visible {
            layoutExpandedTextSurface()
        }
        expandedTextScrollView?.isHidden = !visible || expandedTextFrameInHosting == nil
        expandedBottomBarControlsHostingView?.isHidden = !visible || expandedTextFrameInHosting == nil
    }

    private func createWindow() {
        let w = ToastPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80))
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
        let contentSize = NSSize(width: panelSize.width, height: h)
        let windowSize = ExpandedWindowLayoutMetrics.windowSize(
            for: contentSize,
            isExpanded: viewModel.isExpanded
        )
        let x = screen.visibleFrame.midX - windowSize.width / 2
        let y = screen.frame.maxY - windowSize.height + 20
        let rect = NSRect(origin: NSPoint(x: x, y: y), size: windowSize)
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
        hosting.frame = ExpandedWindowLayoutMetrics.hostingFrame(
            for: contentSize,
            isExpanded: viewModel.isExpanded
        )
        hosting.layoutSubtreeIfNeeded()
        if viewModel.isExpanded {
            layoutExpandedTextSurface()
        }
    }

    func dismissToast(animated: Bool) {
        let shouldHideSurfaceImmediately = ToastDismissSurfacePolicy.shouldHideImmediately(
            animated: animated,
            isExpanded: viewModel.isExpanded
        )
        if shouldHideSurfaceImmediately {
            setExpandedTextSurfaceVisible(false)
        }
        dismissTimer?.invalidate()
        dismissTimer = nil
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
                self.setExpandedTextSurfaceVisible(false)
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
        quickTriggerCoordinator.stop()
    }
}
