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
        try cachedDirectoryPresentationRefreshes()
        try saturatedDirectoryUsesSessionCancellation()
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

        let directoryStarted = DispatchSemaphore(value: 0)
        let directoryRelease = DispatchSemaphore(value: 0)
        let packageStarted = DispatchSemaphore(value: 0)
        let packageRelease = DispatchSemaphore(value: 0)
        let coordinator = ClipboardDirectorySizeCoordinator(
            label: "tests.file-enricher-background",
            calculator: { root, duration, shouldCancel, interval, onProgress in
                let isPackage = root.pathExtension.lowercased() == "app"
                onProgress(isPackage ? 23 : 17)
                (isPackage ? packageStarted : directoryStarted).signal()
                _ = (isPackage ? packageRelease : directoryRelease).wait(timeout: .now() + 1)
                if shouldCancel() { return .cancelled }
                guard duration == 30 && interval == 0.25 else { return .unavailable }
                return .exact(isPackage ? 23 : 17)
            }
        )

        let updateLock = NSLock()
        var directoryUpdates: [ClipboardEnrichmentUpdate] = []
        let directoryTerminal = DispatchSemaphore(value: 0)
        var directoryObservation: ClipboardDirectorySizeObservation?
        ClipboardFileEnricher.enrich(
            content: fileContent(url: directory),
            directorySizeCoordinator: coordinator,
            registerDirectorySizeObservation: { directoryObservation = $0 }
        ) {
            updateLock.lock()
            directoryUpdates.append($0)
            updateLock.unlock()
            if case let .fileFacts(_, _, _, _, _, _, loading) = $0, !loading {
                directoryTerminal.signal()
            }
        }
        try expect(directoryObservation != nil, "directory background observation was not registered")
        try expect(directoryStarted.wait(timeout: .now() + 1) == .success,
                   "directory background calculation did not start")
        try expect(directoryTerminal.wait(timeout: .now() + 0.05) == .timedOut,
                   "file enrichment blocked until its background calculation completed")
        directoryRelease.signal()
        try expect(directoryTerminal.wait(timeout: .now() + 1) == .success,
                   "directory background calculation emitted no terminal update")
        updateLock.lock()
        let directoryFacts = directoryUpdates.compactMap { update -> (String, Bool)? in
            guard case let .fileFacts(_, detail, _, _, _, _, detailIsLoading) = update else {
                return nil
            }
            return (detail, detailIsLoading)
        }
        updateLock.unlock()
        try expect(directoryFacts.first?.1 == true && directoryFacts.last?.1 == false,
                   "directory detail-loading state did not reach a terminal update")
        try expect(directoryFacts.first?.0.contains(where: \Character.isNumber) == true
                   && directoryFacts.first?.0.contains("正在") == false,
                   "directory size progress did not start with a numeric value")
        try expect(directoryFacts.count >= 2,
                   "directory size progress did not emit before its terminal value")

        var packageUpdates: [ClipboardEnrichmentUpdate] = []
        let packageTerminal = DispatchSemaphore(value: 0)
        var packageObservation: ClipboardDirectorySizeObservation?
        ClipboardFileEnricher.enrich(
            content: fileContent(url: package),
            directorySizeCoordinator: coordinator,
            registerDirectorySizeObservation: { packageObservation = $0 }
        ) {
            updateLock.lock()
            packageUpdates.append($0)
            updateLock.unlock()
            if case let .fileFacts(_, _, _, _, _, _, loading) = $0, !loading {
                packageTerminal.signal()
            }
        }
        try expect(packageObservation != nil, "package background observation was not registered")
        try expect(packageStarted.wait(timeout: .now() + 1) == .success,
                   "package background calculation did not start")
        try expect(packageTerminal.wait(timeout: .now() + 0.05) == .timedOut,
                   "package enrichment blocked until its background calculation completed")
        packageRelease.signal()
        try expect(packageTerminal.wait(timeout: .now() + 1) == .success,
                   "package background calculation emitted no terminal update")
        updateLock.lock()
        let packageUpdatesSnapshot = packageUpdates
        updateLock.unlock()
        guard let firstPackage = packageUpdatesSnapshot.first,
              case let .fileFacts(_, firstPackageDetail, _, _, _, _, firstPackageLoading)
                = firstPackage else {
            throw Failure.failed("package enrichment emitted no initial file facts")
        }
        try expect(firstPackageLoading
                   && firstPackageDetail.contains(where: \Character.isNumber)
                   && !firstPackageDetail.contains("正在"),
                   "package size progress did not start with a numeric value")
        guard let finalPackage = packageUpdatesSnapshot.last,
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

    private static func cachedDirectoryPresentationRefreshes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = NSLock()
        var time: TimeInterval = 0
        var blocks = false
        var result = ClipboardDirectorySizeResult.exact(100)
        var calculationCount = 0
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let coordinator = ClipboardDirectorySizeCoordinator(now: {
            lock.lock()
            defer { lock.unlock() }
            return time
        }) { _, _, _, _, progress in
            calculationCount += 1
            progress(5)
            if blocks {
                started.signal()
                _ = release.wait(timeout: .now() + 1)
            }
            lock.lock()
            time += 2
            lock.unlock()
            return result
        }
        _ = coordinator.calculate(at: root, shouldCancel: { false }, onProgress: { _ in })
        var facts: [(String, Bool)] = []
        func enrich() {
            ClipboardFileEnricher.enrich(content: fileContent(url: root), directorySizeCoordinator: coordinator) { update in
                guard case let .fileFacts(_, detail, _, _, _, _, loading) = update else { return }
                lock.lock()
                facts.append((detail, loading))
                lock.unlock()
                if !loading { finished.signal() }
            }
        }
        enrich()
        try expect(finished.wait(timeout: .now() + 1) == .success, "cached display did not finish")
        try expect(calculationCount == 1 && facts.count == 1 && facts[0].0.hasPrefix("上次统计") && !facts[0].1,
                   "fresh cache started another calculation or hid its historical label")
        for refreshedResult in [ClipboardDirectorySizeResult.exact(10), .atLeast(3)] {
            lock.lock()
            time += 30
            facts.removeAll()
            lock.unlock()
            blocks = true
            result = refreshedResult
            enrich()
            try expect(started.wait(timeout: .now() + 1) == .success, "expired cache did not start refreshing")
            lock.lock()
            let initial = facts
            lock.unlock()
            try expect(initial.count == 1 && initial[0].0.hasPrefix("上次统计") && initial[0].1,
                       "refresh progress replaced the historical total with a misleading current lower bound")
            release.signal()
            try expect(finished.wait(timeout: .now() + 1) == .success, "refresh left the loading state active")
            lock.lock()
            let final = facts.last!
            lock.unlock()
            try expect(!final.1 && !final.0.hasPrefix("上次统计"), "refresh retained the cached presentation")
            if case .atLeast = refreshedResult {
                try expect(final.0.hasPrefix("至少"), "partial refresh was presented as an exact size")
            }
        }
        lock.lock()
        facts.removeAll()
        let countBeforeReuse = calculationCount
        lock.unlock()
        enrich()
        try expect(finished.wait(timeout: .now() + 1) == .success, "partial cache did not emit")
        try expect(calculationCount == countBeforeReuse && facts.count == 1
                   && facts[0].0.hasPrefix("上次至少") && !facts[0].1,
                   "partial cache restarted traversal or appeared as an exact/current value")
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

    private static func saturatedDirectoryUsesSessionCancellation() throws {
        let temporary = FileManager.default.temporaryDirectory
        let roots = try (0..<3).map { index -> URL in
            let root = temporary.appendingPathComponent(
                "Copied-saturated-enrichment-\(index)-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try Data([1]).write(to: root.appendingPathComponent("payload"))
            return root
        }
        defer { roots.forEach { try? FileManager.default.removeItem(at: $0) } }
        let started = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
        let release = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
        let coordinator = ClipboardDirectorySizeCoordinator(
            label: "tests.saturated-file-enricher",
            calculator: { root, _, shouldCancel, _, onProgress in
                guard !shouldCancel() else { return .cancelled }
                let index = roots.firstIndex { $0.standardizedFileURL == root.standardizedFileURL }!
                onProgress(1)
                started[index].signal()
                _ = release[index].wait(timeout: .now() + 1)
                return .exact(1)
            }
        )
        for index in 0..<2 {
            let attachment = coordinator.attach(
                to: roots[index],
                observer: { _ in }
            )
            guard attachment != nil else {
                throw Failure.failed("failed to fill background directory slots")
            }
        }
        try expect(started[0].wait(timeout: .now() + 1) == .success
                   && started[1].wait(timeout: .now() + 1) == .success,
                   "background directory slots did not fill")

        var cancelForeground = false
        var updates: [ClipboardEnrichmentUpdate] = []
        ClipboardFileEnricher.enrich(
            content: fileContent(url: roots[2]),
            shouldCancel: { cancelForeground },
            directorySizeCoordinator: coordinator
        ) { update in
            updates.append(update)
            if case let .fileFacts(_, _, _, _, _, _, loading) = update, loading {
                cancelForeground = true
            }
        }
        try expect(cancelForeground, "saturated foreground path did not start numeric progress")
        try expect(updates.allSatisfy {
            guard case let .fileFacts(_, _, _, _, _, _, loading) = $0 else { return false }
            return loading
        }, "session-cancelled saturated path emitted a terminal result")
        release.forEach { $0.signal() }
        let deadline = Date().addingTimeInterval(1)
        while coordinator.inFlightTaskCount != 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        try expect(coordinator.inFlightTaskCount == 0,
                   "saturated-path setup tasks did not finish")
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
