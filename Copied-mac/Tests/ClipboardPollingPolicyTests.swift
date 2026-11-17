import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

@main
enum ClipboardPollingPolicyTests {
    static func main() {
        var policy = ClipboardPollingPolicy(now: 100)
        expect(policy.interval(at: 100, firstResponseBoostActive: true) == 0.025,
               "startup lost the first-response interval")
        expect(policy.interval(at: 100, firstResponseBoostActive: false) == 0.075,
               "ordinary polling did not preserve its fallback")
        expect(policy.interval(at: 129.999, firstResponseBoostActive: false) == 0.075,
               "the monitor entered idle before the threshold")
        expect(policy.interval(at: 130, firstResponseBoostActive: false) == 0.1,
               "idle polling did not reduce wakeups")
        expect(policy.interval(at: 140, firstResponseBoostActive: true) == 0.025,
               "idle detection overrode startup's first-response interval")

        policy.recordActivity(at: 140)
        expect(policy.interval(at: 140, firstResponseBoostActive: true) == 0.016,
               "activity did not accelerate startup")
        expect(policy.interval(at: 140.999, firstResponseBoostActive: false) == 0.016,
               "activity acceleration did not retain its tail")
        expect(policy.interval(at: 141, firstResponseBoostActive: false) == 0.075,
               "acceleration did not expire at its boundary")
        policy.recordActivity(at: 141)
        expect(policy.interval(at: 141.999, firstResponseBoostActive: false) == 0.016,
               "subsequent activity did not extend acceleration")
        expect(policy.interval(at: 171, firstResponseBoostActive: false) == 0.1,
               "activity prevented an eventual return to idle")
        print("ClipboardPollingPolicyTests: PASS")
    }
}
