import AppKit
import Foundation

// MARK: - Action Protocol

protocol ClipboardAction: Identifiable {
    var id: String { get }
    var title: String { get }          // button text, ≤3 Chinese chars
    var systemImage: String { get }    // SF Symbol name
    var menuTitle: String { get }      // right-click menu label
    func perform(content: ClipboardContent, controller: ToastWindowController?)
}

// MARK: - Open URL Action

struct OpenURLAction: ClipboardAction {
    let url: URL
    var id: String { "open-url" }
    var title: String { "打开" }
    var systemImage: String { "safari" }
    var menuTitle: String { "打开链接" }

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Reveal File Action

struct RevealFileAction: ClipboardAction {
    let path: String
    var id: String { "reveal-file" }
    var title: String { "打开" }
    var systemImage: String { "folder" }
    var menuTitle: String { "打开文件位置" }

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        let fileURL = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}

// MARK: - Calculate Action

struct CalculateAction: ClipboardAction {
    let expression: String
    var id: String { "calculate" }
    var title: String { "计算" }
    var systemImage: String { "function" }
    var menuTitle: String { "计算结果" }

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        // Clean: remove trailing =, replace operators, trim whitespace
        let cleaned = expression
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "^", with: "**")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let expr = NSExpression(format: cleaned)
        guard let result = expr.expressionValue(with: nil, context: nil) else { return }

        // Show result inline (no clipboard write to avoid re-triggering toast)
        let fullText = "\(expression)=\(result)"
        controller?.showResultOverlay(fullText)
    }
}

// MARK: - Search Action

struct SearchTextAction: ClipboardAction {
    let text: String
    var id: String { "search" }
    var title: String { "搜索" }
    var systemImage: String { "magnifyingglass" }
    var menuTitle: String { "搜索" }

    private static let searchEngines: [String: String] = [
        "google":    "https://www.google.com/search?q=%@",
        "baidu":     "https://www.baidu.com/s?wd=%@",
        "bing":      "https://www.bing.com/search?q=%@",
        "duckduckgo": "https://duckduckgo.com/?q=%@",
    ]

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        let engine = UserDefaults.standard.string(forKey: "searchEngine") ?? "google"
        let template = Self.searchEngines[engine] ?? "https://www.google.com/search?q=%@"

        guard let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: String(format: template, query)) else { return }

        NSWorkspace.shared.open(url)
    }
}

// MARK: - Show Pinyin Action

struct ShowPinyinAction: ClipboardAction {
    let character: Character
    var id: String { "pinyin" }
    var title: String { "拼音" }
    var systemImage: String { "waveform" }
    var menuTitle: String { "显示拼音" }

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        let mutable = NSMutableString(string: String(character))
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        // Keep tone marks — do NOT strip diacritics
        let pinyin = (mutable as String).trimmingCharacters(in: .whitespaces)

        let resultText = "\(character)  \(pinyin)"
        controller?.showResultOverlay(resultText)
    }
}

// MARK: - Save File Action (for context menu)

struct SaveFileAction: ClipboardAction {
    let text: String
    let defaultName: String
    var id: String { "save-file" }
    var title: String { "另存为" }
    var systemImage: String { "arrow.down.doc" }
    var menuTitle: String { "另存为…" }

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        // Determine save location
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }) ?? NSApp.keyWindow else {
            // Fallback: save to Desktop
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
            let fileURL = desktop.appendingPathComponent(defaultName)
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

// MARK: - Action Resolver

enum ActionResolver {

    /// Returns (primary button action, right-click menu actions).
    /// Primary is the highest-priority action for the right-side button.
    /// Menu includes all applicable actions for the context menu.
    static func resolve(for content: ClipboardContent)
        -> (primary: (any ClipboardAction)?, menu: [any ClipboardAction]) {

        var primary: (any ClipboardAction)? = nil
        var menu: [any ClipboardAction] = []

        for detection in content.detections {
            let action = makeAction(for: detection)
            if let action {
                if primary == nil { primary = action } else { menu.append(action) }
            }
        }

        // If no detection produced a primary action but we have plain text, offer "搜索"
        if primary == nil, content.type == .text, !content.preview.isEmpty {
            let text = content.rawText ?? content.preview
            if !text.isEmpty {
                primary = SearchTextAction(text: String(text.prefix(100)))
            }
        }

        return (primary, menu)
    }

    /// Map a ContentDetection to its corresponding ClipboardAction.
    private static func makeAction(for detection: ContentDetection) -> (any ClipboardAction)? {
        // Built-in entity types
        switch detection.kind.id {
        case ContentKind.url.id:
            guard let urlStr = detection.value, let url = URL(string: urlStr) else { return nil }
            return OpenURLAction(url: url)

        case ContentKind.filePath.id:
            guard let path = detection.value else { return nil }
            return RevealFileAction(path: path)

        case ContentKind.mathExpr.id:
            guard let expr = detection.value else { return nil }
            return CalculateAction(expression: expr)

        case ContentKind.chineseChar.id:
            guard let charStr = detection.value, let char = charStr.first else { return nil }
            return ShowPinyinAction(character: char)

        case ContentKind.englishPhrase.id:
            guard let text = detection.value else { return nil }
            return SearchTextAction(text: text)

        case ContentKind.colorHex.id,
             ContentKind.colorRGB.id,
             ContentKind.colorHSL.id:
            return nil  // Color is visual only (swatch)

        default:
            break
        }

        // Plugin-defined action
        if let template = detection.pluginActionTemplate {
            return PluginAction(detection: detection, template: template)
        }

        // Language types — no primary button, just labeling
        return nil
    }
}
