import Foundation
import QuickLookThumbnailing

private enum TestFailure: Error { case failed(String) }

private struct RegistryNoopDetector: ContentDetectorProtocol {
    let kind: ContentKind
    let priority: Int

    func detect(in text: String) -> ContentDetection? {
        ContentDetection(kind: kind, value: text)
    }
}

private final class RegistryReentrantDetector: ContentDetectorProtocol {
    let kind = ContentKind(
        id: "tests.registry.reentrant",
        category: .entity,
        source: .plugin("tests"),
        label: "Test",
        icon: "checkmark"
    )
    let priority = 10_000
    weak var registry: DetectionRegistry?

    func detect(in text: String) -> ContentDetection? {
        let nestedKind = ContentKind(
            id: "tests.registry.nested",
            category: .entity,
            source: .plugin("tests"),
            label: "Nested",
            icon: "checkmark"
        )
        registry?.register(RegistryNoopDetector(kind: nestedKind, priority: 1))
        return ContentDetection(kind: kind, value: text)
    }
}

@main
enum ClipboardPipelineTests {
    static func main() throws {
        try testRevisionIdentity()
        try testRevisionGateRejectsABCUpdates()
        try testLatestOnlyLaneIsBounded()
        try testSessionRetriesAndCancellation()
        try testSoftDeadlineCanBeCancelled()
        try testGraphemeSafeTruncation()
        try testDirectoryOverflowAndPartialBudget()
        try testDirectorySkipsHiddenAndSymlinkTargets()
        try testImageSafetyBounds()
        try testDetectionDisplayFacts()
        try testDetectionRegistryConcurrentMutation()
        try testLateActionLifetime()
        try testQuickLookCancelsExactRequest()
        print("ClipboardPipelineTests: PASS")
    }

    private static func testRevisionGateRejectsABCUpdates() throws {
        let gate = ClipboardRevisionGate()
        let a = ClipboardRevision(generation: 1, changeCount: 1)
        let b = ClipboardRevision(generation: 2, changeCount: 2)
        let c = ClipboardRevision(generation: 3, changeCount: 3)
        gate.activate(a)
        try expect(gate.accept(a), "A should initially be current")
        gate.activate(b)
        gate.activate(c)
        try expect(!gate.accept(a), "late A update reached C")
        try expect(!gate.accept(b), "late B update reached C")
        try expect(gate.accept(c), "C update was rejected")
        try expect(gate.acceptedUpdateCount == 2, "unexpected accepted update count")
    }

    private static func testRevisionIdentity() throws {
        let first = ClipboardRevision(generation: 1, changeCount: 9)
        let second = ClipboardRevision(generation: 2, changeCount: 9)
        try expect(first != second, "generation must distinguish reused changeCount")
    }

    private static func testLatestOnlyLaneIsBounded() throws {
        let lane = ClipboardLatestOnlyLane(label: "test.latest-only")
        let activeStarted = DispatchSemaphore(value: 0)
        let releaseActive = DispatchSemaphore(value: 0)
        let latestFinished = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var ran: [UInt64] = []

        lane.submit(revision: .init(generation: 1, changeCount: 1)) { finish in
            activeStarted.signal()
            _ = releaseActive.wait(timeout: .now() + 2)
            lock.lock(); ran.append(1); lock.unlock()
            finish()
        }
        try expect(activeStarted.wait(timeout: .now() + 1) == .success, "active job did not start")
        for generation in 2...20 {
            lane.submit(revision: .init(generation: UInt64(generation), changeCount: generation)) { finish in
                lock.lock(); ran.append(UInt64(generation)); lock.unlock()
                if generation == 20 { latestFinished.signal() }
                finish()
            }
        }
        Thread.sleep(forTimeInterval: 0.05)
        try expect(lane.snapshot() == .init(activeCount: 1, pendingCount: 1), "lane exceeded 1+1")
        releaseActive.signal()
        try expect(latestFinished.wait(timeout: .now() + 1) == .success, "latest job did not run")
        lock.lock(); let result = ran; lock.unlock()
        try expect(result == [1, 20], "stale pending jobs ran: \(result)")
    }

    private static func testSessionRetriesAndCancellation() throws {
        let revision = ClipboardRevision(generation: 3, changeCount: 7)
        let session = ClipboardLoadSession(revision: revision, backingScale: 2)
        try expect(session.beginBaseAttempt() == 1, "attempt 1")
        try expect(session.beginBaseAttempt() == 2, "attempt 2")
        try expect(session.beginBaseAttempt() == 3, "attempt 3")
        try expect(session.beginBaseAttempt() == nil, "fourth attempt must be rejected")

        var cancelledToken: UUID?
        let token = UUID()
        session.setQuickLookToken(token) { cancelledToken = $0 }
        session.cancelQuickLookRequest()
        try expect(cancelledToken == token, "session must cancel exact QL token")
        try expect(!session.matchesQuickLookToken(token), "cancelled QL token remained current")
        session.cancel()
        try expect(!session.accepts(revision), "cancelled session accepted late result")
    }

