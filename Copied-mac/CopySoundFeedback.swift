import AVFoundation
import Foundation

protocol CopySoundPlaying: AnyObject {
    var volume: Float { get set }

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

    private let queue: DispatchQueue
    private let playerFactory: PlayerFactory
    private var activePlayer: (any CopySoundPlaying)?

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

    func play(selection: String) {
        let resolved = CopySoundFeedback.resolvedSelection(selection)

        queue.async { [self] in
            activePlayer?.stop()
            activePlayer = nil

            guard resolved != CopySoundFeedback.disabledValue else { return }

            let soundURL = URL(
                fileURLWithPath: "/System/Library/Sounds",
                isDirectory: true
            )
            .appendingPathComponent(resolved)
            .appendingPathExtension("aiff")

            guard let player = try? playerFactory(soundURL) else { return }
            player.volume = CopySoundFeedback.playbackVolume
            activePlayer = player
            player.play()
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

    static func playConfiguredSound(defaults: UserDefaults = .standard) {
        play(selection: resolvedSelection(defaults.string(forKey: defaultsKey)))
    }

    static func play(selection: String) {
        playbackEngine.play(selection: selection)
    }
}
