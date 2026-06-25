import Foundation

/// Swift 检测器 — 检测 Swift 关键字和导入语句。
struct SwiftDetector: ContentDetectorProtocol {
    let kind = ContentKind.swift
    let priority = 60

    func detect(in text: String) -> ContentDetection? {
        let pattern = #"\b(func|var|let|struct|class|enum|protocol|extension|guard|throws|async|await|import (SwiftUI|Foundation|UIKit|AppKit))\b"#
        guard text.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        return ContentDetection(kind: .swift, value: nil)
    }
}
