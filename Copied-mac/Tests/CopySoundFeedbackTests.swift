import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private final class PlaybackEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []

    func append(_ event: String) {
        lock.lock()
        storedEvents.append(event)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }
}

private final class RecordingSoundPlayer: CopySoundPlaying {
    private let soundName: String
    private let recorder: PlaybackEventRecorder
    private var storedVolume: Float = 1

    init(soundName: String, recorder: PlaybackEventRecorder) {
        self.soundName = soundName
        self.recorder = recorder
    }

    var volume: Float {
        get { storedVolume }
        set {
            storedVolume = newValue
            recorder.append(
                "volume:\(soundName):\(newValue):main=\(Thread.isMainThread)"
            )
        }
    }

    func stop() {
        recorder.append("stop:\(soundName):main=\(Thread.isMainThread)")
    }

    func play() -> Bool {
        recorder.append("play:\(soundName):main=\(Thread.isMainThread)")
        return true
    }
}

@main
struct CopySoundFeedbackTests {
    static func main() {
        testSelectionPolicy()
        testDispatchGateOnlyClaimsOncePerCopy()
        testPlaybackReturnsBeforeQueuedWorkRuns()
        testPlaybackRunsSeriallyAndReplacesTheActiveSound()

        print("CopySoundFeedbackTests: PASS")
    }

    private static func testSelectionPolicy() {
        expect(
            CopySoundFeedback.defaultSoundName == "Frog",
            "Frog is the default copy sound"
        )
        expect(
            CopySoundFeedback.resolvedSelection(nil) == CopySoundFeedback.defaultSoundName,
            "missing preference uses the default sound"
        )
        expect(
            CopySoundFeedback.resolvedSelection(CopySoundFeedback.disabledValue)
                == CopySoundFeedback.disabledValue,
            "disabled preference remains disabled"
        )
        expect(
            CopySoundFeedback.resolvedSelection("Tink") == "Tink",
            "valid system sound remains selected"
        )
        expect(
            CopySoundFeedback.resolvedSelection("Unknown") == CopySoundFeedback.defaultSoundName,
            "invalid preference falls back to the default sound"
        )
        expect(
            CopySoundFeedback.availableSoundNames.contains(CopySoundFeedback.defaultSoundName),
            "default sound is available in the picker"
        )
        expect(
            CopySoundFeedback.playbackVolume == 0.5,
            "copy feedback uses half volume"
        )
    }

    private static func testDispatchGateOnlyClaimsOncePerCopy() {
        var gate = CopySoundDispatchGate()
        expect(
            gate.claim(selection: "Frog") == "Frog",
            "the first terminal outcome claims the configured sound"
        )
        expect(
            gate.claim(selection: "Tink") == nil,
            "later readable, failure, or timeout outcomes cannot replay the same copy sound"
        )

        var gateWithoutSelection = CopySoundDispatchGate()
        expect(
            gateWithoutSelection.claim(selection: nil) == nil,
            "an absent selection does not dispatch a sound"
        )
        expect(
            gateWithoutSelection.claim(selection: "Frog") == "Frog",
            "an absent selection does not consume the copy's single dispatch"
        )
    }

    private static func testPlaybackReturnsBeforeQueuedWorkRuns() {
        let queue = DispatchQueue(label: "CopySoundFeedbackTests.blocked-audio")
        let blockerStarted = DispatchSemaphore(value: 0)
        let unblockQueue = DispatchSemaphore(value: 0)
        queue.async {
            blockerStarted.signal()
            unblockQueue.wait()
        }
        expect(
            blockerStarted.wait(timeout: .now() + 1) == .success,
            "audio queue blocker starts"
        )

        let recorder = PlaybackEventRecorder()
        let engine = CopySoundPlaybackEngine(queue: queue) { url in
            recorder.append("load:\(url.path):main=\(Thread.isMainThread)")
            return RecordingSoundPlayer(
                soundName: url.deletingPathExtension().lastPathComponent,
                recorder: recorder
            )
        }

        let start = Date.timeIntervalSinceReferenceDate
        engine.play(selection: "Tink")
        let elapsed = Date.timeIntervalSinceReferenceDate - start
        let eventsBeforeUnblock = recorder.snapshot()

        unblockQueue.signal()
        queue.sync {}

        expect(elapsed < 0.05, "play returns without waiting for audio work")
        expect(eventsBeforeUnblock.isEmpty, "play only schedules audio work")
        expect(
            recorder.snapshot().allSatisfy { $0.hasSuffix("main=false") },
            "loading, volume, and playback stay off the main thread"
        )
    }

    private static func testPlaybackRunsSeriallyAndReplacesTheActiveSound() {
        let queue = DispatchQueue(label: "CopySoundFeedbackTests.serial-audio")
        let recorder = PlaybackEventRecorder()
        let engine = CopySoundPlaybackEngine(queue: queue) { url in
            recorder.append("load:\(url.path):main=\(Thread.isMainThread)")
            return RecordingSoundPlayer(
                soundName: url.deletingPathExtension().lastPathComponent,
                recorder: recorder
            )
        }

        engine.play(selection: "Tink")
        engine.play(selection: "Unknown")
        engine.play(selection: CopySoundFeedback.disabledValue)
        queue.sync {}

        expect(
            recorder.snapshot() == [
                "load:/System/Library/Sounds/Tink.aiff:main=false",
                "volume:Tink:0.5:main=false",
                "play:Tink:main=false",
                "stop:Tink:main=false",
                "load:/System/Library/Sounds/Frog.aiff:main=false",
                "volume:Frog:0.5:main=false",
                "play:Frog:main=false",
                "stop:Frog:main=false",
            ],
            "rapid calls stop the old sound and process the latest selection in order"
        )
    }
}
