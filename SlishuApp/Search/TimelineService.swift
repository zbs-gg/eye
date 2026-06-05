import Foundation
import GRDB

/// Запросы для time-travel скруббера: границы истории, тики кадров, плотность по бакетам, кадр в момент.
actor TimelineService {
    private let db: SlishuDatabase
    init(db: SlishuDatabase) { self.db = db }

    func bounds() async throws -> TimeBounds {
        try await db.pool.read { db in
            let oldest = try Int64.fetchOne(db, sql: "SELECT MIN(ts) FROM screen_captures")
            let newest = try Int64.fetchOne(db, sql: "SELECT MAX(ts) FROM screen_captures")
            return TimeBounds(oldest: oldest.map(dateFromMs), newest: newest.map(dateFromMs))
        }
    }

    /// Плотность активности по бакетам (для density-strip). bucketMs — ширина бакета.
    func density(from: Date, to: Date, bucketMs: Int64) async throws -> [DensityBucket] {
        let f = msFromDate(from), t = msFromDate(to)
        let b = max(1000, bucketMs)
        return try await db.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT (ts / ?) * ? AS bucket, COUNT(*) AS c
                FROM screen_captures WHERE ts BETWEEN ? AND ?
                GROUP BY bucket ORDER BY bucket
                """, arguments: [b, b, f, t]).map {
                DensityBucket(ts: dateFromMs($0["bucket"]), count: $0["c"])
            }
        }
    }

    /// Ближайший кадр ≤ времени + его агрегированный текст и контекст.
    func frameAt(_ time: Date) async throws -> FrameDetail? {
        let tm = msFromDate(time)
        return try await db.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT c.id AS id, c.ts AS ts, c.relativePath AS relativePath, c.windowTitle AS windowTitle,
                       c.browserUrl AS browserUrl, c.axQuality AS axQuality, a.bundleId AS bundleId, a.name AS appName
                FROM screen_captures c LEFT JOIN apps a ON a.id = c.appId
                WHERE c.ts <= ? ORDER BY c.ts DESC LIMIT 1
                """, arguments: [tm]) else { return nil }
            let id: Int64 = row["id"]
            let text = try String.fetchOne(db, sql:
                "SELECT group_concat(text, '\n') FROM text_blocks WHERE captureId = ?", arguments: [id]) ?? ""
            return FrameDetail(
                id: id, ts: dateFromMs(row["ts"]), relativePath: row["relativePath"],
                bundleId: row["bundleId"], appName: row["appName"],
                windowTitle: row["windowTitle"], browserURL: row["browserUrl"],
                text: text, axQuality: row["axQuality"])
        }
    }

    func frameDetail(id: Int64) async throws -> FrameDetail? {
        try await db.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT c.id AS id, c.ts AS ts, c.relativePath AS relativePath, c.windowTitle AS windowTitle,
                       c.browserUrl AS browserUrl, c.axQuality AS axQuality, a.bundleId AS bundleId, a.name AS appName
                FROM screen_captures c LEFT JOIN apps a ON a.id = c.appId WHERE c.id = ?
                """, arguments: [id]) else { return nil }
            let text = try String.fetchOne(db, sql:
                "SELECT group_concat(text, '\n') FROM text_blocks WHERE captureId = ?", arguments: [id]) ?? ""
            return FrameDetail(
                id: id, ts: dateFromMs(row["ts"]), relativePath: row["relativePath"],
                bundleId: row["bundleId"], appName: row["appName"],
                windowTitle: row["windowTitle"], browserURL: row["browserUrl"],
                text: text, axQuality: row["axQuality"])
        }
    }
}
