import Foundation

enum MathExpressionEvaluationError: Error, Equatable {
    case invalidSyntax
    case tooComplex
    case divisionByZero
    case numberTooLarge
    case noRealResult
    case unsupportedOperation
    case unstableApproximation
}

struct MathExpressionValue: Equatable {
    let decimal: Decimal
    let absoluteError: Decimal

    var isApproximate: Bool { absoluteError != 0 }

    init(decimal: Decimal, absoluteError: Decimal = .zero) {
        self.decimal = decimal
        self.absoluteError = absoluteError < 0 ? -absoluteError : absoluteError
    }
}

struct MathExpressionFormattedResult: Equatable {
    let displayText: String
    let copyText: String
    let isApproximate: Bool
}

/// Strict parser and bounded decimal evaluator for clipboard formulas.
///
/// Detection and execution intentionally share this implementation so an
/// expression accepted by the detector can never reach a second, looser
/// parser at execution time.
enum MathExpressionEvaluator {
    static let maximumInputBytes = 4_096
    static let maximumTokenCount = 1_024
    static let maximumOperatorCount = 512
    static let maximumRecursionDepth = 64
    static let maximumSignificantDigits = 38
    static let maximumExponentMagnitude = 10_000

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    /// Returns the single-line expression without an optional trailing `=`
    /// when its complete syntax is valid and contains a real binary operation.
    static func validatedExpression(from input: String) -> String? {
        do {
            let prepared = try prepare(input)
            var lexer = Lexer(prepared)
            let tokens = try lexer.tokenize()
            var parser = Parser(tokens: tokens, evaluates: false)
            _ = try parser.parse()
            return prepared
        } catch {
            return nil
        }
    }

    static func evaluate(_ input: String) -> Result<MathExpressionValue, MathExpressionEvaluationError> {
        do {
            let prepared = try prepare(input)
            var lexer = Lexer(prepared)
            let tokens = try lexer.tokenize()
            var parser = Parser(tokens: tokens, evaluates: true)
            return .success(try parser.parse())
        } catch let error as MathExpressionEvaluationError {
            return .failure(error)
        } catch {
            return .failure(.invalidSyntax)
        }
    }

    /// Formats display and clipboard text from the same rounded value.
    /// Display text follows the user's locale; copy text is always parseable
    /// ASCII with no grouping separators.
    static func format(
        _ value: MathExpressionValue,
        locale: Locale = .current
    ) -> MathExpressionFormattedResult? {
        let decimal = value.decimal == 0 ? Decimal.zero : value.decimal
        let profile = DecimalProfile(decimal)
        let useScientific = decimal != 0
            && (profile.highestExponent >= 18 || profile.highestExponent < -12)

        let displayFormatter = makeFormatter(
            scientific: useScientific,
            locale: locale,
            usesGrouping: !useScientific,
            exponentSymbol: "E"
        )
        let copyFormatter = makeFormatter(
            scientific: useScientific,
            locale: posixLocale,
            usesGrouping: false,
            exponentSymbol: "e"
        )
        let number = NSDecimalNumber(decimal: decimal)
        let fallback = number.stringValue
        let display = displayFormatter.string(from: number) ?? fallback
        let copy = copyFormatter.string(from: number) ?? fallback

        if value.isApproximate {
            guard let bounds = outwardBounds(center: decimal, error: value.absoluteError),
                  formattedString(bounds.lower, using: copyFormatter) == copy,
                  formattedString(bounds.upper, using: copyFormatter) == copy else {
                return nil
            }
        }

        let roundedValue = Decimal(string: copy, locale: posixLocale)
        let formattingRounded = roundedValue.map { $0 != decimal } ?? true

        return MathExpressionFormattedResult(
            displayText: display,
            copyText: copy,
            isApproximate: value.isApproximate || formattingRounded
        )
    }

