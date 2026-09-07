
import Foundation
import AppKit

let G = "\u{001B}[32m", R = "\u{001B}[31m", B = "\u{001B}[34m", X = "\u{001B}[0m"
func pass(_ m: String) { print("\(G)  ✓ \(m)\(X)") }
func fail(_ m: String) { print("\(R)  ✗ \(m)\(X)") }
func info(_ m: String) { print("\(B)  ℹ \(m)\(X)") }

var total = 0, passed = 0

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    total += 1
    if actual == expected { passed += 1; pass(label) }
    else { fail("\(label) — got \(actual), expected \(expected)") }
}
func assertTrue(_ actual: Bool, _ label: String) { assertEqual(actual, true, label) }
func assertFalse(_ actual: Bool, _ label: String) { assertEqual(actual, false, label) }

@main
struct AppFilterTests {
    static func main() {
        // ── Setup ────────────────────────────────────────────────────
        let testKey = "popupFilterBlockedApps"
        let suiteName = "CopiedAppFilterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removeObject(forKey: testKey)

        let settings = AppFilterSettings(defaults: defaults)
        let safari = AppFilterEntry(bundleID: "com.apple.Safari", displayName: "Safari")
        let chrome = AppFilterEntry(bundleID: "com.google.Chrome", displayName: "Google Chrome")

        // ═══════════════════════════════════════════════════════════════
        print("\n═══════════════════════════════════════════")
        print("  Phase A: Defaults")
        print("═══════════════════════════════════════════")

        assertTrue(settings.blockedApps.isEmpty, "Default blockedApps empty")

        // ═══════════════════════════════════════════════════════════════
        print("\n═══════════════════════════════════════════")
        print("  Phase B: Empty list → all show")
        print("═══════════════════════════════════════════")

        settings.blockedApps = []
        assertTrue(settings.shouldShowPopup(for: nil), "nil → show")
        assertTrue(settings.shouldShowPopup(for: "com.apple.Safari"), "Safari → show")
        assertTrue(settings.shouldShowPopup(for: "com.google.Chrome"), "Chrome → show")

        // ═══════════════════════════════════════════════════════════════
        print("\n═══════════════════════════════════════════")
        print("  Phase C: Block specific apps")
        print("═══════════════════════════════════════════")

        settings.addToBlocked(safari)

        assertTrue(settings.shouldShowPopup(for: nil), "nil → show")
        assertFalse(settings.shouldShowPopup(for: "com.apple.Safari"), "Safari blocked → hide")
        assertTrue(settings.shouldShowPopup(for: "com.google.Chrome"), "Chrome not blocked → show")

        // ═══════════════════════════════════════════════════════════════
        print("\n═══════════════════════════════════════════")
        print("  Phase D: Add / Remove / Dedup")
        print("═══════════════════════════════════════════")

        settings.blockedApps = []
        settings.addToBlocked(chrome)
        assertEqual(settings.blockedApps.count, 1, "Add: count = 1")
        assertTrue(settings.isBlocked(bundleID: "com.google.Chrome"), "isBlocked Chrome = true")
        assertFalse(settings.isBlocked(bundleID: "com.apple.Safari"), "isBlocked Safari = false")

        settings.addToBlocked(chrome)
        assertEqual(settings.blockedApps.count, 1, "Dedup: still count = 1")

        settings.addToBlocked(safari)
        assertEqual(settings.blockedApps.count, 2, "Two apps: count = 2")

        settings.removeFromBlocked(bundleID: "com.google.Chrome")
        assertEqual(settings.blockedApps.count, 1, "Remove Chrome: count = 1")
        assertFalse(settings.isBlocked(bundleID: "com.google.Chrome"), "isBlocked Chrome = false")
        assertTrue(settings.isBlocked(bundleID: "com.apple.Safari"), "isBlocked Safari still = true")

        settings.removeFromBlocked(bundleID: "com.nonexistent.App")
        assertEqual(settings.blockedApps.count, 1, "Remove non-existent: count unchanged")

        // ═══════════════════════════════════════════════════════════════
        print("\n═══════════════════════════════════════════")
        print("  Phase E: Persistence")
        print("═══════════════════════════════════════════")

        settings.blockedApps = [safari]
        let s2 = AppFilterSettings(defaults: defaults)
        assertEqual(s2.blockedApps.count, 1, "Persist: count = 1")
        assertEqual(s2.blockedApps.first?.bundleID, "com.apple.Safari", "Persist: Safari")

        // ═══════════════════════════════════════════════════════════════
        print("\n═══════════════════════════════════════════")
        print("  Phase F: Running apps")
        print("═══════════════════════════════════════════")

        let running = settings.runningApplications()
        info("Found \(running.count) running regular apps")
        assertTrue(!running.isEmpty, "Non-empty")

        let copiedInList = running.contains(where: { $0.bundleID == Bundle.main.bundleIdentifier })
        assertFalse(copiedInList, "Copied not in list")

        var seen = Set<String>()
        let hasDupes = running.contains(where: { !seen.insert($0.bundleID).inserted })
        assertFalse(hasDupes, "No duplicates")

        // ═══════════════════════════════════════════════════════════════
        print("\n═══════════════════════════════════════════")
        print("  Phase G: Edge cases")
        print("═══════════════════════════════════════════")

        settings.blockedApps = []
        assertTrue(settings.shouldShowPopup(for: ""), "Empty string bid → show")

        for i in 0..<50 {
            settings.addToBlocked(AppFilterEntry(bundleID: "com.test.app\(i)", displayName: "T\(i)"))
        }
        assertEqual(settings.blockedApps.count, 50, "50 apps added")
        assertFalse(settings.shouldShowPopup(for: "com.test.app25"), "#25 blocked")
        assertTrue(settings.shouldShowPopup(for: "com.other.App"), "Unrelated shows")

        // ═══════════════════════════════════════════════════════════════
        print("\n═══════════════════════════════════════════")
        print("  Phase H: JSON codable")
        print("═══════════════════════════════════════════")

        let entries = [
            AppFilterEntry(bundleID: "a.b.c", displayName: "ABC"),
            AppFilterEntry(bundleID: "x.y.z", displayName: "XYZ"),
        ]
        let enc = JSONEncoder()
        let dec = JSONDecoder()
        guard let data = try? enc.encode(entries),
              let decoded = try? dec.decode([AppFilterEntry].self, from: data) else {
            fail("Encode/decode")
            print("\n  Results: \(passed)/\(total) passed")
            exit(1)
        }
        total += 1; passed += 1; pass("Encode + decode")
        assertEqual(decoded.count, 2, "Count = 2")
        assertEqual(decoded[0].bundleID, "a.b.c", "Entry 0 bundleID")
        assertEqual(decoded[0].displayName, "ABC", "Entry 0 name")

        // ── Cleanup ──────────────────────────────────────────────────
        defaults.removeObject(forKey: testKey)

        // ═══════════════════════════════════════════════════════════════
        print("\n═══════════════════════════════════════════")
        print("  Results: \(passed)/\(total) passed")
        print("═══════════════════════════════════════════")
        print(passed == total ? "\(G)ALL TESTS PASSED\(X)" : "\(R)\(total - passed) FAILED\(X)")
        exit(passed == total ? 0 : 1)
    }
}
