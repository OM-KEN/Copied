import Foundation

struct ClipboardRevision: Hashable {
    let generation: UInt64
    let changeCount: Int
}

/// The reducer's sole revision identity check. Fingerprints never participate.
final class ClipboardRevisionGate {
    private let lock = NSLock()
    private var currentRevision: ClipboardRevision?
    private(set) var acceptedUpdateCount = 0
    private(set) var rejectedUpdateCount = 0

    func activate(_ revision: ClipboardRevision) {
        lock.withLock { currentRevision = revision }
    }

    func accept(_ revision: ClipboardRevision) -> Bool {
        lock.withLock {
            if currentRevision == revision {
                acceptedUpdateCount += 1
                return true
            }
            rejectedUpdateCount += 1
            return false
        }
    }
}

enum ClipboardPresentationLifetime {
    static func delayGuaranteeingMinimumActionTime(
        deadline: Date?,
        now: Date,
        minimum: TimeInterval
    ) -> TimeInterval? {
        let remaining = deadline?.timeIntervalSince(now) ?? 0
        return remaining < minimum ? minimum : nil
    }
}

enum ClipboardImageSafety {
    static let maximumDimension = 32_768
    static let maximumPixelCount = 100_000_000

    static func permits(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0,
              width <= maximumDimension, height <= maximumDimension else { return false }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return !overflow && pixels <= maximumPixelCount
    }

    static func permitsGeneratedThumbnail(
        width: Int,
        height: Int,
        maxPixelSize: Int
    ) -> Bool {
        width > 0 && height > 0
            && width <= maxPixelSize && height <= maxPixelSize
    }
}

/// One non-preemptive worker and one replaceable pending job.
/// A blocked system call may keep the active slot occupied; newer pending work stays bounded.
final class ClipboardLatestOnlyLane {
    struct Snapshot: Equatable {
        let activeCount: Int
        let pendingCount: Int
    }

    private struct Job {
        let revision: ClipboardRevision
        let run: (@escaping () -> Void) -> Void
    }

    private let stateQueue: DispatchQueue
    private let workerQueue: DispatchQueue
    private var active: Job?
    private var pending: Job?

    init(label: String) {
        stateQueue = DispatchQueue(label: "\(label).state")
        workerQueue = DispatchQueue(label: "\(label).worker", qos: .userInitiated)
    }

    func submit(
        revision: ClipboardRevision,
        run: @escaping (@escaping () -> Void) -> Void
    ) {
        let job = Job(revision: revision, run: run)
        stateQueue.async { [weak self] in
            guard let self else { return }
            if active == nil {
                start(job)
            } else {
                pending = job
            }
        }
    }

    func discardPending(olderThan revision: ClipboardRevision) {
        stateQueue.async { [weak self] in
            guard let self, let pending, pending.revision != revision else { return }
            self.pending = nil
        }
    }

    func snapshot() -> Snapshot {
        stateQueue.sync {
            Snapshot(
                activeCount: active == nil ? 0 : 1,
                pendingCount: pending == nil ? 0 : 1
            )
        }
    }

    private func start(_ job: Job) {
        active = job
        workerQueue.async { [weak self] in
            let completionLock = NSLock()
            var didFinish = false
            job.run {
                completionLock.lock()
                guard !didFinish else {
                    completionLock.unlock()
                    return
                }
                didFinish = true
                completionLock.unlock()
                self?.finish(job)
            }
        }
    }

    private func finish(_ job: Job) {
        stateQueue.async { [weak self] in
            guard let self, active?.revision == job.revision else { return }
            active = nil
            if let next = pending {
                pending = nil
                start(next)
            }
        }
    }
}

final class ClipboardLoadSession {
    let revision: ClipboardRevision
    let backingScale: CGFloat

    private let lock = NSLock()
    private var cancelled = false
    private var baseAttempts = 0
    private var retryItems: [DispatchWorkItem] = []
    private var softDeadlineItems: [UUID: DispatchWorkItem] = [:]
    private var payload: Any?
    private var imageData: Data?
    private var quickLookToken: UUID?
    private var cancelQuickLook: ((UUID) -> Void)?
    private var directorySizeObservation: ClipboardDirectorySizeObservation?

    init(revision: ClipboardRevision, backingScale: CGFloat) {
        self.revision = revision
        self.backingScale = backingScale
    }

