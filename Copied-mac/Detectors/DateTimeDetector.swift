import Foundation

/// 日期/时间检测器 — 使用 NSDataDetector + 预处理覆盖中文日期格式。
struct DateTimeDetector: ContentDetectorProtocol {
    let kind = ContentKind.dateTime
    let priority = 190

    func detect(in text: String) -> ContentDetection? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

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
}
