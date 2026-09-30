import AppKit
import Combine
import Darwin

struct LastToastSnapshot {
    let content: ClipboardContent
    let source: SourceAppInfo
    let primaryAction: (any ClipboardAction)?
    let menuActions: [any ClipboardAction]
    let resultOverlay: ResultOverlay?
    let showsUpdateReminder: Bool

    init?(viewModel: ToastViewModel) {
        guard viewModel.isContentReady,
              let content = viewModel.rawContent,
              viewModel.revision == content.revision else { return nil }
        self.content = content
        source = SourceAppInfo(
            name: viewModel.sourceAppName,
            icon: viewModel.sourceAppIcon,
            bundleIdentifier: viewModel.sourceBundleID
        )
        primaryAction = viewModel.primaryAction
        menuActions = viewModel.menuActions
        resultOverlay = viewModel.resultOverlay
        showsUpdateReminder = viewModel.showsUpdateReminder
    }

    /// A conservative retained-content budget, not a measurement of process RSS.
    /// Shared App icons and fixed UI assets are outside this clipboard-content budget.
    /// Shared strings are deliberately charged again at every retained field.
    func contentByteCost(limit: Int = LastToastStore.maximumContentBytes) -> Int? {
        var budget = LastToastContentBudget(remaining: limit)
        guard budget.add(content.rawText),
              budget.add(content.expandedFullText), budget.add(content.expandedDisplayText),
              budget.add(content.preview), budget.add(content.detail),
              budget.add(content.displayTypeLabel), budget.add(content.displayIconSymbolName),
              budget.add(content.imageFormat), budget.add(content.thumbnail),
              budget.add(source.name), budget.add(source.bundleIdentifier) else { return nil }
        if let kind = content.contentKind, !budget.add(kind) { return nil }
        for url in content.fileURLs ?? [] {
            guard budget.add(url.absoluteString) else { return nil }
        }
        for detection in content.detections {
            guard budget.add(detection) else { return nil }
        }
        if let action = primaryAction, !budget.add(action) { return nil }
        for action in menuActions {
            guard budget.add(action) else { return nil }
        }
        if let resultOverlay {
            guard budget.add(resultOverlay.displayText), budget.add(resultOverlay.copyText),
                  budget.add(resultOverlay.boundedDisplayText) else { return nil }
        }
        return limit - budget.remaining
    }
}

private struct LastToastContentBudget {
    var remaining: Int

    mutating func add(bytes: Int) -> Bool {
        guard bytes >= 0, bytes <= remaining else { return false }
        remaining -= bytes
        return true
    }

    mutating func add(_ text: String?) -> Bool {
        guard let text else { return true }
        if let count = text.utf8.withContiguousStorageIfAvailable({ $0.count }) {
            return add(bytes: count)
        }
        // UTF-8 needs at least one byte per UTF-16 unit; foreign strings expose this count
        // without conversion, so very large bridged text can be refused immediately.
        guard text.utf16.count <= remaining else { return false }
        // The exact count below stops at the remaining budget + 1.
        for _ in text.utf8 {
            guard add(bytes: 1) else { return false }
        }
        return true
    }

    mutating func add(_ image: NSImage?) -> Bool {
        guard let image else { return true }
        let representations = image.representations
        if representations.isEmpty {
            let width = image.size.width.rounded(.up)
            let height = image.size.height.rounded(.up)
            guard width.isFinite, height.isFinite, width >= 0, height >= 0,
                  width <= CGFloat(remaining), height <= CGFloat(remaining) else { return false }
            return addRaster(width: Int(width), height: Int(height), bytesPerPixel: 4)
        }
        for representation in representations {
            if let bitmap = representation as? NSBitmapImageRep {
                let rowBytes = bitmap.bytesPerRow
                let height = bitmap.pixelsHigh
                let planes = bitmap.numberOfPlanes
                guard rowBytes > 0, height > 0, planes > 0,
                      rowBytes <= remaining / height / planes,
                      add(bytes: rowBytes * height * planes) else { return false }
            } else {
                // CG and Quick Look raster snapshots expose pixel metadata without decoding.
                // Vector/custom representations lack a bounded raster cost and are refused.
                let bits = representation.bitsPerSample
                guard bits > 0, bits <= 64,
                      representation.pixelsWide > 0, representation.pixelsHigh > 0,
                      addRaster(width: representation.pixelsWide, height: representation.pixelsHigh,
                                bytesPerPixel: max(4, 4 * ((bits + 7) / 8))) else { return false }
            }
        }
        return true
    }

    private mutating func addRaster(width: Int, height: Int, bytesPerPixel: Int) -> Bool {
        guard width >= 0, height >= 0, bytesPerPixel > 0 else { return false }
        guard width > 0, height > 0 else { return width == 0 && height == 0 }
        guard width <= remaining / height / bytesPerPixel else { return false }
        return add(bytes: width * height * bytesPerPixel)
    }

    mutating func add(_ kind: ContentKind) -> Bool {
        guard add(kind.id), add(kind.label), add(kind.icon), add(kind.pluginName) else { return false }
        if case let .plugin(identifier) = kind.source { return add(identifier) }
        return true
    }

