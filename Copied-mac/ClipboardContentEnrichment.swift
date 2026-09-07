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
        var displayedCachedSize: Int64?
        func emitFileSizeProgress(
            _ size: Int64,
            typeLabel: String,
            iconSymbolName: String
        ) -> Bool {
            fileSizeUpdateLock.lock()
            defer { fileSizeUpdateLock.unlock() }
            guard !didEmitFileSizeTerminal, displayedCachedSize == nil,
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

        func emitCachedFileSize(_ size: Int64, isPartial: Bool, isRefreshing: Bool, typeLabel: String, iconSymbolName: String) {
            fileSizeUpdateLock.lock()
            defer { fileSizeUpdateLock.unlock() }
            guard !didEmitFileSizeTerminal else { return }
            displayedCachedSize = size
            didEmitFileSizeTerminal = !isRefreshing
            _ = emitIfActive(.fileFacts(
                revision: content.revision,
                detail: isPartial
                    ? String(localized: "上次至少 \(formattedByteCount(size))")
                    : String(localized: "上次统计 \(formattedByteCount(size))"),
                typeLabel: typeLabel,
                iconSymbolName: iconSymbolName,
                allFilesAreImages: false,
                classificationIsComplete: true,
                detailIsLoading: isRefreshing
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
        var directoryIndices: Set<Int> = []
        for (index, url) in urls.enumerated() {
            if shouldCancel() { return }
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isPackageKey,
                .isSymbolicLinkKey,
            ]) else {
                classificationComplete = false
                allImages = false
                continue
            }
            if shouldCancel() { return }
            if index == 0 { firstValues = values }
            if values.isDirectory == true && values.isSymbolicLink != true {
                directoryIndices.insert(index)
            }
            let isImage = values.isRegularFile == true
                && values.isSymbolicLink != true
                && imageExtensions.contains(url.pathExtension.lowercased())
            if !isImage { allImages = false }
        }
        let imageClassification: Bool? = classificationComplete ? allImages : nil

        if urls.count > 1 {
            enrichSelectionSize(
                content: content, urls: urls, directoryIndices: directoryIndices,
                allFilesAreImages: imageClassification,
                classificationIsComplete: classificationComplete,
                shouldCancel: shouldCancel, coordinator: directorySizeCoordinator,
                registerObservation: registerDirectorySizeObservation, emit: emit
            )
            return
        }

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

        func enrichDirectorySize(typeLabel: String, iconSymbolName: String, unavailableDetail: String) {
            if let observation = directorySizeCoordinator.attach(to: url, observer: { event in
                switch event {
                case let .cached(size, isPartial, isRefreshing):
                    emitCachedFileSize(size, isPartial: isPartial, isRefreshing: isRefreshing, typeLabel: typeLabel, iconSymbolName: iconSymbolName)
                case let .progress(size):
                    _ = emitFileSizeProgress(size, typeLabel: typeLabel, iconSymbolName: iconSymbolName)
                case let .terminal(result):
                    _ = emitFileSizeTerminal(
                        result, unavailableDetail: unavailableDetail,
                        typeLabel: typeLabel, iconSymbolName: iconSymbolName
                    )
                }
            }) {
                registerDirectorySizeObservation(observation)
                return
            }
            let result = directorySizeCoordinator.calculate(
                at: url,
                shouldCancel: shouldCancel,
                progressUpdateInterval: progressUpdateInterval,
                onProgress: { size in
                    _ = emitFileSizeProgress(
                        size,
                        typeLabel: typeLabel,
                        iconSymbolName: iconSymbolName
                    )
                }
            )
            _ = emitFileSizeTerminal(
                result,
                unavailableDetail: unavailableDetail,
                typeLabel: typeLabel,
                iconSymbolName: iconSymbolName
            )
        }

        if values.isDirectory == true && values.isPackage != true
            && values.isSymbolicLink != true {
            enrichDirectorySize(
                typeLabel: String(localized: "文件夹"),
                iconSymbolName: "folder",
                unavailableDetail: String(localized: "文件夹大小不可用")
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

        enrichDirectorySize(
            typeLabel: typeLabel,
            iconSymbolName: "document",
            unavailableDetail: String(localized: "文件信息不可用")
        )
    }

    private static func enrichSelectionSize(
        content: ClipboardContent,
        urls: [URL],
        directoryIndices: Set<Int>,
        allFilesAreImages: Bool?,
        classificationIsComplete: Bool,
        shouldCancel: @escaping () -> Bool,
        coordinator: ClipboardDirectorySizeCoordinator,
        registerObservation: (ClipboardDirectorySizeObservation) -> Void,
        emit: @escaping (ClipboardEnrichmentUpdate) -> Void
    ) {
        let lock = NSLock()
        var sizes = Array(repeating: Int64(0), count: urls.count)
        var partial = Array(repeating: true, count: urls.count)
        var finished = Array(repeating: false, count: urls.count)
        var cached = Array(repeating: false, count: urls.count)
        var observations: [ClipboardDirectorySizeObservation] = []
        var cancelled = false
        var lastDetail: String?
        var lastEmission: TimeInterval = 0
        let started = ProcessInfo.processInfo.systemUptime
        let countText = String(localized: "\(content.fileURLCount)个文件")

        // One session observation owns all directory subscriptions. Detaching it
        // leaves only the coordinator's existing bounded background work running.
        registerObservation(ClipboardDirectorySizeObservation {
            lock.lock()
            cancelled = true
            let pending = observations
            observations.removeAll()
            lock.unlock()
            pending.forEach { $0.cancel() }
        })

        func publish(force: Bool = false) {
            guard !cancelled, !shouldCancel() else { return }
            let loading = finished.contains(false)
            let now = ProcessInfo.processInfo.systemUptime
            guard force || !loading || now - lastEmission >= progressUpdateInterval else { return }
            var total: Int64 = 0
            var isPartial = partial.contains(true)
            for size in sizes {
                switch ClipboardDirectorySizeCalculator.adding(size, to: total) {
                case let .exact(value): total = value
                default: isPartial = true
                }
            }
            let sizeText = formattedByteCount(total)
            let detail: String
            if cached.contains(true) {
                detail = isPartial
                    ? String(localized: "上次至少 \(sizeText)")
                    : String(localized: "上次统计 \(sizeText)")
            } else {
                detail = isPartial ? String(localized: "至少 \(sizeText)") : sizeText
            }
            guard force || !loading || detail != lastDetail else { return }
            lastDetail = detail
            lastEmission = now
            emit(.fileFacts(
                revision: content.revision, detail: "\(countText) · \(detail)",
                typeLabel: "", iconSymbolName: "doc.on.doc",
                allFilesAreImages: allFilesAreImages,
                classificationIsComplete: classificationIsComplete,
                detailIsLoading: loading
            ))
        }

        func receive(_ event: ClipboardDirectorySizeTaskEvent, at index: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled, !finished[index], !shouldCancel() else { return }
            switch event {
            case let .cached(size, isPartial, isRefreshing):
                sizes[index] = size
                partial[index] = isPartial
                cached[index] = true
                finished[index] = !isRefreshing
                publish(force: true)
                return
            case let .progress(size):
                guard !cached[index] else { return }
                sizes[index] = max(sizes[index], size)
            case let .terminal(result):
                switch result {
                case let .exact(size):
                    sizes[index] = size
                    partial[index] = false
                    cached[index] = false
                case let .atLeast(size):
                    sizes[index] = size
                    partial[index] = true
                    cached[index] = false
                case .unavailable, .cancelled:
                    partial[index] = true
                }
                finished[index] = true
            }
            publish()
        }

        lock.lock()
        publish(force: true)
        lock.unlock()
        for (index, url) in urls.enumerated() {
            if shouldCancel() { return }
            let deadlineReached = {
                ProcessInfo.processInfo.systemUptime - started >= ClipboardDirectorySizeCoordinator.maximumDuration
            }
            if deadlineReached() {
                receive(.terminal(.unavailable), at: index)
            } else if directoryIndices.contains(index) {
                if let observation = coordinator.attach(to: url, observer: { receive($0, at: index) }) {
                    lock.lock()
                    let detach = cancelled
                    if !detach { observations.append(observation) }
                    lock.unlock()
                    if detach { observation.cancel() }
                } else {
                    let result = coordinator.calculate(
                        at: url, shouldCancel: { shouldCancel() || deadlineReached() },
                        onProgress: { receive(.progress($0), at: index) }
                    )
                    receive(.terminal(result), at: index)
                }
            } else {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey])
                let size = values?.totalFileSize ?? values?.fileSize
                receive(.terminal(size.flatMap { $0 >= 0 ? .exact(Int64($0)) : nil } ?? .unavailable), at: index)
            }
        }
    }

    private static func formattedByteCount(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: count)
    }
}
