import Foundation

/// The small, exact set of macOS processes that own the native screenshot UI.
/// This policy is deliberately separate from CaptureSessionPolicy: a screenshot
/// helper is a temporary scheduling signal, not private content to exclude from
/// history.
struct ScreenshotPriorityProcessIdentity: Sendable, Equatable {
    let processIdentifier: Int32
    let bundleIdentifier: String?
    let executablePath: String?
}

enum ScreenshotPriorityProcessPolicy {
    static let launcherBundleIdentifier = "com.apple.screenshot.launcher"
    static let launcherExecutablePath = "/System/Applications/Utilities/Screenshot.app/Contents/MacOS/Screenshot"
    static let uiBundleIdentifier = "com.apple.screencaptureui"
    static let uiExecutablePath = "/System/Library/CoreServices/screencaptureui.app/Contents/MacOS/screencaptureui"
    static let commandLineBundleIdentifier = "com.apple.screencapture"
    static let commandLineExecutablePath = "/usr/sbin/screencapture"

    static func isNativeScreenshotProcess(
        bundleIdentifier: String?,
        executablePath: String?
    ) -> Bool {
        (bundleIdentifier == launcherBundleIdentifier
            && executablePath == launcherExecutablePath)
            || (bundleIdentifier == uiBundleIdentifier
                && executablePath == uiExecutablePath)
            || ((bundleIdentifier == commandLineBundleIdentifier || bundleIdentifier == nil)
                && executablePath == commandLineExecutablePath)
    }

    /// SCShareableContent exposes no executable URL. Use its exact native
    /// bundle identifier there; process observation above remains stricter and
    /// also validates the immutable system executable path. This path only
    /// removes an application from Eye's content filter and never opens the
    /// screenshot-priority scheduling gate.
    static func isNativeScreenshotApplication(
        bundleIdentifier: String
    ) -> Bool {
        bundleIdentifier == launcherBundleIdentifier
            || bundleIdentifier == uiBundleIdentifier
            || bundleIdentifier == commandLineBundleIdentifier
    }

    static func isNativeScreenshotProcess(_ identity: ScreenshotPriorityProcessIdentity) -> Bool {
        isNativeScreenshotProcess(
            bundleIdentifier: identity.bundleIdentifier,
            executablePath: identity.executablePath
        )
    }
}

struct ScreenshotPriorityYieldState: Sendable, Equatable {
    var suppressionDeadlineMs: UInt64 = 0
    var activeScreenshotProcessIDs: Set<Int32> = []

    func isSuppressed(at nowMs: UInt64) -> Bool {
        !activeScreenshotProcessIDs.isEmpty || nowMs < suppressionDeadlineMs
    }
}

/// Pure state transitions for the system-screenshot yield window. Milliseconds
/// are monotonic uptime, never wall-clock time, so a clock correction cannot
/// shorten or accidentally prolong the gate.
enum ScreenshotPriorityYieldPolicy {
    static let suppressionDurationMs: UInt64 = 2_000

    static func openingSuppression(
        _ previous: ScreenshotPriorityYieldState,
        at nowMs: UInt64
    ) -> ScreenshotPriorityYieldState {
        var next = previous
        next.suppressionDeadlineMs = max(
            previous.suppressionDeadlineMs,
            saturatingAdd(nowMs, suppressionDurationMs)
        )
        return next
    }

    static func replacingActiveProcesses(
        _ processIDs: Set<Int32>,
        in previous: ScreenshotPriorityYieldState,
        at nowMs: UInt64
    ) -> ScreenshotPriorityYieldState {
        guard processIDs != previous.activeScreenshotProcessIDs else { return previous }
        var next = openingSuppression(previous, at: nowMs)
        next.activeScreenshotProcessIDs = processIDs
        return next
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}

/// Main-actor facade shared by the hotkey monitor and capture orchestration.
/// Every signal advances `revision` synchronously; capture work can remember a
/// revision and discard a result if the user requested a native screenshot in
/// the meantime.
@MainActor
final class ScreenshotPriorityYieldGate {
    typealias MonotonicMilliseconds = @MainActor () -> UInt64

    private let nowMilliseconds: MonotonicMilliseconds
    private(set) var state = ScreenshotPriorityYieldState()
    private(set) var revision: UInt64 = 0

    /// Called before `openSuppression` or an active-process transition returns.
    /// CaptureCoordinator uses this to drop pending, not-yet-heavy Eye work.
    var onSuppressionOpened: (@MainActor (_ revision: UInt64) -> Void)?

    init(nowMilliseconds: @escaping MonotonicMilliseconds = {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }) {
        self.nowMilliseconds = nowMilliseconds
    }

    @discardableResult
    func openSuppression(now: UInt64? = nil) -> UInt64 {
        state = ScreenshotPriorityYieldPolicy.openingSuppression(
            state,
            at: now ?? nowMilliseconds()
        )
        advanceRevisionAndNotify()
        return revision
    }

    func isSuppressed(now: UInt64? = nil) -> Bool {
        state.isSuppressed(at: now ?? nowMilliseconds())
    }

    /// Reconciliation is used for both NSWorkspace lifecycle edges and the
    /// initial running-process snapshot. A helper keeps the gate open for its
    /// entire lifetime; its exit leaves the same two-second quiet tail.
    func replaceActiveScreenshotProcesses(
        _ processIDs: Set<Int32>,
        now: UInt64? = nil
    ) {
        let next = ScreenshotPriorityYieldPolicy.replacingActiveProcesses(
            processIDs,
            in: state,
            at: now ?? nowMilliseconds()
        )
        guard next != state else { return }
        state = next
        advanceRevisionAndNotify()
    }

    private func advanceRevisionAndNotify() {
        revision &+= 1
        onSuppressionOpened?(revision)
    }
}