    private static func testSoftDeadlineCanBeCancelled() throws {
        let session = ClipboardLoadSession(
            revision: .init(generation: 8, changeCount: 8),
            backingScale: 2
        )
        let retry = DispatchSemaphore(value: 0)
        let retryStarted = ProcessInfo.processInfo.systemUptime
        session.scheduleRetry(queue: .global()) { retry.signal() }
        try expect(retry.wait(timeout: .now() + 1) == .success, "25ms retry did not fire")
        try expect(ProcessInfo.processInfo.systemUptime - retryStarted >= 0.020,
                   "retry ran without the 25ms staging delay")

        let fired = DispatchSemaphore(value: 0)
        _ = session.scheduleSoftDeadline(after: 0.01, queue: .global()) {
            fired.signal()
        }
        try expect(fired.wait(timeout: .now() + 1) == .success, "soft deadline did not fire")

        let cancelled = DispatchSemaphore(value: 0)
        let token = session.scheduleSoftDeadline(after: 0.02, queue: .global()) {
            cancelled.signal()
        }
        session.cancelSoftDeadline(token)
        try expect(cancelled.wait(timeout: .now() + 0.08) == .timedOut,
                   "cancelled soft deadline still fired")
    }

    private static func testGraphemeSafeTruncation() throws {
        let family = "👨‍👩‍👧‍👦"
        let oversized = String(repeating: family, count: 10_000)
        let result = ClipboardExpandedTextPolicy.displayText(for: oversized)
        try expect(result.truncated, "oversized grapheme text was not truncated")
        try expect(result.text.utf16.count <= 65_536, "UTF-16 limit exceeded")
        try expect(!result.text.hasSuffix("‍"), "grapheme was split")

        let lines = Array(repeating: "x", count: 5_000).joined(separator: "\n")
        let lineResult = ClipboardExpandedTextPolicy.displayText(for: lines)
        try expect(lineResult.text.split(separator: "\n", omittingEmptySubsequences: false).count <= 4_096, "line limit exceeded")

        let exactUTF16 = String(repeating: "x", count: 65_536)
        let exactUTF16Result = ClipboardExpandedTextPolicy.displayText(for: exactUTF16)
        try expect(!exactUTF16Result.truncated && exactUTF16Result.text == exactUTF16,
                   "exact UTF-16 boundary was truncated")
        let exactLines = Array(repeating: "x", count: 4_096).joined(separator: "\n")
        try expect(!ClipboardExpandedTextPolicy.displayText(for: exactLines).truncated,
                   "exact line boundary was truncated")

        let hugeTail = String(repeating: "x", count: 2_000_000)
        let hugeTailScan = ClipboardExpandedTextPolicy.scan(hugeTail)
        try expect(hugeTailScan.truncated, "huge tail was not truncated")
        try expect(
            hugeTailScan.examinedGraphemeCount
                == ClipboardExpandedTextPolicy.maximumUTF16Count + 1,
            "huge tail was scanned beyond the first rejected grapheme"
        )
    }

    private static func testDirectoryOverflowAndPartialBudget() throws {
        try expect(
            ClipboardDirectorySizeCalculator.adding(1, to: .max) == .atLeast(.max),
            "directory size overflow must be partial"
        )

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Copied-directory-budget-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<3 {
            _ = FileManager.default.createFile(
                atPath: root.appendingPathComponent("\(index)").path,
                contents: Data([1])
            )
        }
        let limited = ClipboardDirectorySizeCalculator.calculate(
            at: root,
            maximumEntryCount: 1
        )
        guard case .atLeast = limited else {
            throw TestFailure.failed("entry budget must return partial")
        }

        var cancellationChecks = 0
        let cancelled = ClipboardDirectorySizeCalculator.calculate(
            at: root,
            shouldCancel: {
                cancellationChecks += 1
                return cancellationChecks >= 2
            }
        )
        try expect(cancelled == .cancelled,
                   "directory traversal ignored cooperative cancellation")
    }