    private static func formattedString(_ decimal: Decimal, using formatter: NumberFormatter) -> String {
        let normalized = decimal == 0 ? Decimal.zero : decimal
        let number = NSDecimalNumber(decimal: normalized)
        return formatter.string(from: number) ?? number.stringValue
    }

    private static func outwardBounds(
        center: Decimal,
        error: Decimal
    ) -> (lower: Decimal, upper: Decimal)? {
        var centerCopy = center
        var errorCopy = error
        var lowerDown = Decimal()
        var lowerUp = Decimal()
        let lowerDownStatus = NSDecimalSubtract(&lowerDown, &centerCopy, &errorCopy, .down)
        centerCopy = center
        errorCopy = error
        let lowerUpStatus = NSDecimalSubtract(&lowerUp, &centerCopy, &errorCopy, .up)

        centerCopy = center
        errorCopy = error
        var upperDown = Decimal()
        var upperUp = Decimal()
        let upperDownStatus = NSDecimalAdd(&upperDown, &centerCopy, &errorCopy, .down)
        centerCopy = center
        errorCopy = error
        let upperUpStatus = NSDecimalAdd(&upperUp, &centerCopy, &errorCopy, .up)

        let statuses = [lowerDownStatus, lowerUpStatus, upperDownStatus, upperUpStatus]
        guard statuses.allSatisfy({ $0 == .noError || $0 == .lossOfPrecision }),
              !lowerDown.isNaN, !lowerUp.isNaN, !upperDown.isNaN, !upperUp.isNaN else {
            return nil
        }
        return (
            lower: min(lowerDown, lowerUp),
            upper: max(upperDown, upperUp)
        )
    }

    private static func prepare(_ input: String) throws -> String {
        guard input.utf8.count <= maximumInputBytes else {
            throw MathExpressionEvaluationError.tooComplex
        }

        var prepared = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prepared.isEmpty,
              prepared.rangeOfCharacter(from: .newlines) == nil else {
            throw MathExpressionEvaluationError.invalidSyntax
        }

        if prepared.last == "=" {
            prepared.removeLast()
            prepared = prepared.trimmingCharacters(in: .whitespaces)
        }
        guard !prepared.isEmpty, !prepared.contains("=") else {
            throw MathExpressionEvaluationError.invalidSyntax
        }
        return prepared
    }

    private static func makeFormatter(
        scientific: Bool,
        locale: Locale,
        usesGrouping: Bool,
        exponentSymbol: String
    ) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.roundingMode = .halfEven
        formatter.usesGroupingSeparator = usesGrouping
        if scientific {
            formatter.numberStyle = .scientific
            formatter.minimumSignificantDigits = 1
            formatter.maximumSignificantDigits = 12
            formatter.exponentSymbol = exponentSymbol
        } else {
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 12
        }
        return formatter
    }
}

// MARK: - Lexer

private extension MathExpressionEvaluator {
    enum Token {
        case number(Decimal)
        case plus
        case minus
        case multiply
        case divide
        case power
        case leftParenthesis
        case rightParenthesis
        case end
    }

    struct Lexer {
        private let characters: [Character]
        private var index = 0
        private var tokenCount = 0
        private var operatorCount = 0

        init(_ expression: String) {
            characters = Array(expression)
        }

        mutating func tokenize() throws -> [Token] {
            var tokens: [Token] = []
            while let character = peek() {
                if character.isWhitespace {
                    advance()
                    continue
                }

                let token: Token
                if isASCIIDigit(character) || character == "." {
                    token = try readNumber()
                } else {
                    advance()
                    switch character {
                    case "+": token = .plus
                    case "-": token = .minus
                    case "*", "×": token = .multiply
                    case "/", "÷": token = .divide
                    case "^": token = .power
                    case "(": token = .leftParenthesis
                    case ")": token = .rightParenthesis
                    default: throw MathExpressionEvaluationError.invalidSyntax
                    }
                    if isOperator(token) {
                        operatorCount += 1
                        guard operatorCount <= maximumOperatorCount else {
                            throw MathExpressionEvaluationError.tooComplex
                        }
                    }
                }

                tokenCount += 1
                guard tokenCount <= maximumTokenCount else {
                    throw MathExpressionEvaluationError.tooComplex
                }
                tokens.append(token)
            }
            tokens.append(.end)
            return tokens
        }

