import Foundation

/// 电话号码检测器 — 使用 NSDataDetector 检测完整电话号码。
struct PhoneNumberDetector: ContentDetectorProtocol {
    let kind = ContentKind.phoneNumber
    let priority = 240

    /// E.164 本体最多 15 位；256 UTF-16 单元仍为格式化号码和长分机
    /// 留出充足余量，同时避免整段长文本进入 NSDataDetector。
    static let maximumCandidateUTF16Length = 256

    func detect(in text: String) -> ContentDetection? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPlausibleCandidate(trimmed) else { return nil }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = detector.firstMatch(in: trimmed, range: range),
              match.resultType == .phoneNumber,
              match.range == range,                    // 全文匹配
              let phone = match.phoneNumber else { return nil }

        return ContentDetection(kind: .phoneNumber, value: phone)
    }

    /// 保留国际格式、Unicode 数字、字母号码和本地化分机文字，仅排除
    /// 无数字、含换行/符号噪声或长度明显不合理的候选。
    static func isPlausibleCandidate(_ text: String) -> Bool {
        guard !text.isEmpty,
              text.utf16.count <= maximumCandidateUTF16Length else {
            return false
        }

        let dialSymbols = CharacterSet(charactersIn: "+＋*#")
        var hasDecimalDigit = false

        for scalar in text.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                hasDecimalDigit = true
            } else if CharacterSet.letters.contains(scalar)
                        || CharacterSet.whitespaces.contains(scalar)
                        || CharacterSet.punctuationCharacters.contains(scalar)
                        || dialSymbols.contains(scalar) {
                continue
            } else {
                return false
            }
        }

        return hasDecimalDigit
    }
}
