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
            // NSExpression returns 0 silently for integer division by zero.
            if cleaned.range(of: #"/\s*0(?![.\d])"#, options: .regularExpression) != nil {
                let displayText = "\(expression)\n无法计算"
                controller?.showResultOverlay(displayText: displayText, copyText: "")
                return
            }

            // Detect potential Int64 overflow: extract operands and check digit counts.
            // Int64.max ≈ 9.22×10¹⁸ (19 digits). For multiplication, if the sum of
            // the two largest operands' digit counts ≥ 19, the result might overflow.
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
                let displayText = "\(expression)\n数字过大"
                controller?.showResultOverlay(displayText: displayText, copyText: "")
                return
            }
        }

        // ── Evaluate with NSExpression ──────────────────────────
        let expr = NSExpression(format: cleaned)
        guard let rawResult = expr.expressionValue(with: nil, context: nil) else { return }

        // NSExpression may return NSNumber (Int64/Double) or Double directly.
        let number: Double
        let exactInteger: Int64?
        if let d = rawResult as? Double {
            number = d
            exactInteger = nil
        } else if let ns = rawResult as? NSNumber {
            number = ns.doubleValue
            let objCType = String(cString: ns.objCType)
            if objCType == "q" || objCType == "Q" || objCType == "l" || objCType == "L"
                || objCType == "i" || objCType == "I" || objCType == "s" || objCType == "S" {
                exactInteger = ns.int64Value
            } else {
                exactInteger = nil
            }
        } else {
            let displayText = "\(expression)\n=\(rawResult)"
            controller?.showResultOverlay(displayText: displayText, copyText: "\(rawResult)")
            return
        }

        // Handle non-finite floating result (e.g. 1.0/0.0 → inf)
        guard number.isFinite else {
            let displayText = "\(expression)\n无法计算"
            controller?.showResultOverlay(displayText: displayText, copyText: "")
            return
        }

        // Double precision loss for large integers (2^53 boundary)
        let safeIntegerLimit: Double = 9_007_199_254_740_992.0
        if isIntegerExpr && abs(number) > safeIntegerLimit && exactInteger == nil {
            let displayText = "\(expression)\n数字过大"
            controller?.showResultOverlay(displayText: displayText, copyText: "")
            return
        }

        // Exact Int64 result (safe after pre-checks above)
        if let exact = exactInteger, isIntegerExpr {
            let displayText = "\(expression)\n=\(exact)"
            controller?.showResultOverlay(displayText: displayText, copyText: "\(exact)")
            return
        }

        // Round to 12 decimal places to eliminate floating-point noise
        let rounded = (number * 1e12).rounded() / 1e12
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 12
        formatter.minimumFractionDigits = 0
        let displayResult = formatter.string(from: NSNumber(value: rounded)) ?? "\(rounded)"

        let displayText = "\(expression)\n=\(displayResult)"
        controller?.showResultOverlay(displayText: displayText, copyText: displayResult)
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

// MARK: - Copy Result Action (used after inline-update actions show result)

struct CopyTextAction: ClipboardAction {
    let text: String
    var id: String { "copy-result" }
    var title: String { "复制" }
    var systemImage: String { "doc.on.doc" }
    var menuTitle: String { "复制结果" }

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
    var title: String { "日历" }
    var systemImage: String { "calendar" }
    var menuTitle: String { "在日历中打开" }

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

        case ContentKind.dateTime.id:
            guard let tsStr = detection.value,
                  let ts = TimeInterval(tsStr) else { return nil }
            return OpenCalendarAction(date: Date(timeIntervalSinceReferenceDate: ts))

        case ContentKind.chineseChar.id:
            guard let charStr = detection.value, let char = charStr.first else { return nil }
            return ShowPinyinAction(character: char)

        case ContentKind.englishPhrase.id:
            guard let text = detection.value else { return nil }
            return TranslateAction(
                text: text,
                sourceLanguage: Locale.Language(identifier: "en"),
                targetLanguage: Locale.Language(identifier: "zh_Hans")
            )

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
