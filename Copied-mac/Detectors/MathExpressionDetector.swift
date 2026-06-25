import Foundation

/// 数学表达式检测器 — 检测合法的数学表达式。
///
/// 安全约束：所有验证在检测层完成，NSExpression 异常无法在 Swift 中捕获。
struct MathExpressionDetector: ContentDetectorProtocol {
    let kind = ContentKind.mathExpr
    let priority = 180

    func detect(in text: String) -> ContentDetection? {
        var cleaned = text.replacingOccurrences(of: "=", with: "")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        // Reject multi-line
        guard cleaned.rangeOfCharacter(from: .newlines) == nil else { return nil }

        // Must contain at least one digit and one operator
        let hasDigit = cleaned.range(of: #"\d"#, options: .regularExpression) != nil
        let hasOperator = cleaned.range(of: #"[\+\-\*\/\^×÷]"#, options: .regularExpression) != nil
        guard hasDigit && hasOperator else { return nil }

        // Character whitelist
        let allowedChars = CharacterSet(charactersIn: "0123456789+-*/^.()eE×÷ ")
        guard cleaned.rangeOfCharacter(from: allowedChars.inverted) == nil else { return nil }

        // No letters (except 'e'/'E')
        let lettersExceptE = cleaned
            .replacingOccurrences(of: "e", with: "")
            .replacingOccurrences(of: "E", with: "")
        guard lettersExceptE.range(of: #"[a-zA-Z]"#, options: .regularExpression) == nil else {
            return nil
        }

        // Balanced parentheses
        guard hasBalancedParentheses(cleaned) else { return nil }

        // Valid math structure
        guard isValidMathStructure(cleaned) else { return nil }

        return ContentDetection(kind: .mathExpr, value: cleaned)
    }

    // MARK: - Structure validation

    private func isValidMathStructure(_ text: String) -> Bool {
        let operators = Set("+-*/^×÷")
        var prevChar: Character? = nil
        var justSkippedWhitespace = false
        var hasDigit = false
        var decimalCountInCurrentNumber = 0

        for ch in text {
            if ch == " " {
                justSkippedWhitespace = true
                continue
            }

            if ch == "." {
                decimalCountInCurrentNumber += 1
                if decimalCountInCurrentNumber > 1 { return false }
            } else if operators.contains(ch) || ch == "(" || ch == ")" {
                decimalCountInCurrentNumber = 0
            }

            if ch.isNumber { hasDigit = true }

            // Consecutive operators
            if operators.contains(ch), let p = prevChar, operators.contains(p) {
                if ch == "-" { /* unary minus OK */ }
                else { return false }
            }

            // Implied multiplication (whitespace-separated)
            if justSkippedWhitespace {
                if ch.isNumber, let p = prevChar, (p.isNumber || p == ")" || p == ".") { return false }
                if ch == "(", let p = prevChar, (p.isNumber || p == ")") { return false }
                if ch == ".", let p = prevChar, p.isNumber { return false }
            } else {
                // Direct adjacency
                if ch == "(", let p = prevChar, (p.isNumber || p == ")") { return false }
                if ch.isNumber, let p = prevChar, p == ")" { return false }
            }

            prevChar = ch
            justSkippedWhitespace = false
        }

        guard hasDigit else { return false }
        if let first = text.first(where: { $0 != " " }), operators.contains(first), first != "-" {
            return false
        }
        if let last = text.last(where: { $0 != " " }), operators.contains(last) {
            return false
        }
        return true
    }

    private func hasBalancedParentheses(_ text: String) -> Bool {
        var depth = 0
        for ch in text {
            if ch == "(" { depth += 1 }
            if ch == ")" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }
}
