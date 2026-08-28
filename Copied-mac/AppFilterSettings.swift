import Foundation
import AppKit

// MARK: - Data Models

struct AppFilterEntry: Codable, Identifiable, Equatable {
    let bundleID: String
    let displayName: String
    var id: String { bundleID }
}

// MARK: - AppFilterSettings Singleton

final class AppFilterSettings {
    static let shared = AppFilterSettings()

    private static let blockedKey = "popupFilterBlockedApps"
    private var cachedBlockedApps: [AppFilterEntry]

    private init() {
        cachedBlockedApps = Self.loadEntries(forKey: Self.blockedKey)
    }

    // ── Blocked Apps ────────────────────────────────────────

    var blockedApps: [AppFilterEntry] {
        get { cachedBlockedApps }
        set {
            cachedBlockedApps = newValue
            saveEntries(newValue, forKey: Self.blockedKey)
        }
    }

    func addToBlocked(_ entry: AppFilterEntry) {
        var apps = blockedApps
        guard !apps.contains(where: { $0.bundleID == entry.bundleID }) else { return }
        apps.append(entry)
        blockedApps = apps
    }

    func removeFromBlocked(bundleID: String) {
        blockedApps = blockedApps.filter { $0.bundleID != bundleID }
    }

    func isBlocked(bundleID: String) -> Bool {
        blockedApps.contains(where: { $0.bundleID == bundleID })
    }

    // ── Core Filter Logic ───────────────────────────────────

    /// Whether the popup should show for a clipboard change from the given app.
    /// Unknown source (nil bundleID) always shows.
    func shouldShowPopup(for bundleID: String?) -> Bool {
        guard let bid = bundleID else { return true }
        return !isBlocked(bundleID: bid)
    }

    // ── Running Applications ─────────────────────────────────

    /// Running regular apps available for selection, excluding Copied itself.
    func runningApplications() -> [AppFilterEntry] {
        let excludedIDs = Set([Bundle.main.bundleIdentifier].compactMap { $0 })
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppFilterEntry? in
                guard let bid = app.bundleIdentifier,
                      let name = app.localizedName,
                      !excludedIDs.contains(bid) else { return nil }
                return AppFilterEntry(bundleID: bid, displayName: name)
            }
        var seen = Set<String>()
        return apps.filter { seen.insert($0.bundleID).inserted }
                   .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    // ── Persistence Helpers ──────────────────────────────────

    private static func loadEntries(forKey key: String) -> [AppFilterEntry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([AppFilterEntry].self, from: data)) ?? []
    }

    private func saveEntries(_ entries: [AppFilterEntry], forKey key: String) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
