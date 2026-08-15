import CoreGraphics
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func approximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
    abs(lhs - rhs) < 0.0001
}

private func approximatelyEqual(_ lhs: TimeInterval, _ rhs: TimeInterval) -> Bool {
    abs(lhs - rhs) < 0.0001
}

@main
struct MetadataAutoScrollMetricsTests {
    static func main() {
        expect(
            MetadataAutoScrollMetrics.overflow(contentWidth: 100, viewportWidth: 120) == 0,
            "content narrower than the viewport does not scroll"
        )
        expect(
            MetadataAutoScrollMetrics.overflow(contentWidth: 100, viewportWidth: 100) == 0,
            "equal widths do not scroll"
        )
        expect(
            MetadataAutoScrollMetrics.overflow(contentWidth: 101, viewportWidth: 100) == 0,
            "one-point rounding overflow does not scroll"
        )
        expect(
            approximatelyEqual(
                MetadataAutoScrollMetrics.overflow(contentWidth: 101.01, viewportWidth: 100),
                1.01
            ),
            "overflow beyond one point is preserved"
        )
        expect(
            MetadataAutoScrollMetrics.travelDuration(for: 0) == 0,
            "zero overflow has no travel duration"
        )
        expect(
            approximatelyEqual(MetadataAutoScrollMetrics.travelDuration(for: 12), 0.8),
            "short travel clamps to the minimum duration"
        )
        expect(
            approximatelyEqual(MetadataAutoScrollMetrics.travelDuration(for: 90), 3),
            "travel uses thirty points per second"
        )
        expect(
            approximatelyEqual(MetadataAutoScrollMetrics.travelDuration(for: 240), 6),
            "long travel clamps to the maximum duration"
        )
        expect(
            MetadataAutoScrollMetrics.edgeFadeFraction(viewportWidth: 0) == 0,
            "a zero-width viewport has no fade fraction"
        )
        expect(
            approximatelyEqual(
                MetadataAutoScrollMetrics.edgeFadeFraction(viewportWidth: 100),
                0.14
            ),
            "a regular viewport uses a fourteen-point edge fade"
        )
        expect(
            approximatelyEqual(
                MetadataAutoScrollMetrics.edgeFadeFraction(viewportWidth: 28),
                0.49
            ),
            "a narrow viewport caps each edge fade below half its width"
        )

        print("MetadataAutoScrollMetricsTests: PASS")
    }
}
