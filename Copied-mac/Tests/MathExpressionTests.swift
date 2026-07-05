#!/usr/bin/env swift

import Foundation

// ── Color helpers ──────────────────────────────────────────────
let G = "\u{001B}[32m", R = "\u{001B}[31m", B = "\u{001B}[34m", X = "\u{001B}[0m"
func pass(_ msg: String) { print("\(G)  ✓ \(msg)\(X)") }
func fail(_ msg: String) { print("\(R)  ✗ \(msg)\(X)") }
func info(_ msg: String) { print("\(B)  ℹ \(msg)\(X)") }

var total = 0, passed = 0

// ── Clean & Evaluate ──────────────────────────────────────────

func clean(_ text: String) -> String {
    text.replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "×", with: "*")
        .replacingOccurrences(of: "÷", with: "/")
        .replacingOccurrences(of: "^", with: "**")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func isIntegerExpr(_ s: String) -> Bool {
    s.rangeOfCharacter(from: CharacterSet(charactersIn: ".")) == nil
}

/// First-principles fix: NSExpression inherits C integer semantics.
/// "3/2" → Int/Int → integer division → 1.0 (truncated before we see it).
/// Solution: ALWAYS convert integer literals to double form, so NSExpression
/// uses floating-point arithmetic for all operations.
/// `\b(\d+)\b` uses word boundaries → safe for scientific notation (2e5).
func toDoubleExpr(_ s: String) -> String {
    guard isIntegerExpr(s) else { return s }
    return s.replacingOccurrences(
        of: #"\b(\d+)\b"#,
        with: "$1.0",
        options: .regularExpression
    )
}

func evaluate(_ s: String) -> Any? {
    NSExpression(format: s).expressionValue(with: nil, context: nil)
}

func extractNumber(_ raw: Any?) -> (Double, Int64?)? {
    guard let raw else { return nil }
    if let d = raw as? Double { return (d, nil) }
    if let ns = raw as? NSNumber {
        let t = String(cString: ns.objCType)
        let exact: Int64? = ["q","Q","l","L","i","I","s","S"].contains(t) ? ns.int64Value : nil
        return (ns.doubleValue, exact)
    }
    return nil
}

