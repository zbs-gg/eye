import Foundation
import GRDB

struct VisibleScreenCaptureStats: Sendable, Equatable {
    let frames: Int
    let textBlocks: Int
    let apps: Int
    let oldestMs: Int64?
    let newestMs: Int64?
}

/// Single source of truth for "is this bundleId real user activity?". System shells (loginwindow,
/// screen saver, Dock, Control Center…) can exist in imported or legacy history, but they are not
/// what the user was DOING — in Activities and usage stats they must read as gaps/idle, never as a
/// "top app". Real apps intentionally pass (Finder, Terminal, System Settings are user activity).
/// Case-insensitive: macOS reports inconsistent casing across versions (Spotlight vs spotlight).
/// Stateless enum + statics — Sendable by construction, usable from any actor.
enum SystemAppFilter {
    enum CaptureAppIDReference: Sendable {
        case unqualified
        case c

        fileprivate var sql: String {
            switch self {
            case .unqualified: "appId"
            case .c: "c.appId"
            }
        }
    }

    /// Privacy-sensitive shells that must not cross any read surface, including
    /// legacy rows written before the capture boundary was hardened.
    private static let protectedCaptureDenied: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.screensaver.engine",
        "com.apple.securityagent",
        "com.apple.authorizationhost",
        "com.apple.localauthentication.uiagent",
        "com.apple.localauthenticationremoteservice",
    ]

    private static let protectedCapturePrefixes: [String] = [
        "com.apple.screensaver",
        "com.apple.localauthentication.",
    ]

    /// Exact bundle ids, stored lowercased.
    private static let denied: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.screensaver.engine",
        "com.apple.dock",
        "com.apple.windowmanager",
        "com.apple.windowserver",
        "com.apple.securityagent",
        "com.apple.authorizationhost",
        "com.apple.localauthentication.uiagent",
        "com.apple.localauthenticationremoteservice",
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
        "com.apple.localauthentication.",
    ]

    /// Name fallback for frames recorded without a bundle id (a system shell sometimes surfaces only as
    /// a process name). Covers loginwindow and the screen saver (whose engine has appeared under several
    /// process names across macOS versions) so an idle lock/screensaver stretch reads as a gap, not activity.
    private static let deniedNames: Set<String> = [
        "loginwindow", "login window",
        "screensaverengine", "legacyscreensaver", "screen saver", "screensaver",
        "securityagent", "security agent", "authorizationhost",
        "localauthentication uiagent", "local authentication uiagent",
        "localauthenticationremoteservice", "local authentication remote service",
        "localauthentication", "local authentication", "coreautha", "touch id",
    ]

    /// True → a system shell, not user activity.
    static func isSystem(bundleId: String?, appName: String? = nil) -> Bool {
        if let bid = normalized(bundleId) {
            if denied.contains(bid) { return true }
            if deniedPrefixes.contains(where: { bid.hasPrefix($0) }) { return true }
        }
        if let name = normalized(appName), deniedNames.contains(name) { return true }
        return false
    }

    /// Narrower than `isSystem`: Dock and Control Center remain ordinary
    /// historical data, while lock and authentication surfaces are hidden from
    /// Timeline, Search, Ask, MCP, summaries, and export without deleting rows.
    static func isProtectedCaptureSurface(bundleId: String?, appName: String? = nil) -> Bool {
        if let bid = normalized(bundleId) {
            if protectedCaptureDenied.contains(bid) { return true }
            if protectedCapturePrefixes.contains(where: { bid.hasPrefix($0) }) { return true }
        }
        if let name = normalized(appName), deniedNames.contains(name) { return true }
        return false
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    static func isProtectedCaptureSurface(_ cap: CaptureLite) -> Bool {
        isProtectedCaptureSurface(bundleId: cap.bundleId, appName: cap.appName)
    }

    /// Resolves the small set of protected app ids once per read transaction.
    /// This keeps privacy filtering in SQL (before ORDER/LIMIT/aggregates) while
    /// retaining the same normalized bundle/name policy used at capture time.
    static func protectedAppIDs(in db: Database) throws -> [Int64] {
        try Row.fetchAll(db, sql: "SELECT id, bundleId, name FROM apps").compactMap { row in
            let id: Int64 = row["id"]
            let bundleID: String? = row["bundleId"]
            let appName: String? = row["name"]
            return isProtectedCaptureSurface(bundleId: bundleID, appName: appName) ? id : nil
        }
    }

    /// SQL fragment built only from database integer primary keys. A NULL appId
    /// remains visible because it carries no app identity to classify.
    static func visibleCapturePredicate(
        _ reference: CaptureAppIDReference,
        protectedAppIDs: [Int64]
    ) -> String {
        guard !protectedAppIDs.isEmpty else { return "1 = 1" }
        let ids = protectedAppIDs.map(String.init).joined(separator: ",")
        let column = reference.sql
        return "(\(column) IS NULL OR \(column) NOT IN (\(ids)))"
    }

    static func visibleScreenCaptureStats(in db: Database) throws -> VisibleScreenCaptureStats {
        let protectedIDs = try protectedAppIDs(in: db)
        let bare = visibleCapturePredicate(.unqualified, protectedAppIDs: protectedIDs)
        let joined = visibleCapturePredicate(.c, protectedAppIDs: protectedIDs)
        guard let row = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS frames, COUNT(DISTINCT appId) AS apps,
                   MIN(ts) AS oldestMs, MAX(ts) AS newestMs
            FROM screen_captures WHERE \(bare)
            """) else {
            return VisibleScreenCaptureStats(
                frames: 0,
                textBlocks: 0,
                apps: 0,
                oldestMs: nil,
                newestMs: nil
            )
        }
        let textBlocks = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM text_blocks t
            JOIN screen_captures c ON c.id = t.captureId
            WHERE \(joined)
            """) ?? 0
        return VisibleScreenCaptureStats(
            frames: row["frames"] ?? 0,
            textBlocks: textBlocks,
            apps: row["apps"] ?? 0,
            oldestMs: row["oldestMs"],
            newestMs: row["newestMs"]
        )
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
