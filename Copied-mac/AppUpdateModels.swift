import Foundation

struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(tag: String) {
        let value = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), major >= 0,
              let minor = Int(parts[1]), minor >= 0,
              let patch = Int(parts[2]), patch >= 0,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct AppRelease: Equatable {
    let version: SemanticVersion
    let pageURL: URL

    var hasTrustedPageURL: Bool {
        pageURL.scheme?.lowercased() == "https"
            && pageURL.host?.lowercased() == "github.com"
    }
}

enum LatestReleaseParseResult: Equatable {
    case release(AppRelease)
    case noStableRelease
    case failure
}

enum LatestReleaseParser {
    private struct Response: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    static func parse(statusCode: Int, data: Data) -> LatestReleaseParseResult {
        if statusCode == 404 { return .noStableRelease }
        guard (200..<300).contains(statusCode),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              let version = SemanticVersion(tag: response.tagName),
              response.htmlURL.scheme == "https" else { return .failure }
        let release = AppRelease(version: version, pageURL: response.htmlURL)
        guard release.hasTrustedPageURL else { return .failure }
        return .release(release)
    }
}

enum AppUpdateCheckOutcome: Equatable {
    case success
    case noStableRelease
    case failure
}

struct AppUpdateSchedule: Equatable {
    static let successInterval: TimeInterval = 24 * 60 * 60
    static let failureRetryInterval: TimeInterval = 60 * 60

    var lastSuccessfulCheck: Date?
    var lastFailedCheck: Date?

    func shouldRunAutomaticCheck(at now: Date, enabled: Bool) -> Bool {
        guard enabled else { return false }
        if let lastSuccessfulCheck,
           now.timeIntervalSince(lastSuccessfulCheck) < Self.successInterval {
            return false
        }
        if let lastFailedCheck,
           now.timeIntervalSince(lastFailedCheck) < Self.failureRetryInterval {
            return false
        }
        return true
    }

    mutating func record(_ outcome: AppUpdateCheckOutcome, at date: Date) {
        switch outcome {
        case .success, .noStableRelease:
            lastSuccessfulCheck = date
            lastFailedCheck = nil
        case .failure:
            lastFailedCheck = date
        }
    }
}

struct UpdateToastReminderPolicy {
    static let minimumInterval: TimeInterval = 24 * 60 * 60

    var lastDisplayedAt: Date?

    func shouldDisplay(
        at now: Date,
        automaticRemindersEnabled: Bool,
        hasAvailableUpdate: Bool,
        isLightReminderMode: Bool
    ) -> Bool {
        guard automaticRemindersEnabled, hasAvailableUpdate, !isLightReminderMode else { return false }
        guard let lastDisplayedAt else { return true }
        return now.timeIntervalSince(lastDisplayedAt) >= Self.minimumInterval
    }

    mutating func recordDisplayed(at date: Date) {
        lastDisplayedAt = date
    }
}
