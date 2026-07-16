import CoreGraphics

struct SimulatedKeyEventDescriptor: Equatable {
    let virtualKey: CGKeyCode
    let isKeyDown: Bool
    let flags: CGEventFlags
}

enum CopyGestureEventSequence {
    static let commandKey: CGKeyCode = 0x37
    static let cKey: CGKeyCode = 0x08

    /// A complete physical-style Command-C chord. The final Command release
    /// deliberately carries no flags so the system modifier state is cleared.
    static let commandC: [SimulatedKeyEventDescriptor] = [
        SimulatedKeyEventDescriptor(virtualKey: commandKey, isKeyDown: true, flags: .maskCommand),
        SimulatedKeyEventDescriptor(virtualKey: cKey, isKeyDown: true, flags: .maskCommand),
        SimulatedKeyEventDescriptor(virtualKey: cKey, isKeyDown: false, flags: .maskCommand),
        SimulatedKeyEventDescriptor(virtualKey: commandKey, isKeyDown: false, flags: [])
    ]
}
