import AppKit
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

@main
struct AppBehaviorTests {
    static func main() throws {
        settingsRequestsSurviveAbsentMenu()
        pauseControlsMonitorLifetime()
        try reminderRejectsCopiedContent()
        closingReminderPreservesCopySoundWork()
        searchPreservesQuery()
        emptyResultsHaveNoCopyAction()
        try textFallbackPreservesUnicodeBoundary()
        try pluginReplacementIsValidatedBeforeInstallation()
        print("AppBehaviorTests: PASS")
    }

    private static func settingsRequestsSurviveAbsentMenu() {
        SettingsNavigation.requestSettings()
        var opens = 0
        SettingsNavigation.installSettingsOpener { opens += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        expect(opens == 1, "request before scene registration was lost")
        SettingsNavigation.requestSettings()
        expect(opens == 2, "registered settings action cannot reopen without menu")
        SettingsNavigation.installSettingsOpener { opens += 10 }
        expect(opens == 2, "installing commands opened Settings on cold launch")
        SettingsNavigation.requestSettings()
        expect(opens == 12, "new scene action was not retained")
        SettingsNavigation.installSettingsOpener {}
    }

    private static func pauseControlsMonitorLifetime() {
        let controller = ToastWindowController()
        let monitor = ClipboardMonitor(toastController: controller)
        let delegate = AppDelegate(monitor: monitor)
        delegate.setPaused(false)
        expect(monitor.isRunning, "resume did not start the production monitor timer")
        delegate.setPaused(true)
        expect(!monitor.isRunning, "pause left the production monitor timer running")
        delegate.setPaused(false)
        expect(monitor.isRunning, "resume after pause did not restart monitoring")
        delegate.setPaused(true)
    }

    private static func reminderRejectsCopiedContent() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Synthetic private copied content", forType: .string)
        let oldRevision = ClipboardRevision(generation: 10, changeCount: pasteboard.changeCount)
        guard case let .content(_, content) = ClipboardBaseReader.read(
            session: ClipboardLoadSession(revision: oldRevision, backingScale: 2),
            pasteboard: pasteboard
        ) else { fatalError("synthetic reminder fixture read failed") }
        let source = SourceAppInfo(name: "Synthetic source", icon: nil, bundleIdentifier: "test.synthetic")
        let model = ToastViewModel()
        model.configure(with: content, source: source)
        model.showsUpdateReminder = true
        model.thumbnailImage = NSImage(size: NSSize(width: 1, height: 1))
        model.detectedColor = .red
        model.resultOverlay = ResultOverlay(displayText: "Synthetic result", copyText: "Synthetic result")
        let action = SearchTextAction(text: "synthetic")
        model.applyActions(primary: action, menu: [action])
        for revision in [oldRevision, ClipboardRevision(generation: 11, changeCount: 999)] {
            model.configureReminderNotice(revision: revision)
            expect(!model.acceptsContentUpdate(revision: revision), "base read can overwrite reminder")
            expect(!model.acceptsContentUpdate(revision: oldRevision), "stale base read can overwrite reminder")
            model.applyEnrichment(content)
            model.applyActions(primary: action, menu: [action])
            model.showLoadingIfPending()
            model.configureFailure()
            expect(model.phase == .reminder && model.previewText == String(localized: "已复制"),
                   "late update changed generic reminder")
            expect(model.sourceAppName.isEmpty && model.sourceBundleID == nil && model.sourceAppIcon == nil,
                   "reminder leaked source identity")
            expect(model.rawContent == nil && model.thumbnailImage == nil && model.detailInfo.isEmpty && model.detectedColor == nil && model.resultOverlay == nil,
                   "reminder retained content or thumbnail")
            expect(model.primaryAction == nil && model.menuActions.isEmpty && model.blacklistAction == nil,
                   "reminder exposes an action")
            expect(!model.canExpand && !model.showsUpdateReminder && model.expandedText.isEmpty,
                   "reminder exposes expanded content or update")
            expect(model.iconSymbolName == "checkmark.circle.fill", "reminder lost generic icon")
        }
        model.configurePending(revision: oldRevision, source: source)
        expect(model.acceptsContentUpdate(revision: oldRevision), "switching back to full card is blocked")
        model.configure(with: content, source: source)
        expect(model.isContentReady && model.rawContent != nil, "full card no longer accepts real content")
    }

    private static func closingReminderPreservesCopySoundWork() {
        let controller = ToastWindowController()
        let revision = ClipboardRevision(generation: 12, changeCount: 1000)
        var cancelled: [ClipboardRevision] = []
        controller.onRevisionResourcesShouldCancel = { cancelled.append($0) }
        controller.showReminder(revision: revision)
        controller.dismissSilently(revision: revision)
        expect(cancelled.isEmpty, "closing a reminder cancelled the base read and copy sound timeout")

        let source = SourceAppInfo(name: "Synthetic source", icon: nil, bundleIdentifier: "test.synthetic")
        controller.showPending(revision: revision, source: source)
        controller.dismissSilently(revision: revision)
        expect(cancelled == [revision], "closing a full card no longer cancels its content work")
    }

