import Foundation

// Minimal protocol surface needed to compile the production detector without
// pulling the global registry and every unrelated detector into this test.
protocol ContentDetectorProtocol {
    var kind: ContentKind { get }
    var priority: Int { get }
    func detect(in text: String) -> ContentDetection?
}

@main
enum MathExpressionTests {
    private static let englishLocale = Locale(identifier: "en_US")
    private static var total = 0
    private static var failures = 0

    static func main() {
        testReportedRegression()
        testExactDecimalArithmetic()
        testDivisionAndScientificNotation()
        testPowerSemantics()
        testSyntaxValidation()
        testPrecisionAndComplexityBounds()
        testDetectorIntegration()
        testValidationEvaluationAgreement()

        print("MathExpressionTests: \(total - failures)/\(total) passed")
        guard failures == 0 else { exit(1) }
    }

    private static func testReportedRegression() {
        let expression = "8000-((152.45+88/12+19+88+45+19+148/12+200/12+99/12+30/12+60)+814+(2380+711)+(150+100)+125+28*22+60*8)"
        let value = expectSuccess(expression)
        let formatted = expectFormat(value, context: "reported formula")
        expectEqual(formatted.displayText, "2,193.466666666667", "reported formula display")
        expectEqual(formatted.copyText, "2193.466666666667", "reported formula canonical copy")
        expect(formatted.isApproximate, "repeating divisions are marked approximate")
    }

    private static func testExactDecimalArithmetic() {
        expectFormatted("1.5+3/2", display: "3", copy: "3", approximate: false)
        expectFormatted("0.1+0.2", display: "0.3", copy: "0.3", approximate: false)
        expectFormatted(
            "1000000000000000.1+0.2",
            display: "1,000,000,000,000,000.3",
            copy: "1000000000000000.3",
            approximate: false
        )
        expectFormatted(
            "9007199254740993+0",
            display: "9,007,199,254,740,993",
            copy: "9007199254740993",
            approximate: false
        )
        expectFormatted("(2+3)*4", display: "20", copy: "20", approximate: false)
        expectFormatted("5.+.5", display: "5.5", copy: "5.5", approximate: false)
        expectFormatted(" 1 + 2 = ", display: "3", copy: "3", approximate: false)
    }

    private static func testDivisionAndScientificNotation() {
        expectFormatted("1/8", display: "0.125", copy: "0.125", approximate: false)
        expectFormatted("1/3", display: "0.333333333333", copy: "0.333333333333", approximate: true)
        expectFormatted("1e+2+3", display: "103", copy: "103", approximate: false)
        expectFormatted("2e-2+0.01", display: "0.03", copy: "0.03", approximate: false)

        let tiny = expectFormat(
            expectSuccess("1/10000000000000"),
            context: "tiny non-zero result"
        )
        expect(tiny.displayText != "0", "tiny non-zero display is not zero")
        expect(tiny.copyText != "0", "tiny non-zero copy is not zero")
        expect(tiny.copyText.lowercased().contains("e"), "tiny result uses scientific notation")
        expect(
            Decimal(string: tiny.copyText, locale: Locale(identifier: "en_US_POSIX")) != nil,
            "scientific copy remains parseable"
        )

        let negativeTiny = expectFormat(
            expectSuccess("-1/10000000000000"),
            context: "negative tiny result"
        )
        expect(negativeTiny.displayText != "-0", "negative tiny display is not negative zero")
        expect(negativeTiny.copyText != "-0", "negative tiny copy is not negative zero")

        expectFailure("1/0", .divisionByZero)
        expectFailure("0/0", .divisionByZero)
    }