        private mutating func readNumber() throws -> Token {
            let start = index
            var hasIntegerDigits = false
            while let character = peek(), isASCIIDigit(character) {
                hasIntegerDigits = true
                advance()
            }

            var hasFractionDigits = false
            if peek() == "." {
                advance()
                while let character = peek(), isASCIIDigit(character) {
                    hasFractionDigits = true
                    advance()
                }
            }
            guard hasIntegerDigits || hasFractionDigits else {
                throw MathExpressionEvaluationError.invalidSyntax
            }

            if let character = peek(), character == "e" || character == "E" {
                advance()
                if let sign = peek(), sign == "+" || sign == "-" {
                    advance()
                }
                var hasExponentDigits = false
                while let character = peek(), isASCIIDigit(character) {
                    hasExponentDigits = true
                    advance()
                }
                guard hasExponentDigits else {
                    throw MathExpressionEvaluationError.invalidSyntax
                }
            }

            let literal = String(characters[start..<index])
            guard significantDigitCount(in: literal) <= maximumSignificantDigits,
                  let exact = ExactDecimal(literal),
                  let decimal = exact.decimalValue,
                  !decimal.isNaN else {
                throw MathExpressionEvaluationError.numberTooLarge
            }
            return .number(decimal)
        }

        private func significantDigitCount(in literal: String) -> Int {
            let mantissa = literal.prefix { $0 != "e" && $0 != "E" }
            let digits = Array(mantissa.filter { isASCIIDigit($0) })
            guard let first = digits.firstIndex(where: { $0 != "0" }),
                  let last = digits.lastIndex(where: { $0 != "0" }) else {
                return 1
            }
            return last - first + 1
        }

        private func isOperator(_ token: Token) -> Bool {
            switch token {
            case .plus, .minus, .multiply, .divide, .power: return true
            default: return false
            }
        }

        private func peek() -> Character? {
            index < characters.count ? characters[index] : nil
        }

        private mutating func advance() {
            index += 1
        }

        private func isASCIIDigit(_ character: Character) -> Bool {
            character >= "0" && character <= "9"
        }
    }
}

// MARK: - Parser and evaluator

private extension MathExpressionEvaluator {
    struct Parser {
        private let tokens: [Token]
        private let evaluates: Bool
        private var index = 0
        private var binaryOperationCount = 0

        init(tokens: [Token], evaluates: Bool) {
            self.tokens = tokens
            self.evaluates = evaluates
        }

        mutating func parse() throws -> MathExpressionValue {
            let value = try parseExpression(depth: 0)
            guard case .end = current,
                  binaryOperationCount > 0 else {
                throw MathExpressionEvaluationError.invalidSyntax
            }
            return value
        }

        private mutating func parseExpression(depth: Int) throws -> MathExpressionValue {
            var value = try parseTerm(depth: depth)
            while true {
                switch current {
                case .plus:
                    advance()
                    binaryOperationCount += 1
                    let rhs = try parseTerm(depth: depth)
                    value = try applyAdd(value, rhs)
                case .minus:
                    advance()
                    binaryOperationCount += 1
                    let rhs = try parseTerm(depth: depth)
                    value = try applySubtract(value, rhs)
                default:
                    return value
                }
            }
        }

