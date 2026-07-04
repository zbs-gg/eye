import Foundation

/// Single source of truth for "is this bundleId real user activity?". System shells (loginwindow,
/// screen saver, Dock, Control Center…) get captured like any frontmost app, but they are not what
/// the user was DOING — in Activities and usage stats they must read as gaps/idle, never as a
/// "top app". Real apps intentionally pass (Finder, Terminal, System Settings are user activity).
/// Case-insensitive: macOS reports inconsistent casing across versions (Spotlight vs spotlight).
/// Stateless enum + statics — Sendable by construction, usable from any actor.
enum SystemAppFilter {
    /// Exact bundle ids, stored lowercased.
    private static let denied: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.screensaver.engine",
        "com.apple.dock",
        "com.apple.windowmanager",
        "com.apple.windowserver",
        "com.apple.securityagent",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenter",
        "com.apple.notificationcenterui",   // real id of Notification Center on modern macOS
        "com.apple.spotlight",
        "com.apple.usernotificationcenter",
        "com.apple.coreservices.uiagent",
    ]

    /// Prefix families (screen-saver engine ids vary across macOS versions).
    private static let deniedPrefixes: [String] = [
        "com.apple.screensaver",
    ]

    /// Name fallback for frames recorded without a bundle id (a system shell sometimes surfaces only as
    /// a process name). Covers loginwindow and the screen saver (whose engine has appeared under several
    /// process names across macOS versions) so an idle lock/screensaver stretch reads as a gap, not activity.
    private static let deniedNames: Set<String> = [
        "loginwindow", "login window",
        "screensaverengine", "legacyscreensaver", "screen saver", "screensaver",
    ]

    /// True → a system shell, not user activity.
    static func isSystem(bundleId: String?, appName: String? = nil) -> Bool {
        if let bid = bundleId?.lowercased(), !bid.isEmpty {
            if denied.contains(bid) { return true }
            if deniedPrefixes.contains(where: { bid.hasPrefix($0) }) { return true }
        }
        if let name = appName?.lowercased(), deniedNames.contains(name) { return true }
        return false
    }

    static func isSystem(_ cap: CaptureLite) -> Bool {
        isSystem(bundleId: cap.bundleId, appName: cap.appName)
    }

    /// Frames that represent real user activity (system shells removed). The removed frames become
    /// plain gaps for downstream segmentation/aggregation — exactly how idle time already behaves.
    static func userCaptures(_ caps: [CaptureLite]) -> [CaptureLite] {
        caps.filter { !isSystem($0) }
    }
}
