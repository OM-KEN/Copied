enum CollapsedToastMouseUpDecision: Equatable {
    case performPrimaryAction
    case expandPreview
    case dismiss
}

enum CollapsedToastMouseUpPolicy {
    static func decide(
        isPrimaryActionHovered: Bool,
        isPreviewHovered: Bool
    ) -> CollapsedToastMouseUpDecision {
        if isPrimaryActionHovered { return .performPrimaryAction }
        if isPreviewHovered { return .expandPreview }
        return .dismiss
    }
}

struct ManualPrimaryActionEventGuard {
    private var pendingEventNumber: Int?

    mutating func begin(eventNumber: Int) {
        pendingEventNumber = eventNumber
    }

    mutating func consumeIfMatching(eventNumber: Int?) -> Bool {
        guard let eventNumber, pendingEventNumber == eventNumber else { return false }
        pendingEventNumber = nil
        return true
    }

    mutating func clear(eventNumber: Int) {
        guard pendingEventNumber == eventNumber else { return }
        pendingEventNumber = nil
    }
}
