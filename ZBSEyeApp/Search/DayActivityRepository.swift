import Foundation
import GRDB

/// Lightweight frame row for day-activity aggregation (no text). Sendable — passes out of the actor.
struct CaptureLite: Sendable {
    let id: Int64
    let ts: Int64
    let appId: Int64?
    let appName: String?
    let bundleId: String?
    let windowTitle: String?
    let browserUrl: String?
}

/// One activity session: consecutive frames of one group (app or app+window) with a pause tolerance.
/// Holds the frames themselves (not just ids) — the consumer takes first/last/rep on the spot.
struct ActivitySession: Sendable {
    let captures: [CaptureLite]            // non-empty, ts ASC
    var first: CaptureLite { captures[0] }
    var last: CaptureLite { captures[captures.count - 1] }
    var rep: CaptureLite { captures[captures.count / 2] }   // representative — the middle by index
    var count: Int { captures.count }
    var startMs: Int64 { first.ts }
    var endMs: Int64 { last.ts }
    var durationMs: Int64 { last.ts - first.ts }
    var appId: Int64? { first.appId }
    var captureIds: [Int64] { captures.map(\.id) }

    /// Up to `max` captureIds spread EVENLY across the session (not just the start) — so the text selection
    /// isn't skewed toward the start of a long session (the longest text block can be anywhere).
    func sampledCaptureIds(max: Int) -> [Int64] {
        let ids = captureIds
        guard max > 0, ids.count > max else { return ids }
        let step = Double(ids.count) / Double(max)
        return (0..<max).map { ids[min(ids.count - 1, Int(Double($0) * step))] }
    }
}

/// How to group frames into sessions.
enum SessionGrouping: Sendable {
    case appOnly        // scene = one app (Scenes; the window can change within)
    case appAndWindow   // session = app + window (DailySummary, Cartographer)
}

