#!/usr/bin/env swift

import Foundation

let G = "\u{001B}[32m", R = "\u{001B}[31m", B = "\u{001B}[34m", X = "\u{001B}[0m"
func pass(_ m: String) { print("\(G)  ✓ \(m)\(X)") }
func fail(_ m: String) { print("\(R)  ✗ \(m)\(X)") }
func info(_ m: String) { print("\(B)  ℹ \(m)\(X)") }

// ── Simulate DateTimeDetector logic ────────────────────────────

func hasAmbiguousFormat(_ text: String) -> Bool {
    let twoSegmentSlash = #"^\s*\d{1,2}\s*/\s*\d{1,2}\s*$"#
    return text.range(of: twoSegmentSlash, options: .regularExpression) != nil
}

func isValidCalendarDate(month: Int, day: Int) -> Bool {
    guard (1...12).contains(month) else { return false }
    let days = [0, 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    return day >= 1 && day <= days[month]
}

func extractMonthDay(from text: String) -> (month: Int, day: Int)? {
    // Chinese: "6月23日"
    if let m = try? NSRegularExpression(pattern: #"(\d{1,2})月(\d{1,2})日"#)
        .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
       m.numberOfRanges == 3,
       let mo = Int(text[Range(m.range(at: 1), in: text)!]),
       let d = Int(text[Range(m.range(at: 2), in: text)!]) {
        return (mo, d)
    }
    // Dot: "6.23"
    if let m = try? NSRegularExpression(pattern: #"^(\d{1,2})\.(\d{1,2})\b"#)
        .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
       m.numberOfRanges == 3,
       let mo = Int(text[Range(m.range(at: 1), in: text)!]),
       let d = Int(text[Range(m.range(at: 2), in: text)!]) {
        return (mo, d)
    }
    // ISO YYYY-MM-DD or YYYY/M/D
    if let m = try? NSRegularExpression(pattern: #"^(\d{4})[/-](\d{1,2})[/-](\d{1,2})"#)
        .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
       m.numberOfRanges == 4,
       let mo = Int(text[Range(m.range(at: 2), in: text)!]),
       let d = Int(text[Range(m.range(at: 3), in: text)!]) {
        return (mo, d)
    }
    // Chinese with year: "2024年10月3日"
    if let m = try? NSRegularExpression(pattern: #"(\d{4})年(\d{1,2})月(\d{1,2})日"#)
        .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
       m.numberOfRanges == 4,
       let mo = Int(text[Range(m.range(at: 2), in: text)!]),
       let d = Int(text[Range(m.range(at: 3), in: text)!]) {
        return (mo, d)
    }
    return nil
}

/// Simulate: would DateTimeDetector accept this?
func wouldAcceptDate(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    // Phase 0: format gating
    if hasAmbiguousFormat(trimmed) {
        return "REJECTED (ambiguous slash)"
    }

    // Preprocessor: convert dot format to Chinese (mirrors DateTimeDetector)
    var candidates = [trimmed]
    if let m = try? NSRegularExpression(pattern: #"^(\d{1,2})\.(\d{1,2})$"#)
        .firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
       m.numberOfRanges == 3,
       let mo = Int(trimmed[Range(m.range(at: 1), in: trimmed)!]),
       let d = Int(trimmed[Range(m.range(at: 2), in: trimmed)!]),
       (1...12).contains(mo), (1...31).contains(d) {
        candidates.append("\(mo)月\(d)日")
    }

    // NSDataDetector simulation — try all candidates
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
        return "ERROR"
    }
    var matchedDate: Date? = nil
    var matchedComps: DateComponents? = nil
    for candidate in candidates {
        let range = NSRange(candidate.startIndex..., in: candidate)
        if let match = detector.firstMatch(in: candidate, range: range),
           match.resultType == .date,
           match.range == range,
           let date = match.date {
            matchedDate = date
            matchedComps = Calendar.current.dateComponents([.year, .month, .day], from: date)
            break
        }
    }
    guard let date = matchedDate, let comps = matchedComps else {
        return "REJECTED (NSDataDetector no match)"
    }

    let hasDate = comps.month != nil && comps.day != nil

    // Phase 3: calendar validation — trust the calendar, not NSDataDetector
    if hasDate, let (origM, origD) = extractMonthDay(from: trimmed) {
        guard isValidCalendarDate(month: origM, day: origD) else {
            return "REJECTED (invalid date: \(origM)/\(origD) doesn't exist)"
        }
    }

    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    return "ACCEPTED → \(df.string(from: date))"
}

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
