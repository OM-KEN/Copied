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

/// 使用系统已安装并启用的词典查询英文词条；没有有效中文时由现有搜索兜底。
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
        lookup(word, rawLookup: { target in
            let cfStr = target as CFString
            let range = CFRange(location: 0, length: target.utf16.count)

            guard let raw = DCSCopyTextDefinition(nil, cfStr, range) else { return nil }
            return raw.takeRetainedValue() as String
        })
    }

    /// 明确引用最多查询三次；生产调用仍完整运行于 lookupQueue。
    static func lookup(_ word: String, rawLookup: (String) -> String?) -> String? {
        var target = word
        var visited: Set<String> = []
        var originalPronunciation: String?
        for _ in 0..<3 {
            guard visited.insert(target.lowercased()).inserted,
                  let raw = rawLookup(target),
                  let entry = parseEntry(target, raw) else { return nil }
            if originalPronunciation == nil {
                originalPronunciation = entry.pronunciation
            }

            if !entry.meanings.isEmpty {
                return formatDefinition(word, originalPronunciation ?? "", entry.meanings.joined(separator: "，"))
            }
            guard let reference = entry.reference else { return nil }
            target = reference
        }
        return nil
    }

    // MARK: - Parsing

    private struct ParsedEntry {
        let pronunciation: String
        let meanings: [String]
        let reference: String?
    }

    private static func parseEntry(_ word: String, _ raw: String) -> ParsedEntry? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 默认系统词典也可能按拼音选中汉语词条，不能将其当作英文翻译。
        guard let initial = text.first, initial.isASCII && initial.isLetter else { return nil }
        let fields = text.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var pronunciation = ""
        var body: [String] = []

        if fields.count == 1 {
            // plain 格式必须以本次查询的完整英文 headword 开头，不能仅因正文含中文而接收。
            let headword = #"^"# + NSRegularExpression.escapedPattern(for: word) + #"\s+"#
            guard let head = text.range(of: headword, options: [.regularExpression, .caseInsensitive]) else { return nil }
            body.append(String(text[head.upperBound...]))
        } else {
            for field in fields.dropFirst() {
                if field.range(of: #"^(?:BrE|AmE)\s+"#, options: .regularExpression) != nil {
                    // 一些词条将 /; 后的词性与中文放在发音字段内，只移除前面的发音。
                    let separator = field.range(of: #"/?;\s*"#, options: .regularExpression)
                    let phonetics = String(field[..<(separator?.lowerBound ?? field.endIndex)])
                    if pronunciation.isEmpty {
                        let bre = extractPronunciation(phonetics, tag: "BrE")
                        pronunciation = bre.isEmpty ? extractPronunciation(phonetics, tag: "AmE") : bre
                    }
                    if let separator {
                        body.append(String(field[separator.upperBound...]))
                    }
                } else {
                    body.append(field)
                }
            }
        }

        var mainBody = body.joined(separator: "\u{1F}")
        if let phrasal = mainBody.range(of: #"\bPHRASAL VERBS?\b"#, options: .regularExpression) {
            mainBody = String(mainBody[..<phrasal.lowerBound])
        }
        let meanings = chineseMeanings(mainBody)
        return ParsedEntry(
            pronunciation: pronunciation,
            meanings: meanings,
            reference: meanings.isEmpty ? referenceTarget(mainBody) : nil
        )
    }

    private static func chineseMeanings(_ body: String) -> [String] {
        // ▸ 后是例句；圈号或带已知词性标签的 A./B. 段重新开始主释义，排除 U.S. 等缩写。
        let boundary = #"([①-⑳]|(?<!\.)[A-Z]\.\s+(?=(?:[A-Za-z'-]+\s+){0,4}(?:noun|verb|adjective|adverb|conjunction|determiner|pronoun|preposition|exclamation)\b)|(?:before|after) noun\s+(?=[\p{Han}（(\[]))"#
        let sections = body
            .replacingOccurrences(of: boundary, with: "\u{1F}$1", options: .regularExpression)
            .components(separatedBy: "\u{1F}")
        let words = sections.flatMap { section in
            extractChinesePhrases(String(section.prefix { $0 != "▸" }))
        }

        var seen: Set<String> = []
        return Array(words.filter { seen.insert($0).inserted }.prefix(8))
    }

    private static func formatDefinition(_ word: String, _ pronunciation: String, _ chinese: String) -> String {
        var line1 = word
        if !pronunciation.isEmpty { line1 += "  \(pronunciation)" }
        return "\(line1)\n\(chinese)"
    }

    private static func referenceTarget(_ body: String) -> String? {
        // 只接受整段语法标签后的一个引用符号；自由正文、例句、连续引用均不跟随。
        let parts = body.components(separatedBy: CharacterSet(charactersIn: "=→"))
        guard parts.count == 2 else { return nil }
        let labels = parts[0].split { $0.isWhitespace || $0 == "," || $0 == ";" || $0 == "\u{1F}" }
            .map { $0.lowercased() }
        let allowedLabels: Set<String> = [
            "noun", "verb", "adjective", "adverb", "exclamation", "conjunction", "determiner",
            "pronoun", "preposition", "transitive", "intransitive", "reflexive", "singular", "plural",
            "countable", "uncountable", "past", "present", "tense", "participle", "abbreviation",
            "us", "british", "informal", "and", "or"
        ]
        guard labels.allSatisfy({ allowedLabels.contains($0) }),
              !labels.isEmpty || body.contains("→") else { return nil }

        let target = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let englishTarget = #"^[A-Za-z]+(?:[-'][A-Za-z]+)*(?:\s+[A-Za-z]+(?:[-'][A-Za-z]+)*)*(?:[1-9][0-9]*)?$"#
        guard target.range(of: englishTarget, options: .regularExpression) != nil else { return nil }
        let normalized = target
            .replacingOccurrences(of: #"[1-9][0-9]*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // 不能把否定短语的引用降为后面肯定动词的泛义；negative 标签也不在允许列表中。
        guard !normalized.lowercased().split(separator: " ").contains("not") else { return nil }
        return normalized
    }

    /// 从发音部分提取指定地区的首个音标。
    private static func extractPronunciation(_ part: String, tag: String) -> String {
        guard let tagStart = part.range(of: #"\b"# + tag + #"\s+"#, options: .regularExpression) else { return "" }
        return String(part[tagStart.upperBound...].prefix { $0 != "," && $0 != "/" && $0 != ";" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 中文短语保留标点及紧邻汉字的字母数字；独立英文标签和拼音不参与展示。
    private static func extractChinesePhrases(_ text: String) -> [String] {
        let cleaned = text
            .replacingOccurrences(of: #"[‹«][^›»]*[›»]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[(（]\s*英\s+[A-Za-z][^()（）]*的缩写\s*[)）][。.]?"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[(（][^()（）\p{Han}]*[)）]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[[^\[\]\p{Han}]*\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let punctuation = CharacterSet(charactersIn: "，、；：。！？（）()[]【】《》〈〉「」『』“”‘’…·—／/")
        let characters = Array(cleaned)
        var words: [String] = []
        var current = ""
        func appendCurrent() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.unicodeScalars.contains(where: { isCJK($0.value) }) {
                words.append(value)
            }
            current = ""
        }
        var index = 0
        while index < characters.count {
            let char = characters[index]
            if let scalar = char.unicodeScalars.first,
               isCJK(scalar.value) || punctuation.contains(scalar) || char.isWhitespace {
                current.append(char)
            } else if char.isASCII && (char.isLetter || char.isNumber) {
                var end = index + 1
                while end < characters.count, characters[end].isASCII,
                      characters[end].isLetter || characters[end].isNumber {
                    end += 1
                }
                let touchesChinese = (index > 0 && characters[index - 1].unicodeScalars.contains { isCJK($0.value) })
                    || (end < characters.count && characters[end].unicodeScalars.contains { isCJK($0.value) })
                if touchesChinese {
                    current.append(contentsOf: characters[index..<end])
                } else {
                    appendCurrent()
                }
                index = end
                continue
            } else {
                appendCurrent()
            }
            index += 1
        }
        appendCurrent()
        return words
    }

    private static func isCJK(_ value: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(value)     // CJK 统一汉字
            || (0x3400...0x4DBF).contains(value)  // CJK 扩展 A
            || (0xF900...0xFAFF).contains(value)  // CJK 兼容汉字
    }

}
