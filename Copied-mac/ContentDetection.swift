import AppKit
import Foundation

/// 单次检测结果 — kind + 提取的数据。
///
/// 替换旧的 `DetectedContent` 枚举（带有无法序列化的关联值如 NSColor、URL）。
/// 颜色数据通过 `color` 字段携带；URL/路径/表达式等通过 `value: String?` 携带。
struct ContentDetection: Identifiable, Hashable {

    let id = UUID()

    /// 检测到的类型。
    let kind: ContentKind

    /// 提取的值（URL 字符串、文件路径、数学表达式等）。
    let value: String?

    /// 颜色类型专用（`.colorHex`, `.colorRGB`, `.colorHSL`）。
    var color: NSColor? = nil

    /// 扩展元数据（插件可在此填充自定义字段，如 ruleId）。
    var metadata: [String: String] = [:]

    /// 插件定义的动作模板（nil 表示使用内置动作或无动作）。
    var pluginActionTemplate: PluginActionTemplate? = nil

    // MARK: Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(value)
        hasher.combine(metadata)
    }

    static func == (lhs: ContentDetection, rhs: ContentDetection) -> Bool {
        lhs.kind == rhs.kind
            && lhs.value == rhs.value
            && lhs.metadata == rhs.metadata
    }
}
