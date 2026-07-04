import Foundation

/// 英文单词检测器 — 检测单个 ASCII 单词（对齐 ChineseCharDetector 单个汉字的体验）。
/// 词典预查在 ActionResolver 中进行（避免主线程检测器超时熔断）。
struct EnglishPhraseDetector: ContentDetectorProtocol {
    let kind = ContentKind.englishPhrase
    let priority = 80

    func detect(in text: String) -> ContentDetection? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 必须为单个 ASCII 单词
        let words = trimmed.split(separator: " ")
        guard words.count == 1 else { return nil }

        let word = words[0]
        guard word.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "'") }) else { return nil }
        guard trimmed.count >= 2, trimmed.count < 50 else { return nil }

        return ContentDetection(kind: .englishPhrase, value: String(trimmed))
    }
}
