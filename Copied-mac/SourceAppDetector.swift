import AppKit

struct SourceAppInfo {
    let name: String
    let icon: NSImage?
    let bundleIdentifier: String?
}

enum SourceAppDetector {
    static func detect(for content: ClipboardContent?) -> SourceAppInfo {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return SourceAppInfo(
                name: String(localized: "未知应用"),
                icon: nil,
                bundleIdentifier: nil
            )
        }

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
            return SourceAppInfo(name: name, icon: frontApp.icon, bundleIdentifier: frontApp.bundleIdentifier)
        }

        return SourceAppInfo(
            name: frontApp.localizedName ?? String(localized: "未知应用"),
            icon: frontApp.icon,
            bundleIdentifier: frontApp.bundleIdentifier
        )
    }
}
