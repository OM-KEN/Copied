import CoreGraphics
import Foundation

enum MetadataAutoScrollMetrics {
    static let overflowThreshold: CGFloat = 1
    static let pointsPerSecond: CGFloat = 30
    static let minimumTravelDuration: TimeInterval = 0.8
    static let maximumTravelDuration: TimeInterval = 6
    static let edgeFadeWidth: CGFloat = 14
    static let maximumEdgeFadeFraction: CGFloat = 0.49

    static func overflow(contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        let distance = max(0, contentWidth - viewportWidth)
        return distance > overflowThreshold ? distance : 0
    }

    static func travelDuration(for overflow: CGFloat) -> TimeInterval {
        guard overflow > 0 else { return 0 }
        let rawDuration = TimeInterval(overflow / pointsPerSecond)
        return min(max(rawDuration, minimumTravelDuration), maximumTravelDuration)
    }

    static func edgeFadeFraction(viewportWidth: CGFloat) -> CGFloat {
        guard viewportWidth > 0 else { return 0 }
        return min(edgeFadeWidth / viewportWidth, maximumEdgeFadeFraction)
    }
}
