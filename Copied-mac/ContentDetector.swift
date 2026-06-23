import AppKit
import Foundation

// MARK: - Detected Content Types

enum DetectedContent: Hashable {
    case url(URL)
    case filePath(String)              // expanded absolute path
    case mathExpression(String)        // cleaned expression
    case colorHex(String, NSColor)     // hex string + parsed color
    case colorRGB(NSColor)             // rgb() / rgba()
    case colorHSL(NSColor)             // hsl()
    case chineseCharacter(Character)   // single CJK character
    case englishPhrase(String)         // 2-10 ASCII words
}

// MARK: - Content Detector

struct ContentDetector {

    /// Detect all matching content types from a text string.
    /// Results are ordered by priority (highest first).
    static func detect(in text: String) -> [DetectedContent] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results: [DetectedContent] = []

        // ── 1. Color ──────────────────────────────────────────
        if let color = detectColor(in: trimmed) {
            results.append(color)
        }

        // ── 2. URL ────────────────────────────────────────────
        if let urlResult = detectURL(in: trimmed) {
            results.append(urlResult)
        }

        // ── 3. File path ──────────────────────────────────────
        if let pathResult = detectFilePath(in: trimmed) {
            results.append(pathResult)
        }

        // ── 4. Math expression ────────────────────────────────
        if let mathResult = detectMathExpression(in: trimmed) {
            results.append(mathResult)
        }

        // ── 5. Single Chinese character ───────────────────────
        if let charResult = detectChineseCharacter(in: trimmed) {
            results.append(charResult)
        }

        // ── 6. English phrase ─────────────────────────────────
        if let engResult = detectEnglishPhrase(in: trimmed) {
            results.append(engResult)
        }

