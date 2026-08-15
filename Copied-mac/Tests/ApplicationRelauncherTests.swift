import AppKit
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private struct SyntheticLaunchError: LocalizedError {
    var errorDescription: String? { "synthetic launch failure" }
}

@main
struct ApplicationRelauncherTests {
    @MainActor
    static func main() async {
        openConfigurationStartsAQuietNewInstance()
        await successfulLaunchTerminatesOnce()
        await failedLaunchKeepsCurrentInstance()
        await pendingRequestIsDeduplicated()
        await failureAllowsRetry()
        print("ApplicationRelauncherTests: PASS")
    }

    @MainActor
    private static func openConfigurationStartsAQuietNewInstance() {
        let configuration = ApplicationRelauncher.makeOpenConfiguration()
        expect(
            configuration.createsNewApplicationInstance,
            "relaunch must not reuse the instance that is about to terminate"
        )
        expect(!configuration.activates, "relaunch does not steal focus")
        expect(!configuration.addsToRecentItems, "relaunch does not alter recent items")
    }

    @MainActor
    private static func successfulLaunchTerminatesOnce() async {
        var terminateCount = 0
        let launcher = ApplicationRelauncher(
            launchNewInstance: { completion in completion(.success(())) },
            terminateCurrent: { terminateCount += 1 }
        )

        launcher.relaunch { _ in expect(false, "successful relaunch has no failure") }
        await settleCallbacks()
        expect(terminateCount == 1, "successful launch terminates the current app once")
        launcher.relaunch { _ in expect(false, "termination request remains idempotent") }
        await settleCallbacks()
        expect(terminateCount == 1, "a completed relaunch cannot terminate twice")
    }

    @MainActor
    private static func failedLaunchKeepsCurrentInstance() async {
        var terminateCount = 0
        var failureCount = 0
        let launcher = ApplicationRelauncher(
            launchNewInstance: { completion in
                completion(.failure(SyntheticLaunchError()))
            },
            terminateCurrent: { terminateCount += 1 }
        )

        launcher.relaunch { _ in failureCount += 1 }
        await settleCallbacks()
        expect(terminateCount == 0, "failed launch keeps the current app running")
        expect(failureCount == 1, "failed launch reports one error")
    }

    @MainActor
    private static func pendingRequestIsDeduplicated() async {
        var launchCount = 0
        var terminateCount = 0
        var pendingCompletion: ApplicationRelauncher.LaunchCompletion?
        let launcher = ApplicationRelauncher(
            launchNewInstance: { completion in
                launchCount += 1
                pendingCompletion = completion
            },
            terminateCurrent: { terminateCount += 1 }
        )

        launcher.relaunch { _ in expect(false, "pending success has no failure") }
        launcher.relaunch { _ in expect(false, "duplicate request is ignored") }
        expect(launchCount == 1, "a pending relaunch ignores duplicate requests")

        pendingCompletion?(.success(()))
        pendingCompletion?(.success(()))
        await settleCallbacks()
        expect(terminateCount == 1, "duplicate completion cannot terminate twice")
    }

    @MainActor
    private static func failureAllowsRetry() async {
        var launchCount = 0
        var terminateCount = 0
        var completions: [ApplicationRelauncher.LaunchCompletion] = []
        let launcher = ApplicationRelauncher(
            launchNewInstance: { completion in
                launchCount += 1
                completions.append(completion)
            },
            terminateCurrent: { terminateCount += 1 }
        )

        launcher.relaunch { _ in }
        completions[0](.failure(SyntheticLaunchError()))
        await settleCallbacks()
        launcher.relaunch { _ in expect(false, "retry succeeds") }
        expect(launchCount == 2, "a failed relaunch clears pending state for retry")
        completions[1](.success(()))
        await settleCallbacks()
        expect(terminateCount == 1, "successful retry terminates once")
    }

    private static func settleCallbacks() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}
