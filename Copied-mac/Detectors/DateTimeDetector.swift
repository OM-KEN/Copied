import Foundation

/// 日期/时间检测器 — 使用 NSDataDetector + 预处理覆盖中文日期格式。
struct DateTimeDetector: ContentDetectorProtocol {
    let kind = ContentKind.dateTime
    let priority = 190

    private static let dotDateRegex = try! NSRegularExpression(pattern: #"^(\d{1,2})\.(\d{1,2})$"#)
    private static let dotDateTimeRegex = try! NSRegularExpression(pattern: #"^(\d{1,2})\.(\d{1,2})\s+(.*)$"#)
    private static let chineseHourRegex = try! NSRegularExpression(pattern: #"^(\d{1,2})点$"#)
    private static let chineseHourInDateRegex = try! NSRegularExpression(pattern: #"(\d{1,2})点\b"#)
    private static let zeroSecondsRegex = try! NSRegularExpression(pattern: #"^(\d{1,2}:\d{2}):00$"#)
    private static let chineseMonthDayRegex = try! NSRegularExpression(pattern: #"(\d{1,2})月(\d{1,2})日"#)
    private static let dotMonthDayRegex = try! NSRegularExpression(pattern: #"^(\d{1,2})\.(\d{1,2})\b"#)
    private static let isoMonthDayRegex = try! NSRegularExpression(pattern: #"^(\d{4})[/-](\d{1,2})[/-](\d{1,2})"#)
    private static let chineseYearMonthDayRegex = try! NSRegularExpression(pattern: #"(\d{4})年(\d{1,2})月(\d{1,2})日"#)

    /// 数字日期/时间及其时区描述的保守总上限。
    static let maximumCandidateUTF16Length = 256

    /// 保留 "today"、"next Friday"、"明天" 等短自然语言日期；
    /// 更长的无数字正文不可能是实用的单个日期候选。
    static let maximumTextualCandidateUTF16Length = 64

    func detect(in text: String) -> ContentDetection? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPlausibleCandidate(trimmed) else { return nil }

        // ── Phase 0: Reject ambiguous formats ──
        // Two-segment slash (e.g. "10/3", "31/11") is inherently
        // ambiguous between M/D and D/M, and also valid math division.
        // Chinese users use M月D日 or M.D for dates, not M/D.
        guard !hasAmbiguousFormat(trimmed) else { return nil }

        // 待检测文本列表：原始文本 + 预处理变体
        var candidates = [trimmed]

        // ── 预处理层：将 NSDataDetector 不支持的格式转换为支持的格式 ──

        // 规则1: "6.23" → "6月23日"（月.日 格式）
        if let m = Self.dotDateRegex
            .firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           m.numberOfRanges == 3,
           let monthRange = Range(m.range(at: 1), in: trimmed),
           let dayRange = Range(m.range(at: 2), in: trimmed),
           let month = Int(trimmed[monthRange]),
           let day = Int(trimmed[dayRange]),
           (1...12).contains(month), (1...31).contains(day) {
            candidates.append("\(month)月\(day)日")
        }

        // 规则4: "6.23 20:00" / "6.23 20点" → "6月23日 20:00" / "6月23日 20点"
        // （规则2 会在后续处理 "20点"）
        if let m = Self.dotDateTimeRegex
            .firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           m.numberOfRanges == 4,
           let monthRange = Range(m.range(at: 1), in: trimmed),
           let dayRange = Range(m.range(at: 2), in: trimmed),
           let restRange = Range(m.range(at: 3), in: trimmed),
           let month = Int(trimmed[monthRange]),
           let day = Int(trimmed[dayRange]),
           (1...12).contains(month), (1...31).contains(day) {
            let rest = String(trimmed[restRange])
            candidates.append("\(month)月\(day)日 \(rest)")
        }

        // 规则2: "20点" → "20:00"（单独的"点"不带"分"）
        if let m = Self.chineseHourRegex
            .firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           m.numberOfRanges == 2 {
            candidates.append(trimmed.replacingOccurrences(
                of: #"^(\d{1,2})点$"#,
                with: "$1:00",
                options: .regularExpression
            ))
        }

        // 对候选列表中的每个字符串，也尝试应用规则2
        // 处理 "6月23日 20点" → "6月23日 20:00"
        let extraCandidates = candidates.compactMap { candidate -> String? in
            if (Self.chineseHourInDateRegex
                .firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate))) != nil {
                return candidate.replacingOccurrences(
                    of: #"(\d{1,2})点\b"#,
                    with: "$1:00",
                    options: .regularExpression
                )
            }
            return nil
        }
        candidates.append(contentsOf: extraCandidates)

        // 规则3: "15:30:00" → "15:30"（秒为 :00 时 NSDataDetector 只部分匹配）
        let stripSecondsCandidates = candidates.compactMap { candidate -> String? in
            if let m = Self.zeroSecondsRegex
                .firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
               m.numberOfRanges == 2 {
                return candidate.replacingOccurrences(
                    of: #":00$"#,
                    with: "",
                    options: .regularExpression
                )
            }
            return nil
        }
        candidates.append(contentsOf: stripSecondsCandidates)

        // 中文年月日不应依赖 App 当前界面语言。NSDataDetector 在英文 Locale 下
        // 无法解析“2026年7月15日”，因此追加等价的 ISO 候选；原文仍排在首位，
        // 中文环境的既有解析行为保持不变。
        let normalizedChineseCandidates = candidates.compactMap {
            normalizedChineseDateCandidate(from: $0)
        }
        for candidate in normalizedChineseCandidates where !candidates.contains(candidate) {
            candidates.append(candidate)
        }

        // ── NSDataDetector 全文本匹配 ──
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }

        for candidate in candidates {
            let range = NSRange(candidate.startIndex..., in: candidate)
            guard let match = detector.firstMatch(in: candidate, range: range),
                  match.resultType == .date,
                  match.range == range,
                  let date = match.date else { continue }

            // NSDataDetector always returns a complete Date, even for time-only
            // input, so DateComponents cannot reveal which fields the user typed.
            // Classify the original text instead.
            let subtype = dateSubtype(for: trimmed)
            let hasDate = subtype != "time"

            // ── Calendar validation: reject impossible dates ──
            // NSDataDetector silently overflows invalid dates:
            //   "31/11" → Dec 1,  "6月31日" → Jul 1
            // Trust the calendar, not NSDataDetector's normalization.
            if hasDate, let fields = extractCalendarDate(from: trimmed) {
                guard isValidCalendarDate(year: fields.year, month: fields.month, day: fields.day) else { continue }
            }

            // value 存 timeIntervalSinceReferenceDate（纯数字，零歧义）
            let timestamp = String(date.timeIntervalSinceReferenceDate)

            return ContentDetection(
                kind: .dateTime,
                value: timestamp,
                metadata: ["subtype": subtype]
            )
        }

        return nil
    }

    // MARK: - Format Validation

    static func isPlausibleCandidate(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        let length = text.utf16.count
        guard length <= maximumCandidateUTF16Length else { return false }

        let hasDecimalDigit = text.unicodeScalars.contains {
            CharacterSet.decimalDigits.contains($0)
        }
        return hasDecimalDigit || length <= maximumTextualCandidateUTF16Length
    }

    /// Distinguish the fields present in the user's text. A parsed Date cannot be
    /// used for this because NSDataDetector fills every missing calendar field.
    private func dateSubtype(for text: String) -> String {
        if matchesEntireTimeExpression(text) {
            return "time"
        }
        if containsExplicitTime(in: text) {
            return "dateTime"
        }
        return "date"
    }

    private func matchesEntireTimeExpression(_ text: String) -> Bool {
        let pattern = #"(?ix)^\s*(?:(?:上午|下午|中午|晚上|凌晨)?\s*(?:(?:[01]?\d|2[0-3]):[0-5]\d(?::[0-5]\d)?|(?:[01]?\d|2[0-3])点(?:[0-5]?\d分?)?)|(?:0?\d|1[0-2])(?::[0-5]\d)?\s*(?:a\.?m\.?|p\.?m\.?)|noon|midnight)\s*$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private func containsExplicitTime(in text: String) -> Bool {
        let pattern = #"(?ix)(?:(?:上午|下午|中午|晚上|凌晨)?\s*(?:(?:[01]?\d|2[0-3]):[0-5]\d(?::[0-5]\d)?|(?:[01]?\d|2[0-3])点(?:[0-5]?\d分?)?)|(?:0?\d|1[0-2])(?::[0-5]\d)?\s*(?:a\.?m\.?|p\.?m\.?)|noon|midnight)"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// 将“2026年7月15日”或“7月15日”转换为与 Locale 无关的 ISO 候选。
    /// 日期后的时间部分原样保留，已有预处理会先把“20点”转换为“20:00”。
    private func normalizedChineseDateCandidate(from text: String) -> String? {
        let pattern = #"^(?:(\d{4})年)?(\d{1,2})月(\d{1,2})日(.*)$"#
        guard let match = try? NSRegularExpression(pattern: pattern)
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges == 5,
              let monthRange = Range(match.range(at: 2), in: text),
              let dayRange = Range(match.range(at: 3), in: text),
              let month = Int(text[monthRange]),
              let day = Int(text[dayRange]),
              (1...12).contains(month),
              (1...31).contains(day) else { return nil }

        let year: Int
        if let yearRange = Range(match.range(at: 1), in: text),
           let explicitYear = Int(text[yearRange]) {
            year = explicitYear
        } else {
            year = Calendar.autoupdatingCurrent.component(.year, from: Date())
        }

        let date = String(format: "%04d-%02d-%02d", year, month, day)
        guard let suffixRange = Range(match.range(at: 4), in: text) else { return date }
        let suffix = text[suffixRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? date : "\(date) \(suffix)"
    }

    /// Two-segment slash patterns (e.g. "10/3", "31/11") are rejected:
    /// inherently ambiguous between M/D and D/M, and conflict with math division.
    private func hasAmbiguousFormat(_ text: String) -> Bool {
        let twoSegmentSlash = #"^\s*\d{1,2}\s*/\s*\d{1,2}\s*$"#
        return text.range(of: twoSegmentSlash, options: .regularExpression) != nil
    }

    /// Read the explicit year before the shorter month/day patterns.
    private func extractCalendarDate(from text: String) -> (year: Int?, month: Int, day: Int)? {
        for (regex, hasYear) in [
            (Self.chineseYearMonthDayRegex, true),
            (Self.isoMonthDayRegex, true),
            (Self.chineseMonthDayRegex, false),
            (Self.dotMonthDayRegex, false),
        ] {
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            let source = text as NSString
            let monthGroup = hasYear ? 2 : 1
            guard let month = Int(source.substring(with: match.range(at: monthGroup))),
                  let day = Int(source.substring(with: match.range(at: monthGroup + 1))) else { continue }
            let year = hasYear ? Int(source.substring(with: match.range(at: 1))) : nil
            return (year, month, day)
        }
        return nil
    }

    private func isValidCalendarDate(year: Int?, month: Int, day: Int) -> Bool {
        guard (1...12).contains(month) else { return false }
        let februaryDays: Int
        if let year {
            guard year > 0 else { return false }
            februaryDays = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        } else {
            // Preserve the existing rule for inputs without a year.
            februaryDays = 29
        }
        let days = [0, 31, februaryDays, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day >= 1 && day <= days[month]
    }
}
