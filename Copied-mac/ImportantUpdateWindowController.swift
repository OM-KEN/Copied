import AppKit
import SwiftUI

final class ImportantUpdateWindowController: NSWindowController {
    private let openReleasePage: (URL) -> Void

    init(openReleasePage: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }) {
        self.openReleasePage = openReleasePage
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    @discardableResult
    func show(_ release: AppRelease) -> Bool {
        guard release.hasTrustedPageURL else { return false }
        close()
        let promptWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        promptWindow.title = "Copied"
        promptWindow.isReleasedWhenClosed = false
        let notes = ImportantUpdateNotes.attributedText(
            release.displayNotes(localization: Bundle.main.preferredLocalizations.first)
        )
        let notesHeight: CGFloat
        if notes.characters.isEmpty {
            notesHeight = 0
        } else {
            let notesView = NSHostingView(rootView: ImportantUpdateNotes(text: notes).frame(width: 392))
            let maximumHeight = max(0, min(320, (NSScreen.main?.visibleFrame.height ?? 720) - 240))
            notesHeight = min(notesView.fittingSize.height, maximumHeight)
        }
        let hostingView = NSHostingView(rootView: ImportantUpdatePrompt(
            release: release,
            notes: notes,
            notesHeight: notesHeight,
            onViewUpdate: { [weak self] in
                self?.openReleasePage(release.pageURL)
                self?.close()
            },
            onLater: { [weak self] in self?.close() }
        ))
        promptWindow.contentView = hostingView
        promptWindow.setContentSize(hostingView.fittingSize)
        promptWindow.center()
        window = promptWindow
        NSApp.activate(ignoringOtherApps: true)
        promptWindow.makeKeyAndOrderFront(nil)
        return promptWindow.isVisible
    }
}

private struct ImportantUpdatePrompt: View {
    let release: AppRelease
    let notes: AttributedString
    let notesHeight: CGFloat
    let onViewUpdate: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "重要更新"))
                        .font(.title2.weight(.semibold))
                    Text(String(format: String(localized: "发现新版本 %@"), release.version.description))
                    if notes.characters.isEmpty {
                        Text(String(localized: "此版本包含重要改进或修复，建议查看更新。"))
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !notes.characters.isEmpty {
                ScrollView {
                    ImportantUpdateNotes(text: notes)
                }
                .frame(height: notesHeight)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(String(localized: "稍后"), action: onLater)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "查看更新"), action: onViewUpdate)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 440)
    }
}

private struct ImportantUpdateNotes: View {
    let text: AttributedString

    var body: some View {
        Text(text)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.trailing, 8)
    }

    static func attributedText(_ markdown: String) -> AttributedString {
        var result = AttributedString()
        for (index, line) in markdown.components(separatedBy: "\n").enumerated() {
            let isHeading = line.hasPrefix("## ")
            let content: String
            if isHeading {
                content = String(line.dropFirst(3))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                content = "• " + line.dropFirst(2)
            } else {
                content = line
            }
            var attributedLine = (try? AttributedString(
                markdown: content,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(content)
            if isHeading { attributedLine.font = .headline }
            if index > 0 { result.append(AttributedString("\n")) }
            result.append(attributedLine)
        }
        return result
    }
}
