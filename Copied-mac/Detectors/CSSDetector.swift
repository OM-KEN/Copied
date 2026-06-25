import Foundation

/// CSS 检测器 — 检测 CSS 语法特征（大括号 + 冒号 + 分号 + CSS 单位/属性）。
struct CSSDetector: ContentDetectorProtocol {
    let kind = ContentKind.css
    let priority = 30

    func detect(in text: String) -> ContentDetection? {
        let hasBraces = text.contains("{") && text.contains("}")
        let hasColons = text.contains(":")
        let hasSemicolons = text.contains(";")
        guard hasBraces, hasColons, hasSemicolons else { return nil }

        let hasCSSUnits = text.range(of: #"\d+(px|em|rem|%|vh|vw|pt|cm)"#, options: .regularExpression) != nil
        let hasCSSColors = text.range(of: #"(#[0-9a-fA-F]{3,8}|rgb\(|rgba\(|hsl\()"#, options: .regularExpression) != nil
        let hasCSSProps = text.range(of: #"\b(margin|padding|display|flex|grid|color|font|background|border|width|height|position|align|justify|gap|opacity|transform|transition|animation)\s*:"#, options: .regularExpression) != nil

        if hasCSSUnits || hasCSSColors || hasCSSProps {
            return ContentDetection(kind: .css, value: nil)
        }
        return nil
    }
}
