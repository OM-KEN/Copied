import SwiftUI
import AppKit
import Observation

@Observable
final class ToastViewModel {
    var previewText: String = ""
    var contentType: ClipboardContent.ContentType = .text
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

    /// First non-color, non-English detection — drives left icon and type label.
    var primaryDetection: ContentDetection? {
        guard let detections = rawContent?.detections else { return nil }
        for d in detections {
            // Skip visual-only types (color → swatch; English phrase → deferred)
            let isVisualOnly = d.kind.id == ContentKind.colorHex.id
                || d.kind.id == ContentKind.colorRGB.id
                || d.kind.id == ContentKind.colorHSL.id
                || d.kind.id == ContentKind.englishPhrase.id
            if !isVisualOnly { return d }
        }
        return nil
    }

    /// Right button shows ⌘ icon when a special type is detected (avoiding icon duplication).
    var showCommandIcon: Bool {
        primaryDetection != nil
    }

    /// Human-readable type label for the detail line.
    /// Priority: image format → file type/folder → detection label → language label.
    var typeLabel: String {
        // 1. Image clipboard or image file
        if let fmt = rawContent?.imageFormat {
            return "\(fmt) 图片"
        }
        // 2. Single file/folder
        if contentType == .file,
           let urls = rawContent?.fileURLs, urls.count == 1 {
            let url = urls[0]
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                return "文件夹"
            }
            let ext = url.pathExtension.uppercased()
            if !ext.isEmpty { return "\(ext) 文件" }
        }
        // 3. Content detection label (entity types first, then language types)
        for detection in rawContent?.detections ?? [] {
            if !detection.kind.label.isEmpty { return detection.kind.label }
        }
        return ""
    }

    var iconSymbolName: String {
        // 1. Color swatch replaces icon
        if detectedColor != nil { return "" }

        // 2. Detection type icon
        for detection in rawContent?.detections ?? [] {
            if !detection.kind.icon.isEmpty { return detection.kind.icon }
        }

        // 3. Content type fallback
        switch contentType {
        case .image:
            return "photo"
        case .file:
            if let url = rawContent?.fileURLs?.first,
               (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                return "folder"
            }
            return "doc.on.doc"
        case .text:
            return detailInfo.isEmpty ? "text.alignleft" : "text.quote"
        }
    }

    func configure(with content: ClipboardContent, source: SourceAppInfo) {
        // Cancel any in-flight async thumbnail from previous content
        cancelAsyncThumbnail()
        asyncThumbnail = nil

        previewText = content.preview
        contentType = content.type
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

        // Extract color for swatch (from ContentDetection.color)
        detectedColor = content.detections.first(where: { $0.color != nil })?.color

        // Build detail line: type label + character count / dimensions
        // e.g. "链接 · 120字符", "PNG 图片 · 84×84", "Swift · 120字符"
        let label = typeLabel
        if label.isEmpty {
            detailInfo = content.detail
        } else if content.detail.isEmpty {
            detailInfo = label
        } else {
            detailInfo = "\(label) · \(content.detail)"
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
