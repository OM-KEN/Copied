import AppKit
import QuickLookThumbnailing

/// Owns the exact QL request object so cancellation cannot accidentally target a surrogate.
final class FilePreviewGenerator {
    struct Backend {
        let generate: (
            QLThumbnailGenerator.Request,
            @escaping (QLThumbnailRepresentation?) -> Void
        ) -> Void
        let cancel: (QLThumbnailGenerator.Request) -> Void

        static let live = Backend(
            generate: { request, completion in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                    representation, _ in
                    completion(representation)
                }
            },
            cancel: { QLThumbnailGenerator.shared.cancel($0) }
        )
    }

    private struct InFlight {
        let revision: ClipboardRevision
        let request: QLThumbnailGenerator.Request
        let started: TimeInterval
        let completion: (UUID, ClipboardRevision, NSImage?) -> Void
    }

    static let shared = FilePreviewGenerator()
    static let resultDeadline: TimeInterval = 2

    private let backend: Backend
    private let lock = NSLock()
    private var requests: [UUID: InFlight] = [:]

    init(backend: Backend = .live) {
        self.backend = backend
    }

    @discardableResult
    func generateThumbnail(
        for url: URL,
        size: CGSize,
        scale: CGFloat,
        revision: ClipboardRevision,
        completion: @escaping (UUID, ClipboardRevision, NSImage?) -> Void
    ) -> UUID {
        let token = UUID()
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        let inFlight = InFlight(
            revision: revision,
            request: request,
            started: ProcessInfo.processInfo.systemUptime,
            completion: completion
        )
        lock.withLock { requests[token] = inFlight }
        backend.generate(request) { [weak self] representation in
            self?.receive(representation, token: token)
        }
        return token
    }

    func cancel(token: UUID) {
        let request = lock.withLock { requests.removeValue(forKey: token)?.request }
        if let request { backend.cancel(request) }
    }

    private func receive(_ representation: QLThumbnailRepresentation?, token: UUID) {
        guard let inFlight = lock.withLock({ requests.removeValue(forKey: token) }) else {
            return
        }
        let withinDeadline = ProcessInfo.processInfo.systemUptime - inFlight.started
            <= Self.resultDeadline
        let image = withinDeadline ? representation?.nsImage : nil
        DispatchQueue.main.async {
            inFlight.completion(token, inFlight.revision, image)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
