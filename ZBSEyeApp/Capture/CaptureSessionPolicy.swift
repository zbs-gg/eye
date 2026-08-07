import Foundation
import AppKit

struct ProtectedCaptureApplicationIdentity: Hashable, Sendable {
    let bundleIdentifier: String?
    let applicationName: String?
    let processIdentifier: Int32

    init(bundleIdentifier: String?, applicationName: String?, processIdentifier: Int32) {
        self.bundleIdentifier = Self.normalized(bundleIdentifier)
        self.applicationName = Self.normalized(applicationName)
        self.processIdentifier = processIdentifier
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value.lowercased()
    }
}

struct ProtectedCaptureApplicationSnapshot: Sendable, Equatable {
    let revision: UInt64
    let applications: Set<ProtectedCaptureApplicationIdentity>
}

/// Exact identity of a running process whose bundle was put in the user's
/// screen privacy list. Bundle-only matching is not sufficient here: a stale
/// ScreenCaptureKit inventory can otherwise omit a newly launched helper while
/// still containing another process from the same app.
struct UserIgnoredCaptureApplicationIdentity: Hashable, Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String
}

typealias UserIgnoredCaptureApplicationSnapshot = Set<UserIgnoredCaptureApplicationIdentity>

struct CaptureContentEpoch: Sendable, Equatable {
    private(set) var value: UInt64 = 0

    mutating func invalidate() { value &+= 1 }
    func contains(_ observedValue: UInt64) -> Bool { value == observedValue }
}

struct CaptureSuspensionReasons: OptionSet, Sendable, Equatable {
    let rawValue: UInt8

    static let session = CaptureSuspensionReasons(rawValue: 1 << 0)
    static let systemSleep = CaptureSuspensionReasons(rawValue: 1 << 1)
    static let displaySleep = CaptureSuspensionReasons(rawValue: 1 << 2)
    static let screenSaver = CaptureSuspensionReasons(rawValue: 1 << 3)
}

struct CaptureSessionGateState: Sendable, Equatable {
    let reasons: CaptureSuspensionReasons

    var screenLocked: Bool { reasons.contains(.session) }
    var suspended: Bool { !reasons.isEmpty }
    var isOpen: Bool { reasons.isEmpty }
}

/// Privacy gate shared by session-transition handling and the final capture boundary.
/// Transition notifications can arrive late or out of order around display sleep, so the
/// capture operation also rejects macOS lock-screen shells directly.
enum CaptureSessionPolicy {
    @MainActor private static var protectedApplicationEpoch = CaptureContentEpoch()

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

    /// One authoritative local query shared by screen and explicit Call-audio admission. Unknown
    /// is intentionally fail-closed at each caller.
    static func currentSessionLocked() -> Bool? {
        let sessionInfo = CGSessionCopyCurrentDictionary() as? [String: Any]
        return sessionLockState(from: sessionInfo)
    }

    /// Start fail-closed: a failed initial query must not probe ScreenCaptureKit
    /// until a later valid session observation confirms an unlocked console.
    static func startupGate(sessionLockedNow: Bool?) -> CaptureSessionGateState {
        guard sessionLockedNow == false else {
            return CaptureSessionGateState(reasons: .session)
        }
        return CaptureSessionGateState(reasons: [])
    }

    static func suspendedGate(
        previous: CaptureSessionGateState,
        adding reason: CaptureSuspensionReasons
    ) -> CaptureSessionGateState {
        CaptureSessionGateState(reasons: previous.reasons.union(reason))
    }

    /// Polling owns recovery from missed session lock/unlock notifications. It
    /// changes only the session reason; display and screen-saver reasons require
    /// their matching resume signal and cannot be cross-cleared.
    static func periodicGate(
        previous: CaptureSessionGateState,
        sessionLockedNow: Bool?
    ) -> CaptureSessionGateState? {
        var reasons = previous.reasons
        switch sessionLockedNow {
        case false:
            reasons.remove(.session)
        case true:
            reasons.insert(.session)
        case nil:
            // The caller admits no capture for this tick. Preserve the existing
            // reason so a transient query failure during an active screen saver
            // cannot masquerade as a completed unlock on the next poll.
            return nil
        }
        return CaptureSessionGateState(reasons: reasons)
    }