func fmt(_ n: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = 12
    f.minimumFractionDigits = 0
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

/// Current broken pipeline
func calcCurrent(_ text: String) -> String? {
    let c = clean(text)
    guard let raw = evaluate(c), let num = extractNumber(raw), num.0.isFinite else { return nil }
    if let exact = num.1, isIntegerExpr(c) { return "\(exact)" }
    return fmt(num.0)
}

/// Fixed pipeline: always evaluate in double mode for integer expressions
func calcFixed(_ text: String) -> String? {
    let c = clean(text)
    let evalStr = toDoubleExpr(c)
    guard let raw = evaluate(evalStr), let num = extractNumber(raw), num.0.isFinite else { return nil }
    // Mirror the safeIntegerLimit guard from the real code
    let safeIntegerLimit = 9_007_199_254_740_992.0
    if isIntegerExpr(c) && abs(num.0) > safeIntegerLimit { return nil }
    return fmt(num.0)
}

// ── Test runner ────────────────────────────────────────────────

struct Case { let input: String; let expected: String }

func run(_ title: String, _ cases: [Case], _ fn: (String) -> String?) {
    print("\n── \(title)")
    for c in cases {
        total += 1
        let r = fn(c.input) ?? "nil"
        if r == c.expected { passed += 1; pass("\(c.input) → \(r)") }
        else { fail("\(c.input) → \(r) (expected: \(c.expected))") }
    }
}

// ═══════════════════════════════════════════════════════════════
print("═══════════════════════════════════════════")
print("  PART 1: NSExpression Internal Type Behavior")
print("═══════════════════════════════════════════")

let samples = ["3+2","10-3","4*5","3/2","10/3","1/3","6/3","3^2","(2+3)*4","10/3*3","3*5/2","-10+5","3/2.0","10.0/3"]
print("\nExpression → NSExpression return type + doubleValue:")
for expr in samples {
    let c = clean(expr)
    guard let raw = evaluate(c), let num = extractNumber(raw) else { print("  \(expr) → nil"); continue }
    let ts = num.1.map{"Int64(\($0))"} ?? "Double"
    print("  \(expr.padding(toLength: 12, withPad: " ", startingAt: 0)) → \(ts.padding(toLength: 16, withPad: " ", startingAt: 0))  doubleValue=\(num.0)")
}

// ═══════════════════════════════════════════════════════════════
print("\n═══════════════════════════════════════════")
print("  PART 2: Correctness Tests (Fixed Pipeline)")
print("═══════════════════════════════════════════")

run("Division — fractional results", [
    Case(input: "3/2",    expected: "1.5"),
    Case(input: "10/3",   expected: "3.333333333333"),
    Case(input: "1/3",    expected: "0.333333333333"),
    Case(input: "100/3",  expected: "33.333333333333"),
    Case(input: "1/2",    expected: "0.5"),
    Case(input: "7/2",    expected: "3.5"),
    Case(input: "10/3*3", expected: "10"),
    Case(input: "3*5/2",  expected: "7.5"),
    Case(input: "10÷3",   expected: "3.333333333333"),
    Case(input: "1/8",    expected: "0.125"),
], calcFixed)

run("Division — exact integer results", [
    Case(input: "6/3",    expected: "2"),
    Case(input: "8÷2",    expected: "4"),
    Case(input: "100/10", expected: "10"),
    Case(input: "0/5",    expected: "0"),
    Case(input: "9/3",    expected: "3"),
], calcFixed)

run("Addition & Subtraction", [
    Case(input: "3+2",    expected: "5"),
    Case(input: "10-7",   expected: "3"),
    Case(input: "-5+3",   expected: "-2"),
    Case(input: "5-10",   expected: "-5"),
    Case(input: "999+1",  expected: "1,000"),
    Case(input: "0+0",    expected: "0"),
], calcFixed)

run("Multiplication", [
    Case(input: "4*5",    expected: "20"),
    Case(input: "3×4",    expected: "12"),
    Case(input: "1000*1000", expected: "1,000,000"),
    Case(input: "11*11",  expected: "121"),
    Case(input: "2*3*4",  expected: "24"),
], calcFixed)

run("Exponentiation", [
    Case(input: "3^2",    expected: "9"),
    Case(input: "2^10",   expected: "1,024"),
    Case(input: "2^3",    expected: "8"),
    Case(input: "5^3",    expected: "125"),
    Case(input: "10^0",   expected: "1"),
], calcFixed)

run("Parentheses", [
    Case(input: "(2+3)*4", expected: "20"),
    Case(input: "(10+5)/3", expected: "5"),
    Case(input: "(1+2)/2",  expected: "1.5"),
    Case(input: "20/(3+1)", expected: "5"),
    Case(input: "10/(3+3)", expected: "1.666666666667"),
    Case(input: "1/(2)",    expected: "0.5"),
    Case(input: "((2+3))*2", expected: "10"),
], calcFixed)

run("Negative numbers + division", [
    Case(input: "-3/2",   expected: "-1.5"),
    Case(input: "3/-2",   expected: "-1.5"),
    Case(input: "-3/-2",  expected: "1.5"),
    Case(input: "-10/3",  expected: "-3.333333333333"),
], calcFixed)

run("Already-float expressions", [
    Case(input: "3.5+2",  expected: "5.5"),
    Case(input: "3.5/2",  expected: "1.75"),
    Case(input: "1.5*3",  expected: "4.5"),
    Case(input: "10.0/3", expected: "3.333333333333"),
    Case(input: "2.5^2",  expected: "6.25"),
], calcFixed)

run("Spacing robustness", [
    Case(input: " 3 / 2 ",  expected: "1.5"),
    Case(input: "3+ 2",     expected: "5"),
    Case(input: "( 1 + 2 )/2", expected: "1.5"),
], calcFixed)

// ═══════════════════════════════════════════════════════════════
print("\n═══════════════════════════════════════════")
print("  PART 3: Bug Repro — Current vs Fixed")
print("═══════════════════════════════════════════")

let bugCases = ["3/2", "10/3", "1/3", "10/3*3", "3*5/2", "100/3"]
print("\nExpression   Current → Fixed")
for expr in bugCases {
    let cur = calcCurrent(expr) ?? "nil"
    let fix = calcFixed(expr) ?? "nil"
    let marker = cur == fix ? "  " : "←"
    print("  \(expr.padding(toLength: 10, withPad: " ", startingAt: 0))   \(cur.padding(toLength: 5, withPad: " ", startingAt: 0)) → \(fix) \(marker)")
}

// ═══════════════════════════════════════════════════════════════
print("\n═══════════════════════════════════════════")
print("  PART 4: Edge Cases")
print("═══════════════════════════════════════════")

info("Division by zero: 5/0 → \(calcFixed("5/0") ?? "nil") (inf → isFinite guard)")
info("Scientific notation: 2e5/4 → \(calcFixed("2e5/4") ?? "nil")")
info("Scientific notation reuse: 2e5+2e5 → \(calcFixed("2e5+2e5") ?? "nil")")
info("Large division: 999999999999999999/1 → \(calcFixed("999999999999999999/1") ?? "nil")")
info("Zero num/den: 0/0 → \(calcFixed("0/0") ?? "nil") (NaN → isFinite guard)")

// Verify \b won't match digits in scientific notation
let sciExpr = clean("2e5/4")
let converted = toDoubleExpr(sciExpr)
info("toDoubleExpr('2e5/4') → '\(converted)' (should NOT change: 2e5 is not an integer literal)")

// ═══════════════════════════════════════════════════════════════
print("\n═══════════════════════════════════════════")
print("  Results: \(passed)/\(total) passed")
print("═══════════════════════════════════════════")
print(passed == total ? "\(G)ALL TESTS PASSED\(X)" : "\(R)\(total - passed) FAILED\(X)")

print("""

FIRST-PRINCIPLES ANALYSIS
═══════════════════════════════════════════
Problem: NSExpression inherits C integer arithmetic semantics.
  "3/2" is parsed as Int/Int → integer division → 1.0
  The truncation happens INSIDE NSExpression's parser.
  By the time Swift sees the result, it's already wrong.

Why other ops seem "fine":
  +, -, * on integers always produce integer results — truncation
  is invisible. But the same integer type inference is happening.
  ** (power) on integers → integer result.

General solution (first-principles):
  Decouple evaluation semantics from input syntax. Just because
  the user typed "3/2" without "." doesn't mean they want integer
  division. A calculator should ALWAYS use real-number arithmetic.

Implementation:
  For any integer-only expression, convert all integer literals
  to .0 form BEFORE NSExpression evaluation:
    "3/2" → "3.0/2.0" → NSExpression → 1.5
    "2e5/4" → untouched (\\b guard prevents match in "2e5")

  The regex \\b(\\d+)\\b uses word boundaries:
  - "3" in "3/2" → matched (surrounded by non-word chars)
  - "2" in "2e5" → NOT matched ('e' is a word char, no boundary)
  - This correctly handles scientific notation.

  NumberFormatter handles display: 6/3 → 6.0/3.0 → 2.0 → "2"
""")
