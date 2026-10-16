import CoreGraphics

struct CopyGestureStateMachine {
    struct Request: Equatable {
        let generation: Int
        let targetPID: Int32
    }

    private let isMacOS27OrLater: Bool
    private var isLeftPressed = false
    private var gestureFired = false
    private var generation = 0
    private var pendingCopy: Request?

    init(isMacOS27OrLater: Bool) {
        self.isMacOS27OrLater = isMacOS27OrLater
    }

    mutating func handle(
        _ type: CGEventType,
        frontmostPID: Int32?,
        frontmostBundleIdentifier: String?
    ) -> (consume: Bool, request: Request?) {
        switch type {
        case .leftMouseDown:
            reset()
            isLeftPressed = true
        case .leftMouseUp:
            isLeftPressed = false
            gestureFired = false
            guard let request = pendingCopy else { return (false, nil) }
            pendingCopy = nil
            guard request.targetPID == frontmostPID else {
                cancelPendingCopy()
                return (false, nil)
            }
            return (false, request)
        case .rightMouseDown, .rightMouseUp:
            guard isLeftPressed, !gestureFired else { return (false, nil) }
            gestureFired = true
            let request = frontmostPID.map { Request(generation: generation, targetPID: $0) }
            if isMacOS27OrLater, frontmostBundleIdentifier?.hasPrefix("com.apple.") == true {
                pendingCopy = request
                return (type == .rightMouseDown, nil)
            }
            return (type == .rightMouseDown, request)
        default:
            break
        }
        return (false, nil)
    }

    mutating func consume(_ request: Request, frontmostPID: Int32?) -> Bool {
        guard request.generation == generation else { return false }
        cancelPendingCopy()
        return request.targetPID == frontmostPID
    }

    mutating func cancelPendingCopy() {
        pendingCopy = nil
        generation += 1
    }

    mutating func reset() {
        cancelPendingCopy()
        isLeftPressed = false
        gestureFired = false
    }
}
