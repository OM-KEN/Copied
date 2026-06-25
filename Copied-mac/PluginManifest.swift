import Foundation

// MARK: - Plugin Manifest (manifest.json)

/// 插件清单 — 描述一个 `.copiedplugin` 的元数据。
struct PluginManifest: Codable {

    let name: String                // 显示名称
    let identifier: String          // 反向域名，全局唯一 → ContentKind.id
    let version: String             // 语义化版本
    let category: String            // "language" 或 "entity"
    let icon: String                // SF Symbol 名称
    let label: String               // 显示标签
    let priority: Int               // 检测优先级

    let author: String?             // 可选
    let description: String?        // 可选
    let homepage: String?           // 可选

    /// 从原始 category 字符串解析。
    var resolvedCategory: ContentKind.Category {
        category == "entity" ? .entity : .language
    }

    /// 构建对应的 ContentKind。
    func makeContentKind() -> ContentKind {
        ContentKind(
            id: identifier,
            category: resolvedCategory,
            source: .plugin(identifier),
            label: label,
            icon: icon,
            pluginName: name
        )
    }
}

// MARK: - Detection Rules (rules.json)

/// 插件规则文件。
struct PluginRulesFile: Codable {
    let version: String             // 规则格式版本，"1"
    let rules: [PluginRule]
}

/// 单条检测规则。
struct PluginRule: Codable {
    let id: String                  // 规则唯一 ID
    let pattern: String             // ICU 正则表达式
    let extractValue: String?       // 捕获组名或编号，提取到 ContentDetection.value
    let priority: Int?              // 规则级优先级偏移（叠加 manifest 优先级）
    let action: PluginActionTemplate? // 匹配后的动作
}

/// 编译后的规则（正则已预编译）。
struct CompiledRule {
    let id: String
    let regex: NSRegularExpression
    let extractGroup: String?
    let actionTemplate: PluginActionTemplate?

    init?(rule: PluginRule) throws {
        self.id = rule.id
        self.regex = try NSRegularExpression(pattern: rule.pattern, options: [.anchorsMatchLines])
        self.extractGroup = rule.extractValue
        self.actionTemplate = rule.action
    }
}
