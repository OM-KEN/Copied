enum ClipboardTextFallback {
    case search
    case saveAs
}

enum ClipboardTextPolicy {
    static let longTextThreshold = 50

    static func isLong(_ text: String) -> Bool {
        text.count >= longTextThreshold
    }

    static func fallback(for text: String) -> ClipboardTextFallback {
        isLong(text) ? .saveAs : .search
    }
}
