import Foundation

/// 统一的内容类型标识 — 替换旧的 TextKind 和 DetectedContent。
///
/// `category`（语义类别）和 `source`（来源）是两个正交维度：
/// - 插件可以检测 `category: .language`（如 JSON），也可以检测 `category: .entity`（如 JWT）
/// - `source: .plugin(id)` 关联回插件 identifier，支持禁用/卸载时精准移除
struct ContentKind: Hashable, Identifiable {

    let id: String              // "swift", "url", "com.plugin.jwt"
    let category: Category      // 语义类别（正交维度）
    let source: Source          // 来源（独立于类别）
    let label: String           // 类型标签（toast 详情行："Swift", "JSON"）
    let icon: String            // SF Symbol 名
    var pluginName: String? = nil // 插件的人类可读名称（仅插件有值，如 "JSON 检测器"）

    /// 语义类别。
    enum Category: String, Codable {
        case language           // 语言/格式（旧 TextKind 域）
        case entity             // 内容实体（旧 DetectedContent 域）
    }

    /// 来源。
    enum Source: Hashable, Codable {
        case builtIn
        case plugin(String)     // 关联插件 identifier
    }

    var isBuiltIn: Bool {
        if case .builtIn = source { return true }
        return false
    }

    /// 用于 Settings 中显示来源标记。
    var sourceLabel: String? {
        if case .plugin = source { return String(localized: "content-kind.source.plugin") }
        return nil
    }

    /// SF Symbol 图标是否需强制英文 locale 渲染。
    /// 部分 SF Symbol（如 "textformat"）在不同 locale 下字形差异大，
    /// 中文系统下显示"文"而非"Aa"，导致与弹窗 icon 不一致。
    var forceEnglishLocale: Bool { icon == "textformat" }
}

// MARK: - 内置类型静态常量

extension ContentKind {

    // ── 语言/格式类 ──────────────────────────────────────────

    static let plain = ContentKind(
        id: "plain", category: .language, source: .builtIn,
        label: "", icon: "text.alignleft"
    )

    static let html = ContentKind(
        id: "html", category: .language, source: .builtIn,
        label: "HTML", icon: "chevron.left.forwardslash.chevron.right"
    )

    static let swift = ContentKind(
        id: "swift", category: .language, source: .builtIn,
        label: "Swift", icon: "curlybraces"
    )

    static let css = ContentKind(
        id: "css", category: .language, source: .builtIn,
        label: "CSS", icon: "curlybraces"
    )

    static let python = ContentKind(
        id: "python", category: .language, source: .builtIn,
        label: "Python", icon: "curlybraces"
    )

    static let javascript = ContentKind(
        id: "javascript", category: .language, source: .builtIn,
        label: "JavaScript", icon: "curlybraces"
    )

    static let code = ContentKind(
        id: "code", category: .language, source: .builtIn,
        label: String(localized: "代码"), icon: "curlybraces"
    )

    // ── 实体类 ──────────────────────────────────────────────

    static let url = ContentKind(
        id: "url", category: .entity, source: .builtIn,
        label: String(localized: "链接"), icon: "link"
    )

    static let phoneNumber = ContentKind(
        id: "phoneNumber", category: .entity, source: .builtIn,
        label: String(localized: "电话"), icon: "phone"
    )

    static let email = ContentKind(
        id: "email", category: .entity, source: .builtIn,
        label: String(localized: "邮箱"), icon: "envelope"
    )

    static let filePath = ContentKind(
        id: "filePath", category: .entity, source: .builtIn,
        label: String(localized: "路径"), icon: "folder"
    )

    static let mathExpr = ContentKind(
        id: "mathExpression", category: .entity, source: .builtIn,
        label: String(localized: "公式"), icon: "function"
    )

    static let dateTime = ContentKind(
        id: "dateTime", category: .entity, source: .builtIn,
        label: String(localized: "日期"), icon: "calendar"
    )

    static let colorHex = ContentKind(
        id: "colorHex", category: .entity, source: .builtIn,
        label: String(localized: "颜色"), icon: "paintpalette"
    )

    static let colorRGB = ContentKind(
        id: "colorRGB", category: .entity, source: .builtIn,
        label: String(localized: "RGB 颜色"), icon: "paintpalette"
    )

    static let colorHSL = ContentKind(
        id: "colorHSL", category: .entity, source: .builtIn,
        label: String(localized: "HSL 颜色"), icon: "paintpalette"
    )

    static let chineseChar = ContentKind(
        id: "chineseCharacter", category: .entity, source: .builtIn,
        label: String(localized: "汉字"), icon: "character"
    )

    static let englishPhrase = ContentKind(
        id: "englishPhrase", category: .entity, source: .builtIn,
        label: String(localized: "英文"), icon: "textformat"
    )
}
