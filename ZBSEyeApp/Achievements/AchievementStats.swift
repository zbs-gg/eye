import Foundation
import GRDB

/// Statistics snapshot for evaluating achievement conditions. Sendable — computed on a background thread, handed
/// to the MainActor. The "today" part is computed for TODAY (cheap); persisting unlocks in AchievementStore
/// keeps the unlock permanent even if tomorrow the daily value resets.
struct AchievementStats: Sendable {
    // lifetime (DB)
    var totalFrames = 0
    var activeDays = 0
    var streakDays = 0
    var memoryAgeDays = 0
    var maxFramesInOneDay = 0
    var distinctAppsAllTime = 0
    var maxDistinctAppsInDay = 0
    var distinctBrowserDomains = 0
    var hadNightActivity = false
    var hadEarlyActivity = false
    var hadWeekendActivity = false
    // today (via DayActivityRepository)
    var maxSwitchesInDay = 0
    var hadFocusDay = false
    var maxSingleAppMinutes = 0
    // event counters (UserDefaults — interactions)
    var searches = 0
    var questions = 0
    var cartographerRuns = 0
    var activitiesOpened = 0
    var deletedPeriod = false
    var relocated = false
    var icloudBackup = false
}

/// Computes AchievementStats from the DB + counters. Actor: read-only.
actor AchievementStatsService {
    private let db: ZBSEyeDatabase
    private let repo: DayActivityRepository

    init(db: ZBSEyeDatabase, repo: DayActivityRepository) {
        self.db = db
        self.repo = repo
    }

    /// Sendable result of the DB read (can't mutate a captured var inside a @Sendable read closure —
    /// we return a struct outward, as in ProgressStore).
    private struct DBDerived: Sendable {
        var totalFrames = 0, distinctAppsAllTime = 0, memoryAgeDays = 0
        var activeDays = 0, streakDays = 0
        var maxFramesInOneDay = 0, maxDistinctAppsInDay = 0, distinctBrowserDomains = 0
        var hadNight = false, hadEarly = false, hadWeekend = false
    }

    func compute() async -> AchievementStats {
        var s = AchievementStats()

        let d: DBDerived? = try? await db.pool.read { dbc -> DBDerived in
            var r = DBDerived()
            guard let row = try Row.fetchOne(dbc, sql: """
                SELECT COUNT(*) AS n, MIN(ts) AS minTs, COUNT(DISTINCT appId) AS apps FROM screen_captures
                """) else { return r }
            r.totalFrames = row["n"] ?? 0
            r.distinctAppsAllTime = row["apps"] ?? 0
            if let minTs = row["minTs"] as Int64? {
                let first = Date(timeIntervalSince1970: Double(minTs) / 1000.0)
                r.memoryAgeDays = max(0, Calendar.current.dateComponents([.day], from: first, to: Date()).day ?? 0)
            }
            guard r.totalFrames > 0 else { return r }

            let days = try String.fetchAll(dbc, sql: """
                SELECT DISTINCT date(ts/1000,'unixepoch','localtime') AS d
                FROM screen_captures ORDER BY d DESC
                """)
            r.activeDays = days.count
            let cal = Calendar.current
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.locale = Locale(identifier: "en_US_POSIX")
            var expected = cal.startOfDay(for: Date())
            for ds in days {
                guard let dd = fmt.date(from: ds), cal.startOfDay(for: dd) == expected else { break }
                r.streakDays += 1
                expected = cal.date(byAdding: .day, value: -1, to: expected) ?? expected
            }

            r.maxFramesInOneDay = try Int.fetchOne(dbc, sql: """
                SELECT MAX(c) FROM (SELECT COUNT(*) c FROM screen_captures
                GROUP BY date(ts/1000,'unixepoch','localtime'))
                """) ?? 0
            r.maxDistinctAppsInDay = try Int.fetchOne(dbc, sql: """
                SELECT MAX(c) FROM (SELECT COUNT(DISTINCT appId) c FROM screen_captures
                GROUP BY date(ts/1000,'unixepoch','localtime'))
                """) ?? 0

            r.hadNight = (try Int.fetchOne(dbc, sql: """
                SELECT EXISTS(SELECT 1 FROM screen_captures
                WHERE CAST(strftime('%H', ts/1000, 'unixepoch','localtime') AS INTEGER) < 5)
                """) ?? 0) == 1
            r.hadEarly = (try Int.fetchOne(dbc, sql: """
                SELECT EXISTS(SELECT 1 FROM screen_captures
                WHERE CAST(strftime('%H', ts/1000, 'unixepoch','localtime') AS INTEGER) BETWEEN 5 AND 6)
                """) ?? 0) == 1
            r.hadWeekend = (try Int.fetchOne(dbc, sql: """
                SELECT EXISTS(SELECT 1 FROM screen_captures
                WHERE strftime('%w', ts/1000, 'unixepoch','localtime') IN ('0','6'))
                """) ?? 0) == 1

            let urls = try String.fetchAll(dbc, sql: """
                SELECT DISTINCT browserUrl FROM screen_captures
                WHERE browserUrl IS NOT NULL AND browserUrl <> '' LIMIT 5000
                """)
            var hosts = Set<String>()
            for u in urls { if let h = URL(string: u)?.host { hosts.insert(h) } }
            r.distinctBrowserDomains = hosts.count
            return r
        }

        if let d {
            s.totalFrames = d.totalFrames
            s.distinctAppsAllTime = d.distinctAppsAllTime
            s.memoryAgeDays = d.memoryAgeDays
            s.activeDays = d.activeDays
            s.streakDays = d.streakDays
            s.maxFramesInOneDay = d.maxFramesInOneDay
            s.maxDistinctAppsInDay = d.maxDistinctAppsInDay
            s.distinctBrowserDomains = d.distinctBrowserDomains
            s.hadNightActivity = d.hadNight
            s.hadEarlyActivity = d.hadEarly
            s.hadWeekendActivity = d.hadWeekend
        }

        // ── today: context switches / focus day / longest single-app session ──
        if let caps = try? await repo.captures(forDay: Date()), !caps.isEmpty {
            s.maxSwitchesInDay = DayActivityRepository.contextSwitches(caps)
            let sessions = DayActivityRepository.sessions(caps, grouping: .appOnly, gapMs: 180 * 1000)
            let longest = sessions.map(\.durationMs).max() ?? 0
            s.maxSingleAppMinutes = Int(longest / 60000)
            s.hadFocusDay = caps.count >= 1000 && s.maxSwitchesInDay <= 40
        }

        // ── event counters ──
        s.searches = AchievementCounters.value(.searches)
        s.questions = AchievementCounters.value(.questions)
        s.cartographerRuns = AchievementCounters.value(.cartographerRuns)
        s.activitiesOpened = AchievementCounters.value(.activitiesOpened)
        s.deletedPeriod = AchievementCounters.flag(.deletedPeriod)
        s.relocated = AchievementCounters.flag(.relocated)
        s.icloudBackup = AchievementCounters.flag(.icloudBackup)

        return s
    }
}

/// Interaction counters/flags in UserDefaults — incremented from the relevant stores
/// (search, "Ask", Cartographer, delete/relocate/backup). Cheap, persists between launches.
enum AchievementCounters {
    enum Counter: String { case searches, questions, cartographerRuns, activitiesOpened }
    enum Flag: String { case deletedPeriod, relocated, icloudBackup }

    private static func key(_ s: String) -> String { "zbseye.ach.\(s)" }

    @MainActor static func bump(_ c: Counter, by n: Int = 1) {
        let k = key(c.rawValue)
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: k) + n, forKey: k)
    }
    @MainActor static func set(_ f: Flag) { UserDefaults.standard.set(true, forKey: key(f.rawValue)) }

    static func value(_ c: Counter) -> Int { UserDefaults.standard.integer(forKey: key(c.rawValue)) }
    static func flag(_ f: Flag) -> Bool { UserDefaults.standard.bool(forKey: key(f.rawValue)) }
}
