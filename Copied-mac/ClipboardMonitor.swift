import AppKit

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
    private enum PresentationDecision {
        case allow
        case deny
        case wait
    }

    private var timer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    private var lastObservedChangeCount = 0
    private var revisionGeneration: UInt64 = 0
    private var lastLowInterruptionHash = 0
    private var lastLowInterruptionShowTime = Date.distantPast
    private let dedupWindow: TimeInterval = 0.5
    private let firstResponsePollInterval: TimeInterval = 0.025
    private let steadyStatePollInterval: TimeInterval = 0.075
    private let firstResponseBoostDuration: TimeInterval = 60
    private var firstResponseBoostDeadline: TimeInterval?

    private var cachedIsPaused: Bool
    private var cachedPreferences: PopupPresentationPreferences
    private var cachedLightReminderEnabled: Bool
    private var cachedSoundSelection: String
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
    private var activeLightReminderEnabled: Bool?
    private var activeCandidateDecision: PopupPresentationPolicy.CandidateDecision?
    private var activeSoundSelection: String?
    private var activeLightReminderWasPresented = false
    private var activeContent: ClipboardContent?
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

    init(toastController: ToastWindowController) {
        self.toastController = toastController
        let defaults = UserDefaults.standard
        cachedIsPaused = defaults.bool(forKey: "isPaused")
        cachedPreferences = PopupPresentationPreferences.current(defaults: defaults)
        cachedLightReminderEnabled = defaults.bool(forKey: "lightReminderEnabled")
        cachedSoundSelection = CopySoundFeedback.resolvedSelection(
            defaults.string(forKey: CopySoundFeedback.defaultsKey)
        )
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
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
        scheduleTimer(withTimeInterval: firstResponsePollInterval)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        firstResponseBoostDeadline = nil
        activeSession?.cancel()
        activeSession = nil
        toastController?.onRevisionResourcesShouldCancel = nil
    }

    private func installDefaultsObserverIfNeeded() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            self?.refreshCachedSettings()
        }
    }

    private func refreshCachedSettings() {
        let defaults = UserDefaults.standard
        availableKindIDs = Set(DetectionRegistry.shared.allRegisteredKinds.map(\.id))
        cachedIsPaused = defaults.bool(forKey: "isPaused")
        cachedPreferences = PopupPresentationPreferences.current(defaults: defaults)
        cachedLightReminderEnabled = defaults.bool(forKey: "lightReminderEnabled")
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

    private func checkClipboard() {
        guard !cachedIsPaused else { return }
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastObservedChangeCount else {
            finishFirstResponseBoostIfExpired()
            return
        }

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
        revisionGate.activate(revision)
        activeSession?.cancel()
        baseLane.discardPending(olderThan: revision)
        analysisLane.discardPending(olderThan: revision)
        fileLane.discardPending(olderThan: revision)
        imageLane.discardPending(olderThan: revision)
        resetActiveRevisionState()

        let source = SourceAppDetector.cachedSnapshot()
        guard AppFilterSettings.shared.shouldShowPopup(for: source.bundleIdentifier) else {
            finishFirstResponseBoost()
            return
        }

        let preferences = cachedPreferences
        let lightReminderEnabled = cachedLightReminderEnabled
        let soundSelection = cachedSoundSelection
        let candidateDecision = PopupPresentationPolicy.candidateDecision(
            preferences: preferences,
            availableKindIDs: availableKindIDs
        )

        let session = ClipboardLoadSession(revision: revision, backingScale: backingScale)
        activeSession = session
        activeSource = source
        activePreferences = preferences
        activeLightReminderEnabled = lightReminderEnabled
        activeCandidateDecision = candidateDecision
        activeSoundSelection = soundSelection
        toastController?.onRevisionResourcesShouldCancel = { [weak self, weak session] revision in
            guard let self, let session, revision == session.revision,
                  self.activeSession === session else { return }
            session.cancel()
        }

        if lightReminderEnabled,
           (preferences.mode == .all || candidateDecision == .allAllowed) {
            LightReminderController.shared.show()
            activeLightReminderWasPresented = true
        } else if !lightReminderEnabled,
                  candidateDecision != .allDenied,
                  (preferences.mode == .all || candidateDecision == .allAllowed) {
            // This is deliberately synchronous in the timer callback and precedes base-lane work.
            toastController?.showPending(revision: revision, source: source)
            isActivePresentationVisible = true
        }

        session.scheduleRetry(after: 3) { [weak self, weak session] in
            guard let self, let session, self.activeSession === session else { return }
            self.handleLoadTimeout(session: session)
        }
        submitBaseRead(session: session)
    }

    private func resetActiveRevisionState() {
        activeSource = nil
        activePreferences = nil
        activeLightReminderEnabled = nil
        activeCandidateDecision = nil
        activeSoundSelection = nil
        activeLightReminderWasPresented = false
        activeContent = nil
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
        case .unreadable:
            if session.attemptCount < 3 {
                session.scheduleRetry { [weak self, weak session] in
                    guard let self, let session, self.activeSession === session else { return }
                    self.submitBaseRead(session: session)
                }
            } else {
                handleLoadFailure(session: session)
            }
        case let .content(_, content):
            session.cancelScheduledWorkItems()
            if let activeSoundSelection {
                // A changeCount alone is not enough: unreadable clipboard writes stay silent.
                CopySoundFeedback.play(selection: activeSoundSelection)
            }
            finishFirstResponseBoost()

            // An already-shown light reminder and an all-denied visual policy need only
            // the validated base read for sound; hidden enrichment would waste resources.
            if activeLightReminderWasPresented || activeCandidateDecision == .allDenied {
                session.cancel()
                return
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
                    revision: session.revision
                )
            }
            scheduleEnrichment(for: content, session: session)
            tryPresentLowInterruption(session: session)
        }
    }

    private func handleLoadFailure(session: ClipboardLoadSession) {
        guard activeSession === session else { return }
        session.cancelScheduledWorkItems()
        finishFirstResponseBoost()
        if activePreferences?.mode == .all, activeLightReminderEnabled == false {
            toastController?.showFailure(revision: session.revision)
        } else {
            toastController?.dismissSilently(revision: session.revision)
            session.cancel()
        }
    }

    private func handleLoadTimeout(session: ClipboardLoadSession) {
        guard activeSession === session, activeContent == nil else { return }
        if activePreferences?.mode == .all, activeLightReminderEnabled == false {
            toastController?.showFailure(revision: session.revision)
        } else {
            toastController?.dismissSilently(revision: session.revision)
        }
        session.cancel()
        finishFirstResponseBoost()
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
                shouldCancel: { !session.accepts(session.revision) }
            ) { update in
                DispatchQueue.main.async { [weak self, weak session] in
                    guard let self, let session else { return }
                    self.reduce(update, session: session)
                }
            }
            session.cancelSoftDeadline(deadlineToken)
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

        var shouldApplyEnrichment = true
        switch update {
        case let .analysis(_, detections):
            content.detections = detections
            content.contentKind = detections.first?.kind
            if let facts = ClipboardDetectionDisplayFacts.derive(from: detections) {
                content.displayTypeLabel = facts.typeLabel
                content.displayIconSymbolName = facts.iconSymbolName
                if let detail = facts.detailOverride {
                    content.detail = detail
                }
            }
            analysisIsReady = true
        case let .actions(_, primary, menu):
            shouldApplyEnrichment = false
            if isActivePresentationVisible {
                toastController?.applyActions(
                    primary: primary,
                    menu: menu,
                    revision: session.revision
                )
            }
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
        if isActivePresentationVisible, shouldApplyEnrichment {
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
            activePresentationWasDropped = true
            session.cancel()
        case .allow:
            if activeLightReminderEnabled == true {
                LightReminderController.shared.show()
                activePresentationWasDropped = true
                session.cancel()
                return
            }
            let now = Date()
            if content.visualHashValue == lastLowInterruptionHash,
               now.timeIntervalSince(lastLowInterruptionShowTime) < dedupWindow {
                activePresentationWasDropped = true
                session.cancel()
                return
            }
            lastLowInterruptionHash = content.visualHashValue
            lastLowInterruptionShowTime = now
            guard let source = activeSource else { return }
            toastController?.show(content: content, source: source)
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
        scheduleTimer(withTimeInterval: steadyStatePollInterval)
    }
}
