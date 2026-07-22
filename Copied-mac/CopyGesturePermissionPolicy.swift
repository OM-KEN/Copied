enum CopyGesturePermissionPolicy {
    static func reconciledEnabled(
        requested: Bool,
        accessibilityTrusted: Bool
    ) -> Bool {
        requested && accessibilityTrusted
    }
}
