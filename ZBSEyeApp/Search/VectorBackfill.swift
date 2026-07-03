import Foundation
import GRDB

/// Background semantic indexer, driven by the durable `embed_queue` table. Ingest no longer embeds on the hot path
/// (that kept the ~150MB e5 model resident 24/7 and burned CPU on every capture); instead every text-bearing frame /
/// transcript is enqueued atomically with its text, and this actor drains the queue off the capture path @ .utility.
///
/// The queue IS the source of truth, so nothing is stranded and idle cost is O(pending). A row that can't be
/// embedded right now (offline, DB blip, or genuinely un-embeddable text) is **never deleted** — it stays queued
/// with an `attempts` counter and sinks out of rotation after `maxAttempts`, so it can't head-of-line-block newer
/// rows yet is preserved (history is precious). Attempts reset each launch (so a fixed model / transient blip
/// auto-recovers), and `reconcile()` seeds pre-existing gaps once. The model is released on idle AND on any outage —
/// it is never pinned resident.
actor VectorBackfill {
    private let db: ZBSEyeDatabase
    private let embedder: EmbeddingService
    private var running = false
    private let idleRescanSec: Double = 20
    /// On an outage (model unavailable / DB read or write failing) back off harder than the idle poll.
    private let blockedBackoffSec: Double = 120
    /// Unload the model after this many consecutive empty rounds (~5 min) so the once-a-minute idle-capture
    /// trickle doesn't reload the 449MB model each time.
    private let unloadAfterIdleRounds = 15
    private let batchSize = 300
    /// A row that fails to embed this many times sinks out of rotation (kept in the queue, just not retried this
    /// session) — it can neither block the queue nor be lost. Reset on the next launch.
    private let maxAttempts = 5
    private let reconciledKey = "zbseye.embedQueueReconciled"

    private enum Kind: Int64 { case screen = 0, transcript = 1 }
    private enum DrainStatus { case embedded, idle, blocked }
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

        await resetAttempts()   // give every queued row a fresh set of tries (a fixed model / past blip recovers)
        await reconcileOnce()   // seed pre-existing gaps once — background, off the launch migration

        var idleRounds = 0
        while !Task.isCancelled {
            switch await drainQueue() {
            case .embedded:
                idleRounds = 0
            case .idle:
                idleRounds += 1
                if idleRounds >= unloadAfterIdleRounds { await embedder.unload() }
            case .blocked:
                // Can't make progress (offline / DB failing) — release the model, don't hold 449MB during an outage.
                await embedder.unload()
                idleRounds = 0
                try? await Task.sleep(for: .seconds(blockedBackoffSec))
                continue
            }
            try? await Task.sleep(for: .seconds(idleRescanSec))
        }
    }

    /// Drain retryable queue rows newest-first until empty (or blocked). `.embedded` = made progress, `.idle` =
    /// nothing left to embed, `.blocked` = an outage (model unavailable / whole-DB read or write failing) — back off.
    private func drainQueue() async -> DrainStatus {
        var didWork = false
        var failStreak = 0
        while !Task.isCancelled {
            let batch: [QueueItem]
            do { batch = try await nextBatch(limit: batchSize) }
            catch {
                // Whole-DB read outage (not one bad row) — back off, leave everything queued.
                Log.app.error("embed-queue batch read failed: \(String(describing: error), privacy: .public)")
                return .blocked
            }
            if batch.isEmpty { return didWork ? .embedded : .idle }

            for item in batch where !Task.isCancelled {
                let text: String?
                do { text = try await textFor(item) }
                catch {
                    // Transient read error on THIS row — don't drop it; bump so it sinks and can't block the head.
                    await bumpAttempts(item)
                    continue
                }
                guard let text, !text.isEmpty else {
                    // Source row genuinely has no text (deleted / empty) — safe to drop from the queue.
                    try? await dequeue(item)
                    continue
                }
                guard let vec = await embedder.embed(passage: text), vec.count == ZBSEyeDatabase.embeddingDim else {
                    if await embedder.isReady {
                        // Model loaded but THIS text can't be embedded (too short / untokenizable). Keep it queued —
                        // bump so it sinks after maxAttempts. Never delete: a systematic fault must stay recoverable.
                        await bumpAttempts(item)
                        continue
                    }
                    return .blocked   // offline / provider backoff — leave queued, retry after the backoff
                }
                let blob = floatBlob(vec)
                do {
                    try await writeVector(item, blob: blob)
                    didWork = true
                    failStreak = 0
                } catch {
                    failStreak += 1
                    Log.app.error("embed-queue write failed: \(String(describing: error), privacy: .public)")
                    if failStreak >= 10 { return .blocked }
                }
            }
            try? await Task.sleep(for: .seconds(2))   // pause between batches — background, not a load spike
        }
        return didWork ? .embedded : .idle
    }

    /// Newest-first among rows still worth retrying this session (attempts under the cap). Rows at the cap are
    /// excluded (preserved in the queue, just not re-attempted) so they can't block or waste cycles.
    private func nextBatch(limit: Int) async throws -> [QueueItem] {
        try await db.pool.read { [maxAttempts] dbc in
            try Row.fetchAll(dbc, sql:
                "SELECT row_id, kind, ts FROM embed_queue WHERE attempts < ? ORDER BY ts DESC LIMIT ?",
                arguments: [maxAttempts, limit])
                .map { QueueItem(rowId: $0["row_id"], kind: $0["kind"], ts: $0["ts"]) }
        }
    }

    private func bumpAttempts(_ item: QueueItem) async {
        try? await db.pool.write { dbc in
            try dbc.execute(sql: "UPDATE embed_queue SET attempts = attempts + 1 WHERE row_id = ? AND kind = ?",
                            arguments: [item.rowId, item.kind])
        }
    }

    private func resetAttempts() async {
        try? await db.pool.write { dbc in
            try dbc.execute(sql: "UPDATE embed_queue SET attempts = 0 WHERE attempts > 0")
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

    /// One-time seed of pre-existing gaps (rows from before v6, or any written by a path that forgot to enqueue).
    /// Guarded by a persisted flag so it does NOT re-scan the full history on every launch — all live write sites
    /// (IngestService, HistoryImporter) enqueue at write time, so after the first pass the queue stays complete.
    private func reconcileOnce() async {
        if UserDefaults.standard.bool(forKey: reconciledKey) { return }
        await reconcileGaps(kind: Kind.screen.rawValue, sql: """
            SELECT c.id AS id, c.ts AS ts FROM screen_captures c
            WHERE EXISTS (SELECT 1 FROM text_blocks tb WHERE tb.captureId = c.id)
              AND c.id NOT IN (SELECT capture_id FROM vec_screen)
              AND c.id NOT IN (SELECT row_id FROM embed_queue WHERE kind = 0)
            """)
        await reconcileGaps(kind: Kind.transcript.rawValue, sql: """
            SELECT t.id AS id, a.ts AS ts FROM transcriptions t JOIN audio_captures a ON a.id = t.audioId
            WHERE t.id NOT IN (SELECT transcription_id FROM vec_transcripts)
              AND t.id NOT IN (SELECT row_id FROM embed_queue WHERE kind = 1)
            """)
        guard !Task.isCancelled else { return }   // interrupted → leave the flag unset so it finishes next launch
        UserDefaults.standard.set(true, forKey: reconciledKey)
    }

    private func reconcileGaps(kind: Int64, sql: String) async {
        // Read gaps first (WAL reads don't block capture writes), then enqueue in small batches (short write locks).
        let gaps: [(Int64, Int64)] = (try? await db.pool.read { dbc in
            try Row.fetchAll(dbc, sql: sql).map { row -> (Int64, Int64) in (row["id"], row["ts"]) }
        }) ?? []
        guard !gaps.isEmpty else { return }
        var i = 0
        while i < gaps.count, !Task.isCancelled {
            let chunk = gaps[i..<min(i + batchSize, gaps.count)]
            try? await db.pool.write { dbc in
                for (id, ts) in chunk {
                    try dbc.execute(sql: "INSERT OR IGNORE INTO embed_queue(row_id, kind, ts) VALUES (?, ?, ?)",
                                    arguments: [id, kind, ts])
                }
            }
            i += batchSize
            try? await Task.sleep(for: .milliseconds(50))   // let capture writes through between chunks
        }
    }
}
