import Foundation

/// URL 检测器 — 使用 NSDataDetector 检测完整 URL。
struct URLDetector: ContentDetectorProtocol {
    let kind = ContentKind.url
    let priority = 250

    func detect(in text: String) -> ContentDetection? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, range: range),
              let url = match.url,
              match.range == range else { return nil }  // entire text must be a URL
        return ContentDetection(kind: .url, value: url.absoluteString)
    }
}
