import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func occurrenceCount(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

private final class WarmUpProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var submitCountStorage = 0
    private var lookupWordsStorage: [String] = []
    private var lookupRanOnMainThreadStorage = false

    var submitCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return submitCountStorage
    }

    var lookupWords: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lookupWordsStorage
    }

    var lookupRanOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lookupRanOnMainThreadStorage
    }

    func recordSubmit() {
        lock.lock()
        submitCountStorage += 1
        lock.unlock()
    }

    func recordLookup(word: String) {
        lock.lock()
        lookupWordsStorage.append(word)
        lookupRanOnMainThreadStorage = Thread.isMainThread
        lock.unlock()
    }
}

@main
struct DictionaryWarmUpTests {
    static func main() {
        oneShotSchedulingIsAsynchronousAndThreadSafe()
        productionWiringUsesOnlySyntheticInput()
        print("DictionaryWarmUpTests: PASS")
    }

    private static func oneShotSchedulingIsAsynchronousAndThreadSafe() {
        expect(Thread.isMainThread, "test begins on the main thread")

        let probe = WarmUpProbe()
        let lookupStarted = DispatchSemaphore(value: 0)
        let releaseLookup = DispatchSemaphore(value: 0)
        let lookupFinished = DispatchSemaphore(value: 0)
        let coordinator = DictionaryWarmUpCoordinator(
            syntheticWord: "example",
            submit: { operation in
                probe.recordSubmit()
                DispatchQueue.global(qos: .utility).async(execute: operation)
            },
            lookup: { word in
                probe.recordLookup(word: word)
                lookupStarted.signal()
                _ = releaseLookup.wait(timeout: .now() + 2)
                lookupFinished.signal()
                return nil
            }
        )

        let start = ProcessInfo.processInfo.systemUptime
        coordinator.start()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        coordinator.start()

        expect(elapsed < 0.25, "scheduling does not wait for the lookup")
        expect(
            lookupStarted.wait(timeout: .now() + 1) == .success,
            "scheduled lookup begins"
        )

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            coordinator.start()
        }
        expect(probe.submitCount == 1, "concurrent starts submit exactly one task")

        releaseLookup.signal()
        expect(
            lookupFinished.wait(timeout: .now() + 1) == .success,
            "scheduled lookup finishes"
        )
        coordinator.start()

        expect(probe.submitCount == 1, "a nil lookup result is not retried")
        expect(probe.lookupWords == ["example"], "only the synthetic word is queried")
        expect(!probe.lookupRanOnMainThread, "lookup runs off the main thread")
    }

    private static func productionWiringUsesOnlySyntheticInput() {
        expect(
            DictionaryLookupService.syntheticWarmUpWord == "example",
            "production warm-up uses an explicit synthetic word"
        )

        let appSource = try! String(contentsOfFile: "CopiedApp.swift", encoding: .utf8)
        expect(
            occurrenceCount(
                of: "DictionaryLookupService.scheduleWarmUp()",
                in: appSource
            ) == 1,
            "application startup schedules dictionary warm-up once"
        )

        let actionSource = try! String(contentsOfFile: "ClipboardAction.swift", encoding: .utf8)
        expect(
            occurrenceCount(
                of: "DictionaryLookupService.lookup(text)",
                in: actionSource
            ) == 1,
            "ActionResolver remains the sole dictionary preflight entry"
        )

        let serviceSource = try! String(
            contentsOfFile: "DictionaryLookupService.swift",
            encoding: .utf8
        )
        expect(
            serviceSource.contains("let queue = lookupQueue")
                && serviceSource.contains("lookupQueue.sync"),
            "warm-up and real lookups share the serialized dictionary queue"
        )
        expect(
            !serviceSource.contains("DispatchQueue.main"),
            "dictionary warm-up never targets the main queue"
        )
        expect(!serviceSource.contains("NSLog"), "dictionary warm-up never logs lookup text")
    }
}