    func beginBaseAttempt() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, baseAttempts < 3 else { return nil }
        baseAttempts += 1
        return baseAttempts
    }

    var attemptCount: Int {
        lock.withLock { baseAttempts }
    }

    func accepts(_ revision: ClipboardRevision) -> Bool {
        lock.withLock { !cancelled && self.revision == revision }
    }

    func scheduleRetry(
        after delay: TimeInterval = 0.025,
        queue: DispatchQueue = .main,
        _ action: @escaping () -> Void
    ) {
        let item = DispatchWorkItem { [weak self] in
            guard let self, accepts(revision) else { return }
            action()
        }
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        retryItems.append(item)
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancelScheduledWorkItems() {
        let items = lock.withLock { () -> [DispatchWorkItem] in
            let current = retryItems + Array(softDeadlineItems.values)
            retryItems.removeAll()
            softDeadlineItems.removeAll()
            return current
        }
        items.forEach { $0.cancel() }
    }

    @discardableResult
    func scheduleSoftDeadline(
        after delay: TimeInterval,
        queue: DispatchQueue = .main,
        _ action: @escaping () -> Void
    ) -> UUID {
        let token = UUID()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.accepts(self.revision) else { return }
            _ = self.lock.withLock {
                self.softDeadlineItems.removeValue(forKey: token)
            }
            action()
        }
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            item.cancel()
            return token
        }
        softDeadlineItems[token] = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return token
    }

    func cancelSoftDeadline(_ token: UUID) {
        let item = lock.withLock { softDeadlineItems.removeValue(forKey: token) }
        item?.cancel()
    }

    func hasPendingSoftDeadline(_ token: UUID) -> Bool {
        lock.withLock { softDeadlineItems[token] != nil }
    }

    func storePayload<T>(_ value: T) {
        lock.withLock { payload = value }
    }

    func payload<T>(as type: T.Type = T.self) -> T? {
        lock.withLock { payload as? T }
    }

    func storeImageData(_ data: Data?) {
        lock.withLock { imageData = data }
    }

    func takeImageData() -> Data? {
        lock.withLock {
            defer { imageData = nil }
            return imageData
        }
    }

    func setQuickLookToken(
        _ token: UUID,
        cancel: @escaping (UUID) -> Void
    ) {
        var tokenToCancel: UUID?
        lock.lock()
        if cancelled {
            tokenToCancel = token
        } else {
            quickLookToken = token
            cancelQuickLook = cancel
        }
        lock.unlock()
        if let tokenToCancel { cancel(tokenToCancel) }
    }

    func matchesQuickLookToken(_ token: UUID) -> Bool {
        lock.withLock { !cancelled && quickLookToken == token }
    }

    func clearQuickLookToken(_ token: UUID) {
        lock.withLock {
            guard quickLookToken == token else { return }
            quickLookToken = nil
            cancelQuickLook = nil
        }
    }

    func cancelQuickLookRequest() {
        let token: UUID?
        let cancel: ((UUID) -> Void)?
        lock.lock()
        token = quickLookToken
        cancel = cancelQuickLook
        quickLookToken = nil
        cancelQuickLook = nil
        lock.unlock()
        if let token, let cancel { cancel(token) }
    }

    func setDirectorySizeObservation(_ observation: ClipboardDirectorySizeObservation) {
        let previous: ClipboardDirectorySizeObservation?
        let cancelNew: Bool
        lock.lock()
        if cancelled {
            previous = nil
            cancelNew = true
        } else {
            previous = directorySizeObservation
            directorySizeObservation = observation
            cancelNew = false
        }
        lock.unlock()
        previous?.cancel()
        if cancelNew { observation.cancel() }
    }

    func clearDirectorySizeObservation() {
        lock.withLock { directorySizeObservation = nil }
    }

    func cancel() {
        let items: [DispatchWorkItem]
        let token: UUID?
        let cancel: ((UUID) -> Void)?
        let directoryObservation: ClipboardDirectorySizeObservation?
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        items = retryItems
        retryItems.removeAll()
        let deadlineItems = Array(softDeadlineItems.values)
        softDeadlineItems.removeAll()
        payload = nil
        imageData = nil
        token = quickLookToken
        cancel = cancelQuickLook
        quickLookToken = nil
        cancelQuickLook = nil
        directoryObservation = directorySizeObservation
        directorySizeObservation = nil
        lock.unlock()

        (items + deadlineItems).forEach { $0.cancel() }
        if let token, let cancel { cancel(token) }
        directoryObservation?.cancel()
    }
}

enum ClipboardExpandedTextPolicy {
    static let maximumUTF16Count = 65_536
    static let maximumLineCount = 4_096

    static func displayText(for fullText: String) -> (text: String, truncated: Bool) {
        let scan = scan(fullText)
        guard scan.truncated else { return (fullText, false) }
        return (String(fullText[..<scan.end]), true)
    }

    static func scan(
        _ fullText: String
    ) -> (end: String.Index, truncated: Bool, examinedGraphemeCount: Int) {
        var utf16Count = 0
        var lineCount = 1
        var end = fullText.startIndex
        var examinedGraphemeCount = 0
        for character in fullText {
            examinedGraphemeCount += 1
            let units = String(character).utf16.count
            let addsLine = character == "\n"
            if utf16Count + units > maximumUTF16Count
                || (addsLine && lineCount >= maximumLineCount) {
                return (end, true, examinedGraphemeCount)
            }
            utf16Count += units
            if addsLine { lineCount += 1 }
            end = fullText.index(after: end)
        }
        return (end, false, examinedGraphemeCount)
    }
}

