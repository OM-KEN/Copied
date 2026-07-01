import Foundation

/// 邮箱地址检测器 — 使用正则检测完整邮箱地址。
/// NSDataDetector 没有内置邮箱类型，需手动正则匹配。
struct EmailDetector: ContentDetectorProtocol {
    let kind = ContentKind.email
    let priority = 260

    func detect(in text: String) -> ContentDetection? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 轻量正则：local-part@domain
        // local-part：字母数字 + 常见符号 (. _ % + -)
        // domain：字母数字 + 点 + 连字符，TLD ≥ 2 字符
        let pattern = #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }

        // 额外检查：恰好一个 @
        guard trimmed.filter({ $0 == "@" }).count == 1 else { return nil }

        // 长度限制（RFC 5321 最大 254 字符）
        guard trimmed.count <= 254 else { return nil }

        return ContentDetection(kind: .email, value: trimmed)
    }
}
