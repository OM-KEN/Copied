import Foundation
import Combine

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func waitUntil(
    timeout: TimeInterval = 2,
    _ condition: @escaping () -> Bool
) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
}

private final class MockURLProtocol: URLProtocol {
    struct Response {
        let statusCode: Int?
        let data: Data
        let error: Error?

        static func http(_ statusCode: Int, _ data: Data = Data()) -> Response {
            Response(statusCode: statusCode, data: data, error: nil)
        }

        static func failure(_ error: Error) -> Response {
            Response(statusCode: nil, data: Data(), error: error)
        }
    }

    private static let lock = NSLock()
    private static var response = Response.http(404)
    private static var count = 0

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    static func reset(response: Response) {
        lock.lock()
        self.response = response
        count = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let response = Self.response
        Self.lock.unlock()

        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode!,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
struct AppUpdateServiceTests {
    private static var defaultsSuites: [String] = []
    private static let currentVersion = SemanticVersion(tag: "2.9.1")!
    private static let importantMarker = "<!-- copied:important-update -->"
    private static let newerJSON = Data(
        #"{"tag_name":"v2.10.0","html_url":"https://github.com/OM-KEN/Copied/releases/tag/v2.10.0"}"#.utf8
    )
    private static let olderJSON = Data(
        #"{"tag_name":"v2.9.0","html_url":"https://github.com/OM-KEN/Copied/releases/tag/v2.9.0"}"#.utf8
    )

    static func main() {
        defer {
            for suite in defaultsSuites {
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            }
        }
        automaticDisabledDoesNotRequest()
        manualCheckWorksWhileAutomaticDisabled()
        backgroundFailureIsSilent()
        manualFailureIsVisible()
        notFoundMeansNoStableRelease()
        releaseComparisonUsesSemanticVersioning()
        cachedReleaseRestoresAcrossInstances()
        disablingClearsMenuAndPendingReminder()
        observableObjectPublishesSharedUIStateChanges()
        ordinaryReleasesDoNotShowImportantPrompt()
        importantReleasesAtOrBelowCurrentDoNotPrompt()
        importantPromptIsOnceAcrossChecksAndInstances()
        higherImportantVersionPromptsAndOlderVersionsStaySeen()
        cachedImportantReleaseWaitsForPresenter()
        releaseNotesRestoreAcrossInstances()
        ordinaryReleaseReplacesCachedImportantFlag()
        failedPresentationDoesNotConsumeReminder()
        oldCacheDefaultsToOrdinaryUpdate()
        disabledImportantPromptsPreserveManualChecks()
        manualCheckDoesNotOpenImportantPrompt()
        print("AppUpdateServiceTests: PASS")
    }

    private static func makeDefaults() -> UserDefaults {
        let suite = "com.copied.update-tests.\(UUID().uuidString)"
        defaultsSuites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    private static func makeService(defaults: UserDefaults) -> AppUpdateService {
        AppUpdateService(
            defaults: defaults,
            session: makeSession(),
            currentVersionProvider: { currentVersion }
        )
    }

    private static func automaticDisabledDoesNotRequest() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppUpdateService.automaticRemindersKey)
        MockURLProtocol.reset(response: .http(404))
        let service = makeService(defaults: defaults)
        service.startAutomaticChecks()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        expect(MockURLProtocol.requestCount == 0, "automatic off must not request")
        service.stopForTesting()
    }

    private static func manualCheckWorksWhileAutomaticDisabled() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppUpdateService.automaticRemindersKey)
        MockURLProtocol.reset(response: .http(404))
        let service = makeService(defaults: defaults)
        service.checkManually()
        waitUntil { service.status == .noStableRelease }
        expect(MockURLProtocol.requestCount == 1, "manual check requests while automatic is off")
        service.stopForTesting()
    }

    private static func backgroundFailureIsSilent() {
        let defaults = makeDefaults()
        MockURLProtocol.reset(response: .failure(URLError(.notConnectedToInternet)))
        let service = makeService(defaults: defaults)
        service.startAutomaticChecks()
        waitUntil { MockURLProtocol.requestCount == 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        if case .manualFailure = service.status {
            expect(false, "background error must not expose manualFailure")
        }
        service.stopForTesting()
    }

    private static func manualFailureIsVisible() {
        let defaults = makeDefaults()
        MockURLProtocol.reset(response: .failure(URLError(.timedOut)))
        let service = makeService(defaults: defaults)
        service.checkManually()
        waitUntil {
            if case .manualFailure = service.status { return true }
            return false
        }
        if case .manualFailure = service.status {} else {
            expect(false, "manual error must be visible")
        }
        service.stopForTesting()
    }

    private static func notFoundMeansNoStableRelease() {
        let defaults = makeDefaults()
        MockURLProtocol.reset(response: .http(200, newerJSON))
        let seeded = makeService(defaults: defaults)
        seeded.checkManually()
        waitUntil { seeded.availableRelease != nil }
        seeded.stopForTesting()

        MockURLProtocol.reset(response: .http(404))
        let service = makeService(defaults: defaults)
        service.checkManually()
        waitUntil { service.status == .noStableRelease }
        expect(service.availableRelease == nil, "404 clears available release")
        service.stopForTesting()

        let restored = makeService(defaults: defaults)
        expect(restored.availableRelease == nil, "404 clears persisted release cache")
        restored.stopForTesting()
    }

    private static func releaseComparisonUsesSemanticVersioning() {
        let defaults = makeDefaults()
        MockURLProtocol.reset(response: .http(200, newerJSON))
        let newerService = makeService(defaults: defaults)
        newerService.checkManually()
        waitUntil { newerService.availableRelease?.version == SemanticVersion(tag: "2.10.0") }
        expect(newerService.availableRelease != nil, "2.10.0 is newer than 2.9.1")
        newerService.stopForTesting()

        MockURLProtocol.reset(response: .http(200, olderJSON))
        let olderService = makeService(defaults: makeDefaults())
        olderService.checkManually()
        waitUntil { olderService.status == .upToDate }
        expect(olderService.availableRelease == nil, "older release is not offered")
        olderService.stopForTesting()

        let cacheDefaults = makeDefaults()
        MockURLProtocol.reset(response: .http(200, newerJSON))
        let cached = makeService(defaults: cacheDefaults)
        cached.checkManually()
        waitUntil { cached.availableRelease != nil }
        MockURLProtocol.reset(response: .http(200, olderJSON))
        cached.checkManually()
        waitUntil { cached.status == .upToDate }
        cached.stopForTesting()
        let afterUpToDate = makeService(defaults: cacheDefaults)
        expect(afterUpToDate.availableRelease == nil, "up-to-date result clears persisted release cache")
        afterUpToDate.stopForTesting()
    }

    private static func cachedReleaseRestoresAcrossInstances() {
        let defaults = makeDefaults()
        MockURLProtocol.reset(response: .http(200, newerJSON))
        let first = makeService(defaults: defaults)
        first.checkManually()
        waitUntil { first.availableRelease != nil }
        first.stopForTesting()

        MockURLProtocol.reset(response: .http(500))
        let restored = makeService(defaults: defaults)
        expect(restored.availableRelease?.version == SemanticVersion(tag: "2.10.0"), "cached release restores")
        expect(restored.status == .updateAvailable(SemanticVersion(tag: "2.10.0")!), "cached status restores")
        expect(restored.hasPendingToastReminder, "cached release restores Toast eligibility")
        expect(MockURLProtocol.requestCount == 0, "cache restore does not request")
        restored.stopForTesting()
    }

    private static func disablingClearsMenuAndPendingReminder() {
        let defaults = makeDefaults()
        MockURLProtocol.reset(response: .http(200, newerJSON))
        let first = makeService(defaults: defaults)
        first.checkManually()
        waitUntil { first.availableRelease != nil }
        first.stopForTesting()

        let restored = makeService(defaults: defaults)
        expect(restored.showsMenuUpdateIndicator, "restored update marks menu while enabled")
        expect(restored.hasPendingToastReminder, "restored update is pending while enabled")
        restored.setAutomaticRemindersEnabled(false)
        expect(!restored.showsMenuUpdateIndicator, "toggle off hides menu marker")
        expect(!restored.hasPendingToastReminder, "toggle off clears pending Toast")
        expect(restored.availableRelease != nil, "About retains known release")
        restored.stopForTesting()
    }

    private static func observableObjectPublishesSharedUIStateChanges() {
        let defaults = makeDefaults()
        let service = makeService(defaults: defaults)
        var emissionCount = 0
        let cancellable = service.objectWillChange.sink { emissionCount += 1 }
        service.setAutomaticRemindersEnabled(false)
        expect(emissionCount > 0, "ObservableObject publishes toggle changes used by menu/About")
        expect(AppUpdateService.shared === AppUpdateService.shared, "SwiftUI holders use one shared singleton")
        withExtendedLifetime(cancellable) {}
        service.stopForTesting()
    }

    private static func releaseJSON(version: String = "2.10.0", body: String? = nil) -> Data {
        var response: [String: Any] = [
            "tag_name": "v\(version)",
            "html_url": "https://github.com/OM-KEN/Copied/releases/tag/v\(version)"
        ]
        if let body { response["body"] = body }
        return try! JSONSerialization.data(withJSONObject: response)
    }

    private static func checkAutomatically(
        _ service: AppUpdateService,
        defaults: UserDefaults,
        json: Data
    ) {
        defaults.removeObject(forKey: "appUpdateLastSuccessfulCheck")
        defaults.removeObject(forKey: "appUpdateLastFailedCheck")
        MockURLProtocol.reset(response: .http(200, json))
        service.startAutomaticChecks()
        waitUntil { defaults.object(forKey: "appUpdateLastSuccessfulCheck") is Date }
        expect(defaults.object(forKey: "appUpdateLastSuccessfulCheck") is Date, "automatic check completed")
    }

    private static func ordinaryReleasesDoNotShowImportantPrompt() {
        for body in [nil, "Ordinary release notes", "Inline \(importantMarker)"] as [String?] {
            let defaults = makeDefaults()
            let service = makeService(defaults: defaults)
            var shown = 0
            service.installImportantUpdatePresenter { _ in shown += 1; return true }
            checkAutomatically(service, defaults: defaults, json: releaseJSON(body: body))
            expect(shown == 0, "ordinary update does not open an important prompt")
            expect(service.hasPendingToastReminder, "ordinary update retains the standard Toast reminder")
            service.stopForTesting()
        }
    }

    private static func importantReleasesAtOrBelowCurrentDoNotPrompt() {
        for version in ["2.9.0", "2.9.1"] {
            let defaults = makeDefaults()
            let service = makeService(defaults: defaults)
            var shown = 0
            service.installImportantUpdatePresenter { _ in shown += 1; return true }
            checkAutomatically(service, defaults: defaults, json: releaseJSON(version: version, body: importantMarker))
            expect(service.status == .upToDate && shown == 0, "important release must be newer than the installed version")
            service.stopForTesting()
        }
    }

    private static func importantPromptIsOnceAcrossChecksAndInstances() {
        let defaults = makeDefaults()
        let service = makeService(defaults: defaults)
        var shown: [AppRelease] = []
        service.installImportantUpdatePresenter { shown.append($0); return true }
        checkAutomatically(service, defaults: defaults, json: releaseJSON(body: importantMarker))
        expect(shown.count == 1, "new important release opens once")
        expect(shown.first?.pageURL.absoluteString == "https://github.com/OM-KEN/Copied/releases/tag/v2.10.0", "presenter receives the release page")
        checkAutomatically(service, defaults: defaults, json: releaseJSON(body: importantMarker))
        expect(shown.count == 1, "repeated automatic checks do not reopen the same important release")
        service.stopForTesting()

        let restored = makeService(defaults: defaults)
        restored.installImportantUpdatePresenter { shown.append($0); return true }
        restored.startAutomaticChecks()
        expect(shown.count == 1, "recreating the service does not reopen a shown release")
        restored.stopForTesting()
    }

    private static func higherImportantVersionPromptsAndOlderVersionsStaySeen() {
        let defaults = makeDefaults()
        let service = makeService(defaults: defaults)
        var shown: [SemanticVersion] = []
        service.installImportantUpdatePresenter { shown.append($0.version); return true }
        for version in ["2.10.0", "2.11.0", "2.10.0", "2.10.1"] {
            checkAutomatically(service, defaults: defaults, json: releaseJSON(version: version, body: importantMarker))
        }
        expect(shown == [SemanticVersion(tag: "2.10.0")!, SemanticVersion(tag: "2.11.0")!], "higher versions prompt, server rollback stays below the displayed high-water mark")
        service.stopForTesting()

        let restored = makeService(defaults: defaults)
        restored.installImportantUpdatePresenter { shown.append($0.version); return true }
        restored.startAutomaticChecks()
        expect(shown.count == 2, "restoring a rolled-back cache preserves the higher displayed version")
        restored.stopForTesting()
    }

    private static func cachedImportantReleaseWaitsForPresenter() {
        let defaults = makeDefaults()
        let withoutPresenter = makeService(defaults: defaults)
        checkAutomatically(withoutPresenter, defaults: defaults, json: releaseJSON(body: importantMarker))
        withoutPresenter.stopForTesting()

        MockURLProtocol.reset(response: .http(500))
        let restored = makeService(defaults: defaults)
        expect(restored.availableRelease?.isImportantUpdate == true, "important flag survives cache restoration")
        var shown = 0
        restored.installImportantUpdatePresenter { _ in shown += 1; return true }
        expect(shown == 0, "installing the presenter does not display before automatic checks start")
        restored.startAutomaticChecks()
        expect(shown == 1, "missing presenter did not consume the cached important release")
        expect(MockURLProtocol.requestCount == 0, "cached important reminder works during the 24-hour check interval")
        restored.stopForTesting()
    }

    private static func failedPresentationDoesNotConsumeReminder() {
        let defaults = makeDefaults()
        let service = makeService(defaults: defaults)
        var attempts = 0
        var canShow = false
        service.installImportantUpdatePresenter { _ in attempts += 1; return canShow }
        checkAutomatically(service, defaults: defaults, json: releaseJSON(body: importantMarker))
        expect(attempts == 1, "presenter was asked to show the new release")
        canShow = true
        service.startAutomaticChecks()
        expect(attempts == 2, "failed presentation leaves a later display opportunity")
        service.startAutomaticChecks()
        expect(attempts == 2, "successful presentation consumes the opportunity")
        service.stopForTesting()
    }

    private static func ordinaryReleaseReplacesCachedImportantFlag() {
        let defaults = makeDefaults()
        let service = makeService(defaults: defaults)
        checkAutomatically(service, defaults: defaults, json: releaseJSON(body: "\(importantMarker)\n## Fixes\n- Important fix."))
        checkAutomatically(service, defaults: defaults, json: releaseJSON(version: "2.11.0", body: "Ordinary release notes."))
        service.stopForTesting()

        let restored = makeService(defaults: defaults)
        expect(restored.availableRelease?.version == SemanticVersion(tag: "2.11.0"), "new ordinary release replaces the cached version")
        expect(restored.availableRelease?.isImportantUpdate == false, "new ordinary release clears the cached important flag")
        expect(restored.availableRelease?.releaseNotes == "Ordinary release notes.", "new ordinary release replaces the cached notes")
        var shown = 0
        restored.installImportantUpdatePresenter { _ in shown += 1; return true }
        restored.startAutomaticChecks()
        expect(shown == 0, "ordinary release does not inherit the previous release's important prompt")
        restored.stopForTesting()
    }

    private static func oldCacheDefaultsToOrdinaryUpdate() {
        let defaults = makeDefaults()
        defaults.set("2.10.0", forKey: "appUpdateCachedReleaseVersion")
        defaults.set("https://github.com/OM-KEN/Copied/releases/tag/v2.10.0", forKey: "appUpdateCachedReleaseURL")
        defaults.set(Date(), forKey: "appUpdateLastSuccessfulCheck")
        MockURLProtocol.reset(response: .http(500))
        let service = makeService(defaults: defaults)
        expect(service.availableRelease?.isImportantUpdate == false, "old caches without an important flag stay ordinary")
        expect(service.availableRelease?.releaseNotes.isEmpty == true, "old caches without notes restore an empty body")
        var shown = 0
        service.installImportantUpdatePresenter { _ in shown += 1; return true }
        service.startAutomaticChecks()
        expect(shown == 0 && MockURLProtocol.requestCount == 0, "ordinary old cache is silent without bypassing the check interval")
        service.stopForTesting()
    }

    private static func releaseNotesRestoreAcrossInstances() {
        let defaults = makeDefaults()
        let notes = "\(importantMarker)\r\n## Fixes\r\n- Important fix.\r\n\r\n## 修复\r\n- 重要修复。"
        let service = makeService(defaults: defaults)
        checkAutomatically(service, defaults: defaults, json: releaseJSON(body: notes))
        expect(service.availableRelease?.releaseNotes == notes, "latest response retains the actual release notes")
        service.stopForTesting()

        MockURLProtocol.reset(response: .http(500))
        let restored = makeService(defaults: defaults)
        expect(restored.availableRelease?.releaseNotes == notes, "release notes survive service recreation")
        expect(restored.availableRelease?.displayNotes(localization: "zh-Hant") == "## 修复\n- 重要修复。", "restored notes retain language selection without rewriting the release text")
        var displayedNotes = ""
        restored.installImportantUpdatePresenter { release in
            displayedNotes = release.displayNotes(localization: "en")
            return true
        }
        restored.startAutomaticChecks()
        expect(displayedNotes == "## Fixes\n- Important fix.", "cached prompt receives the concrete release notes")
        expect(MockURLProtocol.requestCount == 0, "restored notes remain available during the daily check interval")
        restored.stopForTesting()
    }

    private static func disabledImportantPromptsPreserveManualChecks() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppUpdateService.automaticRemindersKey)
        let service = makeService(defaults: defaults)
        var shown = 0
        service.installImportantUpdatePresenter { _ in shown += 1; return true }
        MockURLProtocol.reset(response: .http(200, releaseJSON(body: importantMarker)))
        service.startAutomaticChecks()
        expect(MockURLProtocol.requestCount == 0, "disabled important reminders do not start automatic requests")
        service.checkManually()
        waitUntil { service.availableRelease != nil }
        expect(service.availableRelease?.isImportantUpdate == true, "manual check still finds an important update while reminders are disabled")
        expect(shown == 0 && !service.hasPendingToastReminder, "manual check while disabled does not open an automatic prompt")
        service.stopForTesting()

        let restored = makeService(defaults: defaults)
        restored.installImportantUpdatePresenter { _ in shown += 1; return true }
        restored.startAutomaticChecks()
        expect(shown == 0, "disabled cache restoration stays silent")
        restored.setAutomaticRemindersEnabled(true)
        expect(shown == 1, "enabling reminders presents the cached important release")
        restored.stopForTesting()
    }

    private static func manualCheckDoesNotOpenImportantPrompt() {
        let defaults = makeDefaults()
        let service = makeService(defaults: defaults)
        var shown = 0
        service.installImportantUpdatePresenter { _ in shown += 1; return true }
        MockURLProtocol.reset(response: .http(200, releaseJSON(body: importantMarker)))
        service.checkManually()
        waitUntil { service.availableRelease != nil }
        expect(service.status == .updateAvailable(SemanticVersion(tag: "2.10.0")!), "manual check retains its update-available status")
        expect(shown == 0, "manual checks retain their existing non-window feedback")
        service.stopForTesting()
    }
}
