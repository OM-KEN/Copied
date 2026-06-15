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

    var iconSymbolName: String {
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
        previewText = content.preview
        contentType = content.type
        textKind = content.textKind
        sourceAppName = source.name
        sourceAppIcon = source.icon
        thumbnailImage = content.thumbnail

        // Build detail line: "Swift · 120字符" or just "120字符"
        let lang = textKind.label
        if lang.isEmpty {
            detailInfo = content.detail
        } else if content.detail.isEmpty {
            detailInfo = lang
        } else {
            detailInfo = "\(lang) · \(content.detail)"
        }
    }
}
