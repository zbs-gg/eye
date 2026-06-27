import Foundation
import GRDB

/// Queries for the time-travel scrubber: history bounds, frame ticks, density by buckets, the frame at a moment.
actor TimelineService {
    private let db: ZBSEyeDatabase
    init(db: ZBSEyeDatabase) { self.db = db }

    /// History bounds across BOTH sources (screen + audio): live audio over a static screen also
    /// moves the timeline tail (otherwise a call recording wouldn't appear on the strip until a new frame).
    func bounds() async throws -> TimeBounds {
        try await db.pool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT MIN(t) AS lo, MAX(t) AS hi FROM (
                    SELECT MIN(ts) AS t FROM screen_captures
                    UNION ALL SELECT MAX(ts) FROM screen_captures
                    UNION ALL SELECT MIN(ts) FROM audio_captures
                    UNION ALL SELECT MAX(ts) FROM audio_captures
                ) WHERE t IS NOT NULL
                """)
            let lo: Int64? = row?["lo"]
            let hi: Int64? = row?["hi"]
            return TimeBounds(oldest: lo.map(dateFromMs), newest: hi.map(dateFromMs))
        }
    }

    /// Activity density by buckets (for the density strip). bucketMs — bucket width.
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

    /// The nearest frame ≤ the time + its aggregated text and context.
    func frameAt(_ time: Date) async throws -> FrameDetail? {
        try await fetchFrame(where: "c.ts <= ? ORDER BY c.ts DESC, c.id DESC", args: [msFromDate(time)])
    }

    /// Strictly the next frame — for stepping forward and the player. Tie-break (ts,id): frames with equal ts
    /// (multi-monitor) don't collapse — the player visits each. afterId nil → a strict ts transition.
    func nextFrame(after time: Date, afterId: Int64? = nil) async throws -> FrameDetail? {
        let t = msFromDate(time)
        if let id = afterId {
            return try await fetchFrame(
                where: "(c.ts > ? OR (c.ts = ? AND c.id > ?)) ORDER BY c.ts ASC, c.id ASC",
                args: [t, t, id])
        }
        return try await fetchFrame(where: "c.ts > ? ORDER BY c.ts ASC, c.id ASC", args: [t])
    }

    /// Strictly the previous frame — for stepping back (mirrored tie-break).
    func prevFrame(before time: Date, beforeId: Int64? = nil) async throws -> FrameDetail? {
        let t = msFromDate(time)
        if let id = beforeId {
            return try await fetchFrame(
                where: "(c.ts < ? OR (c.ts = ? AND c.id < ?)) ORDER BY c.ts DESC, c.id DESC",
                args: [t, t, id])
        }
        return try await fetchFrame(where: "c.ts < ? ORDER BY c.ts DESC, c.id DESC", args: [t])
    }

    func frameDetail(id: Int64) async throws -> FrameDetail? {
        try await fetchFrame(where: "c.id = ?", args: [id])
    }

    /// AUDIO activity density (the density strip's second track): where in history there's speech.
    func audioDensity(from: Date, to: Date, bucketMs: Int64) async throws -> [DensityBucket] {
        let f = msFromDate(from), t = msFromDate(to)
        let b = max(1000, bucketMs)
        return try await db.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT (ts / ?) * ? AS bucket, COUNT(*) AS c
                FROM audio_captures WHERE ts BETWEEN ? AND ?
                GROUP BY bucket ORDER BY bucket
                """, arguments: [b, b, f, t]).map {
                DensityBucket(ts: dateFromMs($0["bucket"]), count: $0["c"])
            }
        }
    }

    /// Audio segment + its transcript (for the listening panel in the timeline).
    func audioDetail(id: Int64) async throws -> AudioDetail? {
        try await db.pool.read { db in
            guard let row = try Row.fetchOne(db, sql:
                "SELECT id, ts, durationSec, channel, relativePath FROM audio_captures WHERE id = ?",
                arguments: [id]) else { return nil }
            let tr = try Row.fetchOne(db, sql:
                "SELECT text, language, speaker FROM transcriptions WHERE audioId = ? ORDER BY id DESC LIMIT 1",
                arguments: [id])
            return AudioDetail(
                id: row["id"], ts: dateFromMs(row["ts"]), durationSec: row["durationSec"],
                channel: row["channel"], relativePath: row["relativePath"],
                transcript: tr?["text"], language: tr?["language"], speaker: tr?["speaker"])
        }
    }

    // Shared mapping: one frame by a predicate + its concatenated text. clause doesn't need to include ORDER/LIMIT —
    // we add LIMIT 1 here; ORDER is set in clause before LIMIT. clause — the compile-time constants above.
    private func fetchFrame(where clause: String, args: [Int64]) async throws -> FrameDetail? {
        try await db.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT c.id AS id, c.ts AS ts, c.relativePath AS relativePath, c.windowTitle AS windowTitle,
                       c.browserUrl AS browserUrl, c.axQuality AS axQuality, a.bundleId AS bundleId, a.name AS appName
                FROM screen_captures c LEFT JOIN apps a ON a.id = c.appId
                WHERE \(clause) LIMIT 1
                """, arguments: StatementArguments(args)) else { return nil }
            let id: Int64 = row["id"]
            let text = try String.fetchOne(db, sql:
                "SELECT group_concat(text, '\n') FROM text_blocks WHERE captureId = ?", arguments: [id]) ?? ""
            let sources = try String.fetchAll(db, sql:
                "SELECT DISTINCT source FROM text_blocks WHERE captureId = ?", arguments: [id])
            return FrameDetail(
                id: id, ts: dateFromMs(row["ts"]), relativePath: row["relativePath"],
                bundleId: row["bundleId"], appName: row["appName"],
                windowTitle: row["windowTitle"], browserURL: row["browserUrl"],
                text: text, axQuality: row["axQuality"], sources: sources)
        }
    }
}
