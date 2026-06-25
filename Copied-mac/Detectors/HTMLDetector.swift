import Foundation

/// HTML 检测器 — 检测 HTML/XML 标签。
struct HTMLDetector: ContentDetectorProtocol {
    let kind = ContentKind.html
    let priority = 70

    func detect(in text: String) -> ContentDetection? {
        guard text.range(of: #"</?[a-zA-Z]+\b"#, options: .regularExpression) != nil else {
            return nil
        }
        return ContentDetection(kind: .html, value: nil)
    }
}
