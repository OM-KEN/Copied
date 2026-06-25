import Foundation

/// JavaScript/TypeScript 检测器。
struct JavaScriptDetector: ContentDetectorProtocol {
    let kind = ContentKind.javascript
    let priority = 40

    func detect(in text: String) -> ContentDetection? {
        let hasJSKW = text.range(of: #"\b(function|const |let |var |=>|export |require|console\.|document\.)\b"#, options: .regularExpression) != nil
        if hasJSKW { return ContentDetection(kind: .javascript, value: nil) }

        let hasBraces = text.contains("{") && text.contains("}")
        let hasSemicolons = text.contains(";")
        if hasBraces && hasSemicolons,
           text.range(of: #"\b(const|let|var|function|class|import|export|new )\b"#, options: .regularExpression) != nil {
            return ContentDetection(kind: .javascript, value: nil)
        }
        return nil
    }
}
