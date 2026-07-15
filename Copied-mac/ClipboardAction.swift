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

// MARK: - Calculate Action

struct CalculateAction: ClipboardAction {
    let expression: String
    var id: String { "calculate" }
    var title: String { String(localized: "计算") }
    var systemImage: String { "equal" }
    var menuTitle: String { String(localized: "计算结果") }
    var performsInlineUpdate: Bool { true }

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        // Clean: remove trailing =, replace operators, trim whitespace
        let cleaned = expression
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "^", with: "**")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let isIntegerExpr = cleaned.rangeOfCharacter(from: CharacterSet(charactersIn: ".")) == nil

        // ── Pre-checks for integer expressions ──────────────────
        if isIntegerExpr {
            // Integer division by zero → NSExpression returns inf.
            // Catch early for a clearer error message.
            if cleaned.range(of: #"/\s*0(?![.\d])"#, options: .regularExpression) != nil {
                let displayText = "\(expression)\n\(String(localized: "无法计算"))"
                controller?.showResultOverlay(displayText: displayText, copyText: "")
                return
            }

            // Precision guard: operands with ≥19 digits would lose precision
            // when converted to Double for evaluation (53-bit mantissa ≈ 15–16
            // significant decimal digits). Reject early rather than silently
            // returning an imprecise result.
            let numbers = cleaned
                .components(separatedBy: CharacterSet(charactersIn: "+-*/^").union(.whitespaces))
                .filter { !$0.isEmpty }
            let digitCounts = numbers.map { $0.count }.sorted(by: >)
            let maxDigits = digitCounts.first ?? 0
            let topTwoSum = digitCounts.prefix(2).reduce(0, +)
            let overflowRisk: Bool
            if cleaned.contains("*") {
                overflowRisk = topTwoSum >= 19  // product of two N-digit nums can have 2N digits
            } else {
                overflowRisk = maxDigits >= 19  // addition needs 19-digit operand to overflow
            }
            if overflowRisk {
                let displayText = "\(expression)\n\(String(localized: "数字过大"))"
                controller?.showResultOverlay(displayText: displayText, copyText: "")
                return
            }
        }

        // ── Evaluate with NSExpression ──────────────────────────
        // NSExpression inherits C integer arithmetic semantics:
        // integer literals trigger integer division (e.g. 3/2 → 1).
        // Convert integer-only expressions to double form so ALL
        // operations use real-number arithmetic — not just division.
        // The \b word-boundary regex preserves scientific notation (2e5).
        let evalStr: String
        if isIntegerExpr {
            evalStr = cleaned.replacingOccurrences(
                of: #"\b(\d+)\b"#,
                with: "$1.0",
                options: .regularExpression
            )
        } else {
            evalStr = cleaned
        }
        let expr = NSExpression(format: evalStr)
        guard let rawResult = expr.expressionValue(with: nil, context: nil) else { return }

        // Extract numeric result. Integer expressions are converted to
        // double form above, so NSExpression always returns Double.
        let number: Double
        if let d = rawResult as? Double {
            number = d
        } else if let ns = rawResult as? NSNumber {
            number = ns.doubleValue
        } else {
            let displayText = "\(expression)\n=\(rawResult)"
            controller?.showResultOverlay(displayText: displayText, copyText: "\(rawResult)")
            return
        }

        // Handle non-finite floating result (e.g. 1.0/0.0 → inf)
        guard number.isFinite else {
            let displayText = "\(expression)\n\(String(localized: "无法计算"))"
            controller?.showResultOverlay(displayText: displayText, copyText: "")
            return
        }

        // Guard against precision loss for results beyond Double's
        // exact integer range (2^53 ≈ 9×10¹⁵). Numbers this large also
        // produce unwieldy display strings (20+ chars) that overflow the toast.
        let safeIntegerLimit: Double = 9_007_199_254_740_992.0
        if isIntegerExpr && abs(number) > safeIntegerLimit {
            let displayText = "\(expression)\n\(String(localized: "数字过大"))"
            controller?.showResultOverlay(displayText: displayText, copyText: "")
            return
        }

        // NumberFormatter handles rounding and stripping trailing zeros.
        // Pre-rounding with (n * 1e12).rounded() / 1e12 is avoided here
        // because for large integers (e.g. 890123456790), multiplying by
        // 1e12 pushes the value beyond Double's exact integer range (2^53),
        // introducing rounding noise.
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 12
        formatter.minimumFractionDigits = 0
        let displayResult = formatter.string(from: NSNumber(value: number)) ?? "\(number)"

        let displayText = "\(expression)\n=\(displayResult)"
        controller?.showResultOverlay(displayText: displayText, copyText: displayResult)
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
    static func resolve(for content: ClipboardContent)
        -> (primary: (any ClipboardAction)?, menu: [any ClipboardAction]) {

        var primary: (any ClipboardAction)? = nil
        var menu: [any ClipboardAction] = []

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
