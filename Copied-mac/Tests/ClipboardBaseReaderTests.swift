import AppKit
import Foundation

protocol ClipboardAction {}
struct ContentKind {}
struct ContentDetection {}
enum ClipboardTextPolicy { static let longTextThreshold = 50 }
struct LitheClipboardMetadata {
    let isGeneratedByLithe = false
    let requestID: String? = nil
    init(pasteboard: NSPasteboard) {}
}

struct ClipboardContent {
    enum ContentType: Hashable { case text, image, file }
    let revision: ClipboardRevision
    let type: ContentType
    var preview: String
    var detail: String
    var detailIsLoading: Bool
    var thumbnail: NSImage?
    let fileURLs: [URL]?
    let rawText: String?
    var contentKind: ContentKind?
    var detections: [ContentDetection]
    let imageFormat: String?
    let litheMetadata: LitheClipboardMetadata
    let textLength: Int
    let fileURLCount: Int
    let fileSelectionWasTruncated: Bool
    var allFilesAreImages: Bool?
    var displayTypeLabel: String
    var displayIconSymbolName: String
    let expandedDisplayText: String
    let expandedFullText: String
    let expandedTextWasTruncated: Bool
}

private enum Failure: Error { case failed(String) }

@main
enum ClipboardBaseReaderTests {
    static func main() throws {
        try smallAndOversizedText()
        try stagedWriteSucceedsOnThirdAttempt()
        try staleChangeCountIsRejected()
        try pngIsPreferredAndStoredForImageLane()
        try fileSelectionIsCapped()
        try directoryLoadingAndPackageFallback()
        try cancelledFileEnrichmentDoesNotEmit()
        print("ClipboardBaseReaderTests: PASS")
    }

    private static func smallAndOversizedText() throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        try expect(pasteboard.setString("hello", forType: .string), "small text write failed")
        let small = session(for: pasteboard, generation: 1)
        guard case let .content(_, content) = ClipboardBaseReader.read(
            session: small,
            pasteboard: pasteboard
        ) else { throw Failure.failed("small text unreadable") }
        try expect(content.rawText == "hello", "small text changed")
        try expect(!content.expandedTextWasTruncated, "small text was truncated")