    private static func testDirectorySkipsHiddenAndSymlinkTargets() throws {
        let temporary = FileManager.default.temporaryDirectory
        let root = temporary.appendingPathComponent(
            "Copied-directory-boundary-test-\(UUID().uuidString)",
            isDirectory: true
        )
        let outside = temporary.appendingPathComponent(
            "Copied-directory-outside-test-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data(repeating: 1, count: 3).write(to: root.appendingPathComponent("visible"))
        try Data(repeating: 2, count: 50).write(to: root.appendingPathComponent(".hidden"))
        try Data(repeating: 3, count: 100).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"),
            withDestinationURL: outside
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try expect(
            ClipboardDirectorySizeCalculator.calculate(at: root) == .exact(3),
            "hidden content or symlink targets were included"
        )
    }

    private static func testImageSafetyBounds() throws {
        try expect(ClipboardImageSafety.permits(width: 10_000, height: 10_000), "100MP boundary")
        try expect(!ClipboardImageSafety.permits(width: 10_001, height: 10_000), "pixel limit")
        try expect(!ClipboardImageSafety.permits(width: 32_769, height: 1), "edge limit")
        try expect(!ClipboardImageSafety.permits(width: 0, height: 100), "zero edge")
        try expect(
            ClipboardImageSafety.permitsGeneratedThumbnail(
                width: 256,
                height: 128,
                maxPixelSize: 256
            ),
            "bounded generated thumbnail was rejected"
        )
        try expect(
            !ClipboardImageSafety.permitsGeneratedThumbnail(
                width: 257,
                height: 128,
                maxPixelSize: 256
            ),
            "oversized generated thumbnail was accepted"
        )
    }

    private static func testDetectionDisplayFacts() throws {
        for kind in [ContentKind.url, .swift, .englishPhrase, .colorHex] {
            let detection = ContentDetection(kind: kind, value: nil)
            let facts = ClipboardDetectionDisplayFacts.derive(from: [detection])
            try expect(facts?.typeLabel == kind.label, "detection label did not follow primary kind")
            try expect(facts?.iconSymbolName == kind.icon, "detection icon did not follow primary kind")
        }

        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let dateDetection = ContentDetection(
            kind: .dateTime,
            value: String(date.timeIntervalSinceReferenceDate),
            metadata: ["subtype": "dateTime"]
        )
        let dateFacts = ClipboardDetectionDisplayFacts.derive(
            from: [dateDetection],
            relativeTo: date
        )
        try expect(dateFacts?.typeLabel == ContentKind.dateTime.label,
                   "date detection label was not restored")
        try expect(dateFacts?.iconSymbolName == ContentKind.dateTime.icon,
                   "date detection icon was not restored")
        try expect(dateFacts?.detailOverride?.isEmpty == false,
                   "date detection relative detail was not restored")
    }

    private static func testDetectionRegistryConcurrentMutation() throws {
        let registry = DetectionRegistry()
        let reentrant = RegistryReentrantDetector()
        reentrant.registry = registry
        registry.register(reentrant)

        let reentrantFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = registry.detectAll(in: "synthetic")
            reentrantFinished.signal()
        }
        try expect(reentrantFinished.wait(timeout: .now() + 2) == .success,
                   "DetectionRegistry held its state lock while a detector ran")

        let queue = DispatchQueue(
            label: "tests.registry.concurrent",
            attributes: .concurrent
        )
        let group = DispatchGroup()
        for worker in 0..<4 {
            group.enter()
            queue.async {
                for index in 0..<100 {
                    let kind = ContentKind(
                        id: "tests.registry.\(worker).\(index)",
                        category: .language,
                        source: .plugin("tests"),
                        label: "Test",
                        icon: "checkmark"
                    )
                    registry.register(RegistryNoopDetector(kind: kind, priority: index))
                    if index.isMultiple(of: 2) {
                        registry.unregister(kind: kind)
                    }
                    _ = registry.allRegisteredKinds
                    _ = registry.activeDetectors
                    _ = registry.detectAll(in: "synthetic")
                }
                group.leave()
            }
        }
        try expect(group.wait(timeout: .now() + 8) == .success,
                   "concurrent registry mutation/read stress did not finish")
    }

    private static func testLateActionLifetime() throws {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let shortDeadline = now.addingTimeInterval(0.2)
        try expect(
            ClipboardPresentationLifetime.delayGuaranteeingMinimumActionTime(
                deadline: shortDeadline,
                now: now,
                minimum: 1.5
            ) == 1.5,
            "late action must receive 1.5 seconds"
        )
        let longDeadline = now.addingTimeInterval(2)
        try expect(
            ClipboardPresentationLifetime.delayGuaranteeingMinimumActionTime(
                deadline: longDeadline,
                now: now,
                minimum: 1.5
            ) == nil,
            "early action must not shorten the existing timer"
        )
    }

    private static func testQuickLookCancelsExactRequest() throws {
        var generated: QLThumbnailGenerator.Request?
        var cancelled: QLThumbnailGenerator.Request?
        let generator = FilePreviewGenerator(backend: .init(
            generate: { request, _ in generated = request },
            cancel: { request in cancelled = request }
        ))
        let token = generator.generateThumbnail(
            for: URL(fileURLWithPath: "/tmp/Copied-ql-request-test"),
            size: CGSize(width: 32, height: 32),
            scale: 2,
            revision: .init(generation: 1, changeCount: 1)
        ) { _, _, _ in }
        generator.cancel(token: token)
        guard let generated, let cancelled else {
            throw TestFailure.failed("QL backend did not receive requests")
        }
        try expect(generated === cancelled, "QL cancellation used a different request object")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure.failed(message) }
    }
}
