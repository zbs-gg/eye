import Foundation

/// Privacy gate shared by session-transition handling and the final capture boundary.
/// Transition notifications can arrive late or out of order around display sleep, so the
/// capture operation also rejects macOS lock-screen shells directly.
enum CaptureSessionPolicy {
    static func mayResume(screenLocked: Bool, sessionLockedNow: Bool?) -> Bool {
        !screenLocked && sessionLockedNow == false
    }

    static func mayCapture(
        screenLocked: Bool,
        sessionLockedNow: Bool? = false,
        bundleId: String? = nil
    ) -> Bool {
        guard !screenLocked, sessionLockedNow == false else { return false }
        guard let bundleId = bundleId?.lowercased() else { return true }
        return bundleId != "com.apple.loginwindow"
            && !bundleId.hasPrefix("com.apple.screensaver")
    }
}
