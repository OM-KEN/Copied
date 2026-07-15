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

    // MARK: - Scanning

    /// 扫描插件目录，返回所有 `.copiedplugin` 文件夹的 URL。
    func scanPlugins() -> [URL] {
        let dir = Self.pluginsDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            return contents.filter { url in
                url.pathExtension == "copiedplugin"
                    && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
        } catch {
            NSLog("Copied: failed to scan plugins directory: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Loading

    /// 加载单个插件并注册到 DetectionRegistry。
    /// 返回加载后的 ContentKind，失败返回 nil。
    func loadPlugin(at url: URL) -> ContentKind? {
        let manifestURL = url.appendingPathComponent("manifest.json")
        let rulesURL = url.appendingPathComponent("rules.json")

        // 1. Read and parse manifest
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: manifestData) else {
            NSLog("Copied: failed to load manifest for \(url.lastPathComponent)")
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

        // 4. Register with DetectionRegistry + persist
        DetectionRegistry.shared.register(detector)

        var installed = UserDefaults.standard.stringArray(forKey: "installedPlugins") ?? []
        if !installed.contains(kind.id) {
            installed.append(kind.id)
            UserDefaults.standard.set(installed, forKey: "installedPlugins")
        }

        NSLog("Copied: loaded plugin '\(manifest.name)' (\(compiledRules.count) rules)")
        return kind
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
        let dir = Self.pluginsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let destURL = dir.appendingPathComponent(sourceURL.lastPathComponent)

        // Remove existing installation
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }

        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        guard let kind = loadPlugin(at: destURL) else {
            // Clean up on failure
            try? FileManager.default.removeItem(at: destURL)
            throw PluginError.invalidPlugin(
                reason: String(localized: "manifest.json 或 rules.json 格式不正确")
            )
        }

        // Persist enabled state
        var installed = UserDefaults.standard.stringArray(forKey: "installedPlugins") ?? []
        if !installed.contains(kind.id) {
            installed.append(kind.id)
            UserDefaults.standard.set(installed, forKey: "installedPlugins")
        }

        // Mark as enabled
        DetectionRegistry.shared.setEnabled(true, kindID: kind.id)

        return kind
    }

    /// 卸载插件：从 DetectionRegistry 移除 + 删除文件。
    func uninstallPlugin(identifier: String) {
        // Remove from registry
        DetectionRegistry.shared.unregisterPlugin(identifier: identifier)
        DetectionRegistry.shared.setEnabled(true, kindID: identifier) // clear disabled state

        // Remove from installed list
        var installed = UserDefaults.standard.stringArray(forKey: "installedPlugins") ?? []
        installed.removeAll { $0 == identifier }
        UserDefaults.standard.set(installed, forKey: "installedPlugins")

        // Delete folder
        let pluginURL = Self.pluginsDirectory.appendingPathComponent("\(identifier).copiedplugin")
        try? FileManager.default.removeItem(at: pluginURL)

        NSLog("Copied: uninstalled plugin '\(identifier)'")
    }

    /// 已安装的插件 identifier 列表。
    var installedPluginIDs: [String] {
        UserDefaults.standard.stringArray(forKey: "installedPlugins") ?? []
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
        for rule in rules {
            let range = NSRange(text.startIndex..., in: text)
            if let match = rule.regex.firstMatch(in: text, range: range) {
                let value = extractValue(from: match, group: rule.extractGroup, in: text)
                return ContentDetection(
                    kind: kind,
                    value: value,
                    metadata: ["ruleId": rule.id],
                    pluginActionTemplate: rule.actionTemplate
                )
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
