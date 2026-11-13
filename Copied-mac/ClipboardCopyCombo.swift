import Foundation
import CryptoKit

/// Retain an already-read representation without traversing it on the first copy.
/// The base lane prepares memoized digests only when a later copy needs comparison.
final class ClipboardCopyIdentity: Equatable {
    private enum Representation {
        case text(String)
        case files([URL])
    }

    private let kind: UInt8
    private let condition = NSCondition()
    private var representation: Representation?
    private var digest: SHA256.Digest?
    private var preparing = false
    var hasPreparedDigest: Bool { preparedDigest != nil }
#if COPIED_TESTING
    private var digestComputationCount = 0
    var testingWillPrepareDigest: (() -> Void)?
    var testingDigestComputationCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return digestComputationCount
    }
    var testingRetainsRepresentation: Bool {
        condition.lock()
        defer { condition.unlock() }
        return representation != nil
    }
#endif

    private init(kind: UInt8, representation: Representation) {
        self.kind = kind
        self.representation = representation
    }

    static func text(_ text: String) -> Self {
        Self(kind: 0, representation: .text(text))
    }

    static func files(_ urls: [URL]) -> Self {
        Self(kind: 2, representation: .files(urls))
    }

    /// Never called by equality or by the main-thread reducer.
    func prepareComparison(with other: ClipboardCopyIdentity) {
        precondition(!Thread.isMainThread)
        guard kind == other.kind else { return }
        prepareDigest()
        other.prepareDigest()
    }

    static func == (lhs: ClipboardCopyIdentity, rhs: ClipboardCopyIdentity) -> Bool {
        if lhs === rhs { return true }
        guard lhs.kind == rhs.kind, let left = lhs.preparedDigest,
              let right = rhs.preparedDigest else { return false }
        return left == right
    }

    private var preparedDigest: SHA256.Digest? {
        condition.lock()
        defer { condition.unlock() }
        return digest
    }

    private func prepareDigest() {
        condition.lock()
        while preparing { condition.wait() }
        guard digest == nil, let representation else {
            condition.unlock()
            return
        }
        preparing = true
        condition.unlock()

#if COPIED_TESTING
        testingWillPrepareDigest?()
#endif
        let result: SHA256.Digest
        switch representation {
        case let .text(text):
            var hash = SHA256()
            Self.append(text, to: &hash)
            result = hash.finalize()
        case let .files(urls):
            var hash = SHA256()
            for url in urls.map(\.absoluteString).sorted() {
                var length = UInt64(url.utf8.count).bigEndian
                withUnsafeBytes(of: &length) { hash.update(bufferPointer: $0) }
                Self.append(url, to: &hash)
            }
            result = hash.finalize()
        }

        condition.lock()
        digest = result
        self.representation = nil
        preparing = false
#if COPIED_TESTING
        digestComputationCount += 1
#endif
        condition.broadcast()
        condition.unlock()
    }

    private static func append(_ text: String, to hash: inout SHA256) {
        if text.utf8.withContiguousStorageIfAvailable({
            hash.update(bufferPointer: UnsafeRawBufferPointer($0))
        }) != nil { return }

        // Noncontiguous strings use a fixed-size buffer rather than duplicating the body.
        var bytes: [UInt8] = []
        bytes.reserveCapacity(65_536)
        for byte in text.utf8 {
            bytes.append(byte)
            if bytes.count == 65_536 {
                bytes.withUnsafeBytes { hash.update(bufferPointer: $0) }
                bytes.removeAll(keepingCapacity: true)
            }
        }
        bytes.withUnsafeBytes { hash.update(bufferPointer: $0) }
    }
}

struct ClipboardCopyCombo {
    static let enabledKey = "copyComboEnabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    struct Hit {
        let count: Int
        let impulse: Double
        let direction: Double
    }

    private struct Observation {
        let revision: ClipboardRevision
        let time: TimeInterval
        var confirmed = false
    }

    private struct ConfirmedCopy {
        let identity: ClipboardCopyIdentity
        let time: TimeInterval
        let count: Int
        let charge: Double
    }

    private var observation: Observation?
    private var previous: ConfirmedCopy?

    var comparisonIdentity: ClipboardCopyIdentity? { previous?.identity }

    func awaitsConfirmation(_ revision: ClipboardRevision) -> Bool {
        observation?.revision == revision && observation?.confirmed == false
    }

    @discardableResult
    mutating func observe(
        _ revision: ClipboardRevision,
        at time: TimeInterval,
        continuesVisiblePresentation: Bool = true
    ) -> Bool {
        if let observation {
            guard revision.generation > observation.revision.generation else { return false }
            // A skipped write or an unconfirmed intervening revision breaks the sequence.
            if !observation.confirmed
                || revision.generation - observation.revision.generation != 1
                || revision.changeCount - observation.revision.changeCount != 1 {
                previous = nil
            }
        }
        if !continuesVisiblePresentation { previous = nil }
        observation = Observation(revision: revision, time: time)
        return true
    }

    mutating func confirm(
        _ identity: ClipboardCopyIdentity?,
        revision: ClipboardRevision
    ) -> Hit? {
        guard var observation, observation.revision == revision,
              !observation.confirmed else { return nil }
        observation.confirmed = true
        self.observation = observation
        guard let identity else {
            previous = nil
            return nil
        }

        let count: Int
        let charge: Double
        if let previous, previous.identity == identity {
            count = previous.count < Int.max ? previous.count + 1 : previous.count
            charge = min(1, previous.charge * exp(-(observation.time - previous.time) / 0.65) + 0.3)
        } else {
            count = 1
            charge = 0.3
        }
        previous = ConfirmedCopy(identity: identity, time: observation.time, count: count, charge: charge)
        return Hit(
            count: count,
            impulse: 0.8 * (0.7 + charge * 0.5),
            direction: count.isMultiple(of: 2) ? 1 : -1
        )
    }

    mutating func reset() {
        observation = nil
        previous = nil
    }
}
