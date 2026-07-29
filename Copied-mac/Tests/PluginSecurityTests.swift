import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func resolvedParentPath(for url: URL) -> String {
    url.deletingLastPathComponent()
        .resolvingSymlinksInPath()
        .appendingPathComponent(url.lastPathComponent)
        .path
}

private func makePlugin(
    in pluginsDirectory: URL,
    folderName: String,
    identifier: String
) throws -> URL {
    let pluginURL = pluginsDirectory.appendingPathComponent(folderName, isDirectory: true)
    try FileManager.default.createDirectory(at: pluginURL, withIntermediateDirectories: true)
    let manifest = #"{"identifier":"\#(identifier)"}"#
    try Data(manifest.utf8).write(to: pluginURL.appendingPathComponent("manifest.json"))
    return pluginURL
}

@main
struct PluginSecurityTests {
    static func main() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("CopiedPluginSecurityTests-\(UUID().uuidString)", isDirectory: true)
        let pluginsDirectory = temporaryRoot.appendingPathComponent("Plugins", isDirectory: true)
        try fileManager.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let requestedIdentifier = "com.copied.md-to-plaintext"
        expect(PluginRemovalPolicy.isValidIdentifier(requestedIdentifier), "reverse-domain identifier is valid")
        let actualPlugin = try makePlugin(
            in: pluginsDirectory,
            folderName: "md-to-plaintext.copiedplugin",
            identifier: requestedIdentifier
        )
        let mismatchedDecoy = try makePlugin(
            in: pluginsDirectory,
            folderName: "\(requestedIdentifier).copiedplugin",
            identifier: "com.example.different-plugin"
        )
        let expectedActualPath = resolvedParentPath(for: actualPlugin)

        let removed = try PluginRemovalPolicy.removeInstalledPlugins(
            identifier: requestedIdentifier,
            from: pluginsDirectory
        )
        expect(
            removed.map(resolvedParentPath(for:)) == [expectedActualPath],
            "uninstall resolves the actual folder through its manifest"
        )
        expect(!fileManager.fileExists(atPath: actualPlugin.path), "actual plugin folder is removed")
        expect(
            fileManager.fileExists(atPath: mismatchedDecoy.path),
            "a folder whose manifest belongs to another plugin is preserved"
        )

        let outsideSentinel = temporaryRoot.appendingPathComponent("outside-sentinel")
        try Data("keep".utf8).write(to: outsideSentinel)
        let traversalPlugin = try makePlugin(
            in: pluginsDirectory,
            folderName: "traversal.copiedplugin",
            identifier: "../outside-sentinel"
        )
        let absolutePathPlugin = try makePlugin(
            in: pluginsDirectory,
            folderName: "absolute-path.copiedplugin",
            identifier: outsideSentinel.path
        )

        expect(!PluginRemovalPolicy.isValidIdentifier("../outside-sentinel"), "parent traversal identifier is invalid")
        expect(!PluginRemovalPolicy.isValidIdentifier(outsideSentinel.path), "absolute-path identifier is invalid")

        let removedTraversal = try PluginRemovalPolicy.removeInstalledPlugins(
            identifier: "../outside-sentinel",
            from: pluginsDirectory
        )
        expect(
            removedTraversal.map(resolvedParentPath(for:)) == [resolvedParentPath(for: traversalPlugin)],
            "legacy traversal identifier removes only its in-root plugin folder"
        )
        let removedAbsolutePath = try PluginRemovalPolicy.removeInstalledPlugins(
            identifier: outsideSentinel.path,
            from: pluginsDirectory
        )
        expect(
            removedAbsolutePath.map(resolvedParentPath(for:)) == [resolvedParentPath(for: absolutePathPlugin)],
            "legacy absolute identifier removes only its in-root plugin folder"
        )
        expect(fileManager.fileExists(atPath: outsideSentinel.path), "escape target remains untouched")
        expect(fileManager.fileExists(atPath: mismatchedDecoy.path), "invalid identifier cannot remove another plugin")

        let normalRegex = try NSRegularExpression(pattern: #"([a-z]+)-(\d+)"#)
        let normalText = "abc-12 def-34"
        let normalRange = NSRange(normalText.startIndex..., in: normalText)
        switch BoundedRegularExpression.firstMatch(
            normalRegex,
            in: normalText,
            range: normalRange,
            deadline: RegexDeadline(timeLimit: 0.050)
        ) {
        case .match(let match):
            expect(
                (normalText as NSString).substring(with: match.range) == "abc-12",
                "bounded firstMatch preserves normal match semantics"
            )
        case .noMatch, .limitExceeded:
            expect(false, "bounded firstMatch finds a normal match")
        }

        switch BoundedRegularExpression.replacingMatches(
            normalRegex,
            in: normalText,
            range: normalRange,
            withTemplate: "$2:$1",
            deadline: RegexDeadline(timeLimit: 0.050)
        ) {
        case .success(let output):
            expect(output == "12:abc 34:def", "bounded replacement preserves capture semantics")
        case .limitExceeded:
            expect(false, "normal replacement stays within its budget")
        }

        let nestedQuantifier = try NSRegularExpression(pattern: #"^(a+)+$"#)
        let hostileText = String(repeating: "a", count: 50_000) + "!"
        let hostileRange = NSRange(hostileText.startIndex..., in: hostileText)

        var started = ProcessInfo.processInfo.systemUptime
        let matchResult = BoundedRegularExpression.firstMatch(
            nestedQuantifier,
            in: hostileText,
            range: hostileRange,
            deadline: RegexDeadline(timeLimit: 0.050)
        )
        var elapsed = ProcessInfo.processInfo.systemUptime - started
        if case .limitExceeded = matchResult {
            // Expected.
        } else {
            expect(false, "nested-quantifier firstMatch is interrupted")
        }
        expect(elapsed < 1.0, "nested-quantifier firstMatch returns within a reasonable wall-clock bound")

        started = ProcessInfo.processInfo.systemUptime
        let replacementResult = BoundedRegularExpression.replacingMatches(
            nestedQuantifier,
            in: hostileText,
            range: hostileRange,
            withTemplate: "safe",
            deadline: RegexDeadline(timeLimit: 0.050)
        )
        elapsed = ProcessInfo.processInfo.systemUptime - started
        if case .limitExceeded = replacementResult {
            // Expected.
        } else {
            expect(false, "nested-quantifier replacement is interrupted")
        }
        expect(elapsed < 1.0, "nested-quantifier replacement returns within a reasonable wall-clock bound")

        print("PluginSecurityTests: PASS")
    }
}
