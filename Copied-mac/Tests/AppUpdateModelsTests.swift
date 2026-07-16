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
        } else {
            expect(false, "valid latest release response")
        }
        expect(LatestReleaseParser.parse(statusCode: 404, data: Data()) == .noStableRelease, "404 means no stable release")
        expect(LatestReleaseParser.parse(statusCode: 500, data: Data()) == .failure, "server error")
        expect(LatestReleaseParser.parse(statusCode: 200, data: Data("{}".utf8)) == .failure, "malformed response")

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
}
