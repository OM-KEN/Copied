import Foundation

struct FeedbackEnvironment: Equatable {
    let appVersion: String
    let macOSVersion: String
    let architecture: String

    static func current(appVersion: String) -> FeedbackEnvironment {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return FeedbackEnvironment(
            appVersion: appVersion,
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            architecture: currentArchitecture
        )
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        "Apple Silicon"
        #elseif arch(x86_64)
        "Intel"
        #else
        "Unknown"
        #endif
    }
}

enum FeedbackSupport {
    static let recipient = "omken.feedback@gmail.com"
    static let githubIssueChooserURL = URL(
        string: "https://github.com/OM-KEN/Copied/issues/new/choose"
    )!

    static func emailURL(for environment: FeedbackEnvironment) -> URL? {
        let subject = String(
            format: String(localized: "[Copied][问题反馈] v%@"),
            environment.appVersion
        )
        let body = String(
            format: String(localized: feedbackBodyTemplate),
            environment.appVersion,
            environment.macOSVersion,
            environment.architecture
        )

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }

    private static let feedbackBodyTemplate: String.LocalizationValue = """
    请在下方描述问题或建议：

    【问题描述】


    【复现步骤（如适用）】
    1.
    2.

    【预期结果】


    【补充信息】


    ---
    以下信息由 Copied 自动生成：
    Copied 版本：%1$@
    macOS 版本：%2$@
    芯片架构：%3$@
    不包含剪贴板内容、文件路径、设置或日志。
    """
}
