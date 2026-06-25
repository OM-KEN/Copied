import Foundation

/// 中文字符检测器 — 检测单个 CJK 字符。
struct ChineseCharDetector: ContentDetectorProtocol {
    let kind = ContentKind.chineseChar
    let priority = 100

    func detect(in text: String) -> ContentDetection? {
        guard text.count == 1, let char = text.first else { return nil }
        guard let scalar = char.unicodeScalars.first else { return nil }
        // CJK Unified Ideographs: U+4E00–U+9FFF
        guard (0x4E00...0x9FFF).contains(scalar.value) else { return nil }
        return ContentDetection(kind: .chineseChar, value: String(char))
    }
}
