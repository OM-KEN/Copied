import AppKit

struct SourceAppInfo {
    let name: String
    let icon: NSImage?
    let bundleIdentifier: String?
}

enum SourceAppDetector {
    private static let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    /// Materialize the source icon when an app becomes active, before a copy arrives.
    static func prepareIcon(for application: NSRunningApplication?) {
        guard let application else { return }
        _ = cachedIcon(for: application)
    }

    static func detect(for content: ClipboardContent?) -> SourceAppInfo {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return SourceAppInfo(
                name: String(localized: "未知应用"),
                icon: nil,
                bundleIdentifier: nil
            )
        }

        let icon = cachedIcon(for: frontApp)
        let isFinder = frontApp.bundleIdentifier == "com.apple.finder"

        // Finder file copy → show parent folder instead of "访达"
        if isFinder, let urls = content?.fileURLs, !urls.isEmpty {
            let folders = urls.map { $0.deletingLastPathComponent().lastPathComponent }
            let unique = Array(Set(folders))
            let name = if unique.count == 1 {
                unique[0]
            } else {
                String(localized: "\(unique.count)个文件夹")
            }
            return SourceAppInfo(name: name, icon: icon, bundleIdentifier: frontApp.bundleIdentifier)
        }

        return SourceAppInfo(
            name: frontApp.localizedName ?? String(localized: "未知应用"),
            icon: icon,
            bundleIdentifier: frontApp.bundleIdentifier
        )
    }

    private static func cachedIcon(for application: NSRunningApplication) -> NSImage? {
        let cacheKey = (
            application.bundleIdentifier
                ?? application.bundleURL?.path
                ?? "pid:\(application.processIdentifier)"
        ) as NSString
        if let icon = iconCache.object(forKey: cacheKey) {
            return icon
        }
        guard let icon = application.icon else { return nil }
        iconCache.setObject(icon, forKey: cacheKey)
        return icon
    }
}
