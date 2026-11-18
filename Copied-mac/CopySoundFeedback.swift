import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

protocol CopySoundPlaying: AnyObject {
    var volume: Float { get set }
    var currentTime: TimeInterval { get set }

    func stop()

    @discardableResult
    func play() -> Bool
}

extension AVAudioPlayer: CopySoundPlaying {}

struct CopySoundDispatchGate {
    private var hasClaimed = false

    mutating func claim(selection: String?) -> String? {
        guard !hasClaimed, let selection else { return nil }
        hasClaimed = true
        return selection
    }
}

final class CopySoundPlaybackEngine: @unchecked Sendable {
    typealias PlayerFactory = @Sendable (URL) throws -> any CopySoundPlaying

    private static let audioSystemLookup: Void = {
        var mixer = AudioComponentDescription(
            componentType: kAudioUnitType_Mixer,
            componentSubType: kAudioUnitSubType_MultiChannelMixer,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        _ = AudioComponentFindNext(nil, &mixer)

        var property = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device
        )
    }()

    private let queue: DispatchQueue
    private let playerFactory: PlayerFactory
    private var activeSound: (selection: String, player: any CopySoundPlaying)?

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "com.copied.copy-sound-feedback.audio",
            qos: .userInitiated
        ),
        playerFactory: @escaping PlayerFactory = {
            try AVAudioPlayer(contentsOf: $0)
        }
    ) {
        self.queue = queue
        self.playerFactory = playerFactory
    }

    func scheduleAudioSystemLookup() {
        queue.async { _ = Self.audioSystemLookup }
    }

    func play(selection: String) {
        let resolved = CopySoundFeedback.resolvedSelection(selection)

        queue.async { [self] in
            activeSound?.player.stop()
            if activeSound?.selection != resolved { activeSound = nil }

            guard resolved != CopySoundFeedback.disabledValue else { return }

            let player: any CopySoundPlaying
            if let activeSound {
                player = activeSound.player
            } else {
                let soundURL = URL(
                    fileURLWithPath: "/System/Library/Sounds",
                    isDirectory: true
                )
                .appendingPathComponent(resolved)
                .appendingPathExtension("aiff")

                guard let loadedPlayer = try? playerFactory(soundURL) else { return }
                player = loadedPlayer
                activeSound = (resolved, player)
            }
            player.currentTime = 0
            player.volume = CopySoundFeedback.playbackVolume
            if !player.play() { activeSound = nil }
        }
    }
}

enum CopySoundFeedback {
    static let defaultsKey = "copyFeedbackSound"
    static let disabledValue = "none"
    static let defaultSoundName = "Frog"
    static let playbackVolume: Float = 0.5

    static let availableSoundNames = [
        "Basso",
        "Blow",
        "Bottle",
        "Frog",
        "Funk",
        "Glass",
        "Hero",
        "Morse",
        "Ping",
        "Pop",
        "Purr",
        "Sosumi",
        "Submarine",
        "Tink",
    ]

    private static let playbackEngine = CopySoundPlaybackEngine()

    static func resolvedSelection(_ storedValue: String?) -> String {
        guard let storedValue else { return defaultSoundName }
        if storedValue == disabledValue { return disabledValue }
        return availableSoundNames.contains(storedValue) ? storedValue : defaultSoundName
    }

    static func scheduleAudioSystemLookup(selection: String) {
        guard selection != disabledValue else { return }
        playbackEngine.scheduleAudioSystemLookup()
    }

    static func playConfiguredSound(defaults: UserDefaults = .standard) {
        play(selection: resolvedSelection(defaults.string(forKey: defaultsKey)))
    }

    static func play(selection: String) {
        playbackEngine.play(selection: selection)
    }
}
