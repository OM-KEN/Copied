import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct AppUpdateModelsTests {
    static func main() {
        expect(SemanticVersion(tag: "v2.10.0")! > SemanticVersion(tag: "2.9.9")!, "numeric minor comparison")
        expect(SemanticVersion(tag: "2.9.1")?.description == "2.9.1", "plain semantic version")
        expect(SemanticVersion(tag: "v2.9") == nil, "reject incomplete version")
        expect(SemanticVersion(tag: "v2.9.1-beta") == nil, "reject prerelease tag")

        let releaseJSON = Data(#"{"tag_name":"v2.10.0","html_url":"https://github.com/OM-KEN/Copied/releases/tag/v2.10.0"}"#.utf8)
        if case let .release(release) = LatestReleaseParser.parse(statusCode: 200, data: releaseJSON) {
            expect(release.version == SemanticVersion(tag: "2.10.0"), "release version parsed")
            expect(!release.isImportantUpdate, "missing body is an ordinary update")
            expect(release.releaseNotes.isEmpty, "missing body has no release notes")
        } else {
            expect(false, "valid latest release response")
        }
        expect(LatestReleaseParser.parse(statusCode: 404, data: Data()) == .noStableRelease, "404 means no stable release")
        expect(LatestReleaseParser.parse(statusCode: 500, data: Data()) == .failure, "server error")
        expect(LatestReleaseParser.parse(statusCode: 200, data: Data("{}".utf8)) == .failure, "malformed response")

        let marker = "<!-- copied:important-update -->"
        let bodies: [(Any, Bool)] = [
            (NSNull(), false),
            ("", false),
            (" \r\n ", false),
            ("Ordinary release notes", false),
            (marker, true),
            ("## Fixes\n\(marker)\n- Important fix", true),
            ("## Fixes\r\n\(marker)\r\n- Important fix", true),
            ("Text \(marker)", false),
            ("\(marker) extra", false),
            (" \(marker)", false),
            ("\(marker) ", false),
            ("<!-- copied:important-update-->", false),
            ("<!-- Copied:important-update -->", false)
        ]
        for (body, isImportant) in bodies {
            let data = try! JSONSerialization.data(withJSONObject: [
                "tag_name": "v2.10.0",
                "html_url": "https://github.com/OM-KEN/Copied/releases/tag/v2.10.0",
                "body": body
            ])
            guard case let .release(release) = LatestReleaseParser.parse(statusCode: 200, data: data) else {
                expect(false, "optional release body must parse")
                continue
            }
            expect(release.isImportantUpdate == isImportant, "only the exact marker on its own line marks an important update")
            expect(release.releaseNotes == (body as? String ?? ""), "parser preserves release notes and treats null as empty")
        }
        releaseNotesSelectLanguageAndPreserveContent()

        let start = Date(timeIntervalSince1970: 1_000_000)
        var schedule = AppUpdateSchedule(lastSuccessfulCheck: nil, lastFailedCheck: nil)
        expect(schedule.shouldRunAutomaticCheck(at: start, enabled: true), "initial automatic check")
        schedule.record(.failure, at: start)
        expect(!schedule.shouldRunAutomaticCheck(at: start.addingTimeInterval(3599), enabled: true), "failure retry floor")
        expect(schedule.shouldRunAutomaticCheck(at: start.addingTimeInterval(3600), enabled: true), "failure retry boundary")
        schedule.record(.success, at: start)
        expect(!schedule.shouldRunAutomaticCheck(at: start.addingTimeInterval(86_399), enabled: true), "success interval")
        expect(schedule.shouldRunAutomaticCheck(at: start.addingTimeInterval(86_400), enabled: true), "success boundary")
        expect(!schedule.shouldRunAutomaticCheck(at: start.addingTimeInterval(200_000), enabled: false), "toggle disables scheduling")

        var reminder = UpdateToastReminderPolicy(lastDisplayedAt: nil)
        expect(reminder.shouldDisplay(at: start, automaticRemindersEnabled: true, hasAvailableUpdate: true, isLightReminderMode: false), "standard toast reminder")
        expect(!reminder.shouldDisplay(at: start, automaticRemindersEnabled: true, hasAvailableUpdate: true, isLightReminderMode: true), "light mode does not consume")
        reminder.recordDisplayed(at: start)
        expect(!reminder.shouldDisplay(at: start.addingTimeInterval(86_399), automaticRemindersEnabled: true, hasAvailableUpdate: true, isLightReminderMode: false), "rolling 24-hour throttle")
        expect(reminder.shouldDisplay(at: start.addingTimeInterval(86_400), automaticRemindersEnabled: true, hasAvailableUpdate: true, isLightReminderMode: false), "reminder boundary")
        expect(!reminder.shouldDisplay(at: start.addingTimeInterval(86_400), automaticRemindersEnabled: false, hasAvailableUpdate: true, isLightReminderMode: false), "reminder toggle")

        print("AppUpdateModelsTests: PASS")
    }

    private static func releaseNotesSelectLanguageAndPreserveContent() {
        let marker = "<!-- copied:important-update -->"
        let english = "## What's New\n- **English** feature.\nA second line.\n\n## Fixes\n- English fix."
        let chinese = "## 新功能\n- **中文**功能。\n第二行。\n\n## 修复\n- 中文修复。"
        let combined = "\(marker)\n\n\(english)\n\n\(chinese)"
        func release(_ notes: String) -> AppRelease {
            AppRelease(
                version: SemanticVersion(tag: "2.10.0")!,
                pageURL: URL(string: "https://github.com/OM-KEN/Copied/releases/tag/v2.10.0")!,
                releaseNotes: notes
            )
        }
        for localization in ["zh-Hans", "zh-Hant", nil] as [String?] {
            expect(release(combined).displayNotes(localization: localization) == chinese, "Chinese interfaces select the original Chinese release sections")
        }
        for localization in ["en", "en-US"] {
            expect(release(combined).displayNotes(localization: localization) == english, "English interfaces select the English release sections")
        }
        let crlf = combined.replacingOccurrences(of: "\n", with: "\r\n")
        expect(release(crlf).displayNotes(localization: "en") == english, "CRLF release notes retain their line structure")
        expect(release(english).displayNotes(localization: "zh-Hans") == english, "Chinese interface falls back to available English notes")
        expect(release(chinese).displayNotes(localization: "en") == chinese, "English interface falls back to available Chinese notes")
        expect(release("## 新功能\n\n\(english)").displayNotes(localization: "zh-Hans") == english, "empty preferred sections fall back to actual content")
        for notes in ["", " \r\n ", marker, "\(marker)\n## 新功能\n\n## 修复\n"] {
            expect(release(notes).displayNotes(localization: "zh-Hans").isEmpty, "empty release notes leave the generic explanation available")
        }
        let unstructured = "A release paragraph.\n\n- First item.\n- Second item."
        expect(release(unstructured).displayNotes(localization: "en") == unstructured, "unsectioned notes preserve paragraphs and lists")
        expect(release("## Notes\n- Available notes.").displayNotes(localization: "zh-Hant") == "## Notes\n- Available notes.", "unknown sections remain available as fallback")
        expect(!release("Before \(marker)\nAfter").displayNotes(localization: "en").contains(marker), "hidden marker is removed from all displayed content")
    }
}
