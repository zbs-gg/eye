import Foundation
import Observation
import GRDB

/// Breakdown of used space (Sendable — returned from a Task.detached into @MainActor). Attribution
/// import/live by monitorId='sp' (live capture writes monitorId=String(displayID): '0'/'1'…).
struct StorageBreakdown: Sendable, Equatable {
    var framesTotal = 0
    var framesImport = 0
    var framesLive = 0
    var audioTotal = 0
    var oldestTs: Int64?
    var newestTs: Int64?
    var liveFrameBytes: Int64 = 0       // import has bytes=NULL → this is the size of live frames in the DB only
    var topApps: [AppUsage] = []

    struct AppUsage: Sendable, Equatable, Identifiable {
        let name: String
        let frames: Int
        var id: String { name }
    }
}

/// Storage settings: retention (days/size, 0 = no limit) + how much is actually used.
/// Before, the user had no idea their history only lived 7 days (hardcoded, no UI) — for a
/// "memory forever" product that's a silent erasure of three weeks of life.
@MainActor
@Observable
final class StorageSettingsStore {
    /// 0 = keep forever. Default 0 ("memory forever" — we do NOT delete by default).
    var retentionDays: Int {
        didSet { if retentionDays != oldValue { UserDefaults.standard.set(retentionDays, forKey: Self.daysKey) } }
    }
    /// Limit in GB; 0 = no limit. Default 0.
    var maxGB: Int {
        didSet { if maxGB != oldValue { UserDefaults.standard.set(maxGB, forKey: Self.gbKey) } }
    }

    private(set) var mediaBytes: Int64 = 0
    private(set) var databaseBytes: Int64 = 0
    private(set) var freeBytes: Int64 = 0
    private(set) var breakdown: StorageBreakdown?
    var totalBytes: Int64 { mediaBytes + databaseBytes }

    // relocate (T1): storage relocation state
    var relocationInProgress = false
    var relocationProgress: Double = 0
    var relocationStatus = ""
    var relocationError: String?
    var dataRootDisplay: String { StorageLocation.displayPath() }
    var isRelocated: Bool { StorageLocation.isRelocated() }

    @ObservationIgnored private static let daysKey = "zbseye.retention.days"
    @ObservationIgnored private static let gbKey = "zbseye.retention.maxGB"

    static let dayOptions = [0, 7, 14, 30, 90]   // 0 = "Forever" first: the default and the essence of the product
    static let gbOptions = [0, 10, 20, 50, 100]   // 0 = "No limit" first

    var effectiveDays: Int? { retentionDays <= 0 ? nil : retentionDays }
    var effectiveMaxBytes: Int64? { maxGB <= 0 ? nil : Int64(maxGB) * 1024 * 1024 * 1024 }

    init() {
        let d = UserDefaults.standard
        retentionDays = (d.object(forKey: Self.daysKey) == nil) ? RetentionPolicy.defaultDays
                                                                : d.integer(forKey: Self.daysKey)
        maxGB = (d.object(forKey: Self.gbKey) == nil) ? 0 : d.integer(forKey: Self.gbKey)
    }

    /// Recompute used space (media — folder walk, DB — size of sqlite+wal, free on the volume) +
    /// the breakdown from the DB (import/live frames, audio, date range, top apps). Called when
    /// Settings opens; all on a utility-priority background with a single read transaction.
    func refresh(storage: StorageManager?, db: ZBSEyeDatabase?) async {
        guard let storage else { return }
        let computed = await Task.detached(priority: .utility) { () async -> (Int64, Int64, Int64, StorageBreakdown?) in
            let media = storage.totalBytes()
            let free = storage.freeBytes()
            var dbBytes: Int64 = 0
            if let url = try? ZBSEyeDatabase.defaultURL() {
                for suffix in ["", "-wal", "-shm"] {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path + suffix)
                    dbBytes += (attrs?[.size] as? Int64) ?? 0
                }
            }
            let bd: StorageBreakdown? = await Self.computeBreakdown(db: db)
            return (media, dbBytes, free, bd)
        }.value
        mediaBytes = computed.0
        databaseBytes = computed.1
        freeBytes = computed.2
        breakdown = computed.3
    }

    /// One aggregate read transaction: counters/attribution/range + top apps. nil when there's no DB.
    /// nonisolated: called from the Task.detached in refresh, must not hop onto MainActor.
    nonisolated private static func computeBreakdown(db: ZBSEyeDatabase?) async -> StorageBreakdown? {
        guard let db else { return nil }
        return try? await db.pool.read { dbc -> StorageBreakdown in
            var bd = StorageBreakdown()
            if let row = try Row.fetchOne(dbc, sql: """
                SELECT
                  (SELECT COUNT(*) FROM screen_captures) AS framesTotal,
                  (SELECT COUNT(*) FROM screen_captures WHERE monitorId = 'sp') AS framesImport,
                  (SELECT COUNT(*) FROM screen_captures WHERE monitorId <> 'sp') AS framesLive,
                  (SELECT COUNT(*) FROM audio_captures) AS audioTotal,
                  (SELECT MIN(ts) FROM screen_captures) AS oldestTs,
                  (SELECT MAX(ts) FROM screen_captures) AS newestTs,
                  (SELECT COALESCE(SUM(bytes), 0) FROM screen_captures WHERE bytes IS NOT NULL) AS liveFrameBytes
                """) {
                bd.framesTotal = row["framesTotal"] ?? 0
                bd.framesImport = row["framesImport"] ?? 0
                bd.framesLive = row["framesLive"] ?? 0
                bd.audioTotal = row["audioTotal"] ?? 0
                bd.oldestTs = row["oldestTs"]
                bd.newestTs = row["newestTs"]
                bd.liveFrameBytes = row["liveFrameBytes"] ?? 0
            }
            bd.topApps = try Row.fetchAll(dbc, sql: """
                SELECT COALESCE(a.name, '(?)') AS name, COUNT(*) AS frames
                FROM screen_captures c LEFT JOIN apps a ON a.id = c.appId
                GROUP BY c.appId ORDER BY frames DESC LIMIT 6
                """).map { StorageBreakdown.AppUsage(name: $0["name"], frames: $0["frames"]) }
            return bd
        }
    }

    nonisolated static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
