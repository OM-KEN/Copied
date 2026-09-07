enum ClipboardTextFallback {
    case search
    case saveAs
}

enum ClipboardTextPolicy {
    static let longTextThreshold = 50

    static func fallback(textLength: Int) -> ClipboardTextFallback {
        textLength >= longTextThreshold ? .saveAs : .search
    }
}