        private mutating func parseTerm(depth: Int) throws -> MathExpressionValue {
            var value = try parseUnary(depth: depth)
            while true {
                switch current {
                case .multiply:
                    advance()
                    binaryOperationCount += 1
                    let rhs = try parseUnary(depth: depth)
                    value = try applyMultiply(value, rhs)
                case .divide:
                    advance()
                    binaryOperationCount += 1
                    let rhs = try parseUnary(depth: depth)
                    value = try applyDivide(value, rhs)
                default:
                    return value
                }
            }
        }

        private mutating func parseUnary(depth: Int) throws -> MathExpressionValue {
            try checkDepth(depth)
            switch current {
            case .plus:
                advance()
                return try parseUnary(depth: depth + 1)
            case .minus:
                advance()
                let value = try parseUnary(depth: depth + 1)
                guard evaluates else { return .zero }
                return MathExpressionValue(
                    decimal: value.decimal == 0 ? .zero : -value.decimal,
                    absoluteError: value.absoluteError
                )
            default:
                return try parsePower(depth: depth)
            }
        }

        private mutating func parsePower(depth: Int) throws -> MathExpressionValue {
            try checkDepth(depth)
            let base = try parsePrimary(depth: depth)
            guard case .power = current else { return base }
            advance()
            binaryOperationCount += 1
            let exponent = try parseUnary(depth: depth + 1)
            return try applyPower(base, exponent)
        }

        private mutating func parsePrimary(depth: Int) throws -> MathExpressionValue {
            try checkDepth(depth)
            switch current {
            case let .number(decimal):
                advance()
                return MathExpressionValue(decimal: decimal)
            case .leftParenthesis:
                advance()
                let value = try parseExpression(depth: depth + 1)
                guard case .rightParenthesis = current else {
                    throw MathExpressionEvaluationError.invalidSyntax
                }
                advance()
                return value
            default:
                throw MathExpressionEvaluationError.invalidSyntax
            }
        }

        private var current: Token {
            tokens[index]
        }

        private mutating func advance() {
            index += 1
        }

        private func checkDepth(_ depth: Int) throws {
            guard depth <= maximumRecursionDepth else {
                throw MathExpressionEvaluationError.tooComplex
            }
        }

        private func applyAdd(
            _ lhs: MathExpressionValue,
            _ rhs: MathExpressionValue
        ) throws -> MathExpressionValue {
            guard evaluates else { return .zero }
            if lhs.decimal == 0, !lhs.isApproximate { return rhs }
            if rhs.decimal == 0, !rhs.isApproximate { return lhs }
            if !lhs.isApproximate && !rhs.isApproximate {
                let exact = ExactDecimal(lhs.decimal).adding(ExactDecimal(rhs.decimal))
                guard let decimal = exact.decimalValue else {
                    throw MathExpressionEvaluationError.numberTooLarge
                }
                return MathExpressionValue(decimal: decimal)
            }
            var left = lhs.decimal
            var right = rhs.decimal
            var result = Decimal()
            let error = NSDecimalAdd(&result, &left, &right, .plain)
            return try checkedAdditionResult(result, error: error, lhs: lhs, rhs: rhs)
        }

        private func applySubtract(
            _ lhs: MathExpressionValue,
            _ rhs: MathExpressionValue
        ) throws -> MathExpressionValue {
            guard evaluates else { return .zero }
            if rhs.decimal == 0, !rhs.isApproximate { return lhs }
            if lhs.decimal == 0, !lhs.isApproximate {
                return MathExpressionValue(
                    decimal: rhs.decimal == 0 ? .zero : -rhs.decimal,
                    absoluteError: rhs.absoluteError
                )
            }
            if !lhs.isApproximate && !rhs.isApproximate {
                let exact = ExactDecimal(lhs.decimal).subtracting(ExactDecimal(rhs.decimal))
                guard let decimal = exact.decimalValue else {
                    throw MathExpressionEvaluationError.numberTooLarge
                }
                return MathExpressionValue(decimal: decimal)
            }
            var left = lhs.decimal
            var right = rhs.decimal
            var result = Decimal()
            let error = NSDecimalSubtract(&result, &left, &right, .plain)
            return try checkedAdditionResult(result, error: error, lhs: lhs, rhs: rhs)
        }

