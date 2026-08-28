import Foundation

/// Pure presentation facts derived from the same ordered detections used by
/// filtering and Action resolution. No detector or file-system work happens here.
struct ClipboardDetectionDisplayFacts: Equatable {
    let typeLabel: String
    let iconSymbolName: String
    let detailOverride: String?

    static func derive(
        from detections: [ContentDetection],
        relativeTo referenceDate: Date = Date()
    ) -> ClipboardDetectionDisplayFacts? {
        guard let primary = detections.first else { return nil }
        var detail: String?
        if primary.kind.id == ContentKind.dateTime.id,
           let value = primary.value,
           let interval = TimeInterval(value) {
            detail = RelativeDateDescription.string(
                for: Date(timeIntervalSinceReferenceDate: interval),
                subtype: primary.metadata["subtype"],
                relativeTo: referenceDate
            )
        }
        return ClipboardDetectionDisplayFacts(
            typeLabel: primary.kind.label,
            iconSymbolName: primary.kind.icon,
            detailOverride: detail
        )
    }
}
