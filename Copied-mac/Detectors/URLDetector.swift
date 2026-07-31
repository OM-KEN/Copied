import Foundation

/// URL 检测器 — 使用 NSDataDetector 检测完整 URL。
struct URLDetector: ContentDetectorProtocol {
    let kind = ContentKind.url
    let priority = 250

    /// NSDataDetector 本身不会完整匹配极长的无 scheme URL；2048 仍覆盖
    /// 常见域名、路径与查询，同时阻止点号正文进入昂贵检测。
    static let maximumSchemelessCandidateUTF16Length = 2_048

    func detect(in text: String) -> ContentDetection? {
        guard Self.isPlausibleCandidate(text) else { return nil }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, range: range),
              let url = match.url,
              match.range == range else { return nil }  // entire text must be a URL
        return ContentDetection(kind: .url, value: url.absoluteString)
    }

    /// 全文 URL 不可能包含原始空白或控制字符，并且至少要有 scheme
    /// 或点分隔结构。显式 scheme 不限长；无 scheme 候选保守限制为 2048。
    static func isPlausibleCandidate(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        let forbiddenCharacters = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
        guard text.unicodeScalars.allSatisfy({
            !forbiddenCharacters.contains($0)
        }) else { return false }

        if let colonIndex = text.firstIndex(of: ":"),
           colonIndex != text.startIndex,
           text.index(after: colonIndex) != text.endIndex,
           isValidScheme(text[..<colonIndex]) {
            return true
        }

        guard text.utf16.count <= maximumSchemelessCandidateUTF16Length else {
            return false
        }

        for index in text.indices where text[index] == "." {
            guard index != text.startIndex else { continue }
            let nextIndex = text.index(after: index)
            guard nextIndex != text.endIndex else { continue }

            let previousIndex = text.index(before: index)
            if text[previousIndex] != ".", text[nextIndex] != "." {
                return true
            }
        }
        return false
    }

    private static func isValidScheme(_ scheme: Substring) -> Bool {
        guard let first = scheme.utf8.first, isASCIILetter(first) else {
            return false
        }
        return scheme.utf8.dropFirst().allSatisfy {
            isASCIILetter($0)
                || (48...57).contains($0)
                || $0 == 43  // +
                || $0 == 45  // -
                || $0 == 46  // .
        }
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }
}
