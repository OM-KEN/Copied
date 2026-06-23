import SwiftUI
import AppKit
import Observation

@Observable
final class ToastViewModel {
    var previewText: String = ""
    var contentType: ClipboardContent.ContentType = .text
    var textKind: ClipboardContent.TextKind = .plain
    var sourceAppName: String = ""
    var sourceAppIcon: NSImage?
    var detailInfo: String = ""
    var thumbnailImage: NSImage?

    // ── Action & detection state ──────────────────────────
    var primaryAction: (any ClipboardAction)? = nil
    var isCommandPressed = false
    var menuActions: [any ClipboardAction] = []
    var detectedColor: NSColor? = nil
    var resultText: String? = nil
    var rawContent: ClipboardContent? = nil

    // ── Async thumbnail (Quick Look) ──────────────────────
    var asyncThumbnail: NSImage? = nil
    private var currentThumbnailURL: URL?

    var iconSymbolName: String {
        // Color swatch replaces icon
        if detectedColor != nil { return "" }
        switch contentType {
        case .image:
            return "photo"
        case .file:
            return "doc.on.doc"
        case .text:
            switch textKind {
            case .html:       return "chevron.left.forwardslash.chevron.right"
            case .swift,
                 .css,
                 .python,
                 .javascript,
                 .code:       return "curlybraces"
            case .plain:      return detailInfo.isEmpty ? "text.alignleft" : "text.quote"
            }
        }
    }

    func configure(with content: ClipboardContent, source: SourceAppInfo) {
        // Cancel any in-flight async thumbnail from previous content
        cancelAsyncThumbnail()
        asyncThumbnail = nil

        previewText = content.preview
        contentType = content.type
        textKind = content.textKind
        sourceAppName = source.name
        sourceAppIcon = source.icon
        thumbnailImage = content.thumbnail
        rawContent = content
        resultText = nil  // clear previous result
        isCommandPressed = false

        // Resolve actions
        let resolved = ActionResolver.resolve(for: content)
        primaryAction = resolved.primary
        menuActions = resolved.menu

        // Extract color for swatch
        detectedColor = ContentDetector.extractColor(from: content.detections)

        // Build detail line: "Swift · 120字符" or just "120字符"
        let lang = textKind.label
        if lang.isEmpty {
            detailInfo = content.detail
        } else if content.detail.isEmpty {
            detailInfo = lang
        } else {
            detailInfo = "\(lang) · \(content.detail)"
        }

        // Trigger async Quick Look thumbnail for non-image single files
        loadAsyncThumbnail()
    }

    // MARK: - Async thumbnail (Quick Look)

    private func loadAsyncThumbnail() {
        guard contentType == .file,
              thumbnailImage == nil,
              let urls = rawContent?.fileURLs,
              urls.count == 1,
              let url = urls.first else {
            return
        }

        // Cancel previous in-flight request if URL changed
        if let prev = currentThumbnailURL, prev != url {
            FilePreviewGenerator.shared.cancelRequest(for: prev)
        }

        currentThumbnailURL = url
        asyncThumbnail = nil

        FilePreviewGenerator.shared.generateThumbnail(
            for: url,
            size: CGSize(width: 128, height: 128)
        ) { [weak self] image in
            guard let self, self.currentThumbnailURL == url else { return }
            self.asyncThumbnail = image
        }
    }

    func cancelAsyncThumbnail() {
        if let url = currentThumbnailURL {
            FilePreviewGenerator.shared.cancelRequest(for: url)
        }
        currentThumbnailURL = nil
    }
}