    private static func testPowerSemantics() {
        expectFormatted("2^3^2", display: "512", copy: "512", approximate: false)
        expectFormatted("-2^2", display: "-4", copy: "-4", approximate: false)
        expectFormatted("(-2)^2", display: "4", copy: "4", approximate: false)
        expectFormatted("2^-2", display: "0.25", copy: "0.25", approximate: false)
        expectFormatted("0^0", display: "1", copy: "1", approximate: false)

        expectFailure("2^0.5", .unsupportedOperation)
        expectFailure("(-2)^0.5", .unsupportedOperation)
        expectFailure("(1+1e-17)^(100000000000000000.5)", .unsupportedOperation)
        expectFailure("((1/3)*3-1)*1e127", .unstableApproximation)
        expectFailure(
            "(1/3-0.33333333333333333333333333333333333333)*1e127",
            .unstableApproximation
        )
        expectFailure("2^10001", .numberTooLarge)
        expectFailure("2^-9223372036854775808", .numberTooLarge)
    }

    private static func testSyntaxValidation() {
        let valid = [
            "1+2", ".5+1", "5.+1", "1e+2+3", "3--2", "1/--2", "(1+2)*3", "1+2="
        ]
        for expression in valid {
            expect(
                MathExpressionEvaluator.validatedExpression(from: expression) != nil,
                "valid syntax accepted: \(expression)"
            )
        }

        let invalid = [
            "1e+2", "1+()", "(1+)+2", "1/( )", "1e/2", "1e2e3+1",
            "(+1)", "2(3)+1", "(2)3+1", "1..2+3", "1 2+3", "1=+2", "1+2=="
        ]
        for expression in invalid {
            expect(
                MathExpressionEvaluator.validatedExpression(from: expression) == nil,
                "invalid syntax rejected: \(expression)"
            )
        }
    }

    private static func testPrecisionAndComplexityBounds() {
        let thirtyEightDigits = String(repeating: "9", count: 38)
        let thirtyEightOnes = String(repeating: "1", count: 38)
        let thirtyNineDigits = String(repeating: "9", count: 39)
        let oneWithThirtyEightZeros = "1" + String(repeating: "0", count: 38)
        expectSuccess("\(thirtyEightDigits)+0")
        expectSuccess("\(thirtyEightDigits)*1")
        expectSuccess("-1*\(thirtyEightDigits)")
        expectSuccess("\(oneWithThirtyEightZeros)+0")
        expectSuccess("1e128+0")
        expectSuccess("1e127*10")
        expectSuccess("1e165+0")
        expectFailure("1e166+0", .numberTooLarge)
        expectFailure("1e9223372036854775807+0", .numberTooLarge)
        expectFailure("10e9223372036854775807+0", .numberTooLarge)
        expectFailure("1.0e-9223372036854775808+0", .numberTooLarge)
        let doubledOnes = expectSuccess("\(thirtyEightOnes)*2")
        expectEqual(
            doubledOnes.decimal,
            Decimal(string: String(repeating: "2", count: 38), locale: Locale(identifier: "en_US_POSIX")),
            "38-digit multiplication remains exact"
        )
        expect(!doubledOnes.isApproximate, "38-digit multiplication is not approximate")
        expectFormatted(
            "\(oneWithThirtyEightZeros)-\(thirtyEightDigits)",
            display: "1",
            copy: "1",
            approximate: false
        )
        expectFailure("\(thirtyNineDigits)+0", .numberTooLarge)
        expectFailure("\(thirtyEightDigits)*9", .numberTooLarge)

        expectFormatted("0*(1/3)", display: "0", copy: "0", approximate: false)
        expectFormatted("(1/3)*1", display: "0.333333333333", copy: "0.333333333333", approximate: true)

        let unstableCancellation = expectSuccess("1/3+2/3-1")
        expect(
            MathExpressionEvaluator.format(unstableCancellation, locale: englishLocale) == nil,
            "uncertainty crossing the displayed result is rejected"
        )

        let tooLong = String(repeating: "1+", count: 2_050) + "1"
        expect(
            MathExpressionEvaluator.validatedExpression(from: tooLong) == nil,
            "input byte limit enforced"
        )

        let tooManyOperators = Array(repeating: "1", count: 514).joined(separator: "+")
        expect(
            MathExpressionEvaluator.validatedExpression(from: tooManyOperators) == nil,
            "operator limit enforced"
        )

        let deeplyNested = String(repeating: "(", count: 66) + "1+1" + String(repeating: ")", count: 66)
        expect(
            MathExpressionEvaluator.validatedExpression(from: deeplyNested) == nil,
            "recursion depth enforced"
        )
    }