enum ClipboardDirectorySizeResult: Equatable {
    case exact(Int64)
    case atLeast(Int64)
    case unavailable
    case cancelled
}

enum ClipboardDirectorySizeTaskEvent: Equatable {
    case cached(Int64, isPartial: Bool = false, isRefreshing: Bool)
    case progress(Int64)
    case terminal(ClipboardDirectorySizeResult)
}

final class ClipboardDirectorySizeObservation: @unchecked Sendable {
    let id: UUID
    private let lock = NSLock()
    private var cancellation: (() -> Void)?

    init(id: UUID = UUID(), cancellation: @escaping () -> Void) {
        self.id = id
        self.cancellation = cancellation
    }

    func cancel() {
        let action = lock.withLock { () -> (() -> Void)? in
            defer { cancellation = nil }
            return cancellation
        }
        action?()
    }
}

final class ClipboardDirectorySizeCoordinator: @unchecked Sendable {
    typealias Calculator = (
        URL, TimeInterval, @escaping () -> Bool, TimeInterval, @escaping (Int64) -> Void
    ) -> ClipboardDirectorySizeResult

    static let shared = ClipboardDirectorySizeCoordinator()
    static let slowDirectoryThreshold: TimeInterval = 1
    static let cacheLifetime: TimeInterval = 30
    static let maximumCachedResultCount = 32
    static let maximumDetachedTaskCount = 2
    static let maximumDuration: TimeInterval = 30
    static let progressUpdateInterval: TimeInterval = 0.25

    private struct CachedSize {
        let size: Int64
        let isPartial: Bool
        let completedAt: TimeInterval
    }

    private final class Task {
        let root: URL
        var observers: [UUID: (ClipboardDirectorySizeTaskEvent) -> Void] = [:]
        var latestLowerBound: Int64 = 0
        var cancelled = false

        init(root: URL) { self.root = root }
    }

    private let stateQueue: DispatchQueue
    private let workerQueue: DispatchQueue
    private let now: () -> TimeInterval
    private let calculator: Calculator
    private var tasks: [String: Task] = [:]
    private var cachedSizes: [String: CachedSize] = [:]
    private var cancellationGeneration = 0

    init(
        label: String = "com.copied.clipboard.directory-size",
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        calculator: @escaping Calculator = { root, duration, shouldCancel, interval, progress in
            ClipboardDirectorySizeCalculator.calculate(
                at: root,
                maximumDuration: duration,
                shouldCancel: shouldCancel,
                progressUpdateInterval: interval,
                onProgress: progress
            )
        }
    ) {
        stateQueue = DispatchQueue(label: "\(label).state")
        workerQueue = DispatchQueue(label: "\(label).worker", qos: .utility, attributes: .concurrent)
        self.now = now
        self.calculator = calculator
    }

    func attach(
        to root: URL,
        observer: @escaping (ClipboardDirectorySizeTaskEvent) -> Void
    ) -> ClipboardDirectorySizeObservation? {
        let root = root.standardizedFileURL
        let key = root.path
        var initialEvent = ClipboardDirectorySizeTaskEvent.progress(0)
        var taskToStart: Task?
        let observation: ClipboardDirectorySizeObservation? = stateQueue.sync {
            let cached = cachedSizes[key]
            if let task = tasks[key], !task.cancelled {
                initialEvent = cached.map { .cached($0.size, isPartial: $0.isPartial, isRefreshing: true) }
                    ?? .progress(task.latestLowerBound)
                return makeObservation(for: task, observer: observer)
            }
            if let cached, now() - cached.completedAt < Self.cacheLifetime {
                initialEvent = .cached(cached.size, isPartial: cached.isPartial, isRefreshing: false)
                return ClipboardDirectorySizeObservation(cancellation: {})
            }
            if let cached { initialEvent = .cached(cached.size, isPartial: cached.isPartial, isRefreshing: true) }
            guard tasks[key] == nil, tasks.count < Self.maximumDetachedTaskCount else { return nil }
            let task = Task(root: root)
            tasks[key] = task
            taskToStart = task
            return makeObservation(for: task, observer: observer)
        }
        // Deliver outside the state queue: observers may detach/cancel their session.
        // The enricher rejects an initial snapshot superseded by a terminal update.
        observer(initialEvent)
        if let taskToStart { start(taskToStart) }
        return observation
    }

