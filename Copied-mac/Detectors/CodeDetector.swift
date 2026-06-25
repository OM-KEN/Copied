import Foundation

/// 通用代码检测器 — 检测代码结构特征但无具体语言匹配时的回退。
struct CodeDetector: ContentDetectorProtocol {
    let kind = ContentKind.code
    let priority = 20

    func detect(in text: String) -> ContentDetection? {
        let hasBraces = text.contains("{") && text.contains("}")
        let hasSemicolons = text.contains(";")
        let hasGenericKW = text.range(of: #"\b(func|var|let|class|struct|enum|import|def|function|const|return|if|for|while)\b"#, options: .regularExpression) != nil

        if hasBraces || hasGenericKW || (hasSemicolons && text.contains("\n")) {
            return ContentDetection(kind: .code, value: nil)
        }
        return nil
    }
}
