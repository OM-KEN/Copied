import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct FeedbackSupportTests {
    static func main() {
        let environment = FeedbackEnvironment(
            appVersion: "3.5.2",
            macOSVersion: "26.6.0",
            architecture: "Apple Silicon"
        )
        let url = FeedbackSupport.emailURL(for: environment)
        let components = url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })

        expect(components?.scheme == "mailto", "feedback uses the mailto scheme")
        expect(components?.path == FeedbackSupport.recipient, "feedback targets the support inbox")
        expect(
            query["subject"] == "[Copied][问题反馈] v3.5.2",
            "feedback subject identifies Copied and its version"
        )
        expect(query["body"]?.contains("Copied 版本：3.5.2") == true, "body includes app version")
        expect(query["body"]?.contains("macOS 版本：26.6.0") == true, "body includes macOS version")
        expect(query["body"]?.contains("芯片架构：Apple Silicon") == true, "body includes architecture")
        expect(
            FeedbackSupport.githubIssueChooserURL.absoluteString
                == "https://github.com/OM-KEN/Copied/issues/new/choose",
            "GitHub feedback opens the issue template chooser"
        )

        print("FeedbackSupportTests: PASS")
    }
}
