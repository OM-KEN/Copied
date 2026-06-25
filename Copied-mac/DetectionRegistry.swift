import Foundation

// MARK: - Detector Protocol

/// 可注册到 DetectionRegistry 的检测器。
protocol ContentDetectorProtocol {
    /// 该检测器对应的内容类型。
    var kind: ContentKind { get }

    /// 检测优先级（整数值，越大越先检测）。
    var priority: Int { get }

    /// 对文本执行检测，返回 ContentDetection 或 nil。
    func detect(in text: String) -> ContentDetection?
}

// MARK: - Detection Registry

/// 全局单例，管理所有检测器 + 性能熔断。
final class DetectionRegistry {
    static let shared = DetectionRegistry()

    // ── 性能常量 ────────────────────────────────────────────

    /// 文本超过此值（字节数）→ 仅执行内置语言启发式检测。
    static let textLengthCutoff = 100_000  // 100KB

    /// 单检测器最大执行时间（秒）。
    /// 50ms — 足够宽松以容纳 NSDataDetector 首次惰性初始化（~20ms），
    /// 同时仍能拦截正则灾难性回溯（通常 >100ms）。
    static let detectorTimeout: TimeInterval = 0.050  // 50ms

    /// 熔断冷却时间（秒），之后自动重试。
    static let throttleCooldown: TimeInterval = 30

    /// 连续熔断达到此次数 → 自动禁用该类型。
    static let maxConsecutiveThrottles = 3

    // ── 状态 ────────────────────────────────────────────────

    private var detectors: [any ContentDetectorProtocol] = []

    /// 熔断冷却截止时间。
    private var throttledUntil: [String: Date] = [:]

    /// 连续熔断计数。
    private var throttleCounts: [String: Int] = [:]

    /// 被自动禁用的类型 ID 集合。
    private(set) var disabledKinds: Set<String> = []

    /// 用户手动禁用的类型 ID 集合（持久化）。
    var userDisabledKinds: Set<String> {
        get {
            let arr = UserDefaults.standard.stringArray(forKey: "disabledContentKinds") ?? []
            return Set(arr)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: "disabledContentKinds")
        }
    }

    /// 用户自定义优先级（持久化）。
    var userPriorities: [String: Int] {
        get {
            UserDefaults.standard.dictionary(forKey: "contentKindPriorities") as? [String: Int] ?? [:]
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "contentKindPriorities")
        }
    }

    // MARK: - Kinds & Detectors

    /// 所有注册过的 ContentKind（包括已禁用的），去重。
    /// 用于 Settings UI 展示完整列表。
    var allRegisteredKinds: [ContentKind] {
        var seen: Set<String> = []
        var kinds: [ContentKind] = []
        for detector in detectors {
            guard !seen.contains(detector.kind.id) else { continue }
            seen.insert(detector.kind.id)
            kinds.append(detector.kind)
        }
        return kinds
    }

    /// 所有活跃的检测器，按有效优先级降序排列。
    /// 被禁用/熔断冷却中的检测器排在末尾（仍会被遍历，但 detectAll 会跳过）。
    var activeDetectors: [any ContentDetectorProtocol] {
        detectors
            .filter { !userDisabledKinds.contains($0.kind.id) && !disabledKinds.contains($0.kind.id) }
            .sorted { lhs, rhs in
                let lhsThrottled = throttledUntil[lhs.kind.id].map { $0 > Date() } ?? false
                let rhsThrottled = throttledUntil[rhs.kind.id].map { $0 > Date() } ?? false
                if lhsThrottled != rhsThrottled { return !lhsThrottled }  // 未熔断的优先
                return effectivePriority(for: lhs) > effectivePriority(for: rhs)
            }
    }

    // MARK: - Registration

    func register(_ detector: any ContentDetectorProtocol) {
        detectors.append(detector)
    }

    func unregister(kind: ContentKind) {
        detectors.removeAll { $0.kind.id == kind.id }
    }

    /// 卸载指定插件的所有检测器。
    func unregisterPlugin(identifier: String) {
        detectors.removeAll { detector in
            if case .plugin(let id) = detector.kind.source, id == identifier {
                return true
            }
            return false
        }
    }

    /// 启用/禁用一个类型。
    func setEnabled(_ enabled: Bool, kindID: String) {
        if enabled {
            userDisabledKinds.remove(kindID)
            disabledKinds.remove(kindID)
            throttleCounts[kindID] = 0
            throttledUntil.removeValue(forKey: kindID)
        } else {
            userDisabledKinds.insert(kindID)
        }
    }

    func isEnabled(kindID: String) -> Bool {
        !userDisabledKinds.contains(kindID) && !disabledKinds.contains(kindID)
    }

    // MARK: - Detection

    /// 对文本执行全部检测，返回优先级排序的结果。
    /// - 超大文本（>100KB）：仅运行内置语言检测器。
    /// - 熔断保护：超时检测器被跳过，冷却后自动重试。
    func detectAll(in text: String) -> [ContentDetection] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let isOversize = text.utf8.count > Self.textLengthCutoff
        var results: [ContentDetection] = []

        for detector in activeDetectors {
            // 熔断 1: 超大文本 → 仅内置语言检测器
            if isOversize {
                guard detector.kind.isBuiltIn,
                      detector.kind.category == .language else { continue }
            }

            // 熔断 2: 冷却期未过
            if let until = throttledUntil[detector.kind.id], Date() < until {
                continue
            }

            let start = CFAbsoluteTimeGetCurrent()
            let detection = detector.detect(in: trimmed)
            let elapsed = CFAbsoluteTimeGetCurrent() - start

            if elapsed > Self.detectorTimeout {
                // 超时 → 熔断
                throttledUntil[detector.kind.id] = Date().addingTimeInterval(Self.throttleCooldown)
                throttleCounts[detector.kind.id, default: 0] += 1
                NSLog("Copied: throttled '\(detector.kind.id)' (\(String(format: "%.1f", elapsed * 1000))ms)")

                if throttleCounts[detector.kind.id, default: 0] >= Self.maxConsecutiveThrottles {
                    disabledKinds.insert(detector.kind.id)
                    NSLog("Copied: auto-disabled '\(detector.kind.id)' after \(Self.maxConsecutiveThrottles) throttles")
                }
                continue
            }

            // 成功 → 重置连续熔断计数
            throttleCounts[detector.kind.id] = 0

            if let detection = detection {
                results.append(detection)
            }
        }

        return results
    }

    // MARK: - Built-in Registration

    /// 注册所有内置检测器（app 启动时调用一次）。
    func registerBuiltInDetectors() {
        // 实体检测器
        register(ColorDetector())
        register(URLDetector())
        register(FilePathDetector())
        register(MathExpressionDetector())
        register(ChineseCharDetector())
        register(EnglishPhraseDetector())

        // 语言检测器
        register(HTMLDetector())
        register(SwiftDetector())
        register(PythonDetector())
        register(JavaScriptDetector())
        register(CSSDetector())
        register(CodeDetector())
    }

    // MARK: - Helpers

    /// 获取检测器的有效优先级（用户覆盖 > 默认）。
    private func effectivePriority(for detector: any ContentDetectorProtocol) -> Int {
        userPriorities[detector.kind.id] ?? detector.priority
    }
}
