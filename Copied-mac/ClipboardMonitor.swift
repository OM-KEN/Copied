import AppKit

// MARK: - Clipboard Content Model

struct ClipboardContent {
    enum ContentType: Hashable { case text, image, file }

    let type: ContentType
    let preview: String
    let detail: String
    let thumbnail: NSImage?
    let fileURLs: [URL]?

    // ── Extended content info ────────────────────────────────
    let rawText: String?                         // full original text (before truncation)
    let contentKind: ContentKind?                // primary type (highest-priority detection)
    let detections: [ContentDetection]           // all detected content types
    let imageFormat: String?                     // "PNG", "JPEG", "TIFF", "HEIC", etc.

    var hashValue: Int {
        var hasher = Hasher()
        hasher.combine(type)
        hasher.combine(preview)
        hasher.combine(detail)  // e.g. image dims "1920×1080" makes each image unique
        return hasher.finalize()
    }
}

// MARK: - Clipboard Monitor

final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private var lastHash: Int = 0
    private var lastShowTime: Date = .distantPast
    private let dedupWindow: TimeInterval = 0.5
    private let pollInterval: TimeInterval = 0.15

    weak var toastController: ToastWindowController?

    init(toastController: ToastWindowController) {
        self.toastController = toastController
    }

    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: pollInterval,
            repeats: true
        ) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Private

    private func checkClipboard() {
        guard !UserDefaults.standard.bool(forKey: "isPaused") else { return }

        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount
        NSLog("Copied: clipboard change detected (count=\(currentCount))")

        guard let content = readClipboardContent(pasteboard) else {
            NSLog("Copied: readClipboardContent returned nil (types=\(pasteboard.types ?? []))")
            return
        }

        let now = Date()
        if content.hashValue == lastHash,
           now.timeIntervalSince(lastShowTime) < dedupWindow {
            NSLog("Copied: dedup skip (hash=\(content.hashValue), elapsed=\(String(format: "%.3f", now.timeIntervalSince(lastShowTime)))s)")
            return
        }
        lastHash = content.hashValue
        lastShowTime = now

        let source = SourceAppDetector.detect(for: content)
        NSLog("Copied: dispatching show (type=\(content.type), preview=\(content.preview.prefix(50)))")

        // Popup filter gate — check against blacklist/whitelist
        if !AppFilterSettings.shared.shouldShowPopup(for: source.bundleIdentifier) {
            NSLog("Copied: popup filtered (bundleID=\(source.bundleIdentifier ?? "nil"))")
            return
        }

        DispatchQueue.main.async { [weak self] in
            if LightReminderController.shared.isEnabled {
                LightReminderController.shared.show()
            } else {
                self?.toastController?.show(content: content, source: source)
            }
        }
    }

    /// Parse clipboard using actual pasteboard types, not guesswork from readObjects.
    private func readClipboardContent(_ pasteboard: NSPasteboard) -> ClipboardContent? {
        let types = pasteboard.types ?? []

        // ── 1. File URLs ──────────────────────────────────────────
        if types.contains(.fileURL),
           let urls = pasteboard.readObjects(
               forClasses: [NSURL.self],
               options: [.urlReadingFileURLsOnly: true]
           ) as? [URL], !urls.isEmpty {
            let names = urls.map { $0.lastPathComponent }
            let preview: String = if names.count <= 3 {
                names.joined(separator: ", ")
            } else {
                names.prefix(3).joined(separator: ", ")
                    + String(localized: "（\(names.count)个文件）")
            }
            // Single image file → thumbnail + dimensions; single file → size
            var thumb: NSImage? = nil
            let detail: String
            let imgFmt: String?
            if urls.count == 1 {
                if isImageFile(urls[0]),
                   let fileImage = NSImage(contentsOf: urls[0]) {
                    thumb = createThumbnail(from: fileImage)
                    let (w, h) = imagePixelDimensions(fileImage)
                    detail = "\(w)×\(h)"
                    imgFmt = urls[0].pathExtension.uppercased()
                } else if (try? urls[0].resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]))
                    .map({ $0.isDirectory == true && $0.isPackage != true }) == true {
                    // Real folder (not a package like .app/.bundle/.rtfd)
                    detail = formatFileSize(urls[0])
                    imgFmt = nil
                } else {
                    detail = formatFileSize(urls[0])
                    imgFmt = nil
                }
            } else {
                detail = String(localized: "\(urls.count)个文件")
                imgFmt = nil
            }
            return ClipboardContent(
                type: .file,
                preview: preview,
                detail: detail,
                thumbnail: thumb,
                fileURLs: urls,
                rawText: nil,
                contentKind: nil,
                detections: [],
                imageFormat: imgFmt
            )
        }

        // ── 2. Image (tiff/png WITHOUT file URLs) ──────────────────
        //    Screenshots, app-internal image copies → thumbnail-able
        let imageTypes: Set<NSPasteboard.PasteboardType> = [.tiff, .png]
        if !types.filter({ imageTypes.contains($0) }).isEmpty,
           let images = pasteboard.readObjects(
               forClasses: [NSImage.self],
               options: nil
           ) as? [NSImage], let img = images.first {
            let (w, h) = imagePixelDimensions(img)
            let thumb = createThumbnail(from: img)
            // Detect image format from pasteboard types
            let fmt: String?
            if types.contains(.png) {
                fmt = "PNG"
            } else if types.contains(.tiff) {
                fmt = "TIFF"
            } else {
                let utiFormats: [(String, String)] = [
                    ("public.jpeg", "JPEG"),
                    ("public.heic", "HEIC"),
                    ("com.compuserve.gif", "GIF"),
                    ("public.heif", "HEIF"),
                    ("com.microsoft.bmp", "BMP"),
                    ("org.webmproject.webp", "WebP"),
                ]
                fmt = utiFormats.first(where: { types.contains(NSPasteboard.PasteboardType($0.0)) })?.1
            }
            return ClipboardContent(
                type: .image,
                preview: String(localized: "图片"),
                detail: "\(w)×\(h)",
                thumbnail: thumb,
                fileURLs: nil,
                rawText: nil,
                contentKind: nil,
                detections: [],
                imageFormat: fmt
            )
        }

        // ── 3. Text ───────────────────────────────────────────────
        if types.contains(.string),
           let items = pasteboard.pasteboardItems {
            for item in items {
                if let text = item.string(forType: .string), !text.isEmpty {
                    let truncated = text.count > 200
                        ? String(text.prefix(200)) + "…"
                        : text
                    let lines = truncated.components(separatedBy: .newlines)
                    let preview = lines.prefix(3).joined(separator: "\n")
                    let detail = ClipboardTextPolicy.isLong(text)
                        ? String(localized: "\(text.count)字符")
                        : ""
                    let detections = DetectionRegistry.shared.detectAll(in: text)
                    let primaryKind = detections.first?.kind
                    return ClipboardContent(
                        type: .text,
                        preview: preview,
                        detail: detail,
                        thumbnail: nil,
                        fileURLs: nil,
                        rawText: text,
                        contentKind: primaryKind,
                        detections: detections,
                        imageFormat: nil
                    )
                }
            }
        }

        return nil
    }

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp"
    ]

    private static let fileSizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private func formatFileSize(_ url: URL) -> String {
        let res = try? url.resourceValues(forKeys: [
            .totalFileSizeKey, .fileSizeKey, .isDirectoryKey, .isPackageKey
        ])

        // Fast path: totalFileSize (recursive, works for most packages/directories)
        if let totalSize = res?.totalFileSize, totalSize > 0 {
            return Self.fileSizeFormatter.string(fromByteCount: Int64(totalSize))
        }

        // Regular file: use fileSize
        if let fileSize = res?.fileSize, fileSize > 0,
           res?.isDirectory != true {
            return Self.fileSizeFormatter.string(fromByteCount: Int64(fileSize))
        }

        // Directory/package fallback: recursively enumerate to get real size
        let isDirOrPackage = (res?.isDirectory == true) || (res?.isPackage == true)
        if isDirOrPackage {
            let recursiveSize = calculateRecursiveSize(url)
            if recursiveSize > 0 {
                return Self.fileSizeFormatter.string(fromByteCount: recursiveSize)
            }
        }

        // Last resort: attributesOfItem
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64, size > 0 {
            return Self.fileSizeFormatter.string(fromByteCount: size)
        }
        return ""
    }

    /// Recursively sum file sizes under a directory or package.
    private func calculateRecursiveSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let res = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  res.isDirectory != true,
                  let size = res.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    private func imagePixelDimensions(_ image: NSImage) -> (Int, Int) {
        let w = image.representations.first?.pixelsWide ?? Int(image.size.width)
        let h = image.representations.first?.pixelsHigh ?? Int(image.size.height)
        return (w, h)
    }

    private func isImageFile(_ url: URL) -> Bool {
        Self.imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Create a thumbnail from NSImage, cropped to square and resized to 64pt.
    private func createThumbnail(from image: NSImage?, maxSize: CGFloat = 64) -> NSImage? {
        guard let image else { return nil }
        let originalSize = image.size
        guard originalSize.width > 0, originalSize.height > 0 else { return nil }

        let side = min(originalSize.width, originalSize.height)
        let cropRect = NSRect(
            x: (originalSize.width - side) / 2,
            y: (originalSize.height - side) / 2,
            width: side,
            height: side
        )

        let thumbSize = NSSize(width: maxSize, height: maxSize)
        let thumbnail = NSImage(size: thumbSize)
        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: thumbSize),
            from: cropRect,
            operation: .copy,
            fraction: 1.0
        )
        thumbnail.unlockFocus()

        return thumbnail
    }
}
