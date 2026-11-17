import AppKit
import CoreGraphics

// MARK: - Clipboard Content Model

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

    /// Low-interruption visual coalescing only. Revision identity is never derived from this.
    var visualHashValue: Int {
        var hasher = Hasher()
        hasher.combine(type)
        hasher.combine(preview)
        hasher.combine(detail)
        hasher.combine(litheMetadata.isGeneratedByLithe)
        hasher.combine(litheMetadata.requestID)
        return hasher.finalize()
    }
}

// MARK: - Clipboard Monitor

final class ClipboardMonitor {
    private struct InputEventCounts: Equatable {
        let keyDown: UInt32
        let leftMouseDown: UInt32
        let rightMouseDown: UInt32
        let otherMouseDown: UInt32
        let scrollWheel: UInt32

        static func current() -> Self {
            Self(
                keyDown: CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown),
                leftMouseDown: CGEventSource.counterForEventType(.hidSystemState, eventType: .leftMouseDown),
                rightMouseDown: CGEventSource.counterForEventType(.hidSystemState, eventType: .rightMouseDown),
                otherMouseDown: CGEventSource.counterForEventType(.hidSystemState, eventType: .otherMouseDown),
                scrollWheel: CGEventSource.counterForEventType(.hidSystemState, eventType: .scrollWheel)
            )
        }
    }

    private struct ReuseSettings: Equatable {
        let paused: Bool
        let preferences: PopupPresentationPreferences
        let reminderEnabled: Bool
        let reminderStyle: LightReminderStyle
        let comboEnabled: Bool
        let disabledKindIDs: Set<String>
        let priorities: [String: Int]
        let installedPlugins: Set<String>
        let detectorRegistrationGeneration: UInt64
        let blockedApps: Set<String>
        let quickTrigger: QuickTriggerSettings
        let searchEngine: String
    }

    private enum PresentationDecision {
        case allow
        case deny
        case wait
    }

    private var timer: Timer?
    var isRunning: Bool { timer?.isValid == true }
    private var defaultsObserver: NSObjectProtocol?
    private var registryObserver: NSObjectProtocol?
    private var modifierActivityMonitor: Any?
    private var copyRequestObserver: NSObjectProtocol?
    private var lastInputEventCounts: InputEventCounts?
    private var pollingPolicy = ClipboardPollingPolicy(now: ProcessInfo.processInfo.systemUptime)
    private var lastObservedChangeCount = 0
    private var revisionGeneration: UInt64 = 0
    private var lastLowInterruptionHash = 0
    private var lastLowInterruptionShowTime = Date.distantPast
    private let dedupWindow: TimeInterval = 0.5
    private let firstResponseBoostDuration: TimeInterval = 60
    private var firstResponseBoostDeadline: TimeInterval?

    private var cachedIsPaused: Bool
    private var cachedPreferences: PopupPresentationPreferences
    private var cachedLightReminderStyle: LightReminderStyle
    private var cachedLightReminderEnabled: Bool
    private var cachedCopyComboEnabled: Bool
    private var cachedSoundSelection: String
    private var cachedReuseSettings: ReuseSettings?
    private var availableKindIDs = Set<String>()
    private var backingScale: CGFloat = 2

    private let baseLane = ClipboardLatestOnlyLane(label: "com.copied.clipboard.base")
    private let analysisLane = ClipboardLatestOnlyLane(label: "com.copied.clipboard.analysis")
    private let fileLane = ClipboardLatestOnlyLane(label: "com.copied.clipboard.file")
    private let imageLane = ClipboardLatestOnlyLane(label: "com.copied.clipboard.image")
    private let revisionGate = ClipboardRevisionGate()

    private var activeSession: ClipboardLoadSession?
    private var activeSource: SourceAppInfo?
    private var activePreferences: PopupPresentationPreferences?
    private var activeLightReminderStyle: LightReminderStyle = .cursorIcon
    private var activeLightReminderEnabled: Bool?
    private var activeCandidateDecision: PopupPresentationPolicy.CandidateDecision?
    private var activeSoundSelection: String?
    private var activeSoundDispatchGate = CopySoundDispatchGate()
    private var activeLightReminderWasPresented = false
    private var activeContent: ClipboardContent?
    private var activeReusesActions = false
    private var isActivePresentationVisible = false
    private var activePresentationWasDropped = false
    private var analysisIsReady = false
    private var fileClassificationIsReady = false
    private var fileClassificationIsComplete = false
    private var actionsWereScheduled = false
    private var thumbnailWasScheduled = false
    private var analysisDeadlineExpired = false
    private var fileDeadlineExpired = false
    private var bitmapDeadlineExpired = false
    private var fileThumbnailDeadlineExpired = false

    private let analysisSoftDeadline: TimeInterval = 3
    private let fileSoftDeadline: TimeInterval = 30
    private let imageSoftDeadline: TimeInterval = 2

    weak var toastController: ToastWindowController?
    private let defaults: UserDefaults
    private let directorySizeCoordinator: ClipboardDirectorySizeCoordinator
    private let filterSettings: AppFilterSettings
    private let soundPlayback: (String) -> Void

    init(
        toastController: ToastWindowController,
        defaults: UserDefaults = .standard,
        directorySizeCoordinator: ClipboardDirectorySizeCoordinator = .shared,
        filterSettings: AppFilterSettings = .shared,
        soundPlayback: @escaping (String) -> Void = CopySoundFeedback.play
    ) {
        self.toastController = toastController
        self.defaults = defaults
        self.directorySizeCoordinator = directorySizeCoordinator
        self.filterSettings = filterSettings
        self.soundPlayback = soundPlayback
        cachedIsPaused = defaults.bool(forKey: "isPaused")
        cachedPreferences = PopupPresentationPreferences.current(defaults: defaults)
        cachedLightReminderEnabled = defaults.bool(forKey: "lightReminderEnabled")
        cachedLightReminderStyle = LightReminderStyle.current(defaults: defaults)
        cachedCopyComboEnabled = ClipboardCopyCombo.isEnabled(defaults: defaults)
        toastController.setCopyComboEnabled(cachedCopyComboEnabled)
        cachedSoundSelection = CopySoundFeedback.resolvedSelection(
            defaults.string(forKey: CopySoundFeedback.defaultsKey)
        )
    }

    deinit {
        removePollingActivityObservers()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        if let registryObserver {
            NotificationCenter.default.removeObserver(registryObserver)
        }
    }

    func start() {
        let pasteboard = NSPasteboard.general
        lastObservedChangeCount = pasteboard.changeCount
        backingScale = NSScreen.main?.backingScaleFactor ?? 2
        availableKindIDs = Set(DetectionRegistry.shared.allRegisteredKinds.map(\.id))
        refreshCachedSettings()
        installDefaultsObserverIfNeeded()
        firstResponseBoostDeadline = ProcessInfo.processInfo.systemUptime
            + firstResponseBoostDuration
        pollingPolicy = ClipboardPollingPolicy(now: ProcessInfo.processInfo.systemUptime)
        lastInputEventCounts = .current()
        scheduleTimer(withTimeInterval: ClipboardPollingPolicy.firstResponseInterval)
        installPollingActivityObservers()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        removePollingActivityObservers()
        lastInputEventCounts = nil
        firstResponseBoostDeadline = nil
        activeSession?.cancel()
        activeSession = nil
        directorySizeCoordinator.cancelAll()
        toastController?.onRevisionResourcesShouldCancel = nil
        toastController?.clearLastToast()
        toastController?.dismissToast(animated: false)
        LightReminderController.shared.dismiss(animated: false)
    }

    private func installDefaultsObserverIfNeeded() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            self?.refreshCachedSettings()
        }
        registryObserver = NotificationCenter.default.addObserver(
            forName: DetectionRegistry.registrationsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard notification.object as? DetectionRegistry === DetectionRegistry.shared else { return }
            self?.refreshCachedSettings()
        }
    }

    private func refreshCachedSettings() {
        let preferences = PopupPresentationPreferences.current(defaults: defaults)
        let reminderEnabled = defaults.bool(forKey: "lightReminderEnabled")
        let reminderStyle = LightReminderStyle.current(defaults: defaults)
        let comboEnabled = ClipboardCopyCombo.isEnabled(defaults: defaults)
        let reuseSettings = ReuseSettings(
            paused: defaults.bool(forKey: "isPaused"),
            preferences: preferences,
            reminderEnabled: reminderEnabled,
            reminderStyle: reminderStyle,
            comboEnabled: comboEnabled,
            disabledKindIDs: Set(defaults.stringArray(forKey: "disabledContentKinds") ?? []),
            priorities: defaults.dictionary(forKey: "contentKindPriorities") as? [String: Int] ?? [:],
            installedPlugins: Set(defaults.stringArray(forKey: "installedPlugins") ?? []),
            detectorRegistrationGeneration: DetectionRegistry.shared.registeredDetectorsGeneration,
            blockedApps: Set(filterSettings.blockedApps.map(\.bundleID)),
            quickTrigger: QuickTriggerSettings.current(defaults: defaults),
            searchEngine: defaults.string(forKey: "searchEngine") ?? "google"
        )
        if cachedReuseSettings != reuseSettings {
            toastController?.invalidateCopyReuse()
            if cachedReuseSettings != nil { toastController?.interruptCopyCombo() }
            availableKindIDs = Set(DetectionRegistry.shared.allRegisteredKinds.map(\.id))
            cachedReuseSettings = reuseSettings
        }
        cachedIsPaused = reuseSettings.paused
        cachedPreferences = preferences
        cachedLightReminderEnabled = reminderEnabled
        cachedLightReminderStyle = reminderStyle
        if cachedCopyComboEnabled != comboEnabled {
            cachedCopyComboEnabled = comboEnabled
            toastController?.setCopyComboEnabled(comboEnabled)
            if !comboEnabled { activeSession?.disableCopyIdentity() }
        }
        cachedSoundSelection = CopySoundFeedback.resolvedSelection(
            defaults.string(forKey: CopySoundFeedback.defaultsKey)
        )
    }

    private func scheduleTimer(withTimeInterval interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
            [weak self] _ in
            self?.checkClipboard()
        }
    }

    private func installPollingActivityObservers() {
        guard copyRequestObserver == nil else { return }
        copyRequestObserver = NotificationCenter.default.addObserver(
            forName: .copiedCopyRequested, object: nil, queue: .main
        ) { [weak self] _ in
            self?.acceleratePolling()
        }
        // This is an optional hint. State/counter sampling keeps polling functional
        // when the system does not deliver global keyboard events without permission.
        modifierActivityMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            guard event.modifierFlags.contains(.command) else { return }
            MainActor.assumeIsolated { self?.acceleratePolling() }
        }
    }

    private func removePollingActivityObservers() {
        if let modifierActivityMonitor { NSEvent.removeMonitor(modifierActivityMonitor) }
        modifierActivityMonitor = nil
        if let copyRequestObserver { NotificationCenter.default.removeObserver(copyRequestObserver) }
        copyRequestObserver = nil
    }

    private func acceleratePolling() {
        guard isRunning, !cachedIsPaused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        pollingPolicy.recordActivity(at: now)
        updatePollingSchedule(at: now)
    }

    private func updatePollingSchedule(at now: TimeInterval) {
        guard isRunning else { return }
        let counts = InputEventCounts.current()
        if NSEvent.modifierFlags.contains(.command) || counts != lastInputEventCounts {
            pollingPolicy.recordActivity(at: now)
        }
        lastInputEventCounts = counts
        let interval = pollingPolicy.interval(
            at: now, firstResponseBoostActive: firstResponseBoostDeadline != nil
        )
        if timer?.timeInterval != interval { scheduleTimer(withTimeInterval: interval) }
    }

    private func checkClipboard() {
        guard !cachedIsPaused else { return }
        finishFirstResponseBoostIfExpired()
        updatePollingSchedule(at: ProcessInfo.processInfo.systemUptime)
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastObservedChangeCount else { return }

        // Acknowledge observation before any representation access. Retries belong to the session.
        lastObservedChangeCount = currentCount
        revisionGeneration &+= 1
        let revision = ClipboardRevision(
            generation: revisionGeneration,
            changeCount: currentCount
        )
        beginRevision(revision)
    }

    private func beginRevision(_ revision: ClipboardRevision) {
        guard let session = prepareRevision(revision) else { return }
        submitBaseRead(session: session)
    }

    private func prepareRevision(
        _ revision: ClipboardRevision, source: SourceAppInfo? = nil,
        privacyDisposition: ClipboardPrivacyDisposition? = nil
    ) -> ClipboardLoadSession? {
        toastController?.observeCopyRevision(revision)
        revisionGate.activate(revision)
        activeSession?.cancel()
        baseLane.discardPending(olderThan: revision)
        analysisLane.discardPending(olderThan: revision)
        fileLane.discardPending(olderThan: revision)
        imageLane.discardPending(olderThan: revision)
        resetActiveRevisionState()

        let source = source ?? SourceAppDetector.cachedSnapshot()
        guard filterSettings.shouldShowPopup(for: source.bundleIdentifier) else {
            toastController?.interruptCopyCombo()
            finishFirstResponseBoost()
            return nil
        }

        let preferences = cachedPreferences
        let lightReminderEnabled = cachedLightReminderEnabled
        let soundSelection = cachedSoundSelection
        let candidateDecision = PopupPresentationPolicy.candidateDecision(
            preferences: preferences,
            availableKindIDs: availableKindIDs
        )
        if lightReminderEnabled || candidateDecision == .allDenied {
            toastController?.interruptCopyCombo()
        }

        activeSource = source
        activePreferences = preferences
        activeLightReminderEnabled = lightReminderEnabled
        activeLightReminderStyle = cachedLightReminderStyle
        activeCandidateDecision = candidateDecision
        activeSoundSelection = soundSelection
        let privacy: ClipboardPrivacyDisposition
        if let privacyDisposition {
            privacy = privacyDisposition
        } else {
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == revision.changeCount else { return nil }
            privacy = ClipboardPrivacyPolicy.disposition(for: pasteboard.types ?? [])
            guard pasteboard.changeCount == revision.changeCount else { return nil }
        }
        guard privacy == .ordinary else {
            handleProtectedRevision(privacy, revision: revision)
            return nil
        }

        backingScale = ToastScreenSelection.current()?.backingScaleFactor ?? 2
        let session = ClipboardLoadSession(
            revision: revision,
            backingScale: backingScale,
            recordsCopyIdentity: cachedCopyComboEnabled && !lightReminderEnabled && candidateDecision != .allDenied,
            comparisonIdentity: toastController?.copyIdentityForComparison
        )
        activeSession = session
        toastController?.onRevisionResourcesShouldCancel = { [weak self, weak session] revision in
            guard let self, let session, revision == session.revision,
                  self.activeSession === session else { return }
            session.cancel()
            self.activeContent = nil
            self.toastController?.interruptCopyCombo()
        }

        if lightReminderEnabled,
           (preferences.mode == .all || candidateDecision == .allAllowed) {
            showLightReminder(revision: revision)
            activeLightReminderWasPresented = true
        } else if !lightReminderEnabled,
                  candidateDecision != .allDenied,
                  (preferences.mode == .all || candidateDecision == .allAllowed) {
            // This is deliberately synchronous in the timer callback and precedes base-lane work.
            LightReminderController.shared.dismiss(animated: false)
            toastController?.showPending(revision: revision, source: source)
            isActivePresentationVisible = true
        }

        session.scheduleRetry(after: 3) { [weak self, weak session] in
            guard let self, let session, self.activeSession === session else { return }
            self.handleLoadTimeout(session: session)
        }
        return session
    }

    private func handleProtectedRevision(
        _ disposition: ClipboardPrivacyDisposition, revision: ClipboardRevision
    ) {
        activeSession?.cancel()
        activeSession = nil
        toastController?.onRevisionResourcesShouldCancel = nil
        toastController?.interruptCopyCombo()
        toastController?.clearLastToast()
        toastController?.dismissToast(animated: false)
        LightReminderController.shared.dismiss(animated: false)
        finishFirstResponseBoost()
        guard disposition == .concealed else { return }
        playActiveCopySoundIfNeeded()
        guard activePreferences?.mode == .all || activeCandidateDecision == .allAllowed else { return }
        if activeLightReminderEnabled == true {
            showLightReminder(revision: revision, hidesContent: true)
        } else {
            toastController?.showReminder(revision: revision, hidesContent: true)
        }
    }

    private func showLightReminder(revision: ClipboardRevision, hidesContent: Bool = false) {
        switch activeLightReminderStyle {
        case .cursorIcon:
            toastController?.dismissToast(animated: false)
            LightReminderController.shared.show()
        case .topCard:
            LightReminderController.shared.dismiss(animated: false)
            toastController?.showReminder(revision: revision, hidesContent: hidesContent)
        }
    }

    private func resetActiveRevisionState() {
        activeSource = nil
        activePreferences = nil
        activeLightReminderEnabled = nil
        activeCandidateDecision = nil
        activeSoundSelection = nil
        activeSoundDispatchGate = CopySoundDispatchGate()
        activeLightReminderWasPresented = false
        activeContent = nil
        activeReusesActions = false
        isActivePresentationVisible = false
        activePresentationWasDropped = false
        analysisIsReady = false
        fileClassificationIsReady = false
        fileClassificationIsComplete = false
        actionsWereScheduled = false
        thumbnailWasScheduled = false
        analysisDeadlineExpired = false
        fileDeadlineExpired = false
        bitmapDeadlineExpired = false
        fileThumbnailDeadlineExpired = false
    }

    private func submitBaseRead(session: ClipboardLoadSession) {
        baseLane.submit(revision: session.revision) { [weak self, weak session] finish in
            guard let self, let session, session.beginBaseAttempt() != nil else {
                finish()
                return
            }
            let pasteboard = NSPasteboard(name: .general)
            let outcome = ClipboardBaseReader.read(
                session: session,
                pasteboard: pasteboard
            )
            finish()
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self, let session else { return }
                self.receiveBaseRead(outcome, session: session)
            }
        }
    }

    private func receiveBaseRead(
        _ outcome: ClipboardBaseReadOutcome,
        session: ClipboardLoadSession
    ) {
        guard activeSession === session,
              outcome.revision == session.revision,
              session.accepts(session.revision) else { return }
        switch outcome {
        case .stale:
            checkClipboard()
        case .concealed:
            handleProtectedRevision(.concealed, revision: session.revision)
        case .ignored:
            handleProtectedRevision(.ignored, revision: session.revision)
        case .unreadable:
            if session.attemptCount < 3 {
                session.scheduleRetry { [weak self, weak session] in
                    guard let self, let session, self.activeSession === session else { return }
                    self.submitBaseRead(session: session)
                }
            } else {
                handleLoadFailure(session: session)
            }
        case let .content(_, baseContent):
            session.cancelScheduledWorkItems()
            playActiveCopySoundIfNeeded()
            finishFirstResponseBoost()

            // An already-shown light reminder and an all-denied visual policy need only
            // the validated base read for sound; hidden enrichment would waste resources.
            if activeLightReminderWasPresented || activeCandidateDecision == .allDenied {
                session.cancel()
                return
            }

            var content = baseContent
            if let identity = session.confirmedCopyIdentity,
               let previous = toastController?.contentForCopyReuse(matching: identity),
               previous.content.litheMetadata == content.litheMetadata {
                // Reuse only the currently displayed, strictly matching copy.
                // File facts still refresh: equal URLs do not freeze their sizes.
                content.preview = previous.content.preview
                content.detail = previous.content.detail
                content.detailIsLoading = previous.content.detailIsLoading
                content.thumbnail = previous.content.thumbnail
                content.contentKind = previous.content.contentKind
                content.detections = previous.content.detections
                content.allFilesAreImages = previous.content.allFilesAreImages
                content.displayTypeLabel = previous.content.displayTypeLabel
                content.displayIconSymbolName = previous.content.displayIconSymbolName
                activeReusesActions = previous.actionsResolved
                if content.type == .text, previous.actionsResolved {
                    analysisIsReady = true
                    actionsWereScheduled = true
                }
            }
            session.storePayload(content)
            activeContent = content
            if let source = activeSource {
                activeSource = SourceAppDetector.enriching(source, with: content)
            }
            if isActivePresentationVisible, activeLightReminderEnabled == false {
                guard let source = activeSource else { return }
                toastController?.applyBaseContent(
                    content,
                    source: source,
                    revision: session.revision,
                    copyIdentity: session.confirmedCopyIdentity,
                    reusingActions: activeReusesActions
                )
                toastController?.confirmCopyIdentity(
                    session.takeCopyIdentity(),
                    revision: session.revision
                )
            }
            scheduleEnrichment(for: content, session: session)
            tryPresentLowInterruption(session: session)
        }
    }

    private func handleLoadFailure(session: ClipboardLoadSession) {
        guard activeSession === session else { return }
        toastController?.interruptCopyCombo()
        session.cancel()
        playActiveCopySoundIfNeeded()
        finishFirstResponseBoost()
        if activePreferences?.mode == .all, activeLightReminderEnabled == false {
            toastController?.showFailure(revision: session.revision)
        } else if !activeLightReminderWasPresented {
            toastController?.dismissSilently(revision: session.revision)
        }
    }

    private func handleLoadTimeout(session: ClipboardLoadSession) {
        guard activeSession === session, activeContent == nil else { return }
        toastController?.interruptCopyCombo()
        session.cancel()
        playActiveCopySoundIfNeeded()
        if activePreferences?.mode == .all, activeLightReminderEnabled == false {
            toastController?.showFailure(revision: session.revision)
        } else if !activeLightReminderWasPresented {
            toastController?.dismissSilently(revision: session.revision)
        }
        finishFirstResponseBoost()
    }

    private func playActiveCopySoundIfNeeded() {
        guard let selection = activeSoundDispatchGate.claim(
            selection: activeSoundSelection
        ) else { return }
        soundPlayback(selection)
    }

    private func scheduleEnrichment(
        for content: ClipboardContent,
        session: ClipboardLoadSession
    ) {
        switch content.type {
        case .text:
            scheduleAnalysis(session: session, performsDetection: true)
        case .file:
            scheduleFileEnrichment(session: session)
        case .image:
            analysisIsReady = true
            scheduleBitmapEnrichment(session: session)
        }
    }

    private func scheduleAnalysis(
        session: ClipboardLoadSession,
        performsDetection: Bool
    ) {
        guard !actionsWereScheduled else { return }
        actionsWereScheduled = true
        let deadlineToken = session.scheduleSoftDeadline(after: analysisSoftDeadline) {
            [weak self, weak session] in
            guard let self, let session else { return }
            self.handleAnalysisSoftDeadline(session: session)
        }
        analysisLane.submit(revision: session.revision) { [weak session] finish in
            guard let session,
                  session.accepts(session.revision),
                  var content = session.payload(as: ClipboardContent.self) else {
                finish()
                return
            }
            if performsDetection, let text = content.rawText {
                content.detections = DetectionRegistry.shared.detectAll(in: text)
                content.contentKind = content.detections.first?.kind
            }
            guard session.accepts(session.revision) else {
                session.cancelSoftDeadline(deadlineToken)
                finish()
                return
            }
            let resolved = ActionResolver.resolve(for: content)
            session.cancelSoftDeadline(deadlineToken)
            finish()
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self, let session else { return }
                if performsDetection {
                    self.reduce(
                        .analysis(revision: content.revision, detections: content.detections),
                        session: session
                    )
                }
                self.reduce(
                    .actions(
                        revision: content.revision,
                        primary: resolved.primary,
                        menu: resolved.menu
                    ),
                    session: session
                )
            }
        }
    }

    private func scheduleFileEnrichment(session: ClipboardLoadSession) {
        let directorySizeCoordinator = directorySizeCoordinator
        let deadlineToken = session.scheduleSoftDeadline(after: fileSoftDeadline) {
            [weak self, weak session] in
            guard let self, let session else { return }
            self.handleFileSoftDeadline(session: session)
        }
        fileLane.submit(revision: session.revision) { [weak session] finish in
            guard let session,
                  session.accepts(session.revision),
                  let content = session.payload(as: ClipboardContent.self) else {
                finish()
                return
            }
            ClipboardFileEnricher.enrich(
                content: content,
                shouldCancel: { !session.accepts(session.revision) },
                directorySizeCoordinator: directorySizeCoordinator,
                registerDirectorySizeObservation: {
                    session.setDirectorySizeObservation($0)
                }
            ) { update in
                if case let .fileFacts(_, _, _, _, _, _, detailIsLoading) = update,
                   !detailIsLoading {
                    session.cancelSoftDeadline(deadlineToken)
                    session.clearDirectorySizeObservation()
                }
                DispatchQueue.main.async { [weak self, weak session] in
                    guard let self, let session else { return }
                    self.reduce(update, session: session)
                }
            }
            finish()
        }
    }

    private func scheduleBitmapEnrichment(session: ClipboardLoadSession) {
        let deadlineToken = session.scheduleSoftDeadline(after: imageSoftDeadline) {
            [weak self, weak session] in
            guard let self, let session else { return }
            self.handleBitmapSoftDeadline(session: session)
        }
        imageLane.submit(revision: session.revision) { [weak session] finish in
            guard let session, session.accepts(session.revision) else {
                finish()
                return
            }
            let update = ClipboardImageEnricher.enrichBitmap(session: session)
            session.cancelSoftDeadline(deadlineToken)
            finish()
            guard let update else { return }
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self, let session else { return }
                self.reduce(update, session: session)
            }
        }
    }

    private func scheduleFileThumbnailIfNeeded(
        content: ClipboardContent,
        session: ClipboardLoadSession
    ) {
        guard !thumbnailWasScheduled,
              !content.fileSelectionWasTruncated,
              content.fileURLs?.count == 1 else { return }
        thumbnailWasScheduled = true
        imageLane.submit(revision: session.revision) { [weak self, weak session] finish in
            guard let self, let session,
                  session.accepts(session.revision),
                  let content = session.payload(as: ClipboardContent.self),
                  let url = content.fileURLs?.first else {
                finish()
                return
            }
            let deadlineToken = session.scheduleSoftDeadline(after: self.imageSoftDeadline) {
                [weak self, weak session] in
                guard let self, let session else { return }
                self.handleFileThumbnailSoftDeadline(session: session)
            }
            let started = ProcessInfo.processInfo.systemUptime
            if let metadata = ClipboardImageEnricher.enrichImageFile(content: content),
               ProcessInfo.processInfo.systemUptime - started <= self.imageSoftDeadline,
               session.hasPendingSoftDeadline(deadlineToken) {
                DispatchQueue.main.async { [weak self, weak session] in
                    guard let self, let session else { return }
                    self.reduce(metadata, session: session)
                }
            }
            guard ProcessInfo.processInfo.systemUptime - started <= self.imageSoftDeadline,
                  session.hasPendingSoftDeadline(deadlineToken),
                  session.accepts(session.revision) else {
                session.cancelSoftDeadline(deadlineToken)
                finish()
                return
            }
            let token = FilePreviewGenerator.shared.generateThumbnail(
                for: url,
                size: CGSize(width: 128, height: 128),
                scale: session.backingScale,
                revision: session.revision
            ) { [weak self, weak session] token, revision, image in
                session?.cancelSoftDeadline(deadlineToken)
                finish()
                guard let self, let session else { return }
                self.reduce(
                    .thumbnail(revision: revision, token: token, image: image),
                    session: session
                )
            }
            session.setQuickLookToken(token) {
                FilePreviewGenerator.shared.cancel(token: $0)
                finish()
            }
            if !session.hasPendingSoftDeadline(deadlineToken) {
                session.cancelQuickLookRequest()
            }
        }
    }

    private func reduce(
        _ update: ClipboardEnrichmentUpdate,
        session: ClipboardLoadSession
    ) {
        guard Thread.isMainThread,
              activeSession === session,
              session.accepts(update.revision),
              update.revision == session.revision,
              updateIsWithinDeadline(update),
              revisionGate.accept(update.revision),
              var content = activeContent else { return }

        switch update {
        case let .analysis(_, detections):
            content.detections = detections
            content.contentKind = detections.first?.kind
            if let facts = ClipboardDetectionDisplayFacts.derive(from: detections) {
                if !facts.typeLabel.isEmpty {
                    content.displayTypeLabel = facts.typeLabel
                }
                if !facts.iconSymbolName.isEmpty {
                    content.displayIconSymbolName = facts.iconSymbolName
                }
                if let detail = facts.detailOverride {
                    content.detail = detail
                }
            }
            analysisIsReady = true
        case let .actions(_, primary, menu):
            if isActivePresentationVisible {
                toastController?.applyActions(
                    primary: primary,
                    menu: menu,
                    revision: session.revision
                )
            }
            return
        case let .fileFacts(
            _, detail, typeLabel, iconSymbolName, allImages, isComplete, detailIsLoading
        ):
            content.detail = detail
            content.detailIsLoading = detailIsLoading
            content.displayTypeLabel = typeLabel
            content.displayIconSymbolName = iconSymbolName
            content.allFilesAreImages = allImages
            fileClassificationIsReady = true
            fileClassificationIsComplete = isComplete
        case let .imageFacts(_, detail, thumbnail):
            content.detail = detail
            content.detailIsLoading = false
            if let thumbnail {
                content.thumbnail = thumbnail
            }
        case let .thumbnail(_, token, image):
            guard session.matchesQuickLookToken(token) else { return }
            session.clearQuickLookToken(token)
            content.thumbnail = image
        case let .degraded(_, detail):
            content.detail = detail
            content.detailIsLoading = false
        }

        activeContent = content
        session.storePayload(content)
        if isActivePresentationVisible {
            toastController?.applyEnrichment(content, revision: session.revision)
        }

        if content.type == .file, fileClassificationIsReady {
            scheduleAnalysis(session: session, performsDetection: false)
            scheduleFileThumbnailIfNeeded(content: content, session: session)
        }
        tryPresentLowInterruption(session: session)
    }

    private func updateIsWithinDeadline(_ update: ClipboardEnrichmentUpdate) -> Bool {
        switch update {
        case .analysis, .actions:
            return !analysisDeadlineExpired
        case .fileFacts:
            return !fileDeadlineExpired
        case .imageFacts, .thumbnail:
            if case .thumbnail = update {
                return !fileThumbnailDeadlineExpired
            }
            return activeContent?.type == .image
                ? !bitmapDeadlineExpired
                : !fileThumbnailDeadlineExpired
        case .degraded:
            return true
        }
    }

    private func handleAnalysisSoftDeadline(session: ClipboardLoadSession) {
        guard activeSession === session, session.accepts(session.revision) else { return }
        analysisDeadlineExpired = true
        failClosedIfClassificationIsPending(session: session)
    }

    private func handleFileSoftDeadline(session: ClipboardLoadSession) {
        guard activeSession === session, session.accepts(session.revision) else { return }
        fileDeadlineExpired = true
        if var content = activeContent, content.detailIsLoading {
            content.detailIsLoading = false
            activeContent = content
            session.storePayload(content)
            if isActivePresentationVisible {
                toastController?.applyEnrichment(content, revision: session.revision)
            }
        } else {
            applyDegradedDetail(String(localized: "文件信息不可用"), session: session)
        }
        failClosedIfClassificationIsPending(session: session)
    }

    private func handleBitmapSoftDeadline(session: ClipboardLoadSession) {
        guard activeSession === session, session.accepts(session.revision) else { return }
        bitmapDeadlineExpired = true
        applyDegradedDetail(String(localized: "图片无法预览"), session: session)
    }

    private func handleFileThumbnailSoftDeadline(session: ClipboardLoadSession) {
        guard activeSession === session, session.accepts(session.revision) else { return }
        fileThumbnailDeadlineExpired = true
        session.cancelQuickLookRequest()
    }

    private func applyDegradedDetail(_ detail: String, session: ClipboardLoadSession) {
        guard activeSession === session, var content = activeContent else { return }
        content.detail = detail
        content.detailIsLoading = false
        activeContent = content
        session.storePayload(content)
        if isActivePresentationVisible {
            toastController?.applyEnrichment(content, revision: session.revision)
        }
    }

    private func failClosedIfClassificationIsPending(session: ClipboardLoadSession) {
        guard activePreferences?.mode == .lowInterruption,
              !isActivePresentationVisible else { return }
        toastController?.interruptCopyCombo()
        activePresentationWasDropped = true
        session.cancel()
    }

    private func tryPresentLowInterruption(session: ClipboardLoadSession) {
        guard activeSession === session,
              activePreferences?.mode == .lowInterruption,
              !isActivePresentationVisible,
              !activePresentationWasDropped,
              let content = activeContent,
              let preferences = activePreferences else { return }

        switch lowInterruptionDecision(for: content, preferences: preferences) {
        case .wait:
            return
        case .deny:
            toastController?.interruptCopyCombo()
            activePresentationWasDropped = true
            session.cancel()
        case .allow:
            if activeLightReminderEnabled == true {
                showLightReminder(revision: session.revision)
                activePresentationWasDropped = true
                session.cancel()
                return
            }
            let now = Date()
            if content.visualHashValue == lastLowInterruptionHash,
               now.timeIntervalSince(lastLowInterruptionShowTime) < dedupWindow {
                toastController?.confirmCopyIdentity(
                    session.takeCopyIdentity(),
                    revision: session.revision,
                    coalescingWithVisibleToast: true
                )
                activePresentationWasDropped = true
                session.cancel()
                return
            }
            lastLowInterruptionHash = content.visualHashValue
            lastLowInterruptionShowTime = now
            guard let source = activeSource else { return }
            LightReminderController.shared.dismiss(animated: false)
            toastController?.show(content: content, source: source, reusingActions: activeReusesActions,
                                  copyIdentity: session.confirmedCopyIdentity)
            toastController?.confirmCopyIdentity(
                session.takeCopyIdentity(),
                revision: session.revision
            )
            isActivePresentationVisible = true
        }
    }

    private func lowInterruptionDecision(
        for content: ClipboardContent,
        preferences: PopupPresentationPreferences
    ) -> PresentationDecision {
        if activeCandidateDecision == .allAllowed { return .allow }
        switch content.type {
        case .image:
            return preferences.showImages ? .allow : .deny
        case .text:
            guard analysisIsReady else { return .wait }
            return PopupPresentationPolicy.shouldPresent(
                contentType: .text,
                textLength: content.textLength,
                primaryKindID: content.contentKind?.id,
                preferences: preferences
            ) ? .allow : .deny
        case .file:
            guard fileClassificationIsReady else { return .wait }
            return PopupPresentationPolicy.shouldPresentFiles(
                allFilesAreImages: content.allFilesAreImages,
                classificationIsComplete: fileClassificationIsComplete,
                preferences: preferences
            ) ? .allow : .deny
        }
    }

    private func finishFirstResponseBoostIfExpired() {
        guard let deadline = firstResponseBoostDeadline,
              ProcessInfo.processInfo.systemUptime >= deadline else { return }
        finishFirstResponseBoost()
    }

    private func finishFirstResponseBoost() {
        guard firstResponseBoostDeadline != nil else { return }
        firstResponseBoostDeadline = nil
        updatePollingSchedule(at: ProcessInfo.processInfo.systemUptime)
    }

