import Foundation

/// 数学表达式检测器 — 语法验证与实际计算共用 MathExpressionEvaluator。
struct MathExpressionDetector: ContentDetectorProtocol {
    let kind = ContentKind.mathExpr
    let priority = 180

    func detect(in text: String) -> ContentDetection? {
        guard let expression = MathExpressionEvaluator.validatedExpression(from: text) else {
            return nil
        }
        return ContentDetection(kind: .mathExpr, value: expression)
    }
}
