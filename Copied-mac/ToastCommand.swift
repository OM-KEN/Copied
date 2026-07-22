enum ToastCommand<Action> {
    case performPrimary
    case performAction(Action)
    case expand
    case collapse
    case dismiss
    case editInTextEdit
    case openUpdateAbout

    var kind: ToastCommandKind {
        switch self {
        case .performPrimary: .performPrimary
        case .performAction: .performAction
        case .expand: .expand
        case .collapse: .collapse
        case .dismiss: .dismiss
        case .editInTextEdit: .editInTextEdit
        case .openUpdateAbout: .openUpdateAbout
        }
    }
}

enum ToastCommandKind: CaseIterable, Equatable {
    case performPrimary
    case performAction
    case expand
    case collapse
    case dismiss
    case editInTextEdit
    case openUpdateAbout
}

enum ToastActionDisposition: Equatable {
    case keepPresented
    case dismiss

    init(performsInlineUpdate: Bool) {
        self = performsInlineUpdate ? .keepPresented : .dismiss
    }
}

enum ToastDismissSurfacePolicy {
    static func shouldHideImmediately(animated: Bool, isExpanded: Bool) -> Bool {
        !animated || !isExpanded
    }
}

/// Serializes the synchronous command receiver and rejects reentrant dispatch.
/// A SwiftUI control owns one command callback, so one callback can execute at most once.
final class ToastCommandDispatcher<Action> {
    private var isDispatching = false

    @discardableResult
    func dispatch(
        _ command: ToastCommand<Action>,
        to receiver: (ToastCommand<Action>) -> Void
    ) -> Bool {
        guard !isDispatching else { return false }
        isDispatching = true
        defer { isDispatching = false }
        receiver(command)
        return true
    }
}