#if COPIED_TESTING
    var testingPollingInterval: TimeInterval? { timer?.timeInterval }
    func testingBeginCopy(
        _ revision: ClipboardRevision, source: SourceAppInfo,
        pasteboard: NSPasteboard? = nil
    ) -> ClipboardLoadSession? {
        prepareRevision(
            revision, source: source,
            privacyDisposition: pasteboard.map {
                ClipboardPrivacyPolicy.disposition(for: $0.types ?? [])
            } ?? .ordinary
        )
    }

    func testingFinishCopy(_ outcome: ClipboardBaseReadOutcome, session: ClipboardLoadSession) {
        receiveBaseRead(outcome, session: session)
    }

    func testingObserveDefaults() {
        refreshCachedSettings()
        installDefaultsObserverIfNeeded()
    }
    var testingRecordsCopyIdentity: Bool {
        cachedCopyComboEnabled && !cachedLightReminderEnabled
    }

    func testingPresentLowInterruption(
        content: ClipboardContent,
        source: SourceAppInfo,
        preferences: PopupPresentationPreferences,
        analysisIsReady: Bool,
        copyIdentity: ClipboardCopyIdentity? = nil
    ) {
        activeSession?.cancel()
        resetActiveRevisionState()
        let session = ClipboardLoadSession(revision: content.revision, backingScale: 2)
        session.storeCopyIdentity(copyIdentity)
        toastController?.observeCopyRevision(content.revision)
        activeSession = session
        activeContent = content
        activeSource = source
        activePreferences = preferences
        activeLightReminderEnabled = false
        activeCandidateDecision = .needsClassification
        self.analysisIsReady = analysisIsReady
        tryPresentLowInterruption(session: session)
    }
#endif
}
