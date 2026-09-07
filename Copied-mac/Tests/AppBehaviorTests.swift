import AppKit
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

@main
struct AppBehaviorTests {
    static func main() throws {
        searchPreservesQuery()
        emptyResultsHaveNoCopyAction()
        try textFallbackPreservesUnicodeBoundary()
        try pluginReplacementIsValidatedBeforeInstallation()
        print("AppBehaviorTests: PASS")
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
