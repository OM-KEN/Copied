import Foundation

enum MouseButtonRecordingDecision: Equatable {
    case ignore
    case bind(button: Int)
}

struct MouseButtonRecordingStateMachine: Equatable {
    private(set) var isRecording = false

    @discardableResult
    mutating func start(accessibilityTrusted: Bool) -> Bool {
        isRecording = accessibilityTrusted
        return isRecording
    }

    mutating func cancel() {
        isRecording = false
    }

    mutating func handleOtherMouseDown(button: Int) -> MouseButtonRecordingDecision {
        guard isRecording, button >= 3 else { return .ignore }
        isRecording = false
        return .bind(button: button)
    }
}
