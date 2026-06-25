import AppKit
import Foundation

/// 执行插件定义的动作模板。
struct PluginAction: ClipboardAction {

    let detection: ContentDetection
    let template: PluginActionTemplate

    var id: String { "plugin-\(detection.kind.id)" }
    var title: String { template.title }
    var systemImage: String { template.icon }
    var menuTitle: String { template.title }
    var performsInlineUpdate: Bool { template.type == .transform }

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        switch template.type {
        case .openURL:
            let urlStr = (template.template ?? "")
                .replacingOccurrences(of: "{value}", with: detection.value ?? "")
            guard let encoded = urlStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: encoded) ?? URL(string: urlStr) else { return }
            NSWorkspace.shared.open(url)

        case .searchWithEngine:
            SearchTextAction(text: detection.value ?? "").perform(content: content, controller: controller)

        case .transform:
            let result = applyTransform(template, on: detection.value ?? "")
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
