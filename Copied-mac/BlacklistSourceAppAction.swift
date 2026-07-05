import AppKit

/// Adds the source app of a clipboard change to the blacklist.
/// Shown in the toast's right-click context menu.
struct BlacklistSourceAppAction: ClipboardAction {
    let bundleID: String
    let appName: String

    var id: String { "blacklist-app" }
    var title: String { "屏蔽" }
    var systemImage: String { "bell.slash" }
    var menuTitle: String { "屏蔽此来源" }
    var performsInlineUpdate: Bool { false }

    func perform(content: ClipboardContent, controller: ToastWindowController?) {
        AppFilterSettings.shared.addToBlocked(
            AppFilterEntry(bundleID: bundleID, displayName: appName)
        )
    }
}
