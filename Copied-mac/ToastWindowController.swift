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
    private var deferredExpandedTextGeneration = 0
    private var preparedExpandedText: String?
    private var preparedExpandedTextDocumentHeight: CGFloat?
    private var dismissTimer: Timer?
    private var viewModel = ToastViewModel()
    private let commandDispatcher = ToastCommandDispatcher<any ClipboardAction>()

    private var isDismissing = false
    private var dismissGeneration = 0
    private var dismissTimerGeneration = 0
    private var quickTriggerContextGeneration = 0
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
    private let startupNoticeDuration: TimeInterval = 1.0
    private let minimumActionableDuration: TimeInterval = 1.5

    private var isExpandingOrCollapsing = false
    private var currentContent: ClipboardContent?
    private var currentRevision: ClipboardRevision?
    private var resourcesCancelledRevision: ClipboardRevision?
    private var textExportToken: UUID?
    private var lastPresentedRevision: ClipboardRevision?
    private var lastRevisionPresentationTime = Date.distantPast
    private var entranceStyle: ToastEntranceStyle = .standard
    private var dismissDeadline: Date?
    private var hasShownStartupNotice = false
    private var pausesDismissWhileHovered = true
    var onRevisionResourcesShouldCancel: ((ClipboardRevision) -> Void)?

    func showStartupNotice(using source: SourceAppInfo) {
        guard !hasShownStartupNotice else { return }
        hasShownStartupNotice = true
        pauseDismissTimer()
        viewModel.configureStartupNotice(source: source)
        currentContent = nil
        currentRevision = nil
        resourcesCancelledRevision = nil
        textExportToken = nil
        presentConfiguredToast(
            autoDismissAfter: startupNoticeDuration,
            pausesDismissWhileHovered: false
        )
    }

    func show(content: ClipboardContent, source: SourceAppInfo) {
        removeAllMonitors()
        pauseDismissTimer()
        viewModel.configure(with: content, source: source)
        viewModel.showsUpdateReminder = AppUpdateService.shared
            .shouldAttachUpdateReminderToStandardToast()
        currentContent = content
        currentRevision = content.revision
        resourcesCancelledRevision = nil
        textExportToken = nil
        quickTriggerContextGeneration &+= 1
        presentConfiguredToast(
            autoDismissAfter: displayDuration,
            pausesDismissWhileHovered: true
        )
    }

    /// Creates the first frame for a revision. This method performs no clipboard reads.
    func showPending(revision: ClipboardRevision, source: SourceAppInfo) {
        removeAllMonitors()
        pauseDismissTimer()
        viewModel.configurePending(revision: revision, source: source)
        currentContent = nil
        currentRevision = revision
        resourcesCancelledRevision = nil
        textExportToken = nil
        quickTriggerContextGeneration &+= 1
        presentConfiguredToast(
            autoDismissAfter: displayDuration,
            pausesDismissWhileHovered: true
        )
        // Pending has no independent lifetime. ClipboardMonitor owns the 3-second
        // load timeout and decides whether it becomes a visible failure or is silent.
        pauseDismissTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.currentRevision == revision,
                  self.viewModel.revision == revision else { return }
            self.viewModel.showLoadingIfPending()
        }
    }

    func applyBaseContent(
        _ content: ClipboardContent,
        source: SourceAppInfo,
        revision: ClipboardRevision
    ) {
        guard currentRevision == revision,
              viewModel.revision == revision,
              window?.isVisible == true else { return }
        viewModel.configure(with: content, source: source)
        viewModel.showsUpdateReminder = AppUpdateService.shared
            .shouldAttachUpdateReminderToStandardToast()
        currentContent = content
        quickTriggerContextGeneration &+= 1
        if viewModel.showsUpdateReminder {
            AppUpdateService.shared.recordUpdateReminderDisplayed()
        }
        if isMouseInsideWindow() {
            pauseDismissTimer()
        } else {
            startDismissTimer(after: displayDuration)
        }
    }

    func applyEnrichment(_ content: ClipboardContent, revision: ClipboardRevision) {
        guard currentRevision == revision,
              viewModel.revision == revision,
              viewModel.isContentReady else { return }
        currentContent = content
        viewModel.applyEnrichment(content)
    }

    func applyActions(
        primary: (any ClipboardAction)?,
        menu: [any ClipboardAction],
        revision: ClipboardRevision
    ) {
        guard currentRevision == revision,
              viewModel.revision == revision,
              viewModel.isContentReady else { return }
        viewModel.applyActions(primary: primary, menu: menu)
        requestWindowLayout()
        quickTriggerContextGeneration &+= 1
        if primary != nil {
            refreshQuickTriggerContextIfEligible()
            ensureMinimumActionableTime()
        }
    }

    func showFailure(revision: ClipboardRevision) {
        guard currentRevision == revision, viewModel.revision == revision else { return }
        removeAllMonitors()
        viewModel.configureFailure()
        currentContent = nil
        if isMouseInsideWindow() {
            pauseDismissTimer()
        } else {
            startDismissTimer(after: displayDuration)
        }
    }

    func dismissSilently(revision: ClipboardRevision) {
        guard currentRevision == revision, viewModel.revision == revision else { return }
        removeAllMonitors()
        pauseDismissTimer()
        clearCurrentRevisionForDismissal()
        dismissToast(animated: false)
    }

    private func presentConfiguredToast(
        autoDismissAfter duration: TimeInterval,
        pausesDismissWhileHovered: Bool
    ) {
        let now = Date()
        let replacesVisibleRevision = window?.isVisible == true
            && currentRevision != nil
            && lastPresentedRevision != nil
            && currentRevision != lastPresentedRevision
            && now.timeIntervalSince(lastRevisionPresentationTime) < 0.5
        entranceStyle = replacesVisibleRevision ? .rapidReplacement : .standard
        if let currentRevision {
            lastPresentedRevision = currentRevision
            lastRevisionPresentationTime = now
        }
        self.pausesDismissWhileHovered = pausesDismissWhileHovered
        isDismissing = false
        isExpandingOrCollapsing = false
        resetExpandedTextLayoutState()
        dismissGeneration += 1
        dismissTimerGeneration &+= 1
        contentView?.layer?.filters = nil
        contentView?.layer?.removeAnimation(forKey: "dismissBlurAnim")
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

        let toastCard = makeToastView()

        let newHosting = ToastHostingView(rootView: AnyView(toastCard))
        newHosting.wantsLayer = true
        newHosting.layer?.backgroundColor = NSColor.clear.cgColor
        newHosting.translatesAutoresizingMaskIntoConstraints = true

        hostingView?.removeFromSuperview()
        hostingView = newHosting
        contentView?.addSubview(newHosting)
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

        if pausesDismissWhileHovered, isMouseInsideWindow() {
            pauseDismissTimer()
        } else {
            startDismissTimer(after: duration)
        }
    }

    private func makeToastView() -> ToastView {
        ToastView(
            viewModel: viewModel,
            entranceStyle: entranceStyle,
            onHoverChanged: { [weak self] hovering in self?.handleHoverChanged(hovering) },
            onCommand: { [weak self] command in self?.handleCommand(command) },
            onExpandedTextFrameChanged: { [weak self] frame in
                DispatchQueue.main.async { self?.updateExpandedTextFrame(frame) }
            },
            onNeedsLayout: { [weak self] in self?.requestWindowLayout() },
        )
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
        let generation = quickTriggerContextGeneration
        return QuickTriggerCoordinator.Context(
            id: generation,
            isValid: { [weak self] in
                self?.quickTriggerContextGeneration == generation
            },
            canPerform: { [weak self] in
                guard let self else { return false }
                return self.window?.isVisible == true
                    && !self.isDismissing
                    && !self.isExpandingOrCollapsing
                    && !self.viewModel.isExpanded
                    && !self.viewModel.isStartupNotice
                    && self.viewModel.isContentReady
                    && self.quickTriggerAction() != nil
            }
        )
    }

    private func refreshQuickTriggerContextIfEligible() {
        guard window?.isVisible == true,
              !isDismissing,
              !isExpandingOrCollapsing,
              !viewModel.isExpanded,
              viewModel.isContentReady,
              quickTriggerAction() != nil else { return }
        quickTriggerCoordinator.start(context: makeQuickTriggerContext())
    }

    // MARK: - Action execution

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
        if viewModel.isStartupNotice {
            if case .dismiss = command {
                handleDismiss()
            }
            return
        }

        cancelResourcesForCurrentRevision()

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
                clearCurrentRevisionForDismissal()
                dismissToast(animated: true)
            }
        }
    }

    private func handleExpand() {
        guard viewModel.canExpand, !viewModel.isExpanded,
              !isExpandingOrCollapsing else { return }
        installExpandedTextSurface()
        let expandedText = viewModel.expandedText
        let alreadyPrepared = preparedExpandedText == expandedText
            && preparedExpandedTextDocumentHeight != nil
        let requiresDeferredLayout = ExpandedTextLayoutMetrics.requiresDeferredLoading(
            for: expandedText
        ) && !alreadyPrepared
        deferredExpandedTextGeneration &+= 1
        let deferredGeneration = deferredExpandedTextGeneration
        viewModel.isExpandedTextLoading = requiresDeferredLayout
        isExpandingOrCollapsing = true
        viewModel.isExpandedTransitioning = true
        quickTriggerCoordinator.suspend()
        cancelDismiss()
        pauseDismissTimer()

        // Phase 1: blur + fade out (same as dismissToast)
        applyWindowBlur()
        animateWindowAlpha(to: 0, easeIn: true) { [weak self] in
            guard let self else { return }
            // Switch content while invisible
            self.viewModel.isExpanded = true
            self.updateWindowSize()
            self.setExpandedTextSurfaceVisible(true)

            // Phase 2: deblur + fade in (reverse of dismissToast)
            self.animateWindowAlpha(to: 1, easeIn: false) { [weak self] in
                guard let self else { return }
                self.removeWindowBlur()
                self.isExpandingOrCollapsing = false
                self.viewModel.isExpandedTransitioning = false
                if requiresDeferredLayout {
                    self.scheduleDeferredExpandedTextLayout(generation: deferredGeneration)
                } else {
                    self.focusExpandedText()
                }
            }
        }
    }

    private func scheduleDeferredExpandedTextLayout(generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.deferredExpandedTextGeneration == generation,
                  self.viewModel.isExpanded,
                  self.viewModel.isExpandedTextLoading,
                  !self.isExpandingOrCollapsing,
                  !self.isDismissing,
                  self.window?.isVisible == true,
                  self.expandedTextFrameInHosting != nil else { return }
            self.layoutExpandedTextSurface(allowWhileLoading: true)
            self.viewModel.isExpandedTextLoading = false
            self.expandedTextScrollView?.isHidden = self.expandedTextFrameInHosting == nil
            self.focusExpandedText()
        }
    }

    private func handleCollapse() {
        guard viewModel.isExpanded, !isExpandingOrCollapsing else { return }
        deferredExpandedTextGeneration &+= 1
        isExpandingOrCollapsing = true
        viewModel.isExpandedTransitioning = true
        window?.resignKey()

        // Phase 1: blur + fade out
        applyWindowBlur()
        animateWindowAlpha(to: 0, easeIn: true) { [weak self] in
            guard let self else { return }
            // Switch content while invisible
            self.setExpandedTextSurfaceVisible(false)
            self.viewModel.isExpandedTextLoading = false
            self.viewModel.isExpanded = false
            self.updateWindowSize()

            // Phase 2: deblur + fade in
            self.animateWindowAlpha(to: 1, easeIn: false) { [weak self] in
                guard let self else { return }
                self.removeWindowBlur()
                self.isExpandingOrCollapsing = false
                self.viewModel.isExpandedTransitioning = false
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
        guard !isDismissing, !isExpandingOrCollapsing,
              textExportToken == nil,
              let exportRevision = currentRevision else { return }
        let text = viewModel.fullTextForExport
        guard !text.isEmpty else { return }
        let token = UUID()
        textExportToken = token
        viewModel.isTextExportInProgress = true
        TemporaryTextExport.prepare(text: text) { [weak self] url in
            guard let self else {
                if let url { TemporaryTextExport.remove(url) }
                return
            }
            guard self.textExportToken == token,
                  self.currentRevision == exportRevision,
                  !self.isDismissing else {
                if let url { TemporaryTextExport.remove(url) }
                self.finishTextExportIfCurrent(token)
                return
            }
            guard let url else {
                self.finishTextExportIfCurrent(token)
                return
            }
            guard NSWorkspace.shared.open(url) else {
                TemporaryTextExport.remove(url)
                self.finishTextExportIfCurrent(token)
                return
            }
            self.finishTextExportIfCurrent(token)
            self.isDismissing = true
            self.clearCurrentRevisionForDismissal()
            self.dismissToast(animated: true)
        }
    }

    private func finishTextExportIfCurrent(_ token: UUID) {
        guard textExportToken == token else { return }
        textExportToken = nil
        viewModel.isTextExportInProgress = false
    }

    private func handleHoverChanged(_ hovering: Bool) {
        guard !isDismissing, pausesDismissWhileHovered else { return }
        if hovering { pauseDismissTimer() } else { startDismissTimer() }
    }

    private func handleDismiss() {
        guard !isDismissing, !isExpandingOrCollapsing else { return }
        isDismissing = true
        clearCurrentRevisionForDismissal()
        dismissToast(animated: true)
    }

    // MARK: - Dismiss

    private func cancelDismiss() {
        isDismissing = false
        dismissGeneration += 1
        dismissTimerGeneration &+= 1
        quickTriggerContextGeneration &+= 1
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

    func startDismissTimer(after duration: TimeInterval? = nil) {
        dismissTimer?.invalidate()
        guard !viewModel.isExpanded else {
            dismissTimer = nil
            return
        }
        dismissTimerGeneration &+= 1
        let generation = dismissTimerGeneration
        let actualDuration = duration ?? displayDuration
        dismissDeadline = Date().addingTimeInterval(actualDuration)
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: actualDuration,
            repeats: false
        ) { [weak self] _ in
            guard let self,
                  self.dismissTimerGeneration == generation,
                  !self.isDismissing else { return }
            self.isDismissing = true
            self.clearCurrentRevisionForDismissal()
            self.dismissToast(animated: true)
        }
    }

    private func ensureMinimumActionableTime() {
        guard !viewModel.isExpanded, !isMouseInsideWindow() else { return }
        if let delay = ClipboardPresentationLifetime.delayGuaranteeingMinimumActionTime(
            deadline: dismissDeadline,
            now: Date(),
            minimum: minimumActionableDuration
        ) {
            startDismissTimer(after: delay)
        }
    }

    private func pauseDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        dismissDeadline = nil
    }

    private func cancelResourcesForCurrentRevision() {
        guard let revision = currentRevision,
              resourcesCancelledRevision != revision else { return }
        resourcesCancelledRevision = revision
        onRevisionResourcesShouldCancel?(revision)
    }

    private func clearCurrentRevisionForDismissal() {
        deferredExpandedTextGeneration &+= 1
        cancelResourcesForCurrentRevision()
        currentRevision = nil
    }

    private func isMouseInsideWindow() -> Bool {
        guard let windowFrame = window?.frame else { return false }
        return windowFrame.contains(NSEvent.mouseLocation)
    }

    // MARK: - Window

    private func resetExpandedTextLayoutState() {
        deferredExpandedTextGeneration &+= 1
        preparedExpandedText = nil
        preparedExpandedTextDocumentHeight = nil
        viewModel.isExpandedTextLoading = false
        viewModel.isExpandedTransitioning = false
    }

    private func installExpandedTextSurface() {
        guard expandedTextView == nil, let contentView else { return }

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
            width: ExpandedTextLayoutMetrics.cardWidth,
            height: ExpandedTextLayoutMetrics.maximumDocumentHeight
        )
        scrollView.documentView = textView

        let bottomBarControls = ExpandedBottomBarControlsView(
            viewModel: viewModel,
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

    private func layoutExpandedTextSurface(allowWhileLoading: Bool = false) {
        guard viewModel.isExpanded,
              let contentView,
              let hostingView,
              let frameInHosting = expandedTextFrameInHosting,
              let scrollView = expandedTextScrollView,
              let textView = expandedTextView,
              let bottomBarControlsHosting = expandedBottomBarControlsHostingView else { return }

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

        guard allowWhileLoading || !viewModel.isExpandedTextLoading else { return }

        let viewportSize = scrollView.contentSize
        textView.setFrameSize(NSSize(width: viewportSize.width, height: viewportSize.height))
        let expandedText = viewModel.expandedText
        let documentHeight: CGFloat
        if preparedExpandedText == expandedText,
           let preparedExpandedTextDocumentHeight {
            documentHeight = preparedExpandedTextDocumentHeight
        } else {
            textView.textStorage?.setAttributedString(
                ExpandedTextLayoutMetrics.attributedText(expandedText)
            )
            if let textContainer = textView.textContainer {
                textContainer.containerSize = NSSize(
                    width: viewportSize.width,
                    height: ExpandedTextLayoutMetrics.maximumDocumentHeight
                )
                textContainer.widthTracksTextView = true
                textView.layoutManager?.ensureLayout(for: textContainer)
            }
            let usedTextRect = textView.textContainer.flatMap {
                textView.layoutManager?.usedRect(for: $0)
            } ?? .zero
            documentHeight = ExpandedTextLayoutMetrics.documentHeight(
                viewportHeight: viewportSize.height,
                usedTextMaxY: usedTextRect.maxY
            )
            preparedExpandedText = expandedText
            preparedExpandedTextDocumentHeight = documentHeight
        }
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
            expandedTextScrollView?.isHidden = viewModel.isExpandedTextLoading
            expandedBottomBarControlsHostingView?.isHidden = false
            if viewModel.isExpandedTextLoading {
                scheduleDeferredExpandedTextLayout(
                    generation: deferredExpandedTextGeneration
                )
            }
        }
    }

    private func setExpandedTextSurfaceVisible(_ visible: Bool) {
        expandedTextSurfaceRequestedVisible = visible
        if visible {
            layoutExpandedTextSurface()
        }
        expandedTextScrollView?.isHidden = !visible
            || expandedTextFrameInHosting == nil
            || viewModel.isExpandedTextLoading
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

    private var pendingLayoutGeneration: Int?

    private func requestWindowLayout() {
        let generation = dismissGeneration
        guard pendingLayoutGeneration != generation else { return }
        pendingLayoutGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingLayoutGeneration == generation else { return }
            self.pendingLayoutGeneration = nil
            guard self.dismissGeneration == generation, !self.isDismissing,
                  self.window?.isVisible == true else { return }
            self.updateWindowSize()
        }
    }

    func updateWindowSize() {
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
        window?.setFrame(rect, display: true, animate: false)
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
                self.viewModel.cancelAsyncThumbnail()
                self.isDismissing = false
                self.removeAllMonitors()
                self.releasePresentation()
            }
        } else {
            dismissGeneration += 1
            contentView?.layer?.filters = nil
            window?.orderOut(nil)
            viewModel.cancelAsyncThumbnail()
            isDismissing = false
            releasePresentation()
        }
    }

    private func releasePresentation() {
        pendingLayoutGeneration = nil
        releasePresentationSurfaces()
        viewModel = ToastViewModel()
        currentContent = nil
        currentRevision = nil
        pausesDismissWhileHovered = true
    }

    private func releasePresentationSurfaces() {
        resetExpandedTextLayoutState()
        hostingView?.removeFromSuperview()
        hostingView = nil
        window = nil
        contentView = nil
        expandedTextScrollView = nil
        expandedTextView = nil
        expandedBottomBarControlsHostingView = nil
        expandedTextFrameInHosting = nil
        expandedTextSurfaceRequestedVisible = false
    }

    private func removeAllMonitors() {
        quickTriggerCoordinator.stop()
    }
}
