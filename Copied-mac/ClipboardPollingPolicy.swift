import Foundation

struct ClipboardPollingPolicy {
    static let firstResponseInterval: TimeInterval = 0.025
    static let acceleratedInterval: TimeInterval = 0.016
    static let normalInterval: TimeInterval = 0.075
    static let idleInterval: TimeInterval = 0.1
    static let idleDelay: TimeInterval = 30
    static let activityTail: TimeInterval = 1

    private var lastActivity: TimeInterval
    private var acceleratedUntil = -TimeInterval.infinity

    init(now: TimeInterval) {
        lastActivity = now
    }

    mutating func recordActivity(at now: TimeInterval) {
        lastActivity = now
        acceleratedUntil = now + Self.activityTail
    }

    func interval(at now: TimeInterval, firstResponseBoostActive: Bool) -> TimeInterval {
        if now < acceleratedUntil { return Self.acceleratedInterval }
        if firstResponseBoostActive { return Self.firstResponseInterval }
        return now - lastActivity >= Self.idleDelay ? Self.idleInterval : Self.normalInterval
    }
}

extension Notification.Name {
    static let copiedCopyRequested = Notification.Name("CopiedCopyRequested")
}
