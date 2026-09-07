import Foundation

// MARK: - Plugin Loader

/// 负责扫描、验证、加载 `.copiedplugin` 文件夹。
final class PluginLoader {

    /// 插件安装目录。
    static let pluginsDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("Copied/Plugins", isDirectory: true)
    }()

    private let directory: URL
    private let registry: DetectionRegistry
    private let defaults: UserDefaults

    init(directory: URL = pluginsDirectory, registry: DetectionRegistry = .shared, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.registry = registry
        self.defaults = defaults
    }

    // MARK: - Scanning

    /// 扫描插件目录，返回所有 `.copiedplugin` 文件夹的 URL。
    func scanPlugins() -> [URL] {
        PluginRemovalPolicy.pluginDirectories(in: directory)
    }

    // MARK: - Loading

    /// 读取并验证插件；返回尚未注册的检测器，失败返回 nil。
    private func readPlugin(at url: URL) -> PluginDetector? {
        let manifestURL = url.appendingPathComponent("manifest.json")
        let rulesURL = url.appendingPathComponent("rules.json")

        // 1. Read and parse manifest
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: manifestData) else {
            NSLog("Copied: failed to load manifest for \(url.lastPathComponent)")
            return nil
        }
        guard PluginRemovalPolicy.isValidIdentifier(manifest.identifier) else {
            NSLog("Copied: rejected unsafe plugin identifier in \(url.lastPathComponent)")
            return nil
        }

        // 2. Read and compile rules
        guard let rules = loadRules(at: rulesURL) else {
            NSLog("Copied: failed to load rules for \(manifest.name)")
            return nil
        }

        let compiledRules = rules.compactMap { rule -> CompiledRule? in
            do {
                return try CompiledRule(rule: rule)
            } catch {
                NSLog("Copied: invalid regex in rule '\(rule.id)': \(error.localizedDescription)")
                return nil
            }
        }

        guard !compiledRules.isEmpty else {
            NSLog("Copied: no valid rules in plugin '\(manifest.name)'")
            return nil
        }

        // 3. Build ContentKind and detector
        let kind = manifest.makeContentKind()
        let detector = PluginDetector(
            kind: kind,
            priority: manifest.priority,
            rules: compiledRules
        )

        return detector
    }

    func loadPlugin(at url: URL) -> ContentKind? {
        guard let detector = readPlugin(at: url) else { return nil }
        register(detector)
        return detector.kind
    }

    private func register(_ detector: PluginDetector) {
        registry.register(detector)
        var installed = defaults.stringArray(forKey: "installedPlugins") ?? []
        if !installed.contains(detector.kind.id) {
            installed.append(detector.kind.id)
            defaults.set(installed, forKey: "installedPlugins")
        }
    }

    /// 加载所有已安装的插件。
    func loadAllPlugins() {
        let plugins = scanPlugins()
        for url in plugins {
            _ = loadPlugin(at: url)
        }
        NSLog("Copied: loaded \(plugins.count) plugin(s)")
    }

    // MARK: - Installation

    /// 安装插件：将 `.copiedplugin` 文件夹复制到插件目录。
    /// 返回成功加载的 ContentKind，失败抛错。
    func installPlugin(from sourceURL: URL) throws -> ContentKind {
        let manager = FileManager.default
        guard sourceURL.pathExtension == "copiedplugin",
              let values = try? sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent(".install-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: sourceURL, to: staged)
        guard let detector = readPlugin(at: staged) else {
            throw PluginError.invalidPlugin(reason: String(localized: "manifest.json 或 rules.json 格式不正确"))
        }
        let existing = PluginRemovalPolicy.installedDirectories(identifier: detector.kind.id, in: directory)
        let destination = existing.first ?? directory.appendingPathComponent(sourceURL.lastPathComponent)
        if manager.fileExists(atPath: destination.path) {
            guard existing.contains(destination) else { throw CocoaError(.fileWriteFileExists) }
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: destination)
        }
        register(detector)
        registry.setEnabled(true, kindID: detector.kind.id)
        return detector.kind
    }

    /// 卸载插件：从 DetectionRegistry 移除 + 删除文件。
    func uninstallPlugin(identifier: String) {
        do {
            _ = try PluginRemovalPolicy.removeInstalledPlugins(
                identifier: identifier,
                from: directory
            )
        } catch {
            NSLog("Copied: failed to remove plugin '\(identifier)': \(error.localizedDescription)")
            return
        }

        // Remove from registry
        registry.unregisterPlugin(identifier: identifier)
        registry.setEnabled(true, kindID: identifier) // clear disabled state

        // Remove from installed list
        var installed = defaults.stringArray(forKey: "installedPlugins") ?? []
        installed.removeAll { $0 == identifier }
        defaults.set(installed, forKey: "installedPlugins")

        NSLog("Copied: uninstalled plugin '\(identifier)'")
    }

    /// 已安装的插件 identifier 列表。
    var installedPluginIDs: [String] {
        defaults.stringArray(forKey: "installedPlugins") ?? []
    }

    // MARK: - Private

    private func loadRules(at url: URL) -> [PluginRule]? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(PluginRulesFile.self, from: data) else {
            return nil
        }
        return file.rules
    }
}

// MARK: - Plugin Detector

/// 从 rules.json 编译而来的检测器。
struct PluginDetector: ContentDetectorProtocol {
    let kind: ContentKind
    let priority: Int
    let rules: [CompiledRule]

    func detect(in text: String) -> ContentDetection? {
        let deadline = RegexDeadline(timeLimit: BoundedRegularExpression.defaultTimeLimit)
        for rule in rules {
            let range = NSRange(text.startIndex..., in: text)
            switch BoundedRegularExpression.firstMatch(
                rule.regex,
                in: text,
                range: range,
                deadline: deadline
            ) {
            case .match(let match):
                let value = extractValue(from: match, group: rule.extractGroup, in: text)
                return ContentDetection(
                    kind: kind,
                    value: value,
                    metadata: ["ruleId": rule.id],
                    pluginActionTemplate: rule.actionTemplate
                )
            case .noMatch:
                continue
            case .limitExceeded:
                NSLog("Copied: plugin detector '\(kind.id)' exceeded regex budget")
                return nil
            }
        }
        return nil
    }

    /// 从匹配结果中提取捕获组。
    private func extractValue(from match: NSTextCheckingResult, group: String?, in text: String) -> String? {
        guard let group = group else {
            // No group specified → use full match
            let range = match.range
            guard range.location != NSNotFound else { return nil }
            return (text as NSString).substring(with: range)
        }

        // Named group → lookup by name
        let nsText = text as NSString
        let namedRange = match.range(withName: group)
        if namedRange.location != NSNotFound {
            return nsText.substring(with: namedRange)
        }

        // Numeric group → parse as Int
        if let groupNum = Int(group), groupNum < match.numberOfRanges {
            let groupRange = match.range(at: groupNum)
            if groupRange.location != NSNotFound {
                return nsText.substring(with: groupRange)
            }
        }

        return nil
    }
}

// MARK: - Errors

enum PluginError: LocalizedError {
    case invalidPlugin(reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidPlugin(let reason):
            return String(localized: "插件无效：") + reason
        }
    }
}
