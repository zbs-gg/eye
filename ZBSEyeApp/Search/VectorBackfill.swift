import Foundation
import GRDB

/// Background semantic indexer, driven by the durable `embed_queue` table. Ingest no longer embeds on the hot path
/// (that kept the ~150MB e5 model resident 24/7 and burned CPU on every capture); instead every text-bearing frame /
/// transcript is enqueued atomically with its text, and this actor drains the queue off the capture path @ .utility.
///
/// Because the queue IS the source of truth, nothing is ever stranded: an item stays queued until it is successfully
/// vectored (or proven un-embeddable), so an interruption / offline period / migration just resumes later. Idle cost
/// is O(pending) — a tiny indexed read of an (usually empty) queue — not a full-history scan. The model is unloaded
/// after a sustained idle stretch (not on every gap — that would thrash the 449MB load).
actor VectorBackfill {
    private let db: ZBSEyeDatabase
    private let embedder: EmbeddingService
    private var running = false
    private let idleRescanSec: Double = 20
    /// Unload the model only after this many consecutive empty rounds (~5 min) — long enough to ride out the
    /// once-a-minute idle-capture trickle without reloading 449MB each time.
    private let unloadAfterIdleRounds = 15

    private enum Kind: Int64 { case screen = 0, transcript = 1 }
    private struct QueueItem: Sendable { let rowId: Int64; let kind: Int64; let ts: Int64 }

    init(db: ZBSEyeDatabase, embedder: EmbeddingService) {
        self.db = db
        self.embedder = embedder
    }

    /// Runs for the app's lifetime (a repeat call while already running is a no-op).
    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }

        var idleRounds = 0
        while !Task.isCancelled {
            let didWork = await drainQueue()
            if didWork {
                idleRounds = 0
            } else {
                idleRounds += 1
                if idleRounds == unloadAfterIdleRounds { await embedder.unload() }
            }
            try? await Task.sleep(for: .seconds(idleRescanSec))
        }
    }

    /// Drain the queue newest-first until empty (or the model becomes unavailable). Returns whether anything was embedded.
    private func drainQueue() async -> Bool {
        var didWork = false
        var failStreak = 0
        while !Task.isCancelled {
            guard let batch = try? await nextBatch(limit: 300), !batch.isEmpty else { break }
            for item in batch where !Task.isCancelled {
                guard let text = try? await textFor(item), !text.isEmpty else {
                    // no text to embed (deleted / empty) — drop it so the queue can't stall on it forever
                    try? await dequeue(item)
                    continue
                }
                guard let vec = await embedder.embed(passage: text), vec.count == ZBSEyeDatabase.embeddingDim else {
                    // Distinguish "model unavailable" (retry later, leave queued) from "this text can't be embedded"
                    // (e.g. <9 useful chars / untokenizable → drop it, don't block everything behind it).
                    if await embedder.isReady {
                        try? await dequeue(item)
                        continue
                    }
                    return didWork   // offline / provider backoff — stop; the outer loop retries after idleRescan
                }
                let blob = floatBlob(vec)
                do {
                    try await writeVector(item, blob: blob)
                    didWork = true
                    failStreak = 0
                } catch {
                    failStreak += 1
                    Log.app.error("embed-queue write failed: \(String(describing: error), privacy: .public)")
                    if failStreak >= 10 { Log.app.error("embed-queue drain aborted: writes keep failing"); return didWork }
                }
            }
            try? await Task.sleep(for: .seconds(2))   // pause between batches — background, not a load spike
        }
        return didWork
    }

    private func nextBatch(limit: Int) async throws -> [QueueItem] {
        try await db.pool.read { dbc in
            try Row.fetchAll(dbc, sql: "SELECT row_id, kind, ts FROM embed_queue ORDER BY ts DESC LIMIT ?",
                             arguments: [limit])
                .map { QueueItem(rowId: $0["row_id"], kind: $0["kind"], ts: $0["ts"]) }
        }
    }

    private func textFor(_ item: QueueItem) async throws -> String? {
        try await db.pool.read { dbc in
            if item.kind == Kind.screen.rawValue {
                return try String.fetchOne(dbc, sql:
                    "SELECT group_concat(text, ' ') FROM text_blocks WHERE captureId = ?", arguments: [item.rowId])
            } else {
                return try String.fetchOne(dbc, sql: "SELECT text FROM transcriptions WHERE id = ?", arguments: [item.rowId])
            }
        }
    }

    /// Idempotent per-item write: replace any existing vector, insert the fresh one, and remove the queue row — all
    /// in one transaction. WHERE EXISTS guards a row deleted (retention/privacy) mid-embed. If the source row is gone
    /// we still drop the queue entry (no orphan vector, no stuck queue item).
    private func writeVector(_ item: QueueItem, blob: Data) async throws {
        let bucket = monthBucket(dateFromMs(item.ts))
        try await db.pool.write { dbc in
            if item.kind == Kind.screen.rawValue {
                if try Bool.fetchOne(dbc, sql: "SELECT EXISTS(SELECT 1 FROM screen_captures WHERE id = ?)",
                                     arguments: [item.rowId]) ?? false {
                    try dbc.execute(sql: "DELETE FROM vec_screen WHERE capture_id = ?", arguments: [item.rowId])
                    try dbc.execute(sql: "INSERT INTO vec_screen(capture_id, bucket_month, embedding) VALUES (?, ?, ?)",
                                    arguments: [item.rowId, bucket, blob])
                }
            } else {
                if try Bool.fetchOne(dbc, sql: "SELECT EXISTS(SELECT 1 FROM transcriptions WHERE id = ?)",
                                     arguments: [item.rowId]) ?? false {
                    try dbc.execute(sql: "DELETE FROM vec_transcripts WHERE transcription_id = ?", arguments: [item.rowId])
                    try dbc.execute(sql: "INSERT INTO vec_transcripts(transcription_id, bucket_month, embedding) VALUES (?, ?, ?)",
                                    arguments: [item.rowId, bucket, blob])
                }
            }
            try dbc.execute(sql: "DELETE FROM embed_queue WHERE row_id = ? AND kind = ?",
                            arguments: [item.rowId, item.kind])
        }
    }

    private func dequeue(_ item: QueueItem) async throws {
        try await db.pool.write { dbc in
            try dbc.execute(sql: "DELETE FROM embed_queue WHERE row_id = ? AND kind = ?",
                            arguments: [item.rowId, item.kind])
        }
    }
}
