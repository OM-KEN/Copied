import Foundation

/// Python 检测器 — 检测 Python 关键字。
struct PythonDetector: ContentDetectorProtocol {
    let kind = ContentKind.python
    let priority = 50

    func detect(in text: String) -> ContentDetection? {
        let pattern = #"\b(def|import [a-z]+|elif|except|raise|yield|async def)\b"#
        guard text.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        return ContentDetection(kind: .python, value: nil)
    }
}
