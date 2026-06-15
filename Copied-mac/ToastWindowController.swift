import SwiftUI
import AppKit

final class ToastWindowController {
    private var window: NSWindow?
    private var contentView: NSView?
    private var hostingView: NSHostingView<AnyView>?
    private var dismissTimer: Timer?
    private let viewModel = ToastViewModel()

    func show(content: ClipboardContent, source: SourceAppInfo) {
        viewModel.configure(with: content, source: source)
        NSLog("Copied: showing toast type=\(content.type), preview=\(content.preview.prefix(30))")

        dismissToast(animated: false)

        if window == nil { createWindow() }

        let toastCard = ToastView(viewModel: viewModel)

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
        // Push window to absolute screen top; card floats just below menu bar.
        let screenTop = screen.frame.maxY
        let y = screenTop - panelSize.height + 20

        window?.setFrame(
            NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height),
            display: true,
            animate: false
        )
        window?.alphaValue = 1.0
        window?.orderFront(nil)

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: 3.0,
            repeats: false
        ) { [weak self] _ in
            self?.dismissToast(animated: true)
        }
    }

    // MARK: - Private

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
        w.ignoresMouseEvents = true

        let cv = NSView()
        cv.wantsLayer = true
        cv.layer?.backgroundColor = NSColor.clear.cgColor

        w.contentView = cv
        window = w
        contentView = cv
    }

    private func dismissToast(animated: Bool) {
        dismissTimer?.invalidate()
        dismissTimer = nil

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window?.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                self?.window?.orderOut(nil)
            }
        } else {
            window?.orderOut(nil)
        }
    }
}