    /// A wake/unlock/screensaver-stop hint clears only its matching reason, then
    /// refreshes the independent session reason from the authoritative query.
    static func resumeSignalGate(
        previous: CaptureSessionGateState,
        clearing reason: CaptureSuspensionReasons,
        sessionLockedNow: Bool?
    ) -> CaptureSessionGateState {
        var reasons = previous.reasons
        reasons.remove(reason)
        if sessionLockedNow == false {
            reasons.remove(.session)
        } else {
            reasons.insert(.session)
        }
        return CaptureSessionGateState(reasons: reasons)
    }

    static func mayCapture(
        screenLocked: Bool,
        sessionLockedNow: Bool? = false,
        bundleId: String? = nil,
        appName: String? = nil
    ) -> Bool {
        guard !screenLocked, sessionLockedNow == false else { return false }
        return !isProtectedCaptureSurface(bundleId: bundleId, appName: appName)
    }

    static func isProtectedCaptureSurface(bundleId: String?, appName: String? = nil) -> Bool {
        SystemAppFilter.isProtectedCaptureSurface(bundleId: bundleId, appName: appName)
    }

    /// NSWorkspace lifecycle notifications are monotonic evidence. Including
    /// their generation closes the launch→capture→exit ABA hole that two equal
    /// running-application Sets cannot detect.
    @MainActor
    @discardableResult
    static func recordProtectedApplicationLifecycle(
        bundleId: String?,
        appName: String?
    ) -> Bool {
        guard isProtectedCaptureSurface(bundleId: bundleId, appName: appName) else { return false }
        recordProtectedApplicationInventoryChange()
        return true
    }

    /// KVO of NSWorkspace.runningApplications covers background/LSUIElement
    /// processes that do not emit didLaunch/didTerminate notifications.
    @MainActor
    static func recordProtectedApplicationInventoryChange() {
        protectedApplicationEpoch.invalidate()
    }

    /// A process identity, rather than only a bundle id, makes a cached
    /// `SCShareableContent` snapshot invalid as soon as an authentication helper
    /// launches or exits. No process name, window title, or other private text
    /// crosses this boundary.
    @MainActor
    static func protectedRunningApplicationSnapshot() -> ProtectedCaptureApplicationSnapshot {
        let applications: Set<ProtectedCaptureApplicationIdentity> = Set(
            NSWorkspace.shared.runningApplications.compactMap { application -> ProtectedCaptureApplicationIdentity? in
            let bundleIdentifier = application.bundleIdentifier
            let applicationName = application.localizedName
            guard isProtectedCaptureSurface(
                bundleId: bundleIdentifier,
                appName: applicationName
            ) else { return nil }
            return ProtectedCaptureApplicationIdentity(
                bundleIdentifier: bundleIdentifier,
                applicationName: applicationName,
                processIdentifier: Int32(application.processIdentifier)
            )
            }
        )
        return ProtectedCaptureApplicationSnapshot(
            revision: protectedApplicationEpoch.value,
            applications: applications
        )
    }

    /// ScreenCaptureKit must know about every protected process before a frame
    /// filter is constructed. Authentication helpers can stay alive for hours
    /// with an offscreen window, so process lifecycle notifications alone do not
    /// prove that an on-screen-only SCK inventory is safe.
    static func contentCoversProtectedApplications(
        expected: ProtectedCaptureApplicationSnapshot,
        represented: Set<ProtectedCaptureApplicationIdentity>
    ) -> Bool {
        expected.applications.allSatisfy { expectedApplication in
            represented.contains { representedApplication in
                guard representedApplication.processIdentifier
                        == expectedApplication.processIdentifier else { return false }
                if let expectedBundle = expectedApplication.bundleIdentifier {
                    return representedApplication.bundleIdentifier == expectedBundle
                }
                guard let expectedName = expectedApplication.applicationName else { return false }
                return representedApplication.applicationName == expectedName
            }
        }
    }

    /// Exact PID + bundle matching keeps PID reuse and sibling helpers from
    /// satisfying an exclusion attestation built for a different process.
    static func contentCoversUserIgnoredApplications(
        expected: UserIgnoredCaptureApplicationSnapshot,
        represented: UserIgnoredCaptureApplicationSnapshot
    ) -> Bool {
        expected.isSubset(of: represented)
    }
}
