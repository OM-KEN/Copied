import AppKit

enum KeyboardQuickTriggerModifier: String, CaseIterable, Codable {
    case command
    case option
    case control
    case shift
    case disabled

    var displayName: String {
        switch self {
        case .command: String(localized: "Command (⌘)")
        case .option: String(localized: "Option (⌥)")
        case .control: String(localized: "Control (⌃)")
        case .shift: String(localized: "Shift (⇧)")
        case .disabled: String(localized: "关闭")
        }
    }

    var nseventFlags: NSEvent.ModifierFlags {
        switch self {
        case .command: .command
        case .option: .option
        case .control: .control
        case .shift: .shift
        case .disabled: []
        }
    }

    var sfSymbolName: String {
        switch self {
        case .command: "command"
        case .option: "option"
        case .control: "control"
        case .shift: "shift"
        case .disabled: "keyboard"
        }
    }
}

enum KeyboardQuickTriggerMode: String, CaseIterable, Codable {
    case doubleTap
    case singleTap

    var displayName: String {
        switch self {
        case .doubleTap: String(localized: "双击")
        case .singleTap: String(localized: "单击（高级）")
        }
    }
}

struct QuickTriggerSettings: Equatable {
    static let keyboardModifierKey = "keyboardQuickTriggerModifier"
    static let keyboardModeKey = "keyboardQuickTriggerMode"
    static let mouseButtonKey = "mouseQuickTriggerButton"

    var keyboardModifier: KeyboardQuickTriggerModifier
    var keyboardMode: KeyboardQuickTriggerMode
    var mouseButton: Int?

    static func current(defaults: UserDefaults = .standard) -> QuickTriggerSettings {
        let modifier = defaults.string(forKey: keyboardModifierKey)
            .flatMap(KeyboardQuickTriggerModifier.init(rawValue:)) ?? .control
        let mode = defaults.string(forKey: keyboardModeKey)
            .flatMap(KeyboardQuickTriggerMode.init(rawValue:)) ?? .doubleTap
        let storedMouseButton = defaults.object(forKey: mouseButtonKey) as? NSNumber
        let mouseButton = storedMouseButton.map(\.intValue).flatMap { $0 >= 3 ? $0 : nil }
        return QuickTriggerSettings(
            keyboardModifier: modifier,
            keyboardMode: mode,
            mouseButton: mouseButton
        )
    }
}
