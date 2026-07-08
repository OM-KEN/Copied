import AppKit
import Foundation

/// 执行插件定义的动作模板。
struct PluginAction: ClipboardAction {

    let detection: ContentDetection
    let template: PluginActionTemplate

    var id: String { "plugin-\(detection.kind.id)-\(detection.metadata["ruleId"] ?? "")" }
    var title: String { template.title }
    var systemImage: String { template.icon }
    var menuTitle: String { template.title }
    var performsInlineUpdate: Bool { template.type == .transform }

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        let text = detection.value ?? ""

        switch template.type {
        case .openURL:
            // 只对 {value} 替换值编码，并排除 # 等 URL 保留字符
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "#&=+")
            guard let encodedValue = text.addingPercentEncoding(withAllowedCharacters: allowed) else { return }
            let urlStr = (template.template ?? "")
                .replacingOccurrences(of: "{value}", with: encodedValue)
            guard let url = URL(string: urlStr) else { return }
            NSWorkspace.shared.open(url)

        case .searchWithEngine:
            SearchTextAction(text: text).perform(content: content, controller: controller)

        case .transform:
            let result = applyTransform(template, on: text)
            controller?.showResultOverlay(displayText: result, copyText: result)

        case .none:
            break
        }
    }

    // MARK: - Transform

    private func applyTransform(_ template: PluginActionTemplate, on text: String) -> String {
        guard let pattern = template.transformPattern,
              let replacement = template.transformReplacement,
              let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}
