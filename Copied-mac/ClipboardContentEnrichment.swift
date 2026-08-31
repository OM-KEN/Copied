import AppKit
import Foundation
import ImageIO

enum ClipboardBaseReadOutcome {
    case content(revision: ClipboardRevision, content: ClipboardContent)
    case unreadable(revision: ClipboardRevision)
    case stale(revision: ClipboardRevision)

    var revision: ClipboardRevision {
        switch self {
        case let .content(revision, _),
             let .unreadable(revision),
             let .stale(revision):
            revision
        }
    }
}

enum ClipboardEnrichmentUpdate {
    case analysis(
        revision: ClipboardRevision,
        detections: [ContentDetection]
    )
    case actions(
        revision: ClipboardRevision,
        primary: (any ClipboardAction)?,
        menu: [any ClipboardAction]
    )
    case fileFacts(
        revision: ClipboardRevision,
        detail: String,
        typeLabel: String,
        iconSymbolName: String,
        allFilesAreImages: Bool?,
        classificationIsComplete: Bool,
        detailIsLoading: Bool
    )
    case imageFacts(
        revision: ClipboardRevision,
        detail: String,
        thumbnail: NSImage?
    )
    case thumbnail(
        revision: ClipboardRevision,
        token: UUID,
        image: NSImage?
    )
    case degraded(revision: ClipboardRevision, detail: String)

    var revision: ClipboardRevision {
        switch self {
        case let .analysis(revision, _),
             let .actions(revision, _, _),
             let .fileFacts(revision, _, _, _, _, _, _),
             let .imageFacts(revision, _, _),
             let .thumbnail(revision, _, _),
             let .degraded(revision, _):
            revision
        }
    }
}

enum ClipboardBaseReader {
    static let maximumFileURLCount = 4_096
    /// Cooperative post-materialization cap. NSPasteboard may allocate before this check.
    static let maximumImageDataByteCount = 64 * 1_024 * 1_024

    static func read(
        session: ClipboardLoadSession,
        pasteboard: NSPasteboard = .general
    ) -> ClipboardBaseReadOutcome {
        guard session.accepts(session.revision) else {
            return .stale(revision: session.revision)
        }
        guard pasteboard.changeCount == session.revision.changeCount else {
            return .stale(revision: session.revision)
        }
        guard let types = pasteboard.types else {
            return .unreadable(revision: session.revision)
        }
        let litheMetadata = LitheClipboardMetadata(pasteboard: pasteboard)

        let content: ClipboardContent?
        if types.contains(.fileURL) {
            content = readFiles(
                pasteboard: pasteboard,
                revision: session.revision,
                litheMetadata: litheMetadata
            )
        } else if types.contains(.png) || types.contains(.tiff) {
            content = readBitmap(
                pasteboard: pasteboard,
                types: types,
                session: session,
                litheMetadata: litheMetadata
            )
        } else if types.contains(.string) {
            content = readText(
                pasteboard: pasteboard,
                revision: session.revision,
                litheMetadata: litheMetadata
            )
        } else {
            content = nil
        }

        guard pasteboard.changeCount == session.revision.changeCount else {
            return .stale(revision: session.revision)
        }
        if let content {
            return .content(revision: session.revision, content: content)
        }
        return .unreadable(revision: session.revision)
    }

