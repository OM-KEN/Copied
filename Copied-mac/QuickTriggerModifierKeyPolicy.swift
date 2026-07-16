import AppKit

enum QuickTriggerModifierKeyDecision: Equatable {
    case targetDown
    case targetUp
    case ignore
    case cancelOtherModifier(keyCode: UInt16)
    case cancelTargetSideConflict
}

struct QuickTriggerModifierKeyPolicy {
    private static let modifierKeyCodes: Set<UInt16> = [
        54, 55,       // Command right / left
        58, 61,       // Option left / right
        59, 62,       // Control left / right
        56, 60,       // Shift left / right
        57,           // Caps Lock
        63            // Function
    ]

    let targetModifier: KeyboardQuickTriggerModifier
    private(set) var pressedTargetKeyCodes: Set<UInt16> = []
    private var preExistingTarget = false
    private var suppressUntilAllTargetKeysReleased = false
    private var sequenceTargetKeyCode: UInt16?

    var isAnyTargetKeyDown: Bool {
        preExistingTarget || !pressedTargetKeyCodes.isEmpty
    }

    init(targetModifier: KeyboardQuickTriggerModifier) {
        self.targetModifier = targetModifier
    }

    mutating func appeared(preExisting: Bool) {
        pressedTargetKeyCodes.removeAll()
        preExistingTarget = preExisting
        suppressUntilAllTargetKeysReleased = false
        sequenceTargetKeyCode = nil
    }

    mutating func handleFlagsChanged(
        keyCode: UInt16,
        eventFlags: NSEvent.ModifierFlags,
        sequenceActive: Bool
    ) -> QuickTriggerModifierKeyDecision {
        guard targetModifier != .disabled else { return .ignore }
        let targetKeyCodes = Self.keyCodes(for: targetModifier)

        guard targetKeyCodes.contains(keyCode) else {
            if Self.modifierKeyCodes.contains(keyCode), sequenceActive {
                return .cancelOtherModifier(keyCode: keyCode)
            }
            return .ignore
        }

        let targetFlagIsPresent = eventFlags.contains(targetModifier.nseventFlags)

        if pressedTargetKeyCodes.contains(keyCode) {
            // macOS repeats flagsChanged while a modifier remains held. The
            // repeated event has the same keyCode and still carries the target
            // flag, so it is not a release transition.
            if targetFlagIsPresent { return .ignore }
            pressedTargetKeyCodes.remove(keyCode)
            if suppressUntilAllTargetKeysReleased {
                let shouldReleasePreExistingState = preExistingTarget
                pressedTargetKeyCodes.removeAll()
                preExistingTarget = false
                suppressUntilAllTargetKeysReleased = false
                sequenceTargetKeyCode = nil
                return shouldReleasePreExistingState ? .targetUp : .ignore
            }
            return pressedTargetKeyCodes.isEmpty ? .targetUp : .ignore
        }

        if preExistingTarget {
            if !targetFlagIsPresent {
                preExistingTarget = false
                sequenceTargetKeyCode = nil
                return .targetUp
            }
            pressedTargetKeyCodes.insert(keyCode)
            suppressUntilAllTargetKeysReleased = true
            return sequenceActive ? .cancelTargetSideConflict : .ignore
        }

        if suppressUntilAllTargetKeysReleased {
            if !targetFlagIsPresent {
                let shouldReleasePreExistingState = preExistingTarget
                pressedTargetKeyCodes.removeAll()
                preExistingTarget = false
                suppressUntilAllTargetKeysReleased = false
                sequenceTargetKeyCode = nil
                return shouldReleasePreExistingState ? .targetUp : .ignore
            }
            return .ignore
        }

        guard targetFlagIsPresent else {
            // An unmatched target-key release must not leave a synthetic down state.
            return .ignore
        }

        if !pressedTargetKeyCodes.isEmpty
            || (sequenceActive && sequenceTargetKeyCode != nil && sequenceTargetKeyCode != keyCode) {
            pressedTargetKeyCodes.insert(keyCode)
            suppressUntilAllTargetKeysReleased = true
            return .cancelTargetSideConflict
        }

        pressedTargetKeyCodes.insert(keyCode)
        if !sequenceActive { sequenceTargetKeyCode = keyCode }
        return .targetDown
    }

    mutating func reset() {
        pressedTargetKeyCodes.removeAll()
        preExistingTarget = false
        suppressUntilAllTargetKeysReleased = false
        sequenceTargetKeyCode = nil
    }

    static func keyCodes(for modifier: KeyboardQuickTriggerModifier) -> Set<UInt16> {
        switch modifier {
        case .command: [55, 54]
        case .option: [58, 61]
        case .control: [59, 62]
        case .shift: [56, 60]
        case .disabled: []
        }
    }
}