    private func makeObservation(
        for task: Task,
        observer: @escaping (ClipboardDirectorySizeTaskEvent) -> Void
    ) -> ClipboardDirectorySizeObservation {
        let id = UUID()
        task.observers[id] = observer
        return ClipboardDirectorySizeObservation(id: id) { [weak self, weak task] in
            guard let self, let task else { return }
            _ = self.stateQueue.sync { task.observers.removeValue(forKey: id) }
        }
    }

    private func start(_ task: Task) {
        workerQueue.async { [self] in
            let result = calculate(
                at: task.root,
                shouldCancel: { self.stateQueue.sync { task.cancelled } },
                onProgress: { size in
                    let observers = self.stateQueue.sync { () -> [(ClipboardDirectorySizeTaskEvent) -> Void] in
                        guard !task.cancelled, size > task.latestLowerBound else { return [] }
                        task.latestLowerBound = size
                        return Array(task.observers.values)
                    }
                    observers.forEach { $0(.progress(size)) }
                }
            )
            let observers = stateQueue.sync {
                tasks.removeValue(forKey: task.root.path)
                defer { task.observers.removeAll() }
                return Array(task.observers.values)
            }
            observers.forEach { $0(.terminal(result)) }
        }
    }

    /// Shared by detached work and the session-bound fallback when both slots are occupied.
    func calculate(
        at root: URL,
        shouldCancel: @escaping () -> Bool,
        progressUpdateInterval: TimeInterval = progressUpdateInterval,
        onProgress: @escaping (Int64) -> Void
    ) -> ClipboardDirectorySizeResult {
        let generation = stateQueue.sync { cancellationGeneration }
        let started = now()
        let result = calculator(root, Self.maximumDuration, shouldCancel, progressUpdateInterval, onProgress)
        let completed = now()
        guard !shouldCancel() else { return result }
        let size: Int64
        let isPartial: Bool
        switch result {
        case let .exact(value): (size, isPartial) = (value, false)
        case let .atLeast(value): (size, isPartial) = (value, true)
        case .unavailable, .cancelled: return result
        }
        stateQueue.sync {
            guard cancellationGeneration == generation else { return }
            let key = root.standardizedFileURL.path
            if completed - started > Self.slowDirectoryThreshold {
                cachedSizes[key] = CachedSize(size: size, isPartial: isPartial, completedAt: completed)
                if cachedSizes.count > Self.maximumCachedResultCount,
                   let oldest = cachedSizes.min(by: { $0.value.completedAt < $1.value.completedAt })?.key {
                    cachedSizes.removeValue(forKey: oldest)
                }
            } else {
                cachedSizes.removeValue(forKey: key)
            }
        }
        return result
    }

    func cancelAll() {
        stateQueue.sync {
            cancellationGeneration &+= 1
            cachedSizes.removeAll()
            for task in tasks.values {
                task.cancelled = true
                task.observers.removeAll()
            }
        }
    }

    var inFlightTaskCount: Int {
        stateQueue.sync { tasks.count }
    }
}

enum ClipboardDirectorySizeCalculator {
    static let maximumDuration: TimeInterval = 30

    static func calculate(
        at root: URL,
        maximumDuration: TimeInterval = maximumDuration,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        shouldCancel: @escaping () -> Bool = { false },
        progressUpdateInterval: TimeInterval = 0.25,
        onProgress: (Int64) -> Void = { _ in }
    ) -> ClipboardDirectorySizeResult {
        guard !shouldCancel() else { return .cancelled }
        let started = now()
        var hadError = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .fileSizeKey,
                .totalFileSizeKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ],
            options: [],
            errorHandler: { _, _ in
                if shouldCancel() { return false }
                hadError = true
                return true
            }
        ) else {
            return .unavailable
        }

        var total: Int64 = 0
        var lastProgressTime = started
        for case let fileURL as URL in enumerator {
            if shouldCancel() { return .cancelled }
            if now() - started >= maximumDuration {
                return .atLeast(total)
            }
            guard let values = try? fileURL.resourceValues(forKeys: [
                .fileSizeKey,
                .totalFileSizeKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]) else {
                hadError = true
                continue
            }
            if shouldCancel() { return .cancelled }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true { continue }
            guard let size = values.totalFileSize ?? values.fileSize, size >= 0 else {
                hadError = true
                continue
            }
            let (next, overflow) = total.addingReportingOverflow(Int64(size))
            if overflow { return .atLeast(total) }
            total = next
            let currentTime = now()
            if progressUpdateInterval <= 0
                || currentTime - lastProgressTime >= progressUpdateInterval {
                onProgress(total)
                lastProgressTime = currentTime
            }
        }
        if shouldCancel() { return .cancelled }
        return hadError ? .atLeast(total) : .exact(total)
    }

    static func adding(_ size: Int64, to total: Int64) -> ClipboardDirectorySizeResult {
        let (next, overflow) = total.addingReportingOverflow(size)
        return overflow ? .atLeast(total) : .exact(next)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
