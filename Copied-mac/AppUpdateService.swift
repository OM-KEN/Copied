import AppKit
import Combine
import Foundation

enum AppVersion {
    static var currentString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    static var current: SemanticVersion? {
        SemanticVersion(tag: currentString)
    }
}

enum AppUpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case noStableRelease
    case updateAvailable(SemanticVersion)
    case manualFailure(String)
}

final class AppUpdateService: ObservableObject {
    static let shared = AppUpdateService()

    static let automaticRemindersKey = "automaticUpdateRemindersEnabled"
    private static let lastSuccessfulCheckKey = "appUpdateLastSuccessfulCheck"
    private static let lastFailedCheckKey = "appUpdateLastFailedCheck"
    private static let lastToastReminderKey = "appUpdateLastToastReminder"
    private static let cachedReleaseVersionKey = "appUpdateCachedReleaseVersion"
    private static let cachedReleaseURLKey = "appUpdateCachedReleaseURL"
    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/OM-KEN/Copied/releases/latest"
    )!

    @Published private(set) var status: AppUpdateStatus = .idle
    @Published private(set) var availableRelease: AppRelease?
    @Published private(set) var hasPendingToastReminder = false
    @Published private(set) var automaticRemindersEnabled: Bool

    private var automaticTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var dataTask: URLSessionDataTask?
    private var activeCheckIsManual = false
    private var checkGeneration = 0
    private let defaults: UserDefaults
    private let session: URLSession
    private let currentVersionProvider: () -> SemanticVersion?

    var showsMenuUpdateIndicator: Bool {
        automaticRemindersEnabled && availableRelease != nil
    }

    init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        currentVersionProvider: @escaping () -> SemanticVersion? = { AppVersion.current }
    ) {
        self.defaults = defaults
        self.session = session
        self.currentVersionProvider = currentVersionProvider
        defaults.register(defaults: [Self.automaticRemindersKey: true])
        automaticRemindersEnabled = defaults.object(forKey: Self.automaticRemindersKey) as? Bool ?? true
        restoreCachedRelease()
    }

    func startAutomaticChecks() {
        guard automaticRemindersEnabled else { return }
        installAutomaticTriggersIfNeeded()
        checkAutomaticallyIfDue()
    }

    func setAutomaticRemindersEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.automaticRemindersKey)
        automaticRemindersEnabled = enabled
        if enabled {
            installAutomaticTriggersIfNeeded()
            if availableRelease != nil { hasPendingToastReminder = true }
            checkAutomaticallyIfDue()
        } else {
            automaticTimer?.invalidate()
            automaticTimer = nil
            removeAutomaticObservers()
            if !activeCheckIsManual {
                checkGeneration += 1
                dataTask?.cancel()
                dataTask = nil
            }
            hasPendingToastReminder = false
        }
    }

    func checkManually() {
        performCheck(manual: true)
    }

    func shouldAttachUpdateReminderToStandardToast(at now: Date = Date()) -> Bool {
        let policy = UpdateToastReminderPolicy(
            lastDisplayedAt: defaults.object(forKey: Self.lastToastReminderKey) as? Date
        )
        return hasPendingToastReminder && policy.shouldDisplay(
            at: now,
            automaticRemindersEnabled: automaticRemindersEnabled,
            hasAvailableUpdate: availableRelease != nil,
            isLightReminderMode: false
        )
    }

    func recordUpdateReminderDisplayed(at date: Date = Date()) {
        guard hasPendingToastReminder else { return }
        var policy = UpdateToastReminderPolicy(
            lastDisplayedAt: defaults.object(forKey: Self.lastToastReminderKey) as? Date
        )
        policy.recordDisplayed(at: date)
        defaults.set(policy.lastDisplayedAt, forKey: Self.lastToastReminderKey)
        hasPendingToastReminder = false
    }

    private func installAutomaticTriggersIfNeeded() {
        if automaticTimer == nil {
            automaticTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) {
                [weak self] _ in self?.checkAutomaticallyIfDue()
            }
        }
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.checkAutomaticallyIfDue() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.checkAutomaticallyIfDue() })
    }

    private func removeAutomaticObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func checkAutomaticallyIfDue() {
        guard automaticRemindersEnabled, dataTask == nil else { return }
        let schedule = loadSchedule()
        guard schedule.shouldRunAutomaticCheck(at: Date(), enabled: true) else { return }
        performCheck(manual: false)
    }

    private func performCheck(manual: Bool) {
        if let dataTask {
            guard manual else { return }
            checkGeneration += 1
            dataTask.cancel()
            self.dataTask = nil
        }
        if manual {
            status = .checking
        } else if !automaticRemindersEnabled {
            return
        }
        activeCheckIsManual = manual
        checkGeneration += 1
        let generation = checkGeneration

        var request = URLRequest(url: Self.latestReleaseURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Copied/\(AppVersion.currentString)", forHTTPHeaderField: "User-Agent")

        dataTask = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.finishCheck(
                    data: data,
                    response: response,
                    error: error,
                    manual: manual,
                    generation: generation
                )
            }
        }
        dataTask?.resume()
    }

    private func finishCheck(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        manual: Bool,
        generation: Int
    ) {
        guard generation == checkGeneration else { return }
        dataTask = nil
        activeCheckIsManual = false

        if let error {
            recordSchedule(.failure)
            if manual { status = .manualFailure(error.localizedDescription) }
            return
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            recordSchedule(.failure)
            if manual { status = .manualFailure(String(localized: "无效的服务器响应")) }
            return
        }

        switch LatestReleaseParser.parse(statusCode: httpResponse.statusCode, data: data ?? Data()) {
        case .noStableRelease:
            recordSchedule(.noStableRelease)
            availableRelease = nil
            hasPendingToastReminder = false
            status = .noStableRelease
            clearCachedRelease()

        case .failure:
            recordSchedule(.failure)
            if manual {
                status = .manualFailure(String(localized: "无法读取更新信息"))
            }

        case let .release(release):
            recordSchedule(.success)
            guard let currentVersion = currentVersionProvider() else {
                if manual { status = .manualFailure(String(localized: "当前版本号无效")) }
                return
            }
            if release.version > currentVersion {
                availableRelease = release
                cacheRelease(release)
                status = .updateAvailable(release.version)
                if !manual, automaticRemindersEnabled {
                    hasPendingToastReminder = true
                }
            } else {
                availableRelease = nil
                hasPendingToastReminder = false
                status = .upToDate
                clearCachedRelease()
            }
        }
    }

    private func loadSchedule() -> AppUpdateSchedule {
        AppUpdateSchedule(
            lastSuccessfulCheck: defaults.object(forKey: Self.lastSuccessfulCheckKey) as? Date,
            lastFailedCheck: defaults.object(forKey: Self.lastFailedCheckKey) as? Date
        )
    }

    private func recordSchedule(_ outcome: AppUpdateCheckOutcome) {
        var schedule = loadSchedule()
        schedule.record(outcome, at: Date())
        defaults.set(schedule.lastSuccessfulCheck, forKey: Self.lastSuccessfulCheckKey)
        defaults.set(schedule.lastFailedCheck, forKey: Self.lastFailedCheckKey)
    }

    private func restoreCachedRelease() {
        guard let versionString = defaults.string(forKey: Self.cachedReleaseVersionKey),
              let version = SemanticVersion(tag: versionString),
              let urlString = defaults.string(forKey: Self.cachedReleaseURLKey),
              let pageURL = URL(string: urlString),
              let currentVersion = currentVersionProvider() else {
            clearCachedRelease()
            return
        }
        let release = AppRelease(version: version, pageURL: pageURL)
        guard release.hasTrustedPageURL else {
            clearCachedRelease()
            return
        }
        if version > currentVersion {
            availableRelease = release
            status = .updateAvailable(version)
            hasPendingToastReminder = automaticRemindersEnabled
        } else {
            availableRelease = nil
            status = .upToDate
            clearCachedRelease()
        }
    }

    private func cacheRelease(_ release: AppRelease) {
        guard release.hasTrustedPageURL else { return }
        defaults.set(release.version.description, forKey: Self.cachedReleaseVersionKey)
        defaults.set(release.pageURL.absoluteString, forKey: Self.cachedReleaseURLKey)
    }

    private func clearCachedRelease() {
        defaults.removeObject(forKey: Self.cachedReleaseVersionKey)
        defaults.removeObject(forKey: Self.cachedReleaseURLKey)
    }

    func stopForTesting() {
        checkGeneration += 1
        dataTask?.cancel()
        dataTask = nil
        automaticTimer?.invalidate()
        automaticTimer = nil
        removeAutomaticObservers()
    }
}
