import Foundation

enum PluginRemovalPolicy {
    private struct ManifestIdentifier: Decodable {
        let identifier: String
    }

    static func isValidIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty,
              identifier.utf8.count <= 255,
              let first = identifier.unicodeScalars.first,
              let last = identifier.unicodeScalars.last,
              isASCIIAlphanumeric(first),
              isASCIIAlphanumeric(last),
              !identifier.contains("..") else {
            return false
        }

        return identifier.unicodeScalars.allSatisfy { scalar in
            isASCIIAlphanumeric(scalar)
                || scalar == "."
                || scalar == "-"
                || scalar == "_"
        }
    }

    static func pluginDirectories(
        in pluginsDirectory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.filter {
            isSafePluginDirectory(
                $0,
                pluginsDirectory: pluginsDirectory
            )
        }
    }

    static func removeInstalledPlugins(
        identifier: String,
        from pluginsDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let matchingDirectories = pluginDirectories(
            in: pluginsDirectory,
            fileManager: fileManager
        ).filter {
            manifestIdentifier(at: $0) == identifier
        }

        for pluginURL in matchingDirectories {
            try fileManager.removeItem(at: pluginURL)
        }
        return matchingDirectories
    }

    private static func isSafePluginDirectory(
        _ candidate: URL,
        pluginsDirectory: URL
    ) -> Bool {
        guard candidate.pathExtension == "copiedplugin" else { return false }

        let lexicalRoot = pluginsDirectory.standardizedFileURL
        let lexicalCandidate = candidate.standardizedFileURL
        guard lexicalCandidate.deletingLastPathComponent().path == lexicalRoot.path,
              let values = try? lexicalCandidate.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            return false
        }

        let resolvedRoot = lexicalRoot.resolvingSymlinksInPath()
        let resolvedCandidate = lexicalCandidate.resolvingSymlinksInPath()
        return resolvedCandidate.deletingLastPathComponent().path == resolvedRoot.path
    }

    private static func manifestIdentifier(at pluginURL: URL) -> String? {
        let manifestURL = pluginURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(ManifestIdentifier.self, from: data) else {
            return nil
        }
        return manifest.identifier
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return false
        }
    }
}

struct RegexDeadline {
    private let expiresAt: TimeInterval

    init(timeLimit: TimeInterval) {
        expiresAt = ProcessInfo.processInfo.systemUptime + max(0, timeLimit)
    }

    var isExpired: Bool {
        ProcessInfo.processInfo.systemUptime >= expiresAt
    }
}

enum BoundedRegularExpression {
    static let defaultTimeLimit: TimeInterval = 0.050
    static let maximumMatchCount = 10_000
    static let maximumOutputUTF16Length = 1_000_000

    enum FirstMatchResult {
        case match(NSTextCheckingResult)
        case noMatch
        case limitExceeded
    }

    enum ReplacementResult {
        case success(String)
        case limitExceeded
    }

    static func firstMatch(
        _ regex: NSRegularExpression,
        in text: String,
        range: NSRange,
        deadline: RegexDeadline
    ) -> FirstMatchResult {
        guard isValid(range: range, in: text) else { return .limitExceeded }

        var firstMatch: NSTextCheckingResult?
        var limitExceeded = false
        regex.enumerateMatches(
            in: text,
            options: [.reportProgress],
            range: range
        ) { match, flags, stop in
            if deadline.isExpired || flags.contains(.internalError) {
                limitExceeded = true
                stop.pointee = true
                return
            }
            guard !flags.contains(.progress), let match else { return }
            firstMatch = match
            stop.pointee = true
        }

        if limitExceeded || (firstMatch == nil && deadline.isExpired) {
            return .limitExceeded
        }
        if let firstMatch {
            return .match(firstMatch)
        }
        return .noMatch
    }

    static func replacingMatches(
        _ regex: NSRegularExpression,
        in text: String,
        range: NSRange,
        withTemplate replacement: String,
        deadline: RegexDeadline
    ) -> ReplacementResult {
        guard isValid(range: range, in: text),
              replacement.utf16.count <= maximumOutputUTF16Length else {
            return .limitExceeded
        }

        var matches: [NSTextCheckingResult] = []
        var limitExceeded = false
        regex.enumerateMatches(
            in: text,
            options: [.reportProgress],
            range: range
        ) { match, flags, stop in
            if deadline.isExpired || flags.contains(.internalError) {
                limitExceeded = true
                stop.pointee = true
                return
            }
            guard !flags.contains(.progress), let match else { return }
            guard matches.count < maximumMatchCount else {
                limitExceeded = true
                stop.pointee = true
                return
            }
            matches.append(match)
        }

        guard !limitExceeded, !deadline.isExpired else {
            return .limitExceeded
        }

        let source = text as NSString
        let output = NSMutableString()
        let replacementRangeEnd = range.location + range.length
        var cursor = 0

        func append(_ value: String) -> Bool {
            guard !deadline.isExpired,
                  value.utf16.count <= maximumOutputUTF16Length - output.length else {
                return false
            }
            output.append(value)
            return true
        }

        guard append(source.substring(with: NSRange(location: 0, length: range.location))) else {
            return .limitExceeded
        }

        cursor = range.location
        for match in matches {
            guard match.range.location >= cursor,
                  match.range.location + match.range.length <= replacementRangeEnd,
                  append(source.substring(
                    with: NSRange(
                        location: cursor,
                        length: match.range.location - cursor
                    )
                  )) else {
                return .limitExceeded
            }

            let substituted = regex.replacementString(
                for: match,
                in: text,
                offset: 0,
                template: replacement
            )
            guard append(substituted) else { return .limitExceeded }
            cursor = match.range.location + match.range.length
        }

        guard append(source.substring(
            with: NSRange(
                location: cursor,
                length: replacementRangeEnd - cursor
            )
        )),
        append(source.substring(
            with: NSRange(
                location: replacementRangeEnd,
                length: source.length - replacementRangeEnd
            )
        )) else {
            return .limitExceeded
        }

        return .success(output as String)
    }

    private static func isValid(range: NSRange, in text: String) -> Bool {
        let length = (text as NSString).length
        return range.location != NSNotFound
            && range.location <= length
            && range.length <= length - range.location
    }
}
