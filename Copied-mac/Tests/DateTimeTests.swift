
import Foundation

let G = "\u{001B}[32m", R = "\u{001B}[31m", B = "\u{001B}[34m", X = "\u{001B}[0m"
func pass(_ m: String) { print("\(G)  ✓ \(m)\(X)") }
func fail(_ m: String) { print("\(R)  ✗ \(m)\(X)") }
func info(_ m: String) { print("\(B)  ℹ \(m)\(X)") }

private let detector = DateTimeDetector()

func wouldAcceptDate(_ text: String) -> String {
    guard let detection = detector.detect(in: text) else { return "REJECTED" }
    return "ACCEPTED → \(detection.value ?? "")"
}

@main
struct DateTimeTests {
    static func main() {
        // ═══════════════════════════════════════════════════════════════
        print("═══════════════════════════════════════════")
        print("  Phase A: Two-segment slash — ALL rejected")
        print("═══════════════════════════════════════════")

        let slashTests = ["10/3", "3/2", "31/11", "11/31", "13/1", "1/1", "5/10", "12/25"]
        var passCount = 0, total = slashTests.count
        for t in slashTests {
            let r = wouldAcceptDate(t)
            if r.hasPrefix("REJECTED") { passCount += 1; pass("\(t) → \(r)") }
            else { fail("\(t) → \(r)") }
        }

        // ════════════════════════════════════════════
        print("\n═══════════════════════════════════════════")
        print("  Phase B: Three-segment — ACCEPTED")
        print("═══════════════════════════════════════════")

        let threeSegTests = ["2024/10/3", "2024/10/03", "2024-10-3", "2024-10-03", "10/3/2024"]
        total += threeSegTests.count
        for t in threeSegTests {
            let r = wouldAcceptDate(t)
            if r.hasPrefix("ACCEPTED") { passCount += 1; pass("\(t) → \(r)") }
            else { fail("\(t) → \(r)") }
        }

        // ════════════════════════════════════════════
        print("\n═══════════════════════════════════════════")
        print("  Phase C: Chinese formats — valid vs invalid")
        print("═══════════════════════════════════════════")

        let chTests: [(String, Bool)] = [
            ("10月3日", true),
            ("11月31日", false),   // Nov has 30 days
            ("6月31日", false),    // Jun has 30 days
            ("2月30日", false),    // Feb max 29
            ("2月29日", true),     // Feb 29 allowed
            ("12月31日", true),
            ("1月1日", true),
            ("2024年10月3日", true),
            ("2023年2月29日", false),
            ("2023-02-29", false),
            ("1900年2月29日", false),
            ("2000年2月29日", true),
            ("2024年2月29日", true),
            ("2024年11月31日", false),
        ]
        total += chTests.count
        for (t, expected) in chTests {
            let r = wouldAcceptDate(t)
            let ok = expected ? r.hasPrefix("ACCEPTED") : r.hasPrefix("REJECTED")
            if ok { passCount += 1; pass("\(t) → \(r)") }
            else { fail("\(t) → \(r) (expected: \(expected ? "ACCEPTED" : "REJECTED"))") }
        }

        // ════════════════════════════════════════════
        print("\n═══════════════════════════════════════════")
        print("  Phase D: Dot format — valid vs invalid")
        print("═══════════════════════════════════════════")

        let dotTests: [(String, Bool)] = [
            ("6.23", true),
            ("6.31", false),   // Jun has 30 days
            ("12.25", true),
            ("2.29", true),
            ("2.30", false),
        ]
        total += dotTests.count
        for (t, expected) in dotTests {
            let r = wouldAcceptDate(t)
            let ok = expected ? r.hasPrefix("ACCEPTED") : r.hasPrefix("REJECTED")
            if ok { passCount += 1; pass("\(t) → \(r)") }
            else { fail("\(t) → \(r) (expected: \(expected ? "ACCEPTED" : "REJECTED"))") }
        }

        // ════════════════════════════════════════════
        print("\n═══════════════════════════════════════════")
        print("  Phase E: Math-only — DateTime should reject")
        print("═══════════════════════════════════════════")

        let mathTests = ["2+2", "3*4", "10-3", "3.5/2"]
        total += mathTests.count
        for t in mathTests {
            let r = wouldAcceptDate(t)
            if r.hasPrefix("REJECTED") { passCount += 1; pass("\(t) → \(r)") }
            else { fail("\(t) → \(r)") }
        }

        // ════════════════════════════════════════════
        print("\n═══════════════════════════════════════════")
        print("  Results: \(passCount)/\(total) passed")
        print("═══════════════════════════════════════════")
        print(passCount == total ? "\(G)ALL TESTS PASSED\(X)" : "\(R)\(total - passCount) FAILED\(X)")
        exit(passCount == total ? 0 : 1)
    }
}
