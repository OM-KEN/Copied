import AppKit

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

    @MainActor private static var activeSound: NSSound?

    static func resolvedSelection(_ storedValue: String?) -> String {
        guard let storedValue else { return defaultSoundName }
        if storedValue == disabledValue { return disabledValue }
        return availableSoundNames.contains(storedValue) ? storedValue : defaultSoundName
    }

    @MainActor
    static func playConfiguredSound(defaults: UserDefaults = .standard) {
        play(selection: resolvedSelection(defaults.string(forKey: defaultsKey)))
    }

    @MainActor
    static func play(selection: String) {
        activeSound?.stop()
        activeSound = nil

        let resolved = resolvedSelection(selection)
        guard resolved != disabledValue,
              let sound = NSSound(named: NSSound.Name(resolved)) else { return }

        sound.volume = playbackVolume
        activeSound = sound
        sound.play()
    }
}