    private static func readFiles(
        pasteboard: NSPasteboard,
        revision: ClipboardRevision,
        litheMetadata: LitheClipboardMetadata
    ) -> ClipboardContent? {
        guard let items = pasteboard.pasteboardItems else { return nil }
        var urls: [URL] = []
        urls.reserveCapacity(min(items.count, maximumFileURLCount))
        var selectionWasTruncated = false
        for item in items {
            guard let rawURL = item.string(forType: .fileURL),
                  let url = URL(string: rawURL), url.isFileURL else { continue }
            if urls.count == maximumFileURLCount {
                selectionWasTruncated = true
                break
            }
            urls.append(url)
        }
        guard !urls.isEmpty else { return nil }

        let names = urls.prefix(3).map(\.lastPathComponent)
        let preview = names.joined(separator: ", ")
        let detail = selectionWasTruncated
            ? String(localized: "超过4096个文件")
            : String(localized: "\(urls.count)个文件")
        let fullText = ([preview] + urls.map(\.path)).joined(separator: "\n")
        let expanded = ClipboardExpandedTextPolicy.displayText(for: fullText)
        return ClipboardContent(
            revision: revision,
            type: .file,
            preview: preview,
            detail: detail,
            detailIsLoading: false,
            thumbnail: nil,
            fileURLs: urls,
            rawText: nil,
            contentKind: nil,
            detections: [],
            imageFormat: nil,
            litheMetadata: litheMetadata,
            textLength: 0,
            fileURLCount: selectionWasTruncated ? maximumFileURLCount + 1 : urls.count,
            fileSelectionWasTruncated: selectionWasTruncated,
            allFilesAreImages: nil,
            displayTypeLabel: "",
            displayIconSymbolName: urls.count > 1 ? "doc.on.doc" : "document",
            expandedDisplayText: expanded.text,
            expandedFullText: fullText,
            expandedTextWasTruncated: expanded.truncated
        )
    }

    private static func readBitmap(
        pasteboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType],
        session: ClipboardLoadSession,
        litheMetadata: LitheClipboardMetadata
    ) -> ClipboardContent? {
        let format: String
        let data: Data?
        if types.contains(.png), let pngData = pasteboard.data(forType: .png) {
            format = "PNG"
            data = pngData
        } else if types.contains(.tiff), let tiffData = pasteboard.data(forType: .tiff) {
            format = "TIFF"
            data = tiffData
        } else {
            return nil
        }
        guard let data else { return nil }
        let isLimited = data.count > maximumImageDataByteCount
        session.storeImageData(isLimited ? nil : data)
        let detail = isLimited
            ? String(localized: "图片过大，无法预览")
            : formattedByteCount(Int64(data.count))
        let fullText = String(localized: "图片")
        return ClipboardContent(
            revision: session.revision,
            type: .image,
            preview: fullText,
            detail: detail,
            detailIsLoading: false,
            thumbnail: nil,
            fileURLs: nil,
            rawText: nil,
            contentKind: nil,
            detections: [],
            imageFormat: format,
            litheMetadata: litheMetadata,
            textLength: 0,
            fileURLCount: 0,
            fileSelectionWasTruncated: false,
            allFilesAreImages: true,
            displayTypeLabel: String(localized: "\(format) 图片"),
            displayIconSymbolName: "photo",
            expandedDisplayText: fullText,
            expandedFullText: fullText,
            expandedTextWasTruncated: false
        )
    }

    private static func readText(
        pasteboard: NSPasteboard,
        revision: ClipboardRevision,
        litheMetadata: LitheClipboardMetadata
    ) -> ClipboardContent? {
        guard let items = pasteboard.pasteboardItems else { return nil }
        for item in items {
            guard let text = item.string(forType: .string), !text.isEmpty else { continue }
            let characterCount = text.count
            let previewSource = characterCount > 200 ? String(text.prefix(200)) + "…" : text
            let preview = previewSource.components(separatedBy: .newlines).prefix(3)
                .joined(separator: "\n")
            let detail = characterCount >= ClipboardTextPolicy.longTextThreshold
                ? String(localized: "\(characterCount)字符")
                : ""
            let expanded = ClipboardExpandedTextPolicy.displayText(for: text)
            return ClipboardContent(
                revision: revision,
                type: .text,
                preview: preview,
                detail: detail,
                detailIsLoading: false,
                thumbnail: nil,
                fileURLs: nil,
                rawText: text,
                contentKind: nil,
                detections: [],
                imageFormat: nil,
                litheMetadata: litheMetadata,
                textLength: characterCount,
                fileURLCount: 0,
                fileSelectionWasTruncated: false,
                allFilesAreImages: nil,
                displayTypeLabel: "",
                displayIconSymbolName: detail.isEmpty ? "text.bubble" : "text.page",
                expandedDisplayText: expanded.text,
                expandedFullText: text,
                expandedTextWasTruncated: expanded.truncated
            )
        }
        return nil
    }

    private static func formattedByteCount(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }
}

