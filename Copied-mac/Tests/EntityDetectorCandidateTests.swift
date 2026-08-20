import Foundation

// Minimal protocol surface needed to compile the production detectors without
// pulling the global registry and every unrelated detector into this test.
protocol ContentDetectorProtocol {
    var kind: ContentKind { get }
    var priority: Int { get }
    func detect(in text: String) -> ContentDetection?
}

@main
enum EntityDetectorCandidateTests {
    private static var total = 0
    private static var failures = 0

    static func main() {
        testLongNonCandidates()
        testExistingValidCandidates()
        testURLCandidateBoundaries()
        testPhoneCandidateBoundaries()
        testDateCandidateBoundaries()
        testFirstResponseWarmUpCandidates()

        print("EntityDetectorCandidateTests: \(total - failures)/\(total) passed")
        guard failures == 0 else { exit(1) }
    }

    private static func testLongNonCandidates() {
        let longProse = Array(
            repeating: "This is ordinary prose that cannot be one complete entity.",
            count: 120
        ).joined(separator: " ")

        expect(URLDetector().detect(in: longProse) == nil, "long prose is not a URL")
        expect(PhoneNumberDetector().detect(in: longProse) == nil, "long prose is not a phone number")
        expect(DateTimeDetector().detect(in: longProse) == nil, "long prose is not a date")

        let longUnbrokenWord = String(repeating: "a", count: 6_300)
        expect(
            !URLDetector.isPlausibleCandidate(longUnbrokenWord),
            "long unstructured word is rejected before URL detection"
        )
        let longChineseProse = String(repeating: "长文本性能测试。", count: 700)
        expect(
            !URLDetector.isPlausibleCandidate(longChineseProse),
            "long Chinese prose punctuation is not treated as a URL domain"
        )
        expect(
            !PhoneNumberDetector.isPlausibleCandidate(longProse),
            "long prose is rejected before phone detection"
        )
        expect(
            !DateTimeDetector.isPlausibleCandidate(longProse),
            "long prose is rejected before date detection"
        )
    }

    private static func testExistingValidCandidates() {
        let urlDetector = URLDetector()
        expect(
            urlDetector.detect(in: "https://example.com/a%20b?q=1")?.kind == .url,
            "absolute URL remains detected"
        )
        expect(
            urlDetector.detect(in: "example.com")?.kind == .url,
            "schemeless domain remains detected"
        )

        let phoneDetector = PhoneNumberDetector()
        expect(
            phoneDetector.detect(in: "+86 138 0013 8000")?.kind == .phoneNumber,
            "international formatted phone remains detected"
        )
        expect(
            phoneDetector.detect(in: "1-800-FLOWERS")?.kind == .phoneNumber,
            "vanity phone remains detected"
        )
        expect(
            phoneDetector.detect(in: "１２３４５６７８９０")?.kind == .phoneNumber,
            "Unicode decimal digits remain detected"
        )
        expect(
            phoneDetector.detect(in: "＋８６ １３８ ００１３ ８０００")?.kind == .phoneNumber,
            "full-width international phone remains detected"
        )

        let dateDetector = DateTimeDetector()
        expect(
            dateDetector.detect(in: "2026年7月15日")?.metadata["subtype"] == "date",
            "Chinese date remains detected"
        )
        expect(
            dateDetector.detect(in: "2026年7月15日 20点")?.metadata["subtype"] == "dateTime",
            "Chinese date-time preprocessing remains detected"
        )
        expect(
            DateTimeDetector.isPlausibleCandidate("today")
                && DateTimeDetector.isPlausibleCandidate("明天"),
            "short natural-language dates remain candidates"
        )
    }

    private static func testURLCandidateBoundaries() {
        expect(
            URLDetector.maximumSchemelessCandidateUTF16Length == 2_048,
            "schemeless URL candidate limit is pinned at 2048 UTF-16 units"
        )
        expect(
            !URLDetector.isPlausibleCandidate("https://example.com/two words"),
            "raw URL whitespace is rejected"
        )
        expect(
            !URLDetector.isPlausibleCandidate("not-a-domain"),
            "unstructured URL candidate is rejected"
        )
        expect(
            URLDetector.isPlausibleCandidate("custom:value"),
            "syntactically valid schemes stay conservatively eligible"
        )
        expect(
            URLDetector.isPlausibleCandidate("a.b"),
            "minimal dot-separated structure stays conservatively eligible"
        )

        let schemelessAtLimit = "example.com/" + String(repeating: "a", count: 2_036)
        expect(
            URLDetector.isPlausibleCandidate(schemelessAtLimit),
            "schemeless URL candidate at the length limit remains eligible"
        )
        expect(
            !URLDetector.isPlausibleCandidate(schemelessAtLimit + "a"),
            "schemeless URL candidate above the length limit is rejected"
        )

        let veryLongStructuredURL = "https://example.com/" + String(repeating: "a", count: 10_000)
        expect(
            URLDetector.isPlausibleCandidate(veryLongStructuredURL),
            "explicit-scheme URL preflight does not impose a length cutoff"
        )
    }

    private static func testPhoneCandidateBoundaries() {
        expect(
            PhoneNumberDetector.maximumCandidateUTF16Length == 256,
            "phone candidate limit is pinned at 256 UTF-16 units"
        )

        let atLimit = "+1" + String(repeating: "2", count: 254)
        let overLimit = atLimit + "2"
        expect(
            PhoneNumberDetector.isPlausibleCandidate(atLimit),
            "phone candidate at the length limit remains eligible"
        )
        expect(
            !PhoneNumberDetector.isPlausibleCandidate(overLimit),
            "phone candidate above the length limit is rejected"
        )
        expect(
            !PhoneNumberDetector.isPlausibleCandidate("+1 415 555 2671 🙂"),
            "characters outside the phone candidate set are rejected"
        )
    }

    private static func testDateCandidateBoundaries() {
        expect(
            DateTimeDetector.maximumCandidateUTF16Length == 256,
            "date candidate limit is pinned at 256 UTF-16 units"
        )
        expect(
            DateTimeDetector.maximumTextualCandidateUTF16Length == 64,
            "textual date candidate limit is pinned at 64 UTF-16 units"
        )

        let numericAtLimit = String(repeating: "1", count: 256)
        let numericOverLimit = numericAtLimit + "1"
        expect(
            DateTimeDetector.isPlausibleCandidate(numericAtLimit),
            "numeric date candidate at the total limit remains eligible"
        )
        expect(
            !DateTimeDetector.isPlausibleCandidate(numericOverLimit),
            "numeric date candidate above the total limit is rejected"
        )

        let textualAtLimit = String(repeating: "a", count: 64)
        let textualOverLimit = textualAtLimit + "a"
        expect(
            DateTimeDetector.isPlausibleCandidate(textualAtLimit),
            "textual date candidate at its limit remains eligible"
        )
        expect(
            !DateTimeDetector.isPlausibleCandidate(textualOverLimit),
            "textual date candidate above its limit is rejected"
        )
    }

    private static func testFirstResponseWarmUpCandidates() {
        let result = EntityDetectorWarmUp.perform()
        expect(result.matchedURL, "first-response warm-up runs a matching URL candidate")
        expect(result.matchedPhoneNumber, "first-response warm-up runs a matching phone candidate")
        expect(result.matchedDate, "first-response warm-up runs a matching date candidate")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        total += 1
        if condition() {
            print("  ✓ \(message)")
        } else {
            failures += 1
            print("  ✗ \(message)")
        }
    }
}
