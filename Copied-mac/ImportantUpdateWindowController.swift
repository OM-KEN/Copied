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
        let notes = ImportantUpdateNotes.paragraphs(
            release.displayNotes(localization: Bundle.main.preferredLocalizations.first)
        )
        let notesHeight: CGFloat
        if notes.isEmpty {
            notesHeight = 0
        } else {
            let notesView = NSHostingView(rootView: ImportantUpdateNotes(paragraphs: notes).frame(width: 392))
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
    let notes: [ImportantUpdateNotes.Paragraph]
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
                    if notes.isEmpty {
                        Text(String(localized: "此版本包含重要改进或修复，建议查看更新。"))
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !notes.isEmpty {
                ScrollView {
                    ImportantUpdateNotes(paragraphs: notes)
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
    struct Paragraph {
        let text: AttributedString
        let isBullet: Bool
    }

    let paragraphs: [Paragraph]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if paragraph.isBullet {
                        Text("•")
                            .accessibilityHidden(true)
                    }
                    Text(paragraph.text)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.body)
        .padding(.trailing, 8)
    }

    static func paragraphs(_ markdown: String) -> [Paragraph] {
        var result: [Paragraph] = []
        var lines: [String] = []
        var isBullet = false

        func append(_ content: String, isHeading: Bool = false, isBullet: Bool = false) {
            var text = (try? AttributedString(
                markdown: content,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(content)
            if isHeading { text.font = .headline }
            result.append(Paragraph(text: text, isBullet: isBullet))
        }

        func flush() {
            guard !lines.isEmpty else { return }
            append(lines.joined(separator: "\n"), isBullet: isBullet)
            lines.removeAll(keepingCapacity: true)
            isBullet = false
        }

        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else if line.hasPrefix("## ") {
                flush()
                append(String(line.dropFirst(3)), isHeading: true)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                isBullet = true
                lines.append(String(line.dropFirst(2)))
            } else {
                lines.append(line)
            }
        }
        flush()
        return result
    }
}
