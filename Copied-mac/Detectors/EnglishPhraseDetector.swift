import Foundation

/// 英文短语检测器 — 检测 2-10 个 ASCII 单词的短语。
struct EnglishPhraseDetector: ContentDetectorProtocol {
    let kind = ContentKind.englishPhrase
    let priority = 80

    func detect(in text: String) -> ContentDetection? {
        // 翻译开关关闭时跳过检测
        guard UserDefaults.standard.bool(forKey: "translationEnabled") else { return nil }

        let words = text.split(separator: " ")
        guard (2...10).contains(words.count) else { return nil }

        // All words must be ASCII letters
        let allAsciiWords = words.allSatisfy { word in
            word.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "'") }
        }
        guard allAsciiWords else { return nil }

        // No code-like delimiters
        let hasCodeDelimiters = text.contains("{") || text.contains("}")
            || text.contains(";") || text.contains("(") || text.contains(")")
        guard !hasCodeDelimiters else { return nil }

        guard text.count < 200 else { return nil }

        return ContentDetection(kind: .englishPhrase, value: String(text))
    }
}
