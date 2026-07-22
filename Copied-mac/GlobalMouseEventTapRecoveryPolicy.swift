import CoreGraphics

enum GlobalMouseEventTapRecoveryAction: Equatable {
    case reenable
    case keepDisabled
}

enum GlobalMouseEventTapRecoveryPolicy {
    static func action(
        for eventType: CGEventType,
        accessibilityTrusted: Bool
    ) -> GlobalMouseEventTapRecoveryAction {
        guard eventType == .tapDisabledByTimeout, accessibilityTrusted else {
            return .keepDisabled
        }
        return .reenable
    }
}