        return results
    }

    // MARK: - Color Detection

    private static func detectColor(in text: String) -> DetectedContent? {
        // Hex with #: #RGB, #RRGGBB, #RRGGBBAA
        let hexPattern = #"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"#
        if let match = text.range(of: hexPattern, options: .regularExpression),
           match == text.startIndex..<text.endIndex,
           let color = parseHexColor(String(text)) {
            return .colorHex(String(text), color)
        }

        // Bare 6-digit hex (no #): try prepending # and parse
        let bareHexPattern = #"^[0-9a-fA-F]{6}$"#
        if text.range(of: bareHexPattern, options: .regularExpression) != nil,
           let color = parseHexColor("#\(text)") {
            return .colorHex("#\(text)", color)
        }

        // rgb() / rgba()
        // Alpha: 0, 1, 0.0–1.0 with optional decimal digits
        let rgbPattern = #"^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(?:,\s*(0|1|0?\.\d+|[01]\.\d+))?\s*\)$"#
        if let color = parseRGBColor(text, pattern: rgbPattern) {
            return .colorRGB(color)
        }

        // hsl()
        let hslPattern = #"^hsl\(\s*(\d{1,3})\s*,\s*(\d{1,3})%\s*,\s*(\d{1,3})%\s*\)$"#
        if let color = parseHSLColor(text, pattern: hslPattern) {
            return .colorHSL(color)
        }

        return nil
    }

    private static func parseHexColor(_ hex: String) -> NSColor? {
        var hex = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex

        // Expand #RGB → #RRGGBB
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }

        guard hex.count == 6 || hex.count == 8 else { return nil }

        var int: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&int) else { return nil }

        let r, g, b, a: CGFloat
        if hex.count == 8 {
            r = CGFloat((int >> 24) & 0xFF) / 255
            g = CGFloat((int >> 16) & 0xFF) / 255
            b = CGFloat((int >> 8) & 0xFF) / 255
            a = CGFloat(int & 0xFF) / 255
        } else {
            r = CGFloat((int >> 16) & 0xFF) / 255
            g = CGFloat((int >> 8) & 0xFF) / 255
            b = CGFloat(int & 0xFF) / 255
            a = 1.0
        }
        return NSColor(red: r, green: g, blue: b, alpha: a)
    }

    private static func parseRGBColor(_ text: String, pattern: String) -> NSColor? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range.location != NSNotFound else { return nil }

        let nsText = text as NSString
        guard let r = Int(nsText.substring(with: match.range(at: 1))),
              let g = Int(nsText.substring(with: match.range(at: 2))),
              let b = Int(nsText.substring(with: match.range(at: 3))),
              (0...255).contains(r), (0...255).contains(g), (0...255).contains(b) else { return nil }

        let a: CGFloat
        if match.range(at: 4).location != NSNotFound {
            a = CGFloat(Double(nsText.substring(with: match.range(at: 4))) ?? 1.0)
        } else {
            a = 1.0
        }
        return NSColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
    }

    private static func parseHSLColor(_ text: String, pattern: String) -> NSColor? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range.location != NSNotFound else { return nil }

        let nsText = text as NSString
        guard let h = Double(nsText.substring(with: match.range(at: 1))),
              let s = Double(nsText.substring(with: match.range(at: 2))),
              let l = Double(nsText.substring(with: match.range(at: 3))),
              (0...360).contains(h),
              (0...100).contains(s),
              (0...100).contains(l) else { return nil }

        let sNorm = s / 100
        let lNorm = l / 100
        let c = (1 - abs(2 * lNorm - 1)) * sNorm
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = lNorm - c / 2

        var r, g, b: Double
        switch h {
        case 0..<60:   (r, g, b) = (c, x, 0)
        case 60..<120:  (r, g, b) = (x, c, 0)
        case 120..<180: (r, g, b) = (0, c, x)
        case 180..<240: (r, g, b) = (0, x, c)
        case 240..<300: (r, g, b) = (x, 0, c)
        default:        (r, g, b) = (c, 0, x)
        }

        return NSColor(red: r + m, green: g + m, blue: b + m, alpha: 1.0)
    }

    // MARK: - URL Detection

    private static func detectURL(in text: String) -> DetectedContent? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, range: range),
              let url = match.url,
              match.range == range else { return nil }  // entire text must be a URL
        return .url(url)
    }

    // MARK: - File Path Detection

    private static func detectFilePath(in text: String) -> DetectedContent? {
        // Must start with ~ or /
        guard text.hasPrefix("/") || text.hasPrefix("~") else { return nil }

        let expanded = (text as NSString).expandingTildeInPath

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            return nil
        }

        return .filePath(expanded)
    }

    // MARK: - Math Expression Detection

    private static func detectMathExpression(in text: String) -> DetectedContent? {
        // Clean first: remove trailing = and whitespace
        var cleaned = text.replacingOccurrences(of: "=", with: "")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        // Reject multi-line — NSExpression can't parse newlines.
        guard cleaned.rangeOfCharacter(from: .newlines) == nil else { return nil }

        // Must contain at least one digit and one operator
        let hasDigit = cleaned.range(of: #"\d"#, options: .regularExpression) != nil
        // NOTE: '%' is excluded — NSExpression treats it as a format placeholder, not modulo.
        let hasOperator = cleaned.range(of: #"[\+\-\*\/\^×÷]"#, options: .regularExpression) != nil
        guard hasDigit && hasOperator else { return nil }

        // Character whitelist: only digits, operators, parens, decimal, 'e'/'E', spaces.
        // Rejects commas, %, newlines, and other chars that crash NSExpression.
        let allowedChars = CharacterSet(charactersIn: "0123456789+-*/^.()eE×÷ ")
        guard cleaned.rangeOfCharacter(from: allowedChars.inverted) == nil else {
            return nil
        }

        // Must not contain letters (except 'e' in scientific notation)
        let lettersExceptE = cleaned
            .replacingOccurrences(of: "e", with: "")
            .replacingOccurrences(of: "E", with: "")
        guard lettersExceptE.range(of: #"[a-zA-Z]"#, options: .regularExpression) == nil else {
            return nil
        }

        // Check balanced parentheses
        guard hasBalancedParentheses(cleaned) else { return nil }

        // Validate operand structure: must have valid number→operator→number pattern.
        // Do NOT call NSExpression here — it raises NSException on edge cases
        // like "1+", "3***2", etc. and Swift can't catch NSException.
        guard isValidMathStructure(cleaned) else { return nil }

        return .mathExpression(cleaned)
    }

    /// Validate math expression structure without using NSExpression (which crashes on malformed input).
    /// Checks: no consecutive operators, no leading/trailing operator (except unary -),
    /// no implied multiplication (adjacent operands), valid decimal numbers.
    /// Whitespace is NOT ignored — operands separated by only whitespace (e.g. "1+1 2+3")
    /// are rejected as implied multiplication.
    private static func isValidMathStructure(_ text: String) -> Bool {
        let operators = Set("+-*/^×÷")  // NOTE: '%' excluded — NSExpression treats it as format placeholder
        var prevChar: Character? = nil
        var justSkippedWhitespace = false
        var hasDigit = false
        var decimalCountInCurrentNumber = 0

        for ch in text {
            // Whitespace itself is neutral, but we record that we skipped it
            // so the next meaningful char can detect implied multiplication.
            if ch == " " {
                justSkippedWhitespace = true
                continue
            }

            // ── Decimal point validation ──────────────────────
            if ch == "." {
                decimalCountInCurrentNumber += 1
                if decimalCountInCurrentNumber > 1 { return false }
            } else if operators.contains(ch) || ch == "(" || ch == ")" {
                decimalCountInCurrentNumber = 0
            }

            if ch.isNumber { hasDigit = true }

            // ── Consecutive operators ─────────────────────────
            if operators.contains(ch), let p = prevChar, operators.contains(p) {
                if ch == "-" { /* OK, unary minus after operator: "*-3" */ }
                else { return false }
            }

            // ── Implied multiplication (whitespace-separated operands) ──
            // E.g. "1+1 2+3" → after first "1", space, "2" would be adjacent operands.
            // No-whitespace adjacency: "2(3+4)", "(1+2)(3+4)", "(1+2)4"
            if justSkippedWhitespace {
                // Whitespace was skipped → prevChar and ch are separate tokens.
                // Two operands with no operator between them = implied multiplication.
                if ch.isNumber, let p = prevChar, (p.isNumber || p == ")" || p == ".") { return false }
                if ch == "(", let p = prevChar, (p.isNumber || p == ")") { return false }
                if ch == ".", let p = prevChar, p.isNumber { return false }
            } else {
                // No whitespace between prevChar and ch → adjacent chars.
                // Multi-digit numbers are fine; implied multiplication via direct adjacency is not.
                if ch == "(", let p = prevChar, (p.isNumber || p == ")") { return false }
                if ch.isNumber, let p = prevChar, p == ")" { return false }
            }

            prevChar = ch
            justSkippedWhitespace = false
        }

        guard hasDigit else { return false }
        // Must not start or end with operator (except leading minus for negative numbers)
        if let first = text.first(where: { $0 != " " }), operators.contains(first), first != "-" {
            return false
        }
        if let last = text.last(where: { $0 != " " }), operators.contains(last) {
            return false
        }
        return true
    }

    private static func hasBalancedParentheses(_ text: String) -> Bool {
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

    // MARK: - Chinese Character Detection

    private static func detectChineseCharacter(in text: String) -> DetectedContent? {
        guard text.count == 1, let char = text.first else { return nil }
        guard let scalar = char.unicodeScalars.first else { return nil }
        // CJK Unified Ideographs: U+4E00–U+9FFF
        guard (0x4E00...0x9FFF).contains(scalar.value) else { return nil }
        return .chineseCharacter(char)
    }

    // MARK: - English Phrase Detection

    private static func detectEnglishPhrase(in text: String) -> DetectedContent? {
        let words = text.split(separator: " ")
        guard (2...10).contains(words.count) else { return nil }

        // All words must be ASCII letters only
        let allAsciiWords = words.allSatisfy { word in
            word.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "'") }
        }
        guard allAsciiWords else { return nil }

        // No code-like delimiters
        let hasCodeDelimiters = text.contains("{") || text.contains("}")
            || text.contains(";") || text.contains("(") || text.contains(")")
        guard !hasCodeDelimiters else { return nil }

        // Not too long (reasonably short phrase)
        guard text.count < 200 else { return nil }

        return .englishPhrase(String(text))
    }

    // ── Color extraction helper (used by ToastViewModel) ──────

    /// Extract NSColor from detections if any color is found.
    static func extractColor(from detections: [DetectedContent]) -> NSColor? {
        for detection in detections {
            switch detection {
            case .colorHex(_, let color),
                 .colorRGB(let color),
                 .colorHSL(let color):
                return color
            default: break
            }
        }
        return nil
    }
}
