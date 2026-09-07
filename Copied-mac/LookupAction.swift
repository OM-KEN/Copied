import Foundation

/// 系统词典查词 Action — 对齐 ShowPinyinAction（单个汉字→拼音）的体验。
/// 检测到单个英文单词时，右侧按钮显示"查词"，点击后内联展示中文释义。
struct LookupAction: ClipboardAction {
    let definition: String

    var id: String { "lookup" }
    var title: String { String(localized: "翻译") }
    var systemImage: String { "translate" }
    var menuTitle: String { String(localized: "翻译") }
    var performsInlineUpdate: Bool { true }

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        controller?.showInlineResult(displayText: definition, copyText: definition)
    }
}
