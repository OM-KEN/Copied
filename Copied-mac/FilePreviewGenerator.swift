import AppKit
import QuickLookThumbnailing

/// Generates file-content thumbnails using the system Quick Look thumbnail generator.
/// Works for all file types that macOS can preview (PDF, video, audio, text, Office docs, etc.).
/// Caching is handled entirely by the system-level QLThumbnailGenerator (disk + memory).
final class FilePreviewGenerator {
    static let shared = FilePreviewGenerator()

    private init() {}

    /// Asynchronously generate a thumbnail for a file URL.
    /// - Parameters:
    ///   - url: The file URL to generate a thumbnail for.
    ///   - size: The desired thumbnail size in points (will be scaled for retina).
    ///   - completion: Called on the main thread with the thumbnail, or nil on failure.
    func generateThumbnail(
        for url: URL,
        size: CGSize,
        completion: @escaping (NSImage?) -> Void
    ) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
            DispatchQueue.main.async {
                if let rep = representation {
                    completion(rep.nsImage)
                } else {
                    if let error {
                        NSLog("Copied: QLThumbnailGenerator failed for \(url.lastPathComponent): \(error.localizedDescription)")
                    }
                    completion(nil)
                }
            }
        }
    }

    /// Cancel an in-flight thumbnail request for the given URL.
    func cancelRequest(for url: URL) {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: .zero,
            scale: 1.0,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.cancel(request)
    }
}