        private func applyMultiply(
            _ lhs: MathExpressionValue,
            _ rhs: MathExpressionValue
        ) throws -> MathExpressionValue {
            guard evaluates else { return .zero }
            if lhs.decimal == 0, !lhs.isApproximate { return .zero }
            if rhs.decimal == 0, !rhs.isApproximate { return .zero }
            if lhs.decimal == 1, !lhs.isApproximate { return rhs }
            if rhs.decimal == 1, !rhs.isApproximate { return lhs }
            if lhs.decimal == -1, !lhs.isApproximate {
                return MathExpressionValue(
                    decimal: rhs.decimal == 0 ? .zero : -rhs.decimal,
                    absoluteError: rhs.absoluteError
                )
            }
            if rhs.decimal == -1, !rhs.isApproximate {
                return MathExpressionValue(
                    decimal: lhs.decimal == 0 ? .zero : -lhs.decimal,
                    absoluteError: lhs.absoluteError
                )
            }
            guard !lhs.isApproximate, !rhs.isApproximate else {
                throw MathExpressionEvaluationError.unstableApproximation
            }
            let exact = ExactDecimal(lhs.decimal).multiplied(by: ExactDecimal(rhs.decimal))
            guard let decimal = exact.decimalValue else {
                throw MathExpressionEvaluationError.numberTooLarge
            }
            return MathExpressionValue(decimal: decimal)
        }

        private func applyDivide(
            _ lhs: MathExpressionValue,
            _ rhs: MathExpressionValue
        ) throws -> MathExpressionValue {
            guard evaluates else { return .zero }
            guard !lhs.isApproximate, !rhs.isApproximate else {
                throw MathExpressionEvaluationError.unstableApproximation
            }
            guard rhs.decimal != 0 else {
                throw MathExpressionEvaluationError.divisionByZero
            }
            if lhs.decimal == 0 { return .zero }

            var numerator = lhs.decimal
            var denominator = rhs.decimal
            var quotient = Decimal()
            let error = NSDecimalDivide(&quotient, &numerator, &denominator, .plain)
            switch error {
            case .noError, .lossOfPrecision:
                break
            case .divideByZero:
                throw MathExpressionEvaluationError.divisionByZero
            case .underflow, .overflow:
                throw MathExpressionEvaluationError.numberTooLarge
            @unknown default:
                throw MathExpressionEvaluationError.numberTooLarge
            }
            guard !quotient.isNaN else {
                throw MathExpressionEvaluationError.numberTooLarge
            }

            let divisionWasExact = ExactDecimal(quotient)
                .multiplied(by: ExactDecimal(denominator)) == ExactDecimal(numerator)
            return MathExpressionValue(
                decimal: quotient,
                absoluteError: divisionWasExact ? .zero : try unitInLastPlace(of: quotient)
            )
        }

        private func applyPower(
            _ base: MathExpressionValue,
            _ exponent: MathExpressionValue
        ) throws -> MathExpressionValue {
            guard evaluates else { return .zero }
            guard !base.isApproximate, !exponent.isApproximate else {
                throw MathExpressionEvaluationError.unstableApproximation
            }
            switch classifyExponent(exponent.decimal) {
            case let .integer(integer):
                return try integerPower(base, exponent: integer)
            case .integerOutOfRange:
                throw MathExpressionEvaluationError.numberTooLarge
            case .fractional:
                throw MathExpressionEvaluationError.unsupportedOperation
            }
        }

