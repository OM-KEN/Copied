import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct PopupPresentationSettingsTests {
    static func main() {
        modeDefaultsToAll()
        explicitFalseOverridesUnregisteredDefault()
        recognizedKindsIgnorePlainTextLengthPreferences()
        removeEmptyLinesPluginOnlyOverridesPlainTextForActualEmptyLines()
        fileClassificationUsesCurrentPolicy()
        imageAndFileUseTheirOwnPreferences()
        disabledPrimaryKindIsFiltered()
        colorKindsShareOnePreference()
        allModeIgnoresFilters()
        newKindIsEnabledByDefault()
        candidateDecisionSupportsEarlyOut()
        partialFileClassificationFailsClosed()
        restoreDefaultsPreservesMode()
        print("PopupPresentationSettingsTests: PASS")
    }

    private static func makeDefaults() -> UserDefaults {
        let suite = "com.copied.popup-presentation-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func preferences(
        mode: PopupPresentationMode = .lowInterruption,
        showShortPlainText: Bool = false,
        showLongPlainText: Bool = true,
        showImages: Bool = true,
        showFiles: Bool = true,
        disabledKindIDs: Set<String> = []
    ) -> PopupPresentationPreferences {
        PopupPresentationPreferences(
            mode: mode,
            showShortPlainText: showShortPlainText,
            showLongPlainText: showLongPlainText,
            showImages: showImages,
            showFiles: showFiles,
            disabledKindIDs: disabledKindIDs
        )
    }

    private static func modeDefaultsToAll() {
        let defaults = makeDefaults()
        expect(
            PopupPresentationPreferences.current(defaults: defaults).mode == .all,
            "missing mode defaults to all"
        )

        defaults.set("unsupported", forKey: PopupPresentationPreferences.modeKey)
        expect(
            PopupPresentationPreferences.current(defaults: defaults).mode == .all,
            "invalid mode defaults to all"
        )
    }

    private static func explicitFalseOverridesUnregisteredDefault() {
        let defaults = makeDefaults()
        let unregistered = PopupPresentationPreferences.current(defaults: defaults)
        expect(!unregistered.showShortPlainText, "short plain text defaults off")
        expect(unregistered.showLongPlainText, "long plain text defaults on")
        expect(unregistered.showImages, "images default on")
        expect(unregistered.showFiles, "files default on")
        expect(unregistered.disabledKindIDs.isEmpty, "disabled kinds default empty")

        defaults.set(false, forKey: PopupPresentationPreferences.showLongPlainTextKey)
        expect(
            !PopupPresentationPreferences.current(defaults: defaults).showLongPlainText,
            "explicit false overrides the unregistered true default"
        )
    }

    private static func recognizedKindsIgnorePlainTextLengthPreferences() {
        let shortEnabledLongDisabled = preferences(
            showShortPlainText: true,
            showLongPlainText: false
        )
        expect(
            PopupPresentationPolicy.shouldPresent(
                contentType: .text,
                textLength: 49,
                primaryKindID: nil,
                preferences: shortEnabledLongDisabled
            ),
            "unrecognized 49-character text follows the enabled short-text preference"
        )
        expect(
            !PopupPresentationPolicy.shouldPresent(
                contentType: .text,
                textLength: 50,
                primaryKindID: nil,
                preferences: shortEnabledLongDisabled
            ),
            "unrecognized 50-character text follows the disabled long-text preference"
        )

        let shortDisabledLongEnabled = preferences(
            showShortPlainText: false,
            showLongPlainText: true
        )
        expect(
            !PopupPresentationPolicy.shouldPresent(
                contentType: .text,
                textLength: 49,
                primaryKindID: nil,
                preferences: shortDisabledLongEnabled
            ),
            "unrecognized 49-character text follows the disabled short-text preference"
        )
        expect(
            PopupPresentationPolicy.shouldPresent(
                contentType: .text,
                textLength: 50,
                primaryKindID: nil,
                preferences: shortDisabledLongEnabled
            ),
            "unrecognized 50-character text follows the enabled long-text preference"
        )

        let longDisabled = preferences(showLongPlainText: false)
        for textLength in [50, 500] {
            expect(
                PopupPresentationPolicy.shouldPresent(
                    contentType: .text,
                    textLength: textLength,
                    primaryKindID: "url",
                    preferences: longDisabled
                ),
                "recognized \(textLength)-character URL ignores the plain long-text preference"
            )
        }

        let kindDisabled = preferences(
            showLongPlainText: true,
            disabledKindIDs: ["url"]
        )
        for textLength in [50, 500] {
            expect(
                !PopupPresentationPolicy.shouldPresent(
                    contentType: .text,
                    textLength: textLength,
                    primaryKindID: "url",
                    preferences: kindDisabled
                ),
                "recognized \(textLength)-character URL respects its disabled kind"
            )
        }

        let shortPlainTextDisabled = preferences(showShortPlainText: false)
        expect(
            PopupPresentationPolicy.shouldPresent(
                contentType: .text,
                textLength: 49,
                primaryKindID: "url",
                preferences: shortPlainTextDisabled
            ),
            "a short recognized URL ignores the plain short-text preference"
        )
        expect(
            !PopupPresentationPolicy.shouldPresent(
                contentType: .text,
                textLength: 49,
                primaryKindID: nil,
                preferences: shortPlainTextDisabled
            ),
            "unclassified short text respects the plain short-text preference"
        )
    }

    private static func removeEmptyLinesPluginOnlyOverridesPlainTextForActualEmptyLines() {
        let rulesURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Example Plugins/remove-empty-lines.copiedplugin/rules.json")
        guard let data = try? Data(contentsOf: rulesURL),
              let rulesJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rules = rulesJSON["rules"] as? [[String: Any]],
              let pattern = rules.first?["pattern"] as? String,
              let regex = try? NSRegularExpression(pattern: pattern) else {
            expect(false, "remove-empty-lines example exposes a valid detection pattern")
            return
        }

        func pluginMatches(_ text: String) -> Bool {
            let range = NSRange(text.startIndex..., in: text)
            return regex.firstMatch(in: text, range: range)?.range == range
        }

        let multilineWithoutEmptyLines = """
        49/50 字符边界与识别文本回归测试
        图片开关/文件开关组合矩阵
        全量测试
        强制无缓存生产构建
        三语本地化编译
        """
        let settings = preferences(
            showShortPlainText: false,
            showLongPlainText: false
        )
        expect(
            !pluginMatches(multilineWithoutEmptyLines),
            "remove-empty-lines ignores multiline text that has no empty lines"
        )
        expect(
            !PopupPresentationPolicy.shouldPresent(
                contentType: .text,
                textLength: multilineWithoutEmptyLines.count,
                primaryKindID: nil,
                preferences: settings
            ),
            "ordinary multiline text still follows the disabled plain-text preference"
        )

        for text in ["第一行\n\n第二行", "第一行\r\n \t\r\n第二行"] {
            expect(pluginMatches(text), "remove-empty-lines recognizes an actual empty line")
            expect(
                PopupPresentationPolicy.shouldPresent(
                    contentType: .text,
                    textLength: text.count,
                    primaryKindID: "com.copied.remove-empty-lines",
                    preferences: settings
                ),
                "a genuinely applicable plugin remains independently presentable"
            )
        }
    }

    private static func fileClassificationUsesCurrentPolicy() {
        for showImages in [false, true] {
            for showFiles in [false, true] {
                let settings = preferences(showImages: showImages, showFiles: showFiles)
                for allImages: Bool? in [nil, false, true] {
                    for complete in [false, true] {
                        let expected = complete && allImages != nil
                            ? (allImages == true ? showImages : showFiles)
                            : showImages && showFiles
                        expect(
                            PopupPresentationPolicy.shouldPresentFiles(
                                allFilesAreImages: allImages,
                                classificationIsComplete: complete,
                                preferences: settings
                            ) == expected,
                            "file presentation respects classification completeness and both preferences"
                        )
                    }
                }
            }
        }
    }

    private static func imageAndFileUseTheirOwnPreferences() {
        let settings = preferences(showImages: false, showFiles: false)
        expect(
            !PopupPresentationPolicy.shouldPresent(
                contentType: .image,
                textLength: 0,
                primaryKindID: nil,
                preferences: settings
            ),
            "image preference filters images"
        )
        expect(
            !PopupPresentationPolicy.shouldPresent(
                contentType: .file,
                textLength: 0,
                primaryKindID: nil,
                preferences: settings
            ),
            "file preference filters files"
        )
    }

    private static func disabledPrimaryKindIsFiltered() {
        let settings = preferences(disabledKindIDs: ["url"])
        expect(
            !PopupPresentationPolicy.shouldPresent(
                contentType: .text,
                textLength: 3,
                primaryKindID: "url",
                preferences: settings
            ),
            "disabled primary kind is filtered"
        )
    }

    private static func colorKindsShareOnePreference() {
        let settings = preferences(disabledKindIDs: ["colorHex"])
        for kindID in ["colorHex", "colorRGB", "colorHSL"] {
            expect(
                !PopupPresentationPolicy.shouldPresent(
                    contentType: .text,
                    textLength: 12,
                    primaryKindID: kindID,
                    preferences: settings
                ),
                "disabling colorHex filters \(kindID)"
            )
        }
        expect(
            PopupPresentationPolicy.normalizedKindID("url") == "url",
            "unrelated kinds are not normalized"
        )
    }

    private static func allModeIgnoresFilters() {
        let settings = preferences(
            mode: .all,
            showShortPlainText: false,
            showLongPlainText: false,
            showImages: false,
            showFiles: false,
            disabledKindIDs: ["url"]
        )
        expect(
            PopupPresentationPolicy.shouldPresent(
                contentType: .text,
                textLength: 500,
                primaryKindID: "url",
                preferences: settings
            ),
            "all mode ignores text filters"
        )
        expect(
            PopupPresentationPolicy.shouldPresent(
                contentType: .image,
                textLength: 0,
                primaryKindID: nil,
                preferences: settings
            ),
            "all mode ignores image filters"
        )
        expect(
            PopupPresentationPolicy.shouldPresent(
                contentType: .file,
                textLength: 0,
                primaryKindID: nil,
                preferences: settings
            ),
            "all mode ignores file filters"
        )
    }

    private static func newKindIsEnabledByDefault() {
        let settings = preferences(disabledKindIDs: ["url"])
        expect(
            PopupPresentationPolicy.shouldPresent(
                contentType: .text,
                textLength: 500,
                primaryKindID: "future-plugin-kind",
                preferences: settings
            ),
            "a newly introduced kind is enabled until explicitly disabled"
        )
    }

    private static func candidateDecisionSupportsEarlyOut() {
        let kinds: Set<String> = ["url", "colorHex"]
        expect(
            PopupPresentationPolicy.candidateDecision(
                preferences: preferences(
                    showShortPlainText: true,
                    showLongPlainText: true,
                    showImages: true,
                    showFiles: true
                ),
                availableKindIDs: kinds
            ) == .allAllowed,
            "all enabled candidates should be immediately allowed"
        )
        expect(
            PopupPresentationPolicy.candidateDecision(
                preferences: preferences(
                    showShortPlainText: false,
                    showLongPlainText: false,
                    showImages: false,
                    showFiles: false,
                    disabledKindIDs: kinds
                ),
                availableKindIDs: kinds
            ) == .allDenied,
            "all disabled candidates should be immediately denied"
        )
    }

    private static func partialFileClassificationFailsClosed() {
        let split = preferences(showImages: true, showFiles: false)
        expect(
            !PopupPresentationPolicy.shouldPresentFiles(
                allFilesAreImages: nil,
                classificationIsComplete: false,
                preferences: split
            ),
            "partial file classification must fail closed when toggles differ"
        )
        let commonAllow = preferences(showImages: true, showFiles: true)
        expect(
            PopupPresentationPolicy.shouldPresentFiles(
                allFilesAreImages: nil,
                classificationIsComplete: false,
                preferences: commonAllow
            ),
            "equal enabled toggles can safely allow partial classification"
        )
    }

    private static func restoreDefaultsPreservesMode() {
        let defaults = makeDefaults()
        defaults.set(
            PopupPresentationMode.lowInterruption.rawValue,
            forKey: PopupPresentationPreferences.modeKey
        )
        defaults.set(true, forKey: PopupPresentationPreferences.showShortPlainTextKey)
        defaults.set(false, forKey: PopupPresentationPreferences.showLongPlainTextKey)
        defaults.set(false, forKey: PopupPresentationPreferences.showImagesKey)
        defaults.set(false, forKey: PopupPresentationPreferences.showFilesKey)
        defaults.set(["url"], forKey: PopupPresentationPreferences.disabledKindIDsKey)

        PopupPresentationPreferences.restoreDefaults(defaults: defaults)
        let restored = PopupPresentationPreferences.current(defaults: defaults)
        expect(restored.mode == .lowInterruption, "restore preserves the selected mode")
        expect(!restored.showShortPlainText, "restore resets short plain text")
        expect(restored.showLongPlainText, "restore resets long plain text")
        expect(restored.showImages, "restore resets images")
        expect(restored.showFiles, "restore resets files")
        expect(restored.disabledKindIDs.isEmpty, "restore clears disabled kinds")
    }
}