    private static func testDetectorIntegration() {
        let detector = MathExpressionDetector()
        let expression = "152.45+88/12="
        let detection = detector.detect(in: expression)
        expectEqual(detection?.kind, ContentKind.mathExpr, "detector returns math kind")
        expectEqual(detection?.value, "152.45+88/12", "detector returns normalized expression")
        expect(detector.detect(in: "1+()") == nil, "detector rejects parser-invalid input")
        expect(detector.detect(in: "1e+2") == nil, "scientific literal alone is not a formula")
    }

    private static func testValidationEvaluationAgreement() {
        let alphabet = Array("0123456789+-*/^().eE= ×÷")
        var state: UInt64 = 0xC0FFEE
        for _ in 0..<2_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let length = Int((state >> 32) % 48) + 1
            var expression = ""
            for _ in 0..<length {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                expression.append(alphabet[Int((state >> 32) % UInt64(alphabet.count))])
            }

            guard MathExpressionEvaluator.validatedExpression(from: expression) != nil else {
                continue
            }
            if case let .failure(error) = MathExpressionEvaluator.evaluate(expression),
               error == .invalidSyntax || error == .tooComplex {
                expect(false, "validated expression must share execution grammar: \(expression)")
                return
            }
        }
        expect(true, "deterministic parser robustness corpus completed")
    }

    @discardableResult
    private static func expectSuccess(
        _ expression: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> MathExpressionValue {
        total += 1
        switch MathExpressionEvaluator.evaluate(expression) {
        case let .success(value):
            return value
        case let .failure(error):
            failures += 1
            fputs("FAIL: \(expression) unexpectedly failed with \(error) [\(file):\(line)]\n", stderr)
            return MathExpressionValue(decimal: .zero)
        }
    }

    private static func expectFailure(
        _ expression: String,
        _ expected: MathExpressionEvaluationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        total += 1
        switch MathExpressionEvaluator.evaluate(expression) {
        case .success:
            failures += 1
            fputs("FAIL: \(expression) unexpectedly succeeded [\(file):\(line)]\n", stderr)
        case let .failure(actual):
            guard actual == expected else {
                failures += 1
                fputs("FAIL: \(expression) failed with \(actual), expected \(expected) [\(file):\(line)]\n", stderr)
                return
            }
        }
    }

    private static func expectFormatted(
        _ expression: String,
        display: String,
        copy: String,
        approximate: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let value = expectSuccess(expression, file: file, line: line)
        let formatted = expectFormat(value, context: expression, file: file, line: line)
        expectEqual(formatted.displayText, display, "display for \(expression)", file: file, line: line)
        expectEqual(formatted.copyText, copy, "copy for \(expression)", file: file, line: line)
        expectEqual(formatted.isApproximate, approximate, "approximation for \(expression)", file: file, line: line)
    }

    private static func expectFormat(
        _ value: MathExpressionValue,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> MathExpressionFormattedResult {
        total += 1
        guard let formatted = MathExpressionEvaluator.format(value, locale: englishLocale) else {
            failures += 1
            fputs("FAIL: \(context) has no stable formatted result [\(file):\(line)]\n", stderr)
            return MathExpressionFormattedResult(displayText: "", copyText: "", isApproximate: true)
        }
        return formatted
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        total += 1
        guard condition() else {
            failures += 1
            fputs("FAIL: \(message) [\(file):\(line)]\n", stderr)
            return
        }
    }

    private static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        expect(actual == expected, "\(message): got \(actual), expected \(expected)", file: file, line: line)
    }
}
