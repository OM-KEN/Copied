import Foundation

// MARK: - Plugin Action Template

/// 插件定义的动作模板（从 rules.json 加载）。
///
/// 支持四种动作类型：
/// - `openURL`: 用模板 URL 在浏览器打开
/// - `searchWithEngine`: 用配置的搜索引擎搜索
/// - `transform`: 正则替换 + 内联显示结果
/// - `none`: 仅显示标签，无按钮
struct PluginActionTemplate: Codable {

    /// 动作类型。
    let type: ActionType

    /// 按钮标题（≤3 个中文字符）。
    let title: String

    /// 按钮 SF Symbol。
    let icon: String

    /// `openURL` 类型的 URL 模板，`{value}` 会被替换为检测值。
    let template: String?

    /// `transform` 类型的正则 pattern。
    let transformPattern: String?

    /// `transform` 类型的替换字符串。
    let transformReplacement: String?

    /// 强制放入右键菜单，不作为主按钮。默认 false。
    let menuOnly: Bool?

    enum ActionType: String, Codable {
        case openURL
        case searchWithEngine
        case transform
        case none
    }

    // MARK: CodingKeys

    enum CodingKeys: String, CodingKey {
        case type, title, icon, template, menuOnly
        case transformPattern = "pattern"
        case transformReplacement = "replacement"
    }
}
