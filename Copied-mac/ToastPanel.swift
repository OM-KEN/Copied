import AppKit
import SwiftUI

enum ExpandedTextLayoutMetrics {
    static let cardWidth: CGFloat = 360
    static let horizontalInset: CGFloat = 16
    static let topInset: CGFloat = 12
    static let bottomReservedHeight: CGFloat = 64
    static let bottomBarVisualHeight: CGFloat = 54
    static let maxTotalHeight: CGFloat = 300
    static let font = NSFont.systemFont(ofSize: 14)
    static let lineSpacing: CGFloat = 4

    static var textWidth: CGFloat { cardWidth - horizontalInset * 2 }

    static func textHeight(for text: String) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph]
        )
        return max(ceil(bounds.height), ceil(font.ascender - font.descender))
    }

    static func totalHeight(for text: String) -> CGFloat {
        min(textHeight(for: text) + topInset + bottomReservedHeight, maxTotalHeight)
    }

    static func viewportHeight(for text: String) -> CGFloat {
        max(1, totalHeight(for: text) - bottomBarVisualHeight)
    }

    static func documentHeight(viewportHeight: CGFloat, usedTextMaxY: CGFloat) -> CGFloat {
        let bottomTextSpacing = bottomReservedHeight - bottomBarVisualHeight
        return max(viewportHeight, ceil(usedTextMaxY) + topInset + bottomTextSpacing)
    }

    static func attributedText(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
    }
}

enum ExpandedWindowLayoutMetrics {
    static let shadowOutset: CGFloat = 16

    static func windowSize(for contentSize: NSSize, isExpanded: Bool) -> NSSize {
        guard isExpanded else { return contentSize }
        return NSSize(
            width: contentSize.width + shadowOutset * 2,
            height: contentSize.height + shadowOutset
        )
    }

    static func hostingFrame(for contentSize: NSSize, isExpanded: Bool) -> NSRect {
        let origin = isExpanded
            ? NSPoint(x: shadowOutset, y: shadowOutset)
            : .zero
        return NSRect(origin: origin, size: contentSize)
    }
}

enum ExpandedTextCornerPolicy {
    static func topCorners(isGeometryFlipped: Bool) -> CACornerMask {
        isGeometryFlipped
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    }
}

final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        becomesKeyOnlyIfNeeded = true
        isFloatingPanel = true
        hidesOnDeactivate = false
    }
}

final class ToastHostingView: NSHostingView<AnyView> {
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ToastExpandedTextView: NSTextView {
    override var needsPanelToBecomeKey: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ToastExpandedTextScrollView: NSScrollView {
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override var needsPanelToBecomeKey: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}
