import Foundation

/// Privacy gate shared by session-transition handling and the final capture boundary.
/// Transition notifications can arrive late or out of order around display sleep, so the
/// capture operation also rejects macOS lock-screen shells directly.
enum CaptureSessionPolicy {
    static let macOSLockKey = "CGSSessionScreenIsLocked"
    static let macOSOnConsoleKey = "kCGSSessionOnConsoleKey"
    static let macOSLoginDoneKey = "kCGSessionLoginDoneKey"

    /// `CGSessionCopyCurrentDictionary` omits the lock key for a normal unlocked
    /// session. A missing dictionary is a failed query and must stay fail-closed;
    /// the observed unlocked shape is accepted only when it also identifies the
    /// current on-console session with login complete.
    static func sessionLockState(from sessionInfo: [String: Any]?) -> Bool? {
        guard let sessionInfo else { return nil }
        guard sessionInfo[macOSOnConsoleKey] as? Bool == true,
              sessionInfo[macOSLoginDoneKey] as? Bool == true else { return nil }
        guard let rawValue = sessionInfo[macOSLockKey] else { return false }
        return rawValue as? Bool
    }

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
