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

private final class DirectoryTestClock {
    private let lock = NSLock()
    private var time: TimeInterval = 0

    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return time
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        time += interval
        lock.unlock()
    }
}

@main
enum ClipboardPipelineTests {
    private static let registryNotificationChildArgument = "--registry-notification-child"

    static func main() throws {
        if CommandLine.arguments.contains(registryNotificationChildArgument) {
            try testDetectionRegistryNotificationReentryChild()
            return
        }

        try testRevisionIdentity()
        try testRevisionGateRejectsABCUpdates()
        try testLatestOnlyLaneIsBounded()
        try testSessionRetriesAndCancellation()
        try testSoftDeadlineCanBeCancelled()
        try testGraphemeSafeTruncation()
        try testDirectoryOverflowAndTimeBudget()
        try testDirectorySizeFreshness()
        try testDirectorySizeCoordinator()
        try testAdaptiveDirectoryCache()
        try testDirectoryObservationCancellation()
        try testDirectoryProgressReporting()
        try testDirectoryIncludesHiddenAndSkipsSymlinkTargets()
        try testDirectoryTraversesNestedPackageContents()
        try testImageSafetyBounds()
        try testBuiltInDetectionSkipsGenericCodeFallback()
        try testDetectionDisplayFacts()
        try testDetectionRegistryNotificationReentry()
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

    private static func testDirectoryOverflowAndTimeBudget() throws {
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
        var nowCallCount = 0
        let timeLimited = ClipboardDirectorySizeCalculator.calculate(
            at: root,
            now: {
                nowCallCount += 1
                return nowCallCount < 4 ? 0 : 31
            }
        )
        try expect(timeLimited == .atLeast(1),
                   "time budget must retain the leaf size accumulated before expiry")

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

    private static func testDirectorySizeFreshness() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = nested.appendingPathComponent("payload")
        let coordinator = ClipboardDirectorySizeCoordinator()
        for size in [10, 1_000] {
            try Data(repeating: 1, count: size).write(to: payload)
            let finished = DispatchSemaphore(value: 0)
            var result: ClipboardDirectorySizeResult?
            var owner: NSObject? = NSObject()
            weak var weakOwner = owner
            let observation = coordinator.attach(to: root) { [owner = owner!] event in
                withExtendedLifetime(owner) {
                    if case let .terminal(value) = event {
                        result = value
                        finished.signal()
                    }
                }
            }
            owner = nil
            try expect(observation != nil, "fresh directory traversal did not start")
            try expect(finished.wait(timeout: .now() + 2) == .success, "fresh traversal timed out")
            try expect(result == .exact(Int64(size)), "deep file edit reused an old directory size")
            let deadline = Date().addingTimeInterval(1)
            while weakOwner != nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            withExtendedLifetime(observation) {
                precondition(weakOwner == nil, "finished traversal retains its observer payload")
            }
        }
    }

    private static func testDirectorySizeCoordinator() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let other = root.appendingPathComponent("other")
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let coordinator = ClipboardDirectorySizeCoordinator(calculator: { _, duration, shouldCancel, interval, progress in
            guard duration == 30 && interval == 0.25 else { return .unavailable }
            progress(5)
            started.signal()
            _ = release.wait(timeout: .now() + 2)
            return shouldCancel() ? .cancelled : .exact(5)
        })
        let first = coordinator.attach(to: root) { event in
            if case .terminal = event { finished.signal() }
        }
        try expect(started.wait(timeout: .now() + 1) == .success, "first traversal did not start")
        var reattachedProgress: Int64?
        let second = coordinator.attach(to: root.appendingPathComponent(".").standardizedFileURL) { event in
            if case let .progress(size) = event { reattachedProgress = size }
            if case .terminal = event { finished.signal() }
        }
        try expect(first != nil && second != nil && first?.id != second?.id,
                   "shared traversal did not return independent observations")
        try expect(coordinator.inFlightTaskCount == 1 && reattachedProgress == 5,
                   "repeat copy did not reuse its running traversal/progress")
        _ = coordinator.attach(to: other) { _ in }
        try expect(started.wait(timeout: .now() + 1) == .success, "second directory did not start")
        try expect(coordinator.attach(to: root.appendingPathComponent("third"), observer: { _ in }) == nil,
                   "directory workers exceeded their bound")
        first?.cancel()
        try expect(coordinator.inFlightTaskCount == 2, "detach cancelled a shared worker")
        release.signal()
        release.signal()
        try expect(finished.wait(timeout: .now() + 1) == .success, "remaining observer lost its result")
        try expect(finished.wait(timeout: .now() + 0.05) == .timedOut, "detached observer received a terminal event")
        try waitForDirectoryTasks(coordinator)

        let backgroundStarted = DispatchSemaphore(value: 0)
        let backgroundRelease = DispatchSemaphore(value: 0)
        let clock = DirectoryTestClock()
        let background = ClipboardDirectorySizeCoordinator(now: { clock.now }) { _, _, shouldCancel, _, _ in
            backgroundStarted.signal()
            _ = backgroundRelease.wait(timeout: .now() + 2)
            clock.advance(2)
            return shouldCancel() ? .cancelled : .exact(123)
        }
        let session = ClipboardLoadSession(revision: .init(generation: 1, changeCount: 1), backingScale: 2)
        var owner: NSObject? = NSObject()
        weak var weakOwner = owner
        session.setDirectorySizeObservation(background.attach(to: root) { [owner = owner!] _ in
            withExtendedLifetime(owner) {}
        }!)
        owner = nil
        try expect(backgroundStarted.wait(timeout: .now() + 1) == .success, "background traversal did not start")
        session.cancel()
        try expect(weakOwner == nil && background.inFlightTaskCount == 1,
                   "dismiss either retained the UI observer or cancelled background work")
        backgroundRelease.signal()
        try waitForDirectoryTasks(background)
        var cached: ClipboardDirectorySizeTaskEvent?
        _ = background.attach(to: root) { cached = $0 }
        try expect(cached == .cached(123, isRefreshing: false), "dismissed traversal did not populate cache")

        let cancelled = DispatchSemaphore(value: 0)
        let unblock = DispatchSemaphore(value: 0)
        let cancellationCoordinator = ClipboardDirectorySizeCoordinator(calculator: { _, _, shouldCancel, _, _ in
            while !shouldCancel() { Thread.sleep(forTimeInterval: 0.001) }
            cancelled.signal()
            _ = unblock.wait(timeout: .now() + 1)
            return .exact(99)
        })
        _ = cancellationCoordinator.attach(to: root) { _ in }
        cancellationCoordinator.cancelAll()
        try expect(cancelled.wait(timeout: .now() + 1) == .success, "cancelAll did not cancel its worker")
        try expect(cancellationCoordinator.inFlightTaskCount == 1, "cancelAll freed a blocked worker slot")
        unblock.signal()
        try waitForDirectoryTasks(cancellationCoordinator)
        background.cancelAll()
        var restartedEvent: ClipboardDirectorySizeTaskEvent?
        let restarted = background.attach(to: root) { if restartedEvent == nil { restartedEvent = $0 } }
        try expect(restartedEvent == .progress(0), "pause retained a previous cached result")
        restarted?.cancel()
        background.cancelAll()
        backgroundRelease.signal()
        try waitForDirectoryTasks(background)
    }