    mutating func add(_ template: PluginActionTemplate) -> Bool {
        add(template.title) && add(template.icon) && add(template.template)
            && add(template.transformPattern) && add(template.transformReplacement)
    }

    mutating func add(_ detection: ContentDetection) -> Bool {
        guard add(detection.kind), add(detection.value) else { return false }
        if let color = detection.color, color.type != .componentBased { return false }
        for (key, value) in detection.metadata {
            guard add(key), add(value) else { return false }
        }
        if let template = detection.pluginActionTemplate { return add(template) }
        return true
    }

    mutating func add(_ action: any ClipboardAction) -> Bool {
        // Keep this explicit: a new action with unaccounted retained data cannot cost zero.
        switch action {
        case let action as OpenURLAction: return add(action.url.absoluteString)
        case let action as RevealFileAction: return add(action.path)
        case let action as CompressImagesAction:
            guard add(action.invocation.applicationURL.absoluteString) else { return false }
            for url in action.invocation.fileURLs {
                guard add(url.absoluteString) else { return false }
            }
            return true
        case let action as CalculateAction: return add(action.expression)
        case let action as SearchTextAction: return add(action.text)
        case let action as ShowPinyinAction:
            for scalar in action.character.unicodeScalars {
                let value = scalar.value
                let bytes = value <= 0x7f ? 1 : value <= 0x7ff ? 2 : value <= 0xffff ? 3 : 4
                guard add(bytes: bytes) else { return false }
            }
            return true
        case let action as CallPhoneAction: return add(action.phoneNumber)
        case let action as ComposeEmailAction: return add(action.email)
        case let action as SaveFileAction: return add(action.text) && add(action.defaultName)
        case let action as CopyTextAction: return add(action.text)
        case is OpenCalendarAction: return true // Only a fixed-size Date is retained.
        case let action as LookupAction: return add(action.definition)
        case let action as PluginAction: return add(action.detection) && add(action.template)
        case let action as BlacklistSourceAppAction: return add(action.bundleID) && add(action.appName)
        default: return false
        }
    }
}

final class LastToastStore: ObservableObject {
    static let shared = LastToastStore()
    static let retentionDuration: TimeInterval = 600
    static let maximumContentBytes = 8 * 1_024 * 1_024

    @Published private(set) var canReplay = false

    private let defaults: UserDefaults
    private let filterSettings: AppFilterSettings
    private let now: () -> TimeInterval
    private var snapshot: LastToastSnapshot?
    private var presentationRevision: ClipboardRevision?
    private var expirationTime: TimeInterval?
    private var expirationTimer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        filterSettings: AppFilterSettings = .shared,
        now: @escaping () -> TimeInterval = LastToastStore.continuousTime
    ) {
        self.defaults = defaults
        self.filterSettings = filterSettings
        self.now = now
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAvailability()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAvailability()
        }
    }

    deinit {
        expirationTimer?.invalidate()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    /// Called only after a new real full card is ordered front, including its pending frame.
    func beginPresentation(revision: ClipboardRevision) {
        clear()
        guard !defaults.bool(forKey: "isPaused") else { return }
        presentationRevision = revision
        expirationTime = now() + Self.retentionDuration
    }

    func record(_ snapshot: LastToastSnapshot) {
        guard presentationRevision == snapshot.content.revision,
              let expirationTime else { return }
        guard now() < expirationTime, !defaults.bool(forKey: "isPaused") else {
            clear()
            return
        }
        guard snapshot.contentByteCost() != nil else {
            // Clearing the presentation identity also prevents later partial updates reviving it.
            clear()
            return
        }
        self.snapshot = snapshot
        if expirationTimer == nil {
            scheduleExpiration(at: expirationTime)
        }
        refreshAvailability()
    }

    func snapshotForReplay() -> LastToastSnapshot? {
        refreshAvailability()
        return canReplay ? snapshot : nil
    }

    func refreshAvailability() {
        if defaults.bool(forKey: "isPaused")
            || expirationTime.map({ now() >= $0 }) == true {
            clear()
            return
        }
        canReplay = snapshot != nil
            && !defaults.bool(forKey: "lightReminderEnabled")
            && filterSettings.shouldShowPopup(for: snapshot?.source.bundleIdentifier)
    }

    func clear() {
        expirationTimer?.invalidate()
        expirationTimer = nil
        snapshot = nil
        presentationRevision = nil
        expirationTime = nil
        canReplay = false
    }

    private func scheduleExpiration(at deadline: TimeInterval) {
        let timer = Timer(timeInterval: max(0.001, deadline - now()), repeats: false) {
            [weak self] _ in
            guard let self else { return }
            self.expirationTimer = nil
            self.refreshAvailability()
            if self.snapshot != nil, let expirationTime = self.expirationTime {
                self.scheduleExpiration(at: expirationTime)
            }
        }
        expirationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Continuous monotonic time includes sleep and is unaffected by wall-clock changes.
    private static func continuousTime() -> TimeInterval {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(mach_continuous_time()) * Double(timebase.numer)
            / Double(timebase.denom) / 1_000_000_000
    }
}
