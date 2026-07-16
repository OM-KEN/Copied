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
    private static let currentVersion = SemanticVersion(tag: "2.9.1")!
    private static let newerJSON = Data(
        #"{"tag_name":"v2.10.0","html_url":"https://github.com/OM-KEN/Copied/releases/tag/v2.10.0"}"#.utf8
    )
    private static let olderJSON = Data(
        #"{"tag_name":"v2.9.0","html_url":"https://github.com/OM-KEN/Copied/releases/tag/v2.9.0"}"#.utf8
    )

    static func main() {
        automaticDisabledDoesNotRequest()
        manualCheckWorksWhileAutomaticDisabled()
        backgroundFailureIsSilent()
        manualFailureIsVisible()
        notFoundMeansNoStableRelease()
        releaseComparisonUsesSemanticVersioning()
        cachedReleaseRestoresAcrossInstances()
        disablingClearsMenuAndPendingReminder()
        observableObjectPublishesSharedUIStateChanges()
        print("AppUpdateServiceTests: PASS")
    }

    private static func makeDefaults() -> UserDefaults {
        let suite = "com.copied.update-tests.\(UUID().uuidString)"
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
}