    private static func waitForDirectoryTasks(_ coordinator: ClipboardDirectorySizeCoordinator) throws {
        let deadline = Date().addingTimeInterval(2)
        while coordinator.inFlightTaskCount != 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        try expect(coordinator.inFlightTaskCount == 0, "completed workers retained their slots")
    }

    private static func testAdaptiveDirectoryCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for duration in [0.5, 1.0, 1.001] {
            let clock = DirectoryTestClock()
            var count = 0
            let coordinator = ClipboardDirectorySizeCoordinator(now: { clock.now }) { _, _, _, _, _ in
                count += 1
                clock.advance(duration)
                return .exact(Int64(count))
            }
            _ = coordinator.calculate(at: root, shouldCancel: { false }, onProgress: { _ in })
            let terminal = DispatchSemaphore(value: 0)
            var events: [ClipboardDirectorySizeTaskEvent] = []
            _ = coordinator.attach(to: root) { event in
                events.append(event)
                if case .terminal = event { terminal.signal() }
                if case .cached(_, _, false) = event { terminal.signal() }
            }
            try expect(terminal.wait(timeout: .now() + 1) == .success, "threshold case did not finish")
            try expect(duration > 1 ? events == [.cached(1, isRefreshing: false)] : events.last == .terminal(.exact(2)),
                       "strict one-second cache threshold changed")
            try expect(count == (duration > 1 ? 1 : 2), "fast directory reused a complete result")
        }

