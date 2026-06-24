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

    /// First non-color, non-English detection — drives left icon and type label.
    var primaryDetection: DetectedContent? {
        guard let detections = rawContent?.detections else { return nil }
        for d in detections {
            switch d {
            case .colorHex, .colorRGB, .colorHSL, .englishPhrase: continue
            default: return d
            }
        }
        return nil
    }

    /// Right button shows ⌘ icon when a special type is detected (avoiding icon duplication).
    var showCommandIcon: Bool {
        primaryDetection != nil
    }

    /// Human-readable type label for the detail line.
    /// Priority: image format → file type → detection type → text kind.
    var typeLabel: String {
        // Image clipboard or image file: "PNG 图片" / "TIFF 图片"
        if let fmt = rawContent?.imageFormat {
            return "\(fmt) 图片"
        }
        // Single file/folder: image format, directory, or extension
        if contentType == .file,
           let urls = rawContent?.fileURLs, urls.count == 1 {
            let url = urls[0]
            // Directory → "文件夹"
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                return "文件夹"
            }
            let ext = url.pathExtension.uppercased()
            if !ext.isEmpty {
                return "\(ext) 文件"
            }
        }
        // Text detection
        switch primaryDetection {
        case .url:              return "链接"
        case .filePath:         return "路径"
        case .mathExpression:   return "公式"
        case .chineseCharacter: return "汉字"
        default: break
        }
        // Text kind fallback
        return textKind.label
    }

    var iconSymbolName: String {
        // Color swatch replaces icon
        if detectedColor != nil { return "" }

        // Special type detection → type-specific icon
        if let d = primaryDetection {
            switch d {
            case .url:              return "safari"
            case .filePath:         return "folder"
            case .mathExpression:   return "function"
            case .chineseCharacter: return "waveform"
            default: break
            }
        }

        switch contentType {
        case .image:
            return "photo"
        case .file:
            // Folder → folder icon; otherwise doc
            if let url = rawContent?.fileURLs?.first,
               (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                return "folder"
            }
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