        private func integerPower(
            _ base: MathExpressionValue,
            exponent: Int
        ) throws -> MathExpressionValue {
            if exponent == 0 {
                return MathExpressionValue(decimal: 1)
            }
            if exponent < 0, base.decimal == 0 {
                throw MathExpressionEvaluationError.divisionByZero
            }

            var remaining = abs(exponent)
            var factor = base
            var result = MathExpressionValue(decimal: 1)
            while remaining > 0 {
                if remaining % 2 == 1 {
                    result = try applyMultiply(result, factor)
                }
                remaining /= 2
                if remaining > 0 {
                    factor = try applyMultiply(factor, factor)
                }
            }

            if exponent < 0 {
                return try applyDivide(MathExpressionValue(decimal: 1), result)
            }
            return result
        }

        private enum ExponentClassification {
            case integer(Int)
            case integerOutOfRange
            case fractional
        }

        private func classifyExponent(_ decimal: Decimal) -> ExponentClassification {
            var source = decimal
            var rounded = Decimal()
            NSDecimalRound(&rounded, &source, 0, .plain)
            guard rounded == decimal else { return .fractional }
            let string = NSDecimalNumber(decimal: rounded).stringValue
            guard let integer = Int(string),
                  integer >= -maximumExponentMagnitude,
                  integer <= maximumExponentMagnitude else {
                return .integerOutOfRange
            }
            return .integer(integer)
        }

        private func checkedAdditionResult(
            _ result: Decimal,
            error: Decimal.CalculationError,
            lhs: MathExpressionValue,
            rhs: MathExpressionValue
        ) throws -> MathExpressionValue {
            guard !result.isNaN else {
                throw MathExpressionEvaluationError.numberTooLarge
            }
            let operandsApproximate = lhs.isApproximate || rhs.isApproximate
            switch error {
            case .noError:
                break
            case .lossOfPrecision where operandsApproximate:
                break
            case .divideByZero:
                throw MathExpressionEvaluationError.divisionByZero
            case .lossOfPrecision, .underflow, .overflow:
                throw MathExpressionEvaluationError.numberTooLarge
            @unknown default:
                throw MathExpressionEvaluationError.numberTooLarge
            }

            guard operandsApproximate else {
                return MathExpressionValue(decimal: result)
            }
            let roundingQuantum = try additionRoundingQuantum(lhs.decimal, rhs.decimal, result)
            let absoluteError = try sumErrors(
                lhs.absoluteError,
                rhs.absoluteError,
                roundingQuantum
            )
            return MathExpressionValue(decimal: result, absoluteError: absoluteError)
        }

        private func unitInLastPlace(of decimal: Decimal) throws -> Decimal {
            try powerOfTen(DecimalProfile(decimal).lowestExponent)
        }

        private func additionRoundingQuantum(
            _ lhs: Decimal,
            _ rhs: Decimal,
            _ result: Decimal
        ) throws -> Decimal {
            let highestExponent = max(
                DecimalProfile(lhs).highestExponent,
                DecimalProfile(rhs).highestExponent,
                DecimalProfile(result).highestExponent
            )
            return try powerOfTen(max(-128, highestExponent - maximumSignificantDigits + 1))
        }

        private func powerOfTen(_ exponent: Int) throws -> Decimal {
            guard let exact = ExactDecimal("1e\(max(-128, exponent))"),
                  let decimal = exact.decimalValue,
                  !decimal.isNaN else {
                throw MathExpressionEvaluationError.unstableApproximation
            }
            return decimal
        }

        private func sumErrors(_ values: Decimal...) throws -> Decimal {
            var total = Decimal.zero
            for value in values where value != 0 {
                var left = total
                var right = value
                var sum = Decimal()
                let status = NSDecimalAdd(&sum, &left, &right, .up)
                guard (status == .noError || status == .lossOfPrecision), !sum.isNaN else {
                    throw MathExpressionEvaluationError.unstableApproximation
                }
                total = sum
            }
            return total
        }
    }

    struct DecimalProfile {
        let highestExponent: Int
        let lowestExponent: Int