    private static func searchPreservesQuery() {
        for engine in ["google", "baidu", "bing", "duckduckgo", "unknown"] {
            for text in ["a&b#c+d=e", "空 格 %20 /?", "👨‍👩‍👧‍👦\nSwift"] {
                let url = SearchTextAction.url(for: text, engine: engine)!
                let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                expect(parts.queryItems?.count == 1, "search introduced extra query parameters")
                expect(parts.queryItems?.first?.value == text, "search changed the copied query")
                expect(parts.queryItems?.first?.name == (engine == "baidu" ? "wd" : "q"),
                       "search engine query parameter changed")
                expect(parts.fragment == nil, "search query escaped into a fragment")
                expect(!parts.percentEncodedQuery!.contains("+"), "literal plus may be decoded as space")
            }
        }
    }

    private static func emptyResultsHaveNoCopyAction() {
        expect(ResultOverlay(displayText: "empty", copyText: "").copyText == nil,
               "empty transform still offers Copy")
        expect(ResultOverlay(displayText: "error", copyText: nil).copyText == nil,
               "error result offers Copy")
        expect(ResultOverlay(displayText: "space", copyText: " ").copyText == " ",
               "nonempty whitespace result changed")
    }

    private static func textFallbackPreservesUnicodeBoundary() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for character in ["中", "👨‍👩‍👧‍👦", "e\u{301}"] {
            for length in [49, 50] {
                let text = String(repeating: character, count: length)
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                let revision = ClipboardRevision(generation: 1, changeCount: pasteboard.changeCount)
                guard case var .content(_, content) = ClipboardBaseReader.read(
                    session: ClipboardLoadSession(revision: revision, backingScale: 2),
                    pasteboard: pasteboard
                ) else { fatalError("synthetic text read failed") }
                content.detections = [ContentDetection(kind: .swift, value: text)]
                let result = ActionResolver.resolve(for: content)
                expect(content.textLength == length, "base reader character count changed")
                expect(length == 49 ? result.primary is SearchTextAction : result.primary is SaveFileAction,
                       "pure code lost its Unicode-aware fallback action")
            }
        }
    }

    private static func pluginReplacementIsValidatedBeforeInstallation() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("Copied-plugin-test-\(UUID().uuidString)")
        let source = base.appendingPathComponent("source/Synthetic.copiedplugin")
        let installed = base.appendingPathComponent("installed")
        let suite = "CopiedPluginTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? manager.removeItem(at: base)
        }
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = #"{"name":"Synthetic","identifier":"com.copied.synthetic-test","version":"1.0.0","category":"entity","icon":"","label":"","priority":100}"#
        let rules = #"{"version":"1","rules":[{"id":"synthetic","pattern":"^synthetic$"}]}"#
        try manifest.write(to: source.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try rules.write(to: source.appendingPathComponent("rules.json"), atomically: true, encoding: .utf8)
        let registry = DetectionRegistry(defaults: defaults)
        let loader = PluginLoader(directory: installed, registry: registry, defaults: defaults)
        for _ in 0..<2 { _ = try loader.installPlugin(from: source) }
        expect(registry.detectAll(in: "synthetic").count == 1, "reinstall duplicated a detector")
        expect(loader.installedPluginIDs.count == 1, "reinstall duplicated preferences")
        let destination = loader.scanPlugins().first!
        _ = try loader.installPlugin(from: destination)
        let renamed = source.deletingLastPathComponent().appendingPathComponent("Renamed.copiedplugin")
        try manager.copyItem(at: source, to: renamed)
        _ = try loader.installPlugin(from: renamed)
        expect(loader.scanPlugins() == [destination], "same identifier created multiple installed directories")
        try "invalid".write(to: source.appendingPathComponent("rules.json"), atomically: true, encoding: .utf8)
        do {
            _ = try loader.installPlugin(from: source)
            fatalError("invalid update accepted")
        } catch {}
        let retainedRules = try String(contentsOf: destination.appendingPathComponent("rules.json"), encoding: .utf8)
        expect(retainedRules == rules,
               "invalid update destroyed the old plugin")
        expect(registry.detectAll(in: "synthetic").count == 1, "invalid update changed active detection")
        let link = base.appendingPathComponent("Link.copiedplugin")
        try manager.createSymbolicLink(at: link, withDestinationURL: renamed)
        do { _ = try loader.installPlugin(from: link); fatalError("symbolic-link plugin accepted") } catch {}
        loader.uninstallPlugin(identifier: "com.copied.synthetic-test")
        expect(loader.scanPlugins().isEmpty && registry.detectAll(in: "synthetic").isEmpty,
               "uninstall left active plugin state")
        let residue = try manager.contentsOfDirectory(atPath: installed.path)
        expect(residue.isEmpty, "staging residue remains")
    }
}
