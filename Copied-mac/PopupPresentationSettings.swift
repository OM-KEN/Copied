import Foundation

enum PopupPresentationMode: String, CaseIterable {
    case all
    case lowInterruption

    var displayName: String {
        switch self {
        case .all:
            String(localized: "默认模式")
        case .lowInterruption:
            String(localized: "轻打扰模式")
        }
    }
}

enum PopupPresentationContentType {
    case text
    case image
    case file
}

enum PopupPresentationSourceContentType {
    case text
    case image
    case file
}

struct PopupPresentationPreferences: Equatable {
    static let modeKey = "popupPresentationMode"
    static let showShortPlainTextKey = "popupShowShortPlainText"
    static let showLongPlainTextKey = "popupShowLongPlainText"
    static let showImagesKey = "popupShowImages"
    static let showFilesKey = "popupShowFiles"
    static let disabledKindIDsKey = "popupDisabledKindIDs"

    let mode: PopupPresentationMode
    let showShortPlainText: Bool
    let showLongPlainText: Bool
    let showImages: Bool
    let showFiles: Bool
    let disabledKindIDs: Set<String>

    static func current(defaults: UserDefaults = .standard) -> PopupPresentationPreferences {
        PopupPresentationPreferences(
            mode: defaults.string(forKey: modeKey)
                .flatMap(PopupPresentationMode.init(rawValue:)) ?? .all,
            showShortPlainText: bool(
                forKey: showShortPlainTextKey,
                defaultValue: false,
                defaults: defaults
            ),
            showLongPlainText: bool(
                forKey: showLongPlainTextKey,
                defaultValue: true,
                defaults: defaults
            ),
            showImages: bool(
                forKey: showImagesKey,
                defaultValue: true,
                defaults: defaults
            ),
            showFiles: bool(
                forKey: showFilesKey,
                defaultValue: true,
                defaults: defaults
            ),
            disabledKindIDs: Set(defaults.stringArray(forKey: disabledKindIDsKey) ?? [])
        )
    }

    static func restoreDefaults(defaults: UserDefaults = .standard) {
        [
            showShortPlainTextKey,
            showLongPlainTextKey,
            showImagesKey,
            showFilesKey,
            disabledKindIDsKey,
        ].forEach(defaults.removeObject(forKey:))
    }

    private static func bool(
        forKey key: String,
        defaultValue: Bool,
        defaults: UserDefaults
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

enum PopupPresentationPolicy {
    static func presentationContentType(
        sourceContentType: PopupPresentationSourceContentType,
        fileURLCount: Int,
        allFilesAreImages: Bool
    ) -> PopupPresentationContentType {
        switch sourceContentType {
        case .text:
            return .text
        case .image:
            return .image
        case .file:
            return fileURLCount > 0 && allFilesAreImages ? .image : .file
        }
    }

    static func shouldPresent(
        contentType: PopupPresentationContentType,
        textLength: Int,
        primaryKindID: String?,
        preferences: PopupPresentationPreferences
    ) -> Bool {
        guard preferences.mode == .lowInterruption else {
            return true
        }

        switch contentType {
        case .image:
            return preferences.showImages
        case .file:
            return preferences.showFiles
        case .text:
            if let primaryKindID {
                return !preferences.disabledKindIDs.contains(
                    normalizedKindID(primaryKindID)
                )
            }
            return textLength >= ClipboardTextPolicy.longTextThreshold
                ? preferences.showLongPlainText
                : preferences.showShortPlainText
        }
    }

    static func normalizedKindID(_ kindID: String) -> String {
        switch kindID {
        case "colorHex", "colorRGB", "colorHSL":
            "colorHex"
        default:
            kindID
        }
    }
}