        init(_ decimal: Decimal) {
            if decimal == 0 {
                highestExponent = 0
                lowestExponent = 0
                return
            }

            let string = NSDecimalNumber(decimal: decimal).stringValue
            let unsigned = string.first == "-" ? String(string.dropFirst()) : string
            let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false)
            let integerPart = parts.first.map(String.init) ?? "0"
            let fractionPart = parts.count > 1 ? String(parts[1]) : ""
            let digits = Array(integerPart + fractionPart)
            let decimalPosition = integerPart.count
            let first = digits.firstIndex(where: { $0 != "0" }) ?? 0
            let last = digits.lastIndex(where: { $0 != "0" }) ?? first

            highestExponent = decimalPosition - first - 1
            lowestExponent = decimalPosition - last - 1
        }
    }

    /// Exact base-10 coefficient arithmetic used to verify that Decimal can
    /// represent add/subtract/multiply results without silent rounding.
    struct ExactDecimal: Equatable {
        let isNegative: Bool
        let digits: [UInt8]
        let exponent: Int

        init(_ decimal: Decimal) {
            let string = NSDecimalNumber(decimal: decimal).stringValue
            guard let parsed = ExactDecimal(string) else {
                preconditionFailure("Decimal must have a canonical finite representation")
            }
            self = parsed
        }

        init?(_ string: String) {
            var source = string
            let negative = source.first == "-"
            if negative { source.removeFirst() }

            var explicitExponent = 0
            if let exponentIndex = source.firstIndex(where: { $0 == "e" || $0 == "E" }) {
                let exponentText = source[source.index(after: exponentIndex)...]
                guard let parsedExponent = Int(exponentText) else { return nil }
                explicitExponent = parsedExponent
                source = String(source[..<exponentIndex])
            }

            let parts = source.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            let integerPart = parts.first.map(String.init) ?? ""
            let fractionPart = parts.count == 2 ? String(parts[1]) : ""
            let characters = Array(integerPart + fractionPart)
            guard !characters.isEmpty,
                  characters.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
                return nil
            }
            let rawDigits = characters.compactMap { UInt8(String($0)) }
            let (combinedExponent, overflow) = explicitExponent.subtractingReportingOverflow(fractionPart.count)
            guard !overflow else { return nil }
            self.init(
                isNegative: negative,
                digits: rawDigits,
                exponent: combinedExponent
            )
        }

        private init(isNegative: Bool, digits rawDigits: [UInt8], exponent rawExponent: Int) {
            let firstNonZero = rawDigits.firstIndex(where: { $0 != 0 })
            guard let firstNonZero else {
                self.isNegative = false
                digits = [0]
                exponent = 0
                return
            }

            var normalized = Array(rawDigits[firstNonZero...])
            var normalizedExponent = rawExponent
            while normalized.count > 1,
                  normalized.last == 0,
                  normalizedExponent < Int.max {
                normalized.removeLast()
                normalizedExponent += 1
            }
            self.isNegative = isNegative
            digits = normalized
            exponent = normalizedExponent
        }

        var decimalValue: Decimal? {
            guard exponent >= -128,
                  exponent <= 165,
                  digits.count - 1 <= 165 - exponent else {
                return nil
            }
            let unsigned = digits.map(String.init).joined()
            let decimalText: String
            if exponent >= 0 {
                decimalText = unsigned + String(repeating: "0", count: exponent)
            } else {
                let decimalPosition = unsigned.count + exponent
                if decimalPosition > 0 {
                    let index = unsigned.index(unsigned.startIndex, offsetBy: decimalPosition)
                    decimalText = String(unsigned[..<index]) + "." + String(unsigned[index...])
                } else {
                    decimalText = "0." + String(repeating: "0", count: -decimalPosition) + unsigned
                }
            }
            let sign = isNegative ? "-" : ""
            guard let decimal = Decimal(
                string: sign + decimalText,
                locale: posixLocale
            ), !decimal.isNaN, ExactDecimal(decimal) == self else {
                return nil
            }
            return decimal
        }

        func adding(_ other: ExactDecimal) -> ExactDecimal {
            if isZero { return other }
            if other.isZero { return self }

            let commonExponent = min(exponent, other.exponent)
            let left = alignedDigits(at: commonExponent)
            let right = other.alignedDigits(at: commonExponent)

            if isNegative == other.isNegative {
                return ExactDecimal(
                    isNegative: isNegative,
                    digits: Self.addMagnitudes(left, right),
                    exponent: commonExponent
                )
            }

            switch Self.compareMagnitudes(left, right) {
            case 0:
                return ExactDecimal(isNegative: false, digits: [0], exponent: 0)
            case let comparison where comparison > 0:
                return ExactDecimal(
                    isNegative: isNegative,
                    digits: Self.subtractMagnitudes(left, right),
                    exponent: commonExponent
                )
            default:
                return ExactDecimal(
                    isNegative: other.isNegative,
                    digits: Self.subtractMagnitudes(right, left),
                    exponent: commonExponent
                )
            }
        }

        func subtracting(_ other: ExactDecimal) -> ExactDecimal {
            adding(other.negated())
        }

        func multiplied(by other: ExactDecimal) -> ExactDecimal {
            guard !isZero, !other.isZero else {
                return ExactDecimal(isNegative: false, digits: [0], exponent: 0)
            }
            var product = [Int](repeating: 0, count: digits.count + other.digits.count)
            for leftIndex in digits.indices.reversed() {
                for rightIndex in other.digits.indices.reversed() {
                    product[leftIndex + rightIndex + 1] += Int(digits[leftIndex]) * Int(other.digits[rightIndex])
                }
            }
            for index in stride(from: product.count - 1, through: 1, by: -1) {
                product[index - 1] += product[index] / 10
                product[index] %= 10
            }
            return ExactDecimal(
                isNegative: isNegative != other.isNegative,
                digits: product.map(UInt8.init),
                exponent: exponent + other.exponent
            )
        }

        private var isZero: Bool { digits == [0] }

        private func negated() -> ExactDecimal {
            ExactDecimal(
                isNegative: isZero ? false : !isNegative,
                digits: digits,
                exponent: exponent
            )
        }

        private func alignedDigits(at commonExponent: Int) -> [UInt8] {
            digits + Array(repeating: 0, count: exponent - commonExponent)
        }

        private static func compareMagnitudes(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
            if lhs.count != rhs.count { return lhs.count < rhs.count ? -1 : 1 }
            for (left, right) in zip(lhs, rhs) where left != right {
                return left < right ? -1 : 1
            }
            return 0
        }

        private static func addMagnitudes(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
            let width = max(lhs.count, rhs.count)
            var result = [UInt8](repeating: 0, count: width + 1)
            var carry = 0
            for offset in 0..<width {
                let left = offset < lhs.count ? Int(lhs[lhs.count - 1 - offset]) : 0
                let right = offset < rhs.count ? Int(rhs[rhs.count - 1 - offset]) : 0
                let sum = left + right + carry
                result[result.count - 1 - offset] = UInt8(sum % 10)
                carry = sum / 10
            }
            result[0] = UInt8(carry)
            return result
        }

        /// Requires lhs >= rhs.
        private static func subtractMagnitudes(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: lhs.count)
            var borrow = 0
            for offset in 0..<lhs.count {
                let left = Int(lhs[lhs.count - 1 - offset]) - borrow
                let right = offset < rhs.count ? Int(rhs[rhs.count - 1 - offset]) : 0
                if left < right {
                    result[result.count - 1 - offset] = UInt8(left + 10 - right)
                    borrow = 1
                } else {
                    result[result.count - 1 - offset] = UInt8(left - right)
                    borrow = 0
                }
            }
            return result
        }
    }
}

private extension MathExpressionValue {
    static let zero = MathExpressionValue(decimal: .zero)
}
