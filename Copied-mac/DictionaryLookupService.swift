import Foundation
import CoreServices  // DCSCopyTextDefinition（DictionaryServices 子框架）

/// 线程安全的一次性后台任务协调器。
/// 提交器与查询闭包可注入，便于在不访问真实系统词典的情况下验证调度语义。
final class DictionaryWarmUpCoordinator: @unchecked Sendable {
    typealias Submit = (@escaping @Sendable () -> Void) -> Void
    typealias Lookup = @Sendable (String) -> String?

    private let lock = NSLock()
    private var didSchedule = false
    private let syntheticWord: String
    private let submit: Submit
    private let lookup: Lookup

    init(
        syntheticWord: String,
        submit: @escaping Submit,
        lookup: @escaping Lookup
    ) {
        self.syntheticWord = syntheticWord
        self.submit = submit
        self.lookup = lookup
    }

    func start() {
        lock.lock()
        guard !didSchedule else {
            lock.unlock()
            return
        }
        didSchedule = true
        lock.unlock()

        let syntheticWord = syntheticWord
        let lookup = lookup
        submit {
            _ = lookup(syntheticWord)
        }
    }
}

/// 系统词典查询服务 — 调用 macOS 内置词典（牛津英汉汉英），查询英文单词的中文释义。
/// 无需下载、无需网络，零配置即可使用。
enum DictionaryLookupService {
    static let syntheticWarmUpWord = "example"

    /// DictionaryServices 的首次加载和真实查询共用同一串行队列，
    /// 避免启动预热与用户立即复制英文词时并发进入底层服务。
    private static let lookupQueue = DispatchQueue(
        label: "com.copied.dictionary-lookup",
        qos: .utility
    )
    private static let warmUpCoordinator: DictionaryWarmUpCoordinator = {
        let queue = lookupQueue
        return DictionaryWarmUpCoordinator(
            syntheticWord: syntheticWarmUpWord,
            submit: { operation in
                queue.async(execute: operation)
            },
            lookup: { word in
                lookupOnDictionaryQueue(word)
            }
        )
    }()

    /// 在后台预热 DictionaryServices。进程内重复调用只会提交一次。
    static func scheduleWarmUp() {
        warmUpCoordinator.start()
    }

    /// 对单个英文词查询中文释义。失败返回 nil。
    /// 返回两行格式（\n 分隔），ToastView 对每行独立设 lineLimit(1)，
    /// 第一行不会挤压第二行。
    ///   第二行: 中文释义（用，分隔）
    static func lookup(_ word: String) -> String? {
        lookupQueue.sync {
            lookupOnDictionaryQueue(word)
        }
    }

    /// 仅可在 lookupQueue 上调用；预热直接走这里，避免对同一串行队列 sync。
    private static func lookupOnDictionaryQueue(_ word: String) -> String? {
        let cfStr = word as CFString
        let range = CFRange(location: 0, length: word.utf16.count)

        guard let raw = DCSCopyTextDefinition(nil, cfStr, range) else { return nil }
        let textOnly = raw.takeRetainedValue() as String
        return parseDefinition(word, textOnly)
    }

    // MARK: - Parsing

    /// 从词典原始文本中提取音标和中文释义。
    /// 原始格式: "word | BrE ..., AmE ... | A. pos zhōngwén pīnyīn B. pos zhōngwén pīnyīn …"
    private static func parseDefinition(_ word: String, _ raw: String) -> String? {
        let parts = raw.components(separatedBy: " | ")
        guard parts.count >= 2 else { return nil }

        // ── 1. 提取音标 ──────────────────────────────────
        let pronPart = parts.count >= 3 ? parts[1] : ""
        let bre = extractPronunciation(pronPart, tag: "BrE ")
        let ame = extractPronunciation(pronPart, tag: "AmE ")

        // ── 2. 提取中文释义 ──────────────────────────────
        let defPart = parts.count >= 3
            ? parts[2...].joined(separator: " ")
            : parts[1...].joined(separator: " ")

        // 去掉搭配标记 ‹…›
        let cleaned = defPart
            .replacingOccurrences(of: "‹[^›]+›", with: "", options: .regularExpression)

        // 提取 CJK 词组，只保留短词（≤5 字）— 长词通常是例句翻译
        let allWords = extractCJKGroups(cleaned)
        let coreWords = allWords.filter { $0.count <= 5 }

        // 去重
        var seen: Set<String> = []
        let unique = coreWords.filter { seen.insert($0).inserted }.prefix(8)
        let chinese = unique.joined(separator: "，")

        // ── 3. 组装（对齐拼音格式：第一行原词+音标，第二行中文） ──
        // 每行由 ToastView 独立渲染（lineLimit(1)），不会互相挤压。
        var line1 = word
        if !bre.isEmpty { line1 += "  \(bre)" }

        if chinese.isEmpty {
            return bre.isEmpty && ame.isEmpty ? nil : line1
        }
        return "\(line1)\n\(chinese)"
    }

    /// 从发音部分提取指定标记后的音标（如 "BrE " → "həˈləʊ"）。
    private static func extractPronunciation(_ part: String, tag: String) -> String {
        guard let tagStart = part.range(of: tag) else { return "" }
        let after = String(part[tagStart.upperBound...])
        if let comma = after.firstIndex(of: ",") {
            return String(after[..<comma]).trimmingCharacters(in: .whitespaces)
        }
        return after.trimmingCharacters(in: .whitespaces)
    }

    /// 提取文本中的连续 CJK 字符组（中文词）。
    private static func extractCJKGroups(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for char in text {
            if let scalar = char.unicodeScalars.first, isCJK(scalar.value) {
                current.append(char)
            } else {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func isCJK(_ value: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(value)     // CJK 统一汉字
            || (0x3400...0x4DBF).contains(value)  // CJK 扩展 A
            || (0xF900...0xFAFF).contains(value)  // CJK 兼容汉字
    }

}