        let clock = DirectoryTestClock()
        var duration: TimeInterval = 2
        var result = ClipboardDirectorySizeResult.exact(100)
        let coordinator = ClipboardDirectorySizeCoordinator(now: { clock.now }) { _, _, _, _, progress in
            progress(5)
            clock.advance(duration)
            return result
        }
        _ = coordinator.calculate(at: root, shouldCancel: { false }, onProgress: { _ in })
        clock.advance(29.999)
        var cached: ClipboardDirectorySizeTaskEvent?
        _ = coordinator.attach(to: root) { cached = $0 }
        try expect(cached == .cached(100, isRefreshing: false), "cache expired before 30 seconds after completion")
        clock.advance(0.001)
        result = .exact(10)
        let terminal = DispatchSemaphore(value: 0)
        var events: [ClipboardDirectorySizeTaskEvent] = []
        _ = coordinator.attach(to: root) { event in
            events.append(event)
            if case .terminal = event { terminal.signal() }
        }
        try expect(terminal.wait(timeout: .now() + 1) == .success, "expired cache did not refresh")
        try expect(events.first == .cached(100, isRefreshing: true) && events.last == .terminal(.exact(10)),
                   "refresh did not distinguish old cached size from a smaller current result")
        duration = 1
        _ = coordinator.calculate(at: root, shouldCancel: { false }, onProgress: { _ in })
        events.removeAll()
        _ = coordinator.attach(to: root) { event in
            events.append(event)
            if case .terminal = event { terminal.signal() }
        }
        try expect(terminal.wait(timeout: .now() + 1) == .success, "now-fast directory did not recalculate")
        try expect(events.first == .progress(0), "fast refresh failed to remove the previous slow cache")

        duration = 2
        result = .atLeast(7)
        _ = coordinator.calculate(at: root, shouldCancel: { false }, onProgress: { _ in })
        events.removeAll()
        _ = coordinator.attach(to: root) { event in
            events.append(event)
            if case .terminal = event { terminal.signal() }
            if case .cached = event { terminal.signal() }
        }
        try expect(terminal.wait(timeout: .now() + 1) == .success, "partial result reuse did not finish")
        try expect(events == [.cached(7, isPartial: true, isRefreshing: false)],
                   "slow partial result restarted traversal or lost its lower-bound status")


        clock.advance(30)
        result = .exact(4)
        events.removeAll()
        _ = coordinator.attach(to: root) { event in
            events.append(event)
            if case .terminal = event { terminal.signal() }
        }
        try expect(terminal.wait(timeout: .now() + 1) == .success, "expired partial cache did not refresh")
        try expect(events.first == .cached(7, isPartial: true, isRefreshing: true)
                   && events.last == .terminal(.exact(4)), "partial refresh lost its label or smaller final result")
        for uncacheable in [ClipboardDirectorySizeResult.unavailable, .cancelled] {
            let empty = ClipboardDirectorySizeCoordinator(now: { clock.now }) { _, _, _, _, _ in
                clock.advance(2)
                return uncacheable
            }
            _ = empty.calculate(at: root, shouldCancel: { false }, onProgress: { _ in })
            var initial: ClipboardDirectorySizeTaskEvent?
            _ = empty.attach(to: root) { if initial == nil { initial = $0 } }
            try waitForDirectoryTasks(empty)
            try expect(initial == .progress(0), "unavailable or cancelled result became cached size")
        }

