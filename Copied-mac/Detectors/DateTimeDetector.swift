import Foundation

/// 日期/时间检测器 — 使用 NSDataDetector + 预处理覆盖中文日期格式。
struct DateTimeDetector: ContentDetectorProtocol {
    let kind = ContentKind.dateTime
    let priority = 190

    func detect(in text: String) -> ContentDetection? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // ── Phase 0: Reject ambiguous formats ──
        // Two-segment slash (e.g. "10/3", "31/11") is inherently
        // ambiguous between M/D and D/M, and also valid math division.
        // Chinese users use M月D日 or M.D for dates, not M/D.
        guard !hasAmbiguousFormat(trimmed) else { return nil }

        // 待检测文本列表：原始文本 + 预处理变体
        var candidates = [trimmed]

        // ── 预处理层：将 NSDataDetector 不支持的格式转换为支持的格式 ──

        // 规则1: "6.23" → "6月23日"（月.日 格式）
        if let m = try? NSRegularExpression(pattern: #"^(\d{1,2})\.(\d{1,2})$"#)
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
        if let m = try? NSRegularExpression(pattern: #"^(\d{1,2})\.(\d{1,2})\s+(.*)$"#)
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
        if let m = try? NSRegularExpression(pattern: #"^(\d{1,2})点$"#)
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
            if (try? NSRegularExpression(pattern: #"(\d{1,2})点\b"#)
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
            if let m = try? NSRegularExpression(pattern: #"^(\d{1,2}:\d{2}):00$"#)
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

            // ── 子类型判断 ──
            let cal = Calendar.current
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let hasDate = comps.year != nil && comps.month != nil && comps.day != nil
            let hasTime = comps.hour != nil || comps.minute != nil

            // ── Calendar validation: reject impossible dates ──
            // NSDataDetector silently overflows invalid dates:
            //   "31/11" → Dec 1,  "6月31日" → Jul 1
            // Trust the calendar, not NSDataDetector's normalization.
            if hasDate, let (origM, origD) = extractMonthDay(from: trimmed) {
                guard isValidCalendarDate(month: origM, day: origD) else { continue }
            }

            let subtype: String
            if hasDate {
                subtype = "date"
            } else if hasTime {
                subtype = "time"
            } else {
                subtype = "unknown"
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

    /// Extract (month, day) from the original text for calendar validation.
    /// Returns nil for time-only formats (no validation needed).
    private func extractMonthDay(from text: String) -> (month: Int, day: Int)? {
        // Chinese: "6月23日" or "6月23日 20:00"
        if let m = try? NSRegularExpression(pattern: #"(\d{1,2})月(\d{1,2})日"#)
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           m.numberOfRanges == 3,
           let month = Int(text[Range(m.range(at: 1), in: text)!]),
           let day = Int(text[Range(m.range(at: 2), in: text)!]) {
            return (month, day)
        }
        // Dot: "6.23" or "6.23 20:00"
        if let m = try? NSRegularExpression(pattern: #"^(\d{1,2})\.(\d{1,2})\b"#)
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           m.numberOfRanges == 3,
           let month = Int(text[Range(m.range(at: 1), in: text)!]),
           let day = Int(text[Range(m.range(at: 2), in: text)!]) {
            return (month, day)
        }
        // ISO YYYY-MM-DD or YYYY/M/D (3+ segments, year first)
        if let m = try? NSRegularExpression(pattern: #"^(\d{4})[/-](\d{1,2})[/-](\d{1,2})"#)
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           m.numberOfRanges == 4,
           let month = Int(text[Range(m.range(at: 2), in: text)!]),
           let day = Int(text[Range(m.range(at: 3), in: text)!]) {
            return (month, day)
        }
        // Chinese with year: "2024年10月3日"
        if let m = try? NSRegularExpression(pattern: #"(\d{4})年(\d{1,2})月(\d{1,2})日"#)
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           m.numberOfRanges == 4,
           let month = Int(text[Range(m.range(at: 2), in: text)!]),
           let day = Int(text[Range(m.range(at: 3), in: text)!]) {
            return (month, day)
        }
        return nil  // time-only or unrecognized format — skip validation
    }

    /// Verify (month, day) is a valid calendar date.
    /// Feb 29 is always allowed (NSDataDetector assigns a leap year when needed).
    private func isValidCalendarDate(month: Int, day: Int) -> Bool {
        guard (1...12).contains(month) else { return false }
        let daysInMonth = [0, 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day >= 1 && day <= daysInMonth[month]
    }
}