/// Shared day-activity aggregation layer: ONE frame scan + pure functions for segmentation / active
/// time / context switches + batch text. Dedup of logic that was smeared across
/// SceneService / CartographerService / DailySummaryService (Pro review #9). Actor: read only, not a writer.
actor DayActivityRepository {
    private let db: ZBSEyeDatabase
    init(db: ZBSEyeDatabase) { self.db = db }

    // MARK: — fetching (DB)

    /// One scan of the range's frames (ts ASC). Lightweight fields — no text.
    func captures(fromMs: Int64, toMs: Int64) async throws -> [CaptureLite] {
        try await db.pool.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT c.id AS id, c.ts AS ts, c.appId AS appId,
                       a.name AS appName, a.bundleId AS bundleId,
                       c.windowTitle AS windowTitle, c.browserUrl AS browserUrl
                FROM screen_captures c LEFT JOIN apps a ON a.id = c.appId
                WHERE c.ts BETWEEN ? AND ? ORDER BY c.ts ASC, c.id ASC
                """, arguments: [fromMs, toMs]).map {
                CaptureLite(id: $0["id"], ts: $0["ts"], appId: $0["appId"],
                            appName: $0["appName"], bundleId: $0["bundleId"],
                            windowTitle: $0["windowTitle"], browserUrl: $0["browserUrl"])
            }
        }
    }

    /// Frames for a single calendar day (`day` — any time within it).
    func captures(forDay day: Date) async throws -> [CaptureLite] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return try await captures(fromMs: msFromDate(start), toMs: msFromDate(end) - 1)
    }

    /// Frame text in a single query (`group_concat` per capture) — no N+1.
    func batchText(captureIds: [Int64]) async throws -> [Int64: String] {
        let ids = Array(Set(captureIds))
        guard !ids.isEmpty else { return [:] }
        return try await db.pool.read { dbc -> [Int64: String] in
            let ph = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(dbc, sql: """
                SELECT captureId, group_concat(text, ' ') AS txt
                FROM text_blocks WHERE captureId IN (\(ph)) GROUP BY captureId
                """, arguments: StatementArguments(ids))
            var out: [Int64: String] = [:]
            for r in rows { out[r["captureId"]] = r["txt"] ?? "" }
            return out
        }
    }

    /// For browser frames that have NO usable URL (Dia/Arc hide it from AX), recover the real host from
    /// imported `browser_visits` by matching the same browser near the frame's timestamp. capId → host.
    /// One range query + in-memory nearest-match (no N+1). Falls back to nothing when no visit is near.
    func browserHostOverrides(_ caps: [CaptureLite], toleranceMs: Int64 = 90_000) async throws -> [Int64: String] {
        let targets = caps.filter { c in
            guard let b = c.bundleId, Self.browserBundleIds.contains(b) else { return false }
            if let u = c.browserUrl, Self.hostFromURL(u) != nil { return false }   // already has a host
            return true
        }
        guard !targets.isEmpty, let lo = caps.first?.ts, let hi = caps.last?.ts else { return [:] }
        let rows = try await db.pool.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT browser, ts, host FROM browser_visits
                WHERE ts BETWEEN ? AND ? AND host IS NOT NULL ORDER BY ts
                """, arguments: [lo - toleranceMs, hi + toleranceMs])
        }
        var byBrowser: [String: [(ts: Int64, host: String)]] = [:]
        for r in rows {
            let b: String = r["browser"]; let ts: Int64 = r["ts"]; let host: String = r["host"]
            byBrowser[b, default: []].append((ts, host))
        }
        var out: [Int64: String] = [:]
        for c in targets {
            guard let b = c.bundleId, let visits = byBrowser[b] else { continue }
            var best: (d: Int64, host: String)? = nil
            for v in visits {
                let d = abs(v.ts - c.ts)
                if d <= toleranceMs && (best == nil || d < best!.d) { best = (d, v.host) }
            }
            if let best { out[c.id] = best.host }
        }
        return out
    }

    // MARK: — pure functions (no DB, independently testable)

    /// Segment frames into sessions. A new session on a group change OR a gap > gapMs.
    static func sessions(_ caps: [CaptureLite], grouping: SessionGrouping, gapMs: Int64) -> [ActivitySession] {
        guard !caps.isEmpty else { return [] }
        func sameGroup(_ a: CaptureLite, _ b: CaptureLite) -> Bool {
            switch grouping {
            case .appOnly:      return a.appId == b.appId
            case .appAndWindow: return a.appId == b.appId && a.windowTitle == b.windowTitle
            }
        }
        var sessions: [ActivitySession] = []
        var bucket: [CaptureLite] = [caps[0]]
        for cap in caps.dropFirst() {
            let head = bucket[0]
            let last = bucket[bucket.count - 1]
            if sameGroup(cap, head) && (cap.ts - last.ts) <= gapMs {
                bucket.append(cap)
            } else {
                sessions.append(ActivitySession(captures: bucket))
                bucket = [cap]
            }
        }
        sessions.append(ActivitySession(captures: bucket))
        return sessions
    }

    /// Active time per app (ms): the delta from the previous frame is credited to the previous app,
    /// with an idle cap (delta > activeGapCapMs = idle, count at most cap). Frame count ≠ time
    /// (the capture interval drifts: active≈3s, idle≈60s, bursts/dedup).
    static func appActiveMs(_ caps: [CaptureLite], activeGapCapMs: Int64) -> [Int64: Int64] {
        var dur: [Int64: Int64] = [:]
        var prev: CaptureLite? = nil
        for cap in caps {
            if let p = prev, let appId = p.appId {
                dur[appId, default: 0] += min(cap.ts - p.ts, activeGapCapMs)
            }
            prev = cap
        }
        return dur
    }

    /// Browser bundle ids — for these, a single "app" is meaningless (a browser is like the OS); time is
    /// attributed per site/page instead. company.thebrowser.dia = Dia, .arc = Arc.
    static let browserBundleIds: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.dia", "company.thebrowser.arc",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera",
    ]

    /// A site/page label for a browser frame; nil for non-browsers. Prefers the URL host (accurate);
    /// falls back to the window/tab title (Dia/Arc don't expose the URL via AX, so title is all we have).
    static func browserSite(_ cap: CaptureLite) -> String? {
        guard let bid = cap.bundleId, browserBundleIds.contains(bid) else { return nil }
        if let url = cap.browserUrl, let host = hostFromURL(url) { return host }
        if let wt = cap.windowTitle, case let page = cleanPageTitle(wt), !page.isEmpty { return page }
        return nil
    }

    /// host("https://github.com/x/y?z") -> "github.com". Uses URLComponents so ports, credentials,
    /// uppercase schemes, IPv6, query-only URLs and IDNs are handled correctly. Only http(s).
    static func hostFromURL(_ url: String) -> String? {
        guard let comps = URLComponents(string: url),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = comps.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }

    /// Clean a browser window/tab title into a compact page label: drop the "Profile N: " Chromium prefix
    /// and any trailing " - <Browser>" suffix, collapse whitespace, cap length.
    static func cleanPageTitle(_ title: String) -> String {
        var t = title.replacingOccurrences(of: #"^Profile \d+:\s*"#, with: "", options: .regularExpression)
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if let dash = t.range(of: " - ", options: .backwards) { t = String(t[t.startIndex..<dash.lowerBound]) }
        return String(t.prefix(48)).trimmingCharacters(in: .whitespaces)
    }

    /// Group key + display label for a frame: browsers roll up per site/page ("Dia · github.com"),
    /// everything else per app.
    /// `hostOverride` (from `browserHostOverrides`) recovers the real host for browsers that hide the URL
    /// from AX (Dia/Arc) — so their time rolls up by SITE, not by page title. Falls back to the URL host
    /// / cleaned title only when there's no history match.
    static func groupKeyLabel(_ cap: CaptureLite, hostOverride: String? = nil) -> (key: String, label: String) {
        let app = cap.appName ?? "—"
        if let site = hostOverride ?? browserSite(cap) {
            return ("b:\(cap.appId ?? -1):\(site)", "\(app) · \(site)")
        }
        return ("a:\(cap.appId ?? -1)", app)
    }

    /// Active time per site-aware group (ms) + frame count + display label. Same delta-crediting as
    /// `appActiveMs`, but the key splits browsers by site so "Dia" becomes "Dia · github.com" etc.
    /// `hosts` (capId → host, from browserHostOverrides) supplies real hosts for URL-hiding browsers.
    static func appSiteActiveMs(_ caps: [CaptureLite], activeGapCapMs: Int64, hosts: [Int64: String] = [:])
        -> (ms: [String: Int64], count: [String: Int], label: [String: String]) {
        var dur: [String: Int64] = [:], count: [String: Int] = [:], label: [String: String] = [:]
        var prev: CaptureLite? = nil
        for cap in caps {
            let (k, l) = groupKeyLabel(cap, hostOverride: hosts[cap.id])
            count[k, default: 0] += 1
            label[k] = l
            if let p = prev {
                let pk = groupKeyLabel(p, hostOverride: hosts[p.id]).key
                dur[pk, default: 0] += min(cap.ts - p.ts, activeGapCapMs)
            }
            prev = cap
        }
        return (dur, count, label)
    }

    /// Context switches per day: adjacent frames with a different appId/windowTitle.
    static func contextSwitches(_ caps: [CaptureLite]) -> Int {
        var switches = 0, hasPrev = false
        var prevApp: Int64? = nil, prevWin: String? = nil
        for cap in caps {
            if hasPrev && (cap.appId != prevApp || cap.windowTitle != prevWin) { switches += 1 }
            prevApp = cap.appId; prevWin = cap.windowTitle; hasPrev = true
        }
        return switches
    }
}
