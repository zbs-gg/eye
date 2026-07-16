import Foundation
import GRDB

/// Queries for the time-travel scrubber: history bounds, frame ticks, density by buckets, the frame at a moment.
actor TimelineService {
    private let db: ZBSEyeDatabase
    init(db: ZBSEyeDatabase) { self.db = db }

    /// History bounds across screen, legacy audio, and explicit calls: live audio over a static screen also
    /// moves the timeline tail (otherwise a call recording wouldn't appear on the strip until a new frame).
    func bounds() async throws -> TimeBounds {
        try await db.pool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT MIN(t) AS lo, MAX(t) AS hi FROM (
                    SELECT MIN(ts) AS t FROM screen_captures
                    UNION ALL SELECT MAX(ts) FROM screen_captures
                    UNION ALL SELECT MIN(ts) FROM audio_captures
                    UNION ALL SELECT MAX(ts) FROM audio_captures
                    UNION ALL SELECT MIN(startTs) FROM calls
                    UNION ALL SELECT MAX(COALESCE(endTs, startTs)) FROM calls
                    UNION ALL SELECT MAX(endMs) FROM call_audio_chunks
                ) WHERE t IS NOT NULL
                """)
            let lo: Int64? = row?["lo"]
            let hi: Int64? = row?["hi"]
            return TimeBounds(oldest: lo.map(dateFromMs), newest: hi.map(dateFromMs))
        }
    }

    /// Bounded first-class call spans for the timeline. Bookmarks are markers, never separate fake audio hits.
    /// State is derived from durable evidence and deliberately exposes only the four promises the strip can keep.
    func callSpans(from: Date, to: Date, limit: Int = 200) async throws -> [CallTimelineSpan] {
        let fromMs = msFromDate(from)
        let toMs = msFromDate(to)
        let boundedLimit = max(1, min(limit, 200))
        return try await db.pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id AS id, c.startTs AS startTs, c.endTs AS endTs,
                       c.state AS callState, c.degradationReason AS degradationReason,
                       c.mediaGeneration AS mediaGeneration,
                       r.kind AS preferredKind, r.state AS preferredState,
                       (
                           SELECT j.state FROM call_transcript_jobs j
                           WHERE j.callId = c.id AND j.mediaGeneration = c.mediaGeneration AND j.kind = 'final'
                           ORDER BY j.id DESC LIMIT 1
                       ) AS finalJobState,
                       EXISTS(
                           SELECT 1 FROM call_source_gaps g
                           WHERE g.callId = c.id AND g.mediaGeneration = c.mediaGeneration
                       ) AS hasSourceGaps
                FROM calls c
                LEFT JOIN call_transcript_revisions r ON r.id = c.preferredRevisionId
                WHERE c.startTs <= ? AND COALESCE(c.endTs, ?) >= ?
                ORDER BY c.startTs DESC, c.id DESC
                LIMIT ?
                """, arguments: [toMs, toMs, fromMs, boundedLimit])

            let callIDs: [Int64] = rows.map { $0["id"] }
            let bookmarksByCall: [Int64: [CallBookmarkRow]]
            if callIDs.isEmpty {
                bookmarksByCall = [:]
            } else {
                let placeholders = Array(repeating: "?", count: callIDs.count).joined(separator: ",")
                let bookmarkRows = try CallBookmarkRow.fetchAll(db, sql: """
                    SELECT b.* FROM call_bookmarks b
                    JOIN calls c ON c.id = b.callId AND c.mediaGeneration = b.mediaGeneration
                    WHERE b.callId IN (\(placeholders)) AND b.acceptedAtMs BETWEEN ? AND ?
                    ORDER BY b.callId, b.ordinal, b.id
                    """, arguments: StatementArguments(callIDs + [fromMs, toMs]))
                bookmarksByCall = Dictionary(grouping: bookmarkRows, by: \.callId)
            }

            return rows.map { row in
                let callID: Int64 = row["id"]
                let bookmarkRows = Array((bookmarksByCall[callID] ?? []).prefix(1_000))
                let callState = CallLifecycleState(rawValue: row["callState"] as String) ?? .failed
                let preferredKind = (row["preferredKind"] as String?).flatMap(CallTranscriptRevisionKind.init(rawValue:))
                let preferredState = (row["preferredState"] as String?).flatMap(CallTranscriptRevisionState.init(rawValue:))
                let finalJobState = (row["finalJobState"] as String?).flatMap(CallTranscriptJobState.init(rawValue:))
                let degraded = (row["degradationReason"] as String?) != nil
                    || (row["hasSourceGaps"] as Int) != 0
                    || finalJobState == .readyDegraded
                let status: CallTimelineStatus
                if callState == .failed || finalJobState == .failed {
                    status = .retryable
                } else if degraded {
                    status = .degraded
                } else if callState == .ready,
                          preferredKind == .final,
                          preferredState == .ready {
                    status = .ready
                } else {
                    status = .processing
                }
                let startMs: Int64 = row["startTs"]
                let endMs: Int64 = (row["endTs"] as Int64?) ?? toMs
                return CallTimelineSpan(
                    id: callID,
                    start: dateFromMs(startMs),
                    end: dateFromMs(max(startMs, endMs)),
                    status: status,
                    bookmarks: bookmarkRows.compactMap { bookmark in
                        guard let id = bookmark.id else { return nil }
                        return CallTimelineBookmark(
                            id: id,
                            acceptedAt: dateFromMs(bookmark.acceptedAtMs),
                            state: bookmark.state
                        )
                    }
                )
            }
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
