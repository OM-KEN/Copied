import Foundation

/// 只描述 App 当前实际采用的界面语言，不读取地区格式或写入用户偏好。
enum AppLanguage {
    static var isEnglish: Bool {
        isEnglish(localization: Bundle.main.preferredLocalizations.first)
    }

    static func isEnglish(localization: String?) -> Bool {
        localization?.lowercased().hasPrefix("en") == true
    }

    /// 英文界面不提供英文单词的词典翻译；其他语言与内容类型保持原行为。
    static func isContentKindAvailable(
        _ kind: ContentKind,
        localization: String? = Bundle.main.preferredLocalizations.first
    ) -> Bool {
        !(isEnglish(localization: localization) && kind.id == ContentKind.englishPhrase.id)
    }
}
