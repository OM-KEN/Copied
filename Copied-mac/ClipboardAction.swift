import AppKit
import Foundation

// MARK: - Action Protocol

protocol ClipboardAction: Identifiable {
    var id: String { get }
    var title: String { get }          // button text, ≤3 Chinese chars
    var systemImage: String { get }    // SF Symbol name
    var menuTitle: String { get }      // right-click menu label
    var performsInlineUpdate: Bool { get }  // true → keep popup open after perform (show result in-place)
    func perform(content: ClipboardContent, controller: ToastWindowController?)
}

extension ClipboardAction {
    var performsInlineUpdate: Bool { false }
}

// MARK: - Open URL Action

struct OpenURLAction: ClipboardAction {
    let url: URL
    var id: String { "open-url" }
    var title: String { String(localized: "打开") }
    var systemImage: String { "arrow.up.forward" }
    var menuTitle: String { String(localized: "打开链接") }

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Reveal File Action

struct RevealFileAction: ClipboardAction {
    let path: String
    var id: String { "reveal-file" }
    var title: String { String(localized: "打开") }
    var systemImage: String { "arrow.up.forward" }
    var menuTitle: String { String(localized: "打开文件位置") }

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        let fileURL = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}

// MARK: - Compress Images in Lithe

struct CompressImagesAction: ClipboardAction {
    let invocation: LitheInvocation
    let client: LitheApplicationClient

    var id: String { "compress-images-in-lithe" }
    var title: String { String(localized: "压缩") }
    var systemImage: String { "arrow.down.right.and.arrow.up.left" }
    var menuTitle: String { String(localized: "压缩图片") }

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        client.openFiles(invocation)
    }
}

// MARK: - Calculate Action

struct CalculateAction: ClipboardAction {
    let expression: String
    var id: String { "calculate" }
    var title: String { String(localized: "计算") }
    var systemImage: String { "equal" }
    var menuTitle: String { String(localized: "计算结果") }
    var performsInlineUpdate: Bool { true }

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        switch MathExpressionEvaluator.evaluate(expression) {
        case let .success(value):
            guard let formatted = MathExpressionEvaluator.format(value) else {
                controller?.showResultOverlay(
                    displayText: "\(expression)\n\(String(localized: "无法计算"))",
                    copyText: nil
                )
                return
            }
            let relation = formatted.isApproximate ? "≈" : "="
            let displayText = "\(expression)\n\(relation)\(formatted.displayText)"
            controller?.showResultOverlay(
                displayText: displayText,
                copyText: formatted.copyText
            )

        case let .failure(error):
            let message: String
            switch error {
            case .numberTooLarge, .tooComplex:
                message = String(localized: "数字过大")
            case .invalidSyntax, .divisionByZero, .noRealResult,
                 .unsupportedOperation, .unstableApproximation:
                message = String(localized: "无法计算")
            }
            controller?.showResultOverlay(
                displayText: "\(expression)\n\(message)",
                copyText: nil
            )
        }
    }
}

// MARK: - Search Action

struct SearchTextAction: ClipboardAction {
    let text: String
    var id: String { "search" }
    var title: String { String(localized: "搜索") }
    var systemImage: String { "magnifyingglass" }
    var menuTitle: String { String(localized: "搜索") }

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
    var title: String { String(localized: "拼音") }
    var systemImage: String { "keyboard" }
    var menuTitle: String { String(localized: "显示拼音") }
    var performsInlineUpdate: Bool { true }

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        let mutable = NSMutableString(string: String(character))
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        // Keep tone marks — do NOT strip diacritics
        let pinyin = (mutable as String).trimmingCharacters(in: .whitespaces)

        // Show result inline: first line = character, second line = pinyin
        let displayText = "\(character)  \(pinyin)"
        controller?.showResultOverlay(displayText: displayText, copyText: pinyin)
    }
}

// MARK: - Call Phone Action

