import AppKit

/// Configurable modifier key for the toast quick-trigger feature.
enum ShortcutModifier: String, CaseIterable, Codable {
    case command
    case option
    case control
    case shift

    var displayName: String {
        switch self {
        case .command: "Command (⌘)"
        case .option:  "Option (⌥)"
        case .control: "Control (⌃)"
        case .shift:   "Shift (⇧)"
        }
    }

    var nseventFlags: NSEvent.ModifierFlags {
        switch self {
        case .command: .command
        case .option:  .option
        case .control: .control
        case .shift:   .shift
        }
    }

    var sfSymbolName: String {
        switch self {
        case .command: "command"
        case .option:  "option"
        case .control: "control"
        case .shift:   "shift"
        }
    }

    static var current: ShortcutModifier {
        let raw = UserDefaults.standard.string(forKey: "quickTriggerModifier") ?? "command"
        return ShortcutModifier(rawValue: raw) ?? .command
    }
}
