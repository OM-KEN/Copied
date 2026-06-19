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
    private let displayDuration: TimeInterval = 3.0

    /// Current clipboard content, stored for action execution.
    private var currentContent: ClipboardContent?

    func show(content: ClipboardContent, source: SourceAppInfo) {
        viewModel.configure(with: content, source: source)
        currentContent = content
        NSLog("Copied: showing toast type=\(content.type), preview=\(content.preview.prefix(30))")

        isDismissing = false

        dismissToast(animated: false)

        if window == nil { createWindow() }

        let toastCard = ToastView(
            viewModel: viewModel,
            onHoverChanged: { [weak self] hovering in
                self?.handleHoverChanged(hovering)
            },
            onTap: { [weak self] in
                self?.handleTap()
            },
            onPerformAction: { [weak self] action in
                self?.handlePerformAction(action)
            },
            onNeedsLayout: { [weak self] in
                // Defer to next run loop so SwiftUI finishes layout before we measure
                DispatchQueue.main.async {
                    self?.updateWindowSize()
                }
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

        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let panelSize = newHosting.fittingSize
        let x = visibleFrame.midX - panelSize.width / 2
        let screenTop = screen.frame.maxY
        let y = screenTop - panelSize.height + 20

        window?.setFrame(
            NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height),
            display: true,
            animate: false
        )
        window?.alphaValue = 1.0
        window?.orderFront(nil)

        if isMouseInsideWindow() {
            // Timer not started — user is already hovering.
        } else {
            startDismissTimer()
        }

        // Install local monitor for click-to-dismiss.
        // Returns the event (does NOT consume) so SwiftUI Buttons also receive it.
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self,
                      let window = self.window,
                      window.isVisible,
                      !self.isDismissing else { return event }
                if window.frame.contains(NSEvent.mouseLocation) {
                    self.handleTap()
                    return event  // pass through so SwiftUI Button fires too
                }
                return event
            }
        }
    }

    // MARK: - Action execution

    func showResultOverlay(_ text: String) {
        // Cancel any in-progress dismiss (from the click that triggered this action)
        cancelDismiss()
        viewModel.resultText = text
        startDismissTimer()
    }

    // MARK: - Interaction handlers

    private func handlePerformAction(_ action: (any ClipboardAction)?) {
        guard let action, let content = currentContent else { return }

        let isResultAction = action is CalculateAction || action is ShowPinyinAction

        if isResultAction {
            // Result actions cancel the click-dismiss and show overlay instead
            action.perform(content: content, controller: self)
        } else {
            // All other actions: perform, then dismiss toast immediately
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
        if hovering {
            pauseDismissTimer()
        } else {
            startDismissTimer()
        }
    }

    private func handleTap() {
        guard !isDismissing else { return }
        isDismissing = true
        viewModel.cancelAsyncThumbnail()
        dismissToast(animated: true)
    }

    // MARK: - Dismiss management

    private func cancelDismiss() {
        // Undo the dismiss that handleTap() started
        isDismissing = false
        dismissGeneration += 1  // invalidate any in-flight animation completion
        window?.alphaValue = 1.0
        window?.orderFront(nil)
    }

    func startDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: displayDuration,
            repeats: false
        ) { [weak self] _ in
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

    // MARK: - Mouse position

    private func isMouseInsideWindow() -> Bool {
        guard let windowFrame = window?.frame else { return false }
        let mouseLocation = NSEvent.mouseLocation
        return windowFrame.contains(mouseLocation)
    }

    // MARK: - Window management

    private func createWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
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
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - panelSize.width / 2
        let screenTop = screen.frame.maxY
        let y = screenTop - panelSize.height + 20
        window?.setFrame(
            NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height),
            display: true,
            animate: true
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
                self.removeLocalMouseMonitor()
            }
        } else {
            dismissGeneration += 1
            window?.orderOut(nil)
            isDismissing = false
        }
    }

    private func removeLocalMouseMonitor() {
        guard let monitor = localMouseMonitor else { return }
        NSEvent.removeMonitor(monitor)
        localMouseMonitor = nil
    }
}