struct CallPhoneAction: ClipboardAction {
    let phoneNumber: String
    var id: String { "call-phone" }
    var title: String { String(localized: "拨打") }
    var systemImage: String { "phone.arrow.up.right" }
    var menuTitle: String { String(localized: "拨打电话") }

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        let cleaned = phoneNumber
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        guard let url = URL(string: "tel://\(cleaned)") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Compose Email Action

struct ComposeEmailAction: ClipboardAction {
    let email: String
    var id: String { "compose-email" }
    var title: String { String(localized: "发邮件") }
    var systemImage: String { "pencil" }
    var menuTitle: String { String(localized: "发送邮件") }

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        let cleaned = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let escaped = cleaned
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Mail"
            activate
            set newMessage to make new outgoing message with properties {visible:true}
            tell newMessage
                make new to recipient at end of to recipients with properties {address:"\(escaped)"}
            end tell
        end tell
        """
        let process = Process()
        process.launchPath = "/usr/bin/osascript"
        process.arguments = ["-e", script]
        process.launch()
    }
}

// MARK: - Save File Action (for context menu)

struct SaveFileAction: ClipboardAction {
    let text: String
    let defaultName: String
    var id: String { "save-file" }
    var title: String { String(localized: "另存为") }
    var systemImage: String { "arrow.down.doc" }
    var menuTitle: String { String(localized: "另存为…") }

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

// MARK: - Copy Result Action (used after inline-update actions show result)

struct CopyTextAction: ClipboardAction {
    let text: String
    var id: String { "copy-result" }
    var title: String { String(localized: "复制") }
    var systemImage: String { "doc.on.doc" }
    var menuTitle: String { String(localized: "复制结果") }

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - Open Calendar Action

struct OpenCalendarAction: ClipboardAction {
    let date: Date
    var id: String { "open-calendar" }
    var title: String { String(localized: "日历") }
    var systemImage: String { "calendar" }
    var menuTitle: String { String(localized: "在日历中打开") }

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        let cal = Calendar.current
        let y = cal.component(.year, from: date)
        let m = cal.component(.month, from: date)
        let d = cal.component(.day, from: date)
        let h = cal.component(.hour, from: date)
        let min = cal.component(.minute, from: date)
        let script = """
        tell application "Calendar"
            activate
            delay 0.3
            set targetDate to current date
            set year of targetDate to \(y)
            set month of targetDate to \(m)
            set day of targetDate to \(d)
            set hours of targetDate to \(h)
            set minutes of targetDate to \(min)
            set seconds of targetDate to 0
            view calendar at targetDate
        end tell
        """
        // Use Process (osascript) instead of NSAppleScript — avoids main-thread
        // silent-failure issues in SwiftUI button handlers.
        let process = Process()
        process.launchPath = "/usr/bin/osascript"
        process.arguments = ["-e", script]
        process.launch()
    }
}

// MARK: - Action Resolver

enum ActionResolver {

    /// Returns (primary button action, right-click menu actions).
    /// Primary is the highest-priority action for the right-side button.
    /// Menu includes all applicable actions for the context menu.
    static func resolve(
        for content: ClipboardContent,
        litheClient: LitheApplicationClient = .live
    )
        -> (primary: (any ClipboardAction)?, menu: [any ClipboardAction]) {

        var primary: (any ClipboardAction)? = nil
        var menu: [any ClipboardAction] = []

        if let invocation = LitheCompressionEligibility.invocation(
            for: content.fileURLs,
            isGeneratedByLithe: content.litheMetadata.isGeneratedByLithe,
            client: litheClient
        ) {
            let compressAction = CompressImagesAction(
                invocation: invocation,
                client: litheClient
            )
            primary = compressAction
            menu.append(compressAction)
        }

        for detection in content.detections {
            guard let action = makeAction(for: detection) else { continue }
            if detection.pluginActionTemplate?.menuOnly == true {
                menu.append(action)
            } else if primary == nil {
                primary = action
            } else {
                menu.append(action)
            }
        }

        // If no detection produced a primary action, save long text and search short text.
        if primary == nil, content.type == .text, !content.preview.isEmpty {
            let text = content.rawText ?? content.preview
            if !text.isEmpty {
                switch ClipboardTextPolicy.fallback(for: text) {
                case .saveAs:
                    primary = SaveFileAction(text: text, defaultName: "clipboard.txt")
                case .search:
                    primary = SearchTextAction(text: String(text.prefix(100)))
                }
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

        case ContentKind.phoneNumber.id:
            guard let phone = detection.value else { return nil }
            return CallPhoneAction(phoneNumber: phone)

        case ContentKind.email.id:
            guard let email = detection.value else { return nil }
            return ComposeEmailAction(email: email)

        case ContentKind.filePath.id:
            guard let path = detection.value else { return nil }
            return RevealFileAction(path: path)

        case ContentKind.mathExpr.id:
            guard let expr = detection.value else { return nil }
            return CalculateAction(expression: expr)

        case ContentKind.dateTime.id:
            guard let tsStr = detection.value,
                  let ts = TimeInterval(tsStr) else { return nil }
            return OpenCalendarAction(date: Date(timeIntervalSinceReferenceDate: ts))

        case ContentKind.chineseChar.id:
            guard let charStr = detection.value, let char = charStr.first else { return nil }
            return ShowPinyinAction(character: char)

        case ContentKind.englishPhrase.id:
            guard let text = detection.value else { return nil }
            // 预查词典：有释义才显示"翻译"按钮，无释义则返回 nil 让 SearchTextAction 兜底
            guard DictionaryLookupService.lookup(text) != nil else { return nil }
            return LookupAction(text: text)

        case ContentKind.colorHex.id,
             ContentKind.colorRGB.id,
             ContentKind.colorHSL.id:
            return nil  // Color is visual only (swatch)

        default:
            break
        }

        // Plugin-defined action（none 类型仅用于类型标签，不产生按钮）
        if let template = detection.pluginActionTemplate, template.type != .none {
            return PluginAction(detection: detection, template: template)
        }

        // Language types — no primary button, just labeling
        return nil
    }
}