        result = .exact(10)
        for index in 0...ClipboardDirectorySizeCoordinator.maximumCachedResultCount {
            _ = coordinator.calculate(at: root.appendingPathComponent(String(index)), shouldCancel: { false }, onProgress: { _ in })
        }
        events.removeAll()
        _ = coordinator.attach(to: root.appendingPathComponent("0")) { event in
            events.append(event)
            if case .terminal = event { terminal.signal() }
        }
        try expect(terminal.wait(timeout: .now() + 1) == .success, "evicted directory did not restart")
        try expect(events.first == .progress(0), "historical cache exceeded its entry bound")
    }

    private static func testDirectoryObservationCancellation() throws {
        let revision = ClipboardRevision(generation: 21, changeCount: 21)
        let firstSession = ClipboardLoadSession(revision: revision, backingScale: 2)
        var firstDetachCount = 0
        firstSession.setDirectorySizeObservation(
            ClipboardDirectorySizeObservation { firstDetachCount += 1 }
        )
        firstSession.cancel()
        try expect(firstDetachCount == 1, "session cancellation did not detach its observer")

        let cancelledSession = ClipboardLoadSession(revision: revision, backingScale: 2)
        cancelledSession.cancel()
        var lateDetachCount = 0
        cancelledSession.setDirectorySizeObservation(
            ClipboardDirectorySizeObservation { lateDetachCount += 1 }
        )
        try expect(lateDetachCount == 1,
                   "observation registered after cancellation was not detached immediately")

        let completedSession = ClipboardLoadSession(revision: revision, backingScale: 2)
        var completedDetachCount = 0
        completedSession.setDirectorySizeObservation(
            ClipboardDirectorySizeObservation { completedDetachCount += 1 }
        )
        completedSession.clearDirectorySizeObservation()
        completedSession.cancel()
        try expect(completedDetachCount == 0,
                   "completed directory observation remained attached to the session")
    }

    private static func testDirectoryProgressReporting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Copied-directory-progress-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<3 {
            try Data([1]).write(to: root.appendingPathComponent("\(index)"))
        }

        var progress: [Int64] = []
        let result = ClipboardDirectorySizeCalculator.calculate(
            at: root,
            progressUpdateInterval: 0,
            onProgress: { progress.append($0) }
        )
        try expect(result == .exact(3), "progress reporting changed the final directory size")
        try expect(progress == [1, 2, 3],
                   "directory progress was not monotonic or did not report each test update")
    }

    private static func testDirectoryIncludesHiddenAndSkipsSymlinkTargets() throws {
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
        let hiddenDirectory = root.appendingPathComponent(".hidden-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: false)
        try Data(repeating: 3, count: 7).write(to: hiddenDirectory.appendingPathComponent("content"))
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
            ClipboardDirectorySizeCalculator.calculate(at: root) == .exact(60),
            "hidden content was excluded or a symlink target was included"
        )
    }

    private static func testDirectoryTraversesNestedPackageContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Copied-directory-package-test-\(UUID().uuidString)",
            isDirectory: true
        )
        let resources = root.appendingPathComponent(
            "Nested.app/Contents/Resources",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 17).write(to: resources.appendingPathComponent("payload"))

        try expect(
            ClipboardDirectorySizeCalculator.calculate(at: root) == .exact(17),
            "nested package descendants were skipped or the package directory was counted"
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

    private static func testBuiltInDetectionSkipsGenericCodeFallback() throws {
        let registry = DetectionRegistry()
        registry.registerBuiltInDetectors()

        let registeredKindIDs = Set(registry.allRegisteredKinds.map(\.id))
        try expect(!registeredKindIDs.contains(ContentKind.code.id),
                   "generic code fallback is still registered")
        for kind in [ContentKind.html, .swift, .python, .javascript, .css] {
            try expect(registeredKindIDs.contains(kind.id),
                       "specific language detector is missing: \(kind.id)")
        }

        let longProse = String(
            repeating: "这是一段普通小说文字，for 表示英文介词。",
            count: 3_000
        )
        try expect(longProse.utf8.count > DetectionRegistry.textLengthCutoff,
                   "synthetic prose no longer exercises the oversized-text path")
        let detections = registry.detectAll(in: longProse)
        try expect(!detections.contains { $0.kind.id == ContentKind.code.id },
                   "a lone natural-language keyword still becomes generic code")
    }

    private static func testDetectionRegistryConcurrentMutation() throws {
        let suiteName = "com.copied.registry-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = DetectionRegistry(defaults: defaults)
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
        let toggledKindIDs = Set((0..<4).flatMap { worker in
            (0..<100).map { "tests.registry.\(worker).\($0)" }
        })
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
                    registry.setEnabled(false, kindID: kind.id)
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
        try expect(
            Set(defaults.stringArray(forKey: "disabledContentKinds") ?? []) == toggledKindIDs,
            "concurrent disables lost a persisted kind ID"
        )

        let enabledKindIDs = Set((0..<4).flatMap { worker in
            stride(from: 0, to: 100, by: 2).map { "tests.registry.\(worker).\($0)" }
        })
        let enableGroup = DispatchGroup()
        for kindID in enabledKindIDs {
            enableGroup.enter()
            queue.async {
                registry.setEnabled(true, kindID: kindID)
                _ = registry.activeDetectors
                enableGroup.leave()
            }
        }
        try expect(enableGroup.wait(timeout: .now() + 8) == .success,
                   "concurrent registry enables did not finish")
        try expect(
            Set(defaults.stringArray(forKey: "disabledContentKinds") ?? [])
                == toggledKindIDs.subtracting(enabledKindIDs),
            "concurrent enables lost a persisted kind ID"
        )

        let pluginID = "tests.registry.uninstall"
        let pluginKind = ContentKind(
            id: pluginID,
            category: .entity,
            source: .plugin(pluginID),
            label: "Test",
            icon: "checkmark"
        )
        registry.register(RegistryNoopDetector(kind: pluginKind, priority: 1))
        registry.setEnabled(false, kindID: pluginID)
        registry.unregisterPlugin(identifier: pluginID)
        registry.setEnabled(true, kindID: pluginID)
        try expect(!registry.allRegisteredKinds.contains { $0.id == pluginID },
                   "plugin uninstall sequence left its detector registered")
        try expect(registry.isEnabled(kindID: pluginID),
                   "plugin uninstall sequence left its disabled state persisted")
    }

    private static func testDetectionRegistryNotificationReentry() throws {
        let executable = URL(
            fileURLWithPath: CommandLine.arguments[0],
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ).standardizedFileURL
        let process = Process()
        let output = Pipe()
        let completed = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = [registryNotificationChildArgument]
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { _ in completed.signal() }
        try process.run()

        let timeout: DispatchTimeInterval = ProcessInfo.processInfo.environment["TSAN_OPTIONS"] == nil
            ? .seconds(2)
            : .seconds(15)
        guard completed.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = completed.wait(timeout: .now() + 1)
            throw TestFailure.failed(
                "setEnabled deadlocked when a synchronous UserDefaults notification reread the registry"
            )
        }
        let childOutput = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        try expect(process.terminationStatus == 0,
                   "notification reentry child failed: \(childOutput)")
    }

    private static func testDetectionRegistryNotificationReentryChild() throws {
        let suiteName = "com.copied.registry-notification-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = DetectionRegistry(defaults: defaults)
        registry.register(RegistryNoopDetector(
            kind: ContentKind(
                id: "tests.registry.notification",
                category: .entity,
                source: .plugin("tests"),
                label: "Test",
                icon: "checkmark"
            ),
            priority: 1
        ))
        let callback = DispatchSemaphore(value: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { _ in
            _ = registry.allRegisteredKinds
            _ = registry.activeDetectors
            callback.signal()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        registry.setEnabled(false, kindID: "tests.registry.notification")
        try expect(callback.wait(timeout: .now()) == .success,
                   "synthetic UserDefaults notification did not run synchronously")
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
