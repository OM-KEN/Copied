@preconcurrency import Translation
import Foundation
import AppKit

// MARK: - Translation Result

struct TranslationResult {
    let text: String?
    let error: String?
}

// MARK: - Translation Service

/// 对 macOS 15 Translation 框架的轻量封装。
/// Session 由 SwiftUI `.translationTask` 注入（MenuBar / Settings / Toast），
/// 模型下载在设置页面手动触发。
/// 用 UserDefaults 标记控制下载状态，方便测试重置。
@MainActor
@Observable
final class TranslationService {
    static let shared = TranslationService()

    private var registeredSessions: [String: TranslationSession] = [:]

    private(set) var enZhReady = false
    private(set) var zhEnReady = false
    private(set) var isDownloading = false
    var downloadError: String?

    /// 用户已主动完成下载（UserDefaults 控制，可重置）
    private var modelsInstalled: Bool {
        get { UserDefaults.standard.bool(forKey: "translationModelsInstalled") }
        set { UserDefaults.standard.set(newValue, forKey: "translationModelsInstalled") }
    }

    // MARK: - Session Registration

    func registerSession(
        _ session: TranslationSession,
        source: Locale.Language,
        target: Locale.Language
    ) {
        let key = sessionKey(source: source, target: target)
        registeredSessions[key] = session
        Task { await refreshReadiness() }
    }

    private func sessionKey(source: Locale.Language, target: Locale.Language) -> String {
        let s = source.languageCode?.identifier ?? "?"
        let t = target.languageCode?.identifier ?? "?"
        return "\(s)->\(t)"
    }

    // MARK: - Readiness

    func refreshReadiness() async {
        if modelsInstalled {
            let availability = LanguageAvailability()
            enZhReady = await availability.status(
                from: Locale.Language(identifier: "en"),
                to: Locale.Language(identifier: "zh_Hans")
            ) == .installed
            zhEnReady = await availability.status(
                from: Locale.Language(identifier: "zh_Hans"),
                to: Locale.Language(identifier: "en")
            ) == .installed
        } else {
            enZhReady = false
            zhEnReady = false
        }
    }

    var allReady: Bool { enZhReady && zhEnReady }

    // MARK: - Download

    func downloadModels() async {
        guard !isDownloading else { return }
        isDownloading = true
        downloadError = nil

        let pairs: [(Locale.Language, Locale.Language)] = [
            (Locale.Language(identifier: "en"), Locale.Language(identifier: "zh_Hans")),
            (Locale.Language(identifier: "zh_Hans"), Locale.Language(identifier: "en")),
        ]

        for (src, tgt) in pairs {
            let key = sessionKey(source: src, target: tgt)
            guard let session = registeredSessions[key] else {
                downloadError = "翻译服务未就绪，请重启应用"
                isDownloading = false
                return
            }

            guard await !session.isReady else { continue }

            do {
                try await session.prepareTranslation()
            } catch {
                downloadError = "下载被取消"
                isDownloading = false
                return
            }

            if await !session.isReady {
                for _ in 1...120 {
                    try? await Task.sleep(for: .seconds(1))
                    if await session.isReady { break }
                }
            }
        }

        modelsInstalled = true
        await refreshReadiness()
        isDownloading = false

        if !allReady {
            downloadError = "下载未完成，请重试"
        }
    }

    // MARK: - Remove (仅重置标记，方便测试)

    func removeModels() {
        modelsInstalled = false
        enZhReady = false
        zhEnReady = false
        downloadError = nil
    }

    // MARK: - Translate

    func translate(
        text: String,
        source: Locale.Language,
        target: Locale.Language
    ) async -> TranslationResult {
        guard !text.isEmpty else { return TranslationResult(text: nil, error: "empty text") }

        let key = sessionKey(source: source, target: target)

        guard let session = registeredSessions[key] else {
            return TranslationResult(text: nil, error: "翻译服务未就绪")
        }

        guard modelsInstalled, await session.isReady else {
            return TranslationResult(text: nil, error: "请前往设置下载翻译模型")
        }

        do {
            let response = try await session.translate(text)
            return TranslationResult(text: response.targetText, error: nil)
        } catch {
            NSLog("Copied: translate error key=\(key): \(error)")
            return TranslationResult(text: nil, error: "翻译失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - Language Detection

func isPredominantlyChinese(_ text: String) -> Bool {
    let scalars = Array(text.unicodeScalars)
    let relevant = scalars.filter { s in
        let v = s.value
        return (0x4E00...0x9FFF).contains(v)
            || (0x3400...0x4DBF).contains(v)
            || (0xF900...0xFAFF).contains(v)
            || s.properties.isAlphabetic
    }
    guard !relevant.isEmpty else { return false }

    let cjkCount = relevant.filter { s in
        let v = s.value
        return (0x4E00...0x9FFF).contains(v)
            || (0x3400...0x4DBF).contains(v)
            || (0xF900...0xFAFF).contains(v)
    }.count

    return Double(cjkCount) / Double(relevant.count) > 0.3
}

// MARK: - UserDefaults Key

extension UserDefaults {
    @objc dynamic var translationEnabled: Bool {
        get { bool(forKey: "translationEnabled") }
        set { set(newValue, forKey: "translationEnabled") }
    }
}

// MARK: - Translate Action

struct TranslateAction: ClipboardAction {
    let text: String
    let sourceLanguage: Locale.Language
    let targetLanguage: Locale.Language

    var id: String { "translate" }
    var title: String { "翻译" }
    var systemImage: String { "character.bubble" }
    var menuTitle: String { "翻译" }
    var performsInlineUpdate: Bool { true }

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        controller?.prepareForAsyncInlineAction()
        controller?.isTranslating = true
        let gen = controller?.nextTranslationGeneration() ?? 0

        Task { @MainActor in
            let result = await TranslationService.shared.translate(
                text: text,
                source: sourceLanguage,
                target: targetLanguage
            )

            guard controller?.translationGeneration == gen else {
                controller?.isTranslating = false
                return
            }

            controller?.isTranslating = false

            if let translated = result.text {
                controller?.showInlineResult(displayText: translated, copyText: translated)
            } else {
                let msg = result.error ?? "翻译失败"
                if msg == "请前往设置下载翻译模型" {
                    controller?.showInlineResult(displayText: "\(text)", copyText: "")
                    showDownloadAlert()
                } else {
                    controller?.showInlineResult(displayText: msg, copyText: "")
                }
            }
        }
    }

    private func showDownloadAlert() {
        let alert = NSAlert()
        alert.messageText = "翻译模型未下载"
        alert.informativeText = "需要下载翻译模型才能使用翻译功能。\n前往设置页面下载？"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "前往设置")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // 打开设置（⌘, 快捷键）
            if let menu = NSApp.mainMenu,
               let appMenu = menu.items.first,
               let prefsItem = appMenu.submenu?.items.first(where: {
                   $0.keyEquivalent == ","
               }) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(prefsItem.action!, to: prefsItem.target, from: prefsItem)
            }
        }
    }
}
