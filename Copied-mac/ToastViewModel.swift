import SwiftUI
import AppKit
import Observation

struct ResultOverlay: Equatable {
    let displayText: String
    let copyText: String?
    let boundedDisplayText: String
    let displayWasTruncated: Bool

    init(displayText: String, copyText: String?) {
        self.displayText = displayText
        self.copyText = copyText
        let bounded = ClipboardExpandedTextPolicy.displayText(for: displayText)
        boundedDisplayText = bounded.text
        displayWasTruncated = bounded.truncated
    }
}

enum ToastContentPhase: Equatable {
    case startup
    case pending
    case loading
    case ready
    case failure
}

@Observable
final class ToastViewModel {
    var previewText = ""
    var contentType: ClipboardContent.ContentType = .text
    var sourceAppName = ""
    var sourceAppIcon: NSImage?
    var sourceBundleID: String?
    var detailInfo = ""
    var detailIsLoading = false
    var thumbnailImage: NSImage?

    var primaryAction: (any ClipboardAction)?
    var quickTriggerVisualState: QuickTriggerVisualState = .idle
    var menuActions: [any ClipboardAction] = []
    var triggerModifierIcon = "control"
    var showsUpdateReminder = false
    var detectedColor: NSColor?
    var resultOverlay: ResultOverlay?
    var rawContent: ClipboardContent?
    var isExpanded = false
    var phase: ToastContentPhase = .pending
    var revision: ClipboardRevision?
    var contentTransitionID = 0
    var displayTypeLabel = ""
    var displayIconSymbolName = "checkmark.circle.fill"
    var expandedDisplayText = ""
    var expandedFullText = ""
    var expandedTextWasTruncated = false
    var isExpandedTextLoading = false
    var isExpandedTransitioning = false
    var isTextExportInProgress = false

    var asyncThumbnail: NSImage? {
        get { thumbnailImage }
        set { thumbnailImage = newValue }
    }

    var isStartupNotice: Bool { phase == .startup }
    var isContentReady: Bool { phase == .ready }
    var canExpand: Bool { isContentReady && !expandedText.isEmpty }

    var primaryDetection: ContentDetection? {
        rawContent?.detections.first {
            $0.kind.id != ContentKind.colorHex.id
                && $0.kind.id != ContentKind.colorRGB.id
                && $0.kind.id != ContentKind.colorHSL.id
        }
    }

    var expandedText: String {
        if let overlay = resultOverlay, !overlay.displayText.isEmpty {
            return overlay.boundedDisplayText
        }
        return expandedDisplayText
    }

    var resultOverlayDisplayText: String {
        guard let overlay = resultOverlay else { return "" }
        return overlay.boundedDisplayText
    }

    var currentExpandedTextWasTruncated: Bool {
        if let overlay = resultOverlay, !overlay.displayText.isEmpty {
            return overlay.displayWasTruncated
        }
        return expandedTextWasTruncated
    }

    var fullTextForExport: String {
        if let overlay = resultOverlay, !overlay.displayText.isEmpty {
            return overlay.displayText
        }
        return expandedFullText
    }

    var blacklistAction: BlacklistSourceAppAction? {
        guard phase != .startup,
              let bid = sourceBundleID,
              bid != Bundle.main.bundleIdentifier,
              !AppFilterSettings.shared.isBlocked(bundleID: bid) else { return nil }
        return BlacklistSourceAppAction(bundleID: bid, appName: sourceAppName)
    }

    var typeLabel: String { displayTypeLabel }

    var metadataDetailText: String {
        [typeLabel, detailInfo]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var iconSymbolName: String {
        if phase == .startup || phase == .pending || phase == .loading || phase == .failure {
            return "checkmark.circle.fill"
        }
        if detectedColor != nil { return "" }
        return displayIconSymbolName
    }

    func configurePending(revision: ClipboardRevision, source: SourceAppInfo) {
        resetForNewPresentation()
        self.revision = revision
        phase = .pending
        previewText = String(localized: "已复制")
        sourceAppName = source.name
        sourceAppIcon = source.icon
        sourceBundleID = source.bundleIdentifier
    }

    func showLoadingIfPending() {
        guard phase == .pending else { return }
        phase = .loading
        detailInfo = String(localized: "正在读取内容…")
        contentTransitionID &+= 1
    }

    func configureFailure() {
        phase = .failure
        previewText = String(localized: "已复制")
        detailInfo = ""
        primaryAction = nil
        menuActions = []
        rawContent = nil
        thumbnailImage = nil
        contentTransitionID &+= 1
    }

    func configure(with content: ClipboardContent, source: SourceAppInfo) {
        resetForNewPresentation()
        phase = .ready
        revision = content.revision
        previewText = content.preview
        contentType = content.type
        sourceAppName = source.name
        sourceAppIcon = source.icon
        sourceBundleID = source.bundleIdentifier
        detailInfo = content.detail
        detailIsLoading = content.detailIsLoading
        thumbnailImage = content.thumbnail
        rawContent = content
        detectedColor = content.detections.first(where: { $0.color != nil })?.color
        displayTypeLabel = content.displayTypeLabel
        displayIconSymbolName = content.displayIconSymbolName
        expandedDisplayText = content.expandedDisplayText
        expandedFullText = content.expandedFullText
        expandedTextWasTruncated = content.expandedTextWasTruncated
        resultOverlay = nil
        quickTriggerVisualState = .idle
        let settings = QuickTriggerSettings.current()
        triggerModifierIcon = settings.keyboardModifier == .disabled
            ? "computermouse"
            : settings.keyboardModifier.sfSymbolName
        isExpanded = false
        contentTransitionID &+= 1
    }

    func applyEnrichment(_ content: ClipboardContent) {
        guard phase == .ready, revision == content.revision else { return }
        previewText = content.preview
        detailInfo = content.detail
        detailIsLoading = content.detailIsLoading
        thumbnailImage = content.thumbnail
        rawContent = content
        detectedColor = content.detections.first(where: { $0.color != nil })?.color
        displayTypeLabel = content.displayTypeLabel
        displayIconSymbolName = content.displayIconSymbolName
        expandedDisplayText = content.expandedDisplayText
        expandedFullText = content.expandedFullText
        expandedTextWasTruncated = content.expandedTextWasTruncated
        contentTransitionID &+= 1
    }

    func applyActions(
        primary: (any ClipboardAction)?,
        menu: [any ClipboardAction]
    ) {
        guard phase == .ready else { return }
        primaryAction = primary
        menuActions = menu
    }

    func configureStartupNotice(source: SourceAppInfo) {
        resetForNewPresentation()
        phase = .startup
        previewText = String(localized: "Copied 已启动")
        sourceAppName = source.name
        sourceAppIcon = source.icon
    }

    func cancelAsyncThumbnail() {
        thumbnailImage = nil
    }

    private func resetForNewPresentation() {
        previewText = ""
        contentType = .text
        sourceAppName = ""
        sourceAppIcon = nil
        sourceBundleID = nil
        detailInfo = ""
        detailIsLoading = false
        thumbnailImage = nil
        primaryAction = nil
        quickTriggerVisualState = .idle
        menuActions = []
        showsUpdateReminder = false
        detectedColor = nil
        resultOverlay = nil
        rawContent = nil
        isExpanded = false
        displayTypeLabel = ""
        displayIconSymbolName = "checkmark.circle.fill"
        expandedDisplayText = ""
        expandedFullText = ""
        expandedTextWasTruncated = false
        isExpandedTextLoading = false
        isExpandedTransitioning = false
        isTextExportInProgress = false
        contentTransitionID &+= 1
    }
}
