import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

@main
enum ClipboardCopyComboTests {
    static func main() {
        fullContentIdentity()
        lazyDigestPreparation()
        adjacentConfirmedCopies()
        visiblePresentationLifetime()
        enabledByDefault()
        interruptedSequences()
        print("ClipboardCopyComboTests: PASS")
    }

    private static func fullContentIdentity() {
        let prefix = String(repeating: "Synthetic preview ", count: 100)
        expect(!sameIdentity(.text(prefix + "A"), .text(prefix + "B")),
               "matching previews were mistaken for matching full bodies")
        expect(!sameIdentity(.text("é"), .text("e\u{301}")),
               "different original text encodings were normalized")
        let first = URL(fileURLWithPath: "/tmp/Copied-combo-synthetic-A")
        let second = URL(fileURLWithPath: "/tmp/Copied-combo-synthetic-B")
        expect(sameIdentity(.files([first, second]), .files([second, first])),
               "the same complete file collection depended on order")
        expect(!sameIdentity(.files([first, second]), .files([first])),
               "an incomplete file collection matched the complete one")
    }

    private static func onWorker(_ work: @escaping () -> Void) {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            done.signal()
        }
        done.wait()
    }

    private static func sameIdentity(_ first: ClipboardCopyIdentity, _ second: ClipboardCopyIdentity) -> Bool {
        onWorker { first.prepareComparison(with: second) }
        return first == second
    }

    private static func lazyDigestPreparation() {
        let first = ClipboardCopyIdentity.text(String(repeating: "Synthetic lazy identity ", count: 1000))
        let second = ClipboardCopyIdentity.text(String(repeating: "Synthetic lazy identity ", count: 1000))
        expect(first.testingDigestComputationCount == 0 && second.testingDigestComputationCount == 0,
               "constructing an identity traversed the first body")
        expect(first != second && first.testingDigestComputationCount == 0,
               "main-thread equality prepared a digest")
        expect(sameIdentity(first, second), "worker preparation did not confirm identical complete bodies")
        expect(first.testingDigestComputationCount == 1 && second.testingDigestComputationCount == 1,
               "the first comparison did not prepare exactly two digests")
        expect(!first.testingRetainsRepresentation && !second.testingRetainsRepresentation,
               "prepared identities retained their source representations")
        let third = ClipboardCopyIdentity.text(String(repeating: "Synthetic lazy identity ", count: 1000))
        expect(sameIdentity(second, third) && second.testingDigestComputationCount == 1
               && third.testingDigestComputationCount == 1,
               "a later copy recalculated a memoized digest")
        let file = ClipboardCopyIdentity.files([URL(fileURLWithPath: "/tmp/Copied-lazy-file")])
        expect(!sameIdentity(third, file) && file.testingDigestComputationCount == 0,
               "different content kinds caused needless digest work")
        let session = ClipboardLoadSession(revision: .init(generation: 1, changeCount: 1), backingScale: 2)
        weak var released: ClipboardCopyIdentity?
        do {
            let identity = ClipboardCopyIdentity.text("Synthetic released identity")
            released = identity
            session.storeCopyIdentity(identity)
        }
        expect(released != nil, "the session failed to hold its first lazy representation")
        session.disableCopyIdentity()
        expect(released == nil, "disabling the session retained a lazy body reference")
    }

    private static func adjacentConfirmedCopies() {
        var combo = ClipboardCopyCombo()
        let identity = ClipboardCopyIdentity.text("Synthetic copied text")
        for index in 1...12 {
            let revision = ClipboardRevision(generation: UInt64(index), changeCount: index)
            expect(combo.observe(revision, at: Double(index) * 0.1), "new revision rejected")
            let hit = combo.confirm(identity, revision: revision)
            expect(hit?.count == index, "adjacent copy did not increment exactly once")
            expect(hit!.impulse <= 0.8 * 1.2, "motion exceeded the fixed 0.8 amplitude")
            expect(!combo.observe(revision, at: 100, continuesVisiblePresentation: false),
                   "duplicate observation replaced its timestamp or broke its sequence")
            expect(combo.confirm(identity, revision: revision) == nil,
                   "enrichment or a retry counted the revision twice")
        }
        let boundary = ClipboardRevision(generation: 13, changeCount: 13)
        combo.observe(boundary, at: 1.7)
        expect(combo.confirm(identity, revision: boundary)?.count == 13,
               "a visible presentation lost its sequence")
        let expired = ClipboardRevision(generation: 14, changeCount: 14)
        combo.observe(expired, at: 2.201, continuesVisiblePresentation: false)
        expect(combo.confirm(identity, revision: expired)?.count == 1,
               "a dismissed presentation retained the count")
    }

    private static func visiblePresentationLifetime() {
        let identity = ClipboardCopyIdentity.text("Synthetic boundary content")
        for gap in [0.1, 0.5, 0.8, 2.9, 60] {
            var combo = ClipboardCopyCombo()
            var lastCount = 0
            for index in 0..<3 {
                let revision = ClipboardRevision(generation: UInt64(index + 1), changeCount: index + 1)
                combo.observe(revision, at: 1 + Double(index) * gap)
                lastCount = combo.confirm(identity, revision: revision)!.count
            }
            expect(lastCount == 3, "elapsed time interrupted a still-visible presentation")
        }
    }

    private static func enabledByDefault() {
        let suite = "CopiedComboDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        expect(ClipboardCopyCombo.isEnabled(defaults: defaults), "the combo default was not enabled")
        defaults.set(false, forKey: ClipboardCopyCombo.enabledKey)
        expect(!ClipboardCopyCombo.isEnabled(defaults: defaults), "an explicit off value was ignored")
        defaults.set(true, forKey: ClipboardCopyCombo.enabledKey)
        expect(ClipboardCopyCombo.isEnabled(defaults: defaults), "the combo could not be re-enabled")
    }

    private static func interruptedSequences() {
        let identity = ClipboardCopyIdentity.text("Synthetic copied text")
        for interruption in 0..<6 {
            var combo = ClipboardCopyCombo()
            let first = ClipboardRevision(generation: 1, changeCount: 10)
            combo.observe(first, at: 1)
            expect(combo.confirm(identity, revision: first)?.count == 1, "first copy count")
            let middle = ClipboardRevision(generation: 2, changeCount: 11)
            switch interruption {
            case 0:
                combo.observe(middle, at: 1.1) // superseded before it could be identified
            case 1:
                combo.observe(middle, at: 1.1)
                _ = combo.confirm(nil, revision: middle) // unreadable or unknown
            case 2:
                combo.observe(middle, at: 1.1)
                _ = combo.confirm(.text("Synthetic different text"), revision: middle)
            case 3:
                combo.reset() // filtering, reminder, replay, interaction, or pause
            case 4:
                break // skipped generation and changeCount
            default:
                let skippedWrite = ClipboardRevision(generation: 2, changeCount: 15)
                combo.observe(skippedWrite, at: 1.1)
                expect(combo.confirm(identity, revision: skippedWrite)?.count == 1,
                       "a missed intermediate pasteboard write connected two copies")
            }
            let next = ClipboardRevision(generation: 3, changeCount: 12)
            combo.observe(next, at: 1.2)
            expect(combo.confirm(identity, revision: first) == nil, "old completion was accepted")
            expect(combo.confirm(identity, revision: next)?.count == 1,
                   "an interrupted sequence retained its count")
        }
    }
}