enum ClipboardImageEnricher {
    static let resultDeadline: TimeInterval = 2

    static func enrichBitmap(
        session: ClipboardLoadSession
    ) -> ClipboardEnrichmentUpdate? {
        let started = ProcessInfo.processInfo.systemUptime
        guard let data = session.takeImageData(), session.accepts(session.revision) else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let dimensions = validatedDimensions(source: source) else {
            return .degraded(
                revision: session.revision,
                detail: String(localized: "图片无法预览")
            )
        }

        let maxPixelSize = max(1, Int(128 * session.backingScale))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let generatedImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        )
        let image = generatedImage.flatMap { image -> NSImage? in
            guard ClipboardImageSafety.permitsGeneratedThumbnail(
                width: image.width,
                height: image.height,
                maxPixelSize: maxPixelSize
            ) else {
                return nil
            }
            return NSImage(cgImage: image, size: .zero)
        }
        guard ProcessInfo.processInfo.systemUptime - started <= resultDeadline else { return nil }
        let byteSize = formattedByteCount(Int64(data.count))
        let detail = "\(dimensions.width)×\(dimensions.height) · \(byteSize)"
        return .imageFacts(revision: session.revision, detail: detail, thumbnail: image)
    }

    static func metadata(forImageFile url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return validatedDimensions(source: source)
    }

    static func enrichImageFile(
        content: ClipboardContent
    ) -> ClipboardEnrichmentUpdate? {
        guard content.allFilesAreImages == true,
              content.fileURLs?.count == 1,
              let url = content.fileURLs?.first,
              let dimensions = metadata(forImageFile: url) else { return nil }
        let dimensionsText = "\(dimensions.width)×\(dimensions.height)"
        let detail = content.detail.isEmpty
            ? dimensionsText
            : "\(dimensionsText) · \(content.detail)"
        return .imageFacts(
            revision: content.revision,
            detail: detail,
            thumbnail: nil
        )
    }

    private static func validatedDimensions(
        source: CGImageSource
    ) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              ClipboardImageSafety.permits(width: width, height: height) else { return nil }
        return (width, height)
    }

    private static func formattedByteCount(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }
}

