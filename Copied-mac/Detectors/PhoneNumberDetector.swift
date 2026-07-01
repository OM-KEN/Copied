import Foundation

/// 电话号码检测器 — 使用 NSDataDetector 检测完整电话号码。
struct PhoneNumberDetector: ContentDetectorProtocol {
    let kind = ContentKind.phoneNumber
    let priority = 240

    func detect(in text: String) -> ContentDetection? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

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
}
