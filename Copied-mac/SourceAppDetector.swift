import AppKit

struct SourceAppInfo {
    let name: String
    let icon: NSImage?
    let bundleIdentifier: String?
}

enum SourceAppDetector {
    private static let sourceLock = NSLock()
    private static var latestSource: SourceAppInfo?
    private static let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    /// Materialize the source icon when an app becomes active, before a copy arrives.
    static func prepareIcon(for application: NSRunningApplication?) {
        guard let application else { return }
        let source = SourceAppInfo(
            name: application.localizedName ?? String(localized: "未知应用"),
            icon: cachedIcon(for: application),
            bundleIdentifier: application.bundleIdentifier
        )
        storeCachedSnapshot(source)
    }

    static func detect() -> SourceAppInfo {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return SourceAppInfo(
                name: String(localized: "未知应用"),
                icon: nil,
                bundleIdentifier: nil
            )
        }

        let source = SourceAppInfo(
            name: frontApp.localizedName ?? String(localized: "未知应用"),
            icon: cachedIcon(for: frontApp),
            bundleIdentifier: frontApp.bundleIdentifier
        )
        storeCachedSnapshot(source)
        return source
    }

    /// First-frame source lookup. It only reads the activation-maintained memory cache.
    static func cachedSnapshot() -> SourceAppInfo {
        sourceLock.lock()
        let source = latestSource
        sourceLock.unlock()
        return source ?? SourceAppInfo(
            name: String(localized: "未知应用"),
            icon: nil,
            bundleIdentifier: nil
        )
    }

    /// Adds content-derived Finder context without consulting NSWorkspace or the file system.
    static func enriching(_ source: SourceAppInfo, with content: ClipboardContent) -> SourceAppInfo {
        guard source.bundleIdentifier == "com.apple.finder",
              let urls = content.fileURLs, !urls.isEmpty else { return source }
        let folders = Set(urls.map { $0.deletingLastPathComponent().lastPathComponent })
        let name = folders.count == 1
            ? (folders.first ?? source.name)
            : String(localized: "\(folders.count)个文件夹")
        return SourceAppInfo(
            name: name,
            icon: source.icon,
            bundleIdentifier: source.bundleIdentifier
        )
    }

    private static func cachedIcon(for application: NSRunningApplication) -> NSImage? {
        let cacheKey = cacheKey(for: application)
        if let icon = iconCache.object(forKey: cacheKey) {
            return icon
        }
        guard let icon = application.icon else { return nil }
        iconCache.setObject(icon, forKey: cacheKey)
        return icon
    }

    private static func storeCachedSnapshot(_ source: SourceAppInfo) {
        sourceLock.lock()
        latestSource = source
        sourceLock.unlock()
    }

    private static func cacheKey(for application: NSRunningApplication) -> NSString {
        (application.bundleIdentifier ?? "pid:\(application.processIdentifier)") as NSString
    }
}