enum ClipboardFileEnricher {
    private static let progressUpdateInterval: TimeInterval = 0.25
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp",
    ]

    static func enrich(
        content: ClipboardContent,
        shouldCancel: @escaping () -> Bool = { false },
        directorySizeCoordinator: ClipboardDirectorySizeCoordinator = .shared,
        registerDirectorySizeObservation: (ClipboardDirectorySizeObservation) -> Void = { _ in },
        emit: @escaping (ClipboardEnrichmentUpdate) -> Void
    ) {
        guard !shouldCancel(), let urls = content.fileURLs, !urls.isEmpty else { return }

        func emitIfActive(_ update: ClipboardEnrichmentUpdate) -> Bool {
            guard !shouldCancel() else { return false }
            emit(update)
            return true
        }

        let fileSizeUpdateLock = NSLock()
        var lastFileSizeProgressDetail: String?
        var latestFileSizeLowerBound: Int64?
        var didEmitFileSizeTerminal = false
        func emitFileSizeProgress(
            _ size: Int64,
            typeLabel: String,
            iconSymbolName: String
        ) -> Bool {
            fileSizeUpdateLock.lock()
            defer { fileSizeUpdateLock.unlock() }
            guard !didEmitFileSizeTerminal,
                  latestFileSizeLowerBound.map({ size >= $0 }) ?? true else { return true }
            latestFileSizeLowerBound = size
            let detail = String(localized: "至少 \(formattedByteCount(size))")
            guard detail != lastFileSizeProgressDetail else { return true }
            lastFileSizeProgressDetail = detail
            return emitIfActive(.fileFacts(
                revision: content.revision,
                detail: detail,
                typeLabel: typeLabel,
                iconSymbolName: iconSymbolName,
                allFilesAreImages: false,
                classificationIsComplete: true,
                detailIsLoading: true
            ))
        }

        func emitFileSizeTerminal(
            _ result: ClipboardDirectorySizeResult,
            unavailableDetail: String,
            typeLabel: String,
            iconSymbolName: String
        ) -> Bool {
            let detail: String
            switch result {
            case let .exact(size):
                detail = formattedByteCount(size)
            case let .atLeast(size):
                detail = String(localized: "至少 \(formattedByteCount(size))")
            case .unavailable:
                detail = unavailableDetail
            case .cancelled:
                return false
            }
            fileSizeUpdateLock.lock()
            defer { fileSizeUpdateLock.unlock() }
            guard !didEmitFileSizeTerminal else { return false }
            didEmitFileSizeTerminal = true
            return emitIfActive(.fileFacts(
                revision: content.revision,
                detail: detail,
                typeLabel: typeLabel,
                iconSymbolName: iconSymbolName,
                allFilesAreImages: false,
                classificationIsComplete: true,
                detailIsLoading: false
            ))
        }

        if content.fileSelectionWasTruncated {
            _ = emitIfActive(.fileFacts(
                revision: content.revision,
                detail: String(localized: "超过4096个文件"),
                typeLabel: "",
                iconSymbolName: "doc.on.doc",
                allFilesAreImages: nil,
                classificationIsComplete: false,
                detailIsLoading: false
            ))
            return
        }

        var allImages = true
        var classificationComplete = true
        var firstValues: URLResourceValues?
        for (index, url) in urls.enumerated() {
            if shouldCancel() { return }
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isPackageKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
            ]) else {
                classificationComplete = false
                allImages = false
                continue
            }
            if shouldCancel() { return }
            if index == 0 { firstValues = values }
            let isImage = values.isRegularFile == true
                && values.isSymbolicLink != true
                && imageExtensions.contains(url.pathExtension.lowercased())
            if !isImage { allImages = false }
        }
        let imageClassification: Bool? = classificationComplete ? allImages : nil

        guard urls.count == 1, let url = urls.first, let values = firstValues else {
            _ = emitIfActive(.fileFacts(
                revision: content.revision,
                detail: String(localized: "\(content.fileURLCount)个文件"),
                typeLabel: "",
                iconSymbolName: "doc.on.doc",
                allFilesAreImages: imageClassification,
                classificationIsComplete: classificationComplete,
                detailIsLoading: false
            ))
            return
        }

        if values.isDirectory == true && values.isPackage != true
            && values.isSymbolicLink != true {
            let folderLabel = String(localized: "文件夹")
            if let contentModificationDate = values.contentModificationDate {
                let attachment = directorySizeCoordinator.attach(
                    to: url,
                    contentModificationDate: contentModificationDate
                ) { event in
                    switch event {
                    case let .progress(size):
                        _ = emitFileSizeProgress(
                            size,
                            typeLabel: folderLabel,
                            iconSymbolName: "folder"
                        )
                    case let .terminal(result):
                        _ = emitFileSizeTerminal(
                            result,
                            unavailableDetail: String(localized: "文件夹大小不可用"),
                            typeLabel: folderLabel,
                            iconSymbolName: "folder"
                        )
                    }
                }
                switch attachment {
                case let .cached(result):
                    _ = emitFileSizeTerminal(
                        result,
                        unavailableDetail: String(localized: "文件夹大小不可用"),
                        typeLabel: folderLabel,
                        iconSymbolName: "folder"
                    )
                    return
                case let .observing(observation, latestLowerBound):
                    guard emitFileSizeProgress(
                        latestLowerBound,
                        typeLabel: folderLabel,
                        iconSymbolName: "folder"
                    ) else {
                        observation.cancel()
                        return
                    }
                    registerDirectorySizeObservation(observation)
                    return
                case .saturated:
                    break
                }
            }
            guard emitFileSizeProgress(0, typeLabel: folderLabel, iconSymbolName: "folder")
            else { return }
            let result = ClipboardDirectorySizeCalculator.calculate(
                at: url,
                shouldCancel: shouldCancel,
                progressUpdateInterval: progressUpdateInterval,
                onProgress: { size in
                    _ = emitFileSizeProgress(
                        size,
                        typeLabel: folderLabel,
                        iconSymbolName: "folder"
                    )
                }
            )
            if let contentModificationDate = values.contentModificationDate {
                ClipboardDirectorySizeCache.store(
                    result,
                    for: url,
                    contentModificationDate: contentModificationDate
                )
            }
            _ = emitFileSizeTerminal(
                result,
                unavailableDetail: String(localized: "文件夹大小不可用"),
                typeLabel: folderLabel,
                iconSymbolName: "folder"
            )
            return
        }

        if shouldCancel() { return }
        let sizeValues = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .totalFileSizeKey,
        ])
        if shouldCancel() { return }
        let size = sizeValues?.totalFileSize ?? sizeValues?.fileSize
        let sizeText = size.map { formattedByteCount(Int64($0)) } ?? ""
        let ext = url.pathExtension.uppercased()
        if imageClassification == true {
            _ = emitIfActive(.fileFacts(
                revision: content.revision,
                detail: sizeText,
                typeLabel: String(localized: "\(ext) 图片"),
                iconSymbolName: "photo",
                allFilesAreImages: true,
                classificationIsComplete: true,
                detailIsLoading: false
            ))
            return
        }

        let typeLabel = ext.isEmpty ? "" : String(localized: "\(ext) 文件")
        guard values.isPackage == true, size == nil else {
            _ = emitIfActive(.fileFacts(
                revision: content.revision,
                detail: sizeText,
                typeLabel: typeLabel,
                iconSymbolName: "document",
                allFilesAreImages: imageClassification,
                classificationIsComplete: classificationComplete,
                detailIsLoading: false
            ))
            return
        }

        if let contentModificationDate = values.contentModificationDate {
            let attachment = directorySizeCoordinator.attach(
                to: url,
                contentModificationDate: contentModificationDate
            ) { event in
                switch event {
                case let .progress(size):
                    _ = emitFileSizeProgress(
                        size,
                        typeLabel: typeLabel,
                        iconSymbolName: "document"
                    )
                case let .terminal(result):
                    _ = emitFileSizeTerminal(
                        result,
                        unavailableDetail: String(localized: "文件信息不可用"),
                        typeLabel: typeLabel,
                        iconSymbolName: "document"
                    )
                }
            }
            switch attachment {
            case let .cached(result):
                _ = emitFileSizeTerminal(
                    result,
                    unavailableDetail: String(localized: "文件信息不可用"),
                    typeLabel: typeLabel,
                    iconSymbolName: "document"
                )
                return
            case let .observing(observation, latestLowerBound):
                guard emitFileSizeProgress(
                    latestLowerBound,
                    typeLabel: typeLabel,
                    iconSymbolName: "document"
                ) else {
                    observation.cancel()
                    return
                }
                registerDirectorySizeObservation(observation)
                return
            case .saturated:
                break
            }
        }
        guard emitFileSizeProgress(0, typeLabel: typeLabel, iconSymbolName: "document")
        else { return }
        let packageResult = ClipboardDirectorySizeCalculator.calculate(
            at: url,
            shouldCancel: shouldCancel,
            progressUpdateInterval: progressUpdateInterval,
            onProgress: { size in
                _ = emitFileSizeProgress(
                    size,
                    typeLabel: typeLabel,
                    iconSymbolName: "document"
                )
            }
        )
        if let contentModificationDate = values.contentModificationDate {
            ClipboardDirectorySizeCache.store(
                packageResult,
                for: url,
                contentModificationDate: contentModificationDate
            )
        }
        _ = emitFileSizeTerminal(
            packageResult,
            unavailableDetail: String(localized: "文件信息不可用"),
            typeLabel: typeLabel,
            iconSymbolName: "document"
        )
    }

    private static func formattedByteCount(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: count)
    }
}
