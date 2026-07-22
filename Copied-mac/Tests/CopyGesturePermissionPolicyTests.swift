import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct CopyGesturePermissionPolicyTests {
    static func main() {
        expect(
            !CopyGesturePermissionPolicy.reconciledEnabled(
                requested: false,
                accessibilityTrusted: false
            ),
            "new users remain disabled without permission"
        )
        expect(
            !CopyGesturePermissionPolicy.reconciledEnabled(
                requested: false,
                accessibilityTrusted: true
            ),
            "permission alone does not enable the gesture"
        )
        expect(
            !CopyGesturePermissionPolicy.reconciledEnabled(
                requested: true,
                accessibilityTrusted: false
            ),
            "a request without permission is reset"
        )
        expect(
            CopyGesturePermissionPolicy.reconciledEnabled(
                requested: true,
                accessibilityTrusted: true
            ),
            "a permitted user request is restored"
        )

        print("CopyGesturePermissionPolicyTests: PASS")
    }
}
