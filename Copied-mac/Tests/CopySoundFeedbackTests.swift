import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct CopySoundFeedbackTests {
    static func main() {
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

        print("CopySoundFeedbackTests: PASS")
    }
}