        let oversizedText = String(repeating: "👨‍👩‍👧‍👦line\n", count: 8_000)
        pasteboard.clearContents()
        try expect(pasteboard.setString(oversizedText, forType: .string), "large text write failed")
        let oversized = session(for: pasteboard, generation: 2)
        guard case let .content(_, largeContent) = ClipboardBaseReader.read(
            session: oversized,
            pasteboard: pasteboard
        ) else { throw Failure.failed("large text unreadable") }
        try expect(largeContent.expandedTextWasTruncated, "large display text not bounded")
        try expect(largeContent.expandedDisplayText.utf16.count <= 65_536,
                   "large display exceeded the UTF-16 cap")
        try expect(largeContent.expandedFullText == oversizedText, "full export text was discarded")
    }

    private static func stagedWriteSucceedsOnThirdAttempt() throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.declareTypes([.string], owner: nil)
        let staged = session(for: pasteboard, generation: 3)
        try expect(staged.beginBaseAttempt() == 1, "staged attempt 1")
        guard case .unreadable(_) = ClipboardBaseReader.read(session: staged, pasteboard: pasteboard)
        else { throw Failure.failed("empty staged write should be unreadable") }
        try expect(staged.beginBaseAttempt() == 2, "staged attempt 2")
        guard case .unreadable(_) = ClipboardBaseReader.read(session: staged, pasteboard: pasteboard)
        else { throw Failure.failed("second staged write should be unreadable") }
        try expect(pasteboard.setString("ready", forType: .string), "complete staged write failed")
        try expect(staged.beginBaseAttempt() == 3, "staged attempt 3")
        guard case let .content(_, content) = ClipboardBaseReader.read(
            session: staged,
            pasteboard: pasteboard
        ) else { throw Failure.failed("third staged read did not recover") }
        try expect(content.rawText == "ready", "third staged read returned wrong content")
    }

    private static func staleChangeCountIsRejected() throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        try expect(pasteboard.setString("A", forType: .string), "stale A write failed")
        let old = session(for: pasteboard, generation: 4)
        pasteboard.clearContents()
        try expect(pasteboard.setString("B", forType: .string), "stale B write failed")
        guard case .stale(_) = ClipboardBaseReader.read(session: old, pasteboard: pasteboard)
        else { throw Failure.failed("changed pasteboard accepted an old revision") }
    }

    private static func pngIsPreferredAndStoredForImageLane() throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.declareTypes([.tiff, .png], owner: nil)
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        try expect(pasteboard.setData(Data([0x49, 0x49]), forType: .tiff), "TIFF write failed")
        try expect(pasteboard.setData(png, forType: .png), "PNG write failed")
        let imageSession = session(for: pasteboard, generation: 5)
        guard case let .content(_, content) = ClipboardBaseReader.read(
            session: imageSession,
            pasteboard: pasteboard
        ) else { throw Failure.failed("bitmap unreadable") }
        try expect(content.imageFormat == "PNG", "PNG was not preferred")
        try expect(imageSession.takeImageData() == png, "bitmap was not retained for the image lane")
    }

    private static func fileSelectionIsCapped() throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = (0...ClipboardBaseReader.maximumFileURLCount).map { index in
            let item = NSPasteboardItem()
            item.setString("file:///tmp/Copied-file-\(index)", forType: .fileURL)
            return item
        }
        try expect(pasteboard.writeObjects(items), "file collection write failed")
        let fileSession = session(for: pasteboard, generation: 6)
        guard case let .content(_, content) = ClipboardBaseReader.read(
            session: fileSession,
            pasteboard: pasteboard
        ) else { throw Failure.failed("file collection unreadable") }
        try expect(content.fileURLs?.count == 4_096, "downstream file URL cap exceeded")
        try expect(content.fileSelectionWasTruncated,
                   "overflowing selection was not marked truncated")
        try expect(content.fileURLCount == 4_097, "overflow count sentinel missing")
    }

    private static func directoryLoadingAndPackageFallback() throws {
        let temporary = FileManager.default.temporaryDirectory
        let directory = temporary.appendingPathComponent(
            "Copied-folder-enrichment-\(UUID().uuidString)",
            isDirectory: true
        )
        let package = temporary.appendingPathComponent(
            "Copied-package-enrichment-\(UUID().uuidString).app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data(repeating: 1, count: 17).write(to: directory.appendingPathComponent("payload"))
        try FileManager.default.createDirectory(
            at: package.appendingPathComponent("Contents/Resources", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(repeating: 2, count: 23).write(
            to: package.appendingPathComponent("Contents/Resources/payload")
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: package)
        }

        var directoryUpdates: [ClipboardEnrichmentUpdate] = []
        ClipboardFileEnricher.enrich(content: fileContent(url: directory)) {
            directoryUpdates.append($0)
        }
        let directoryStates = directoryUpdates.compactMap { update -> Bool? in
            guard case let .fileFacts(_, _, _, _, _, _, detailIsLoading) = update else {
                return nil
            }
            return detailIsLoading
        }
        try expect(directoryStates.first == true && directoryStates.last == false,
                   "directory detail-loading state did not reach a terminal update")

        var packageUpdates: [ClipboardEnrichmentUpdate] = []
        ClipboardFileEnricher.enrich(content: fileContent(url: package)) {
            packageUpdates.append($0)
        }
        guard let finalPackage = packageUpdates.last,
              case let .fileFacts(
                _, detail, typeLabel, icon, allImages, complete, detailIsLoading
              ) = finalPackage else {
            throw Failure.failed("package enrichment emitted no terminal file facts")
        }
        try expect(!detail.isEmpty, "package fallback left file size empty")
        try expect(typeLabel.contains("APP") && icon == "document",
                   "package fallback changed the package into a folder presentation")
        try expect(allImages == false && complete && !detailIsLoading,
                   "package fallback terminal classification is incomplete")
    }

    private static func cancelledFileEnrichmentDoesNotEmit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Copied-cancelled-enrichment-\(UUID().uuidString)")
        try Data([1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var updates: [ClipboardEnrichmentUpdate] = []
        ClipboardFileEnricher.enrich(
            content: fileContent(url: url),
            shouldCancel: { true }
        ) { updates.append($0) }
        try expect(updates.isEmpty, "cancelled file enrichment emitted an update")
    }

    private static func fileContent(url: URL) -> ClipboardContent {
        ClipboardContent(
            revision: .init(generation: 99, changeCount: 99),
            type: .file,
            preview: url.lastPathComponent,
            detail: "",
            detailIsLoading: false,
            thumbnail: nil,
            fileURLs: [url],
            rawText: nil,
            contentKind: nil,
            detections: [],
            imageFormat: nil,
            litheMetadata: LitheClipboardMetadata(pasteboard: makePasteboard()),
            textLength: 0,
            fileURLCount: 1,
            fileSelectionWasTruncated: false,
            allFilesAreImages: nil,
            displayTypeLabel: "",
            displayIconSymbolName: "document",
            expandedDisplayText: url.path,
            expandedFullText: url.path,
            expandedTextWasTruncated: false
        )
    }

    private static func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("com.copied.reader-tests.\(UUID().uuidString)"))
    }

    private static func session(
        for pasteboard: NSPasteboard,
        generation: UInt64
    ) -> ClipboardLoadSession {
        ClipboardLoadSession(
            revision: .init(generation: generation, changeCount: pasteboard.changeCount),
            backingScale: 2
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.failed(message) }
    }
}
