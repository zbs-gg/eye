import Foundation
import GRDB

/// Background semantic indexer, driven by the durable `embed_queue` table. Ingest no longer embeds on the hot path
/// (that kept the ~150MB e5 model resident 24/7 and burned CPU on every capture); instead every text-bearing frame /
/// transcript is enqueued atomically with its text, and this actor drains the queue off the capture path @ .utility.
///
/// Because the queue IS the source of truth, nothing is stranded: an item stays queued until it is successfully
/// vectored, so an interruption / offline period / migration just resumes later. Idle cost is O(pending) — a tiny
/// indexed read of an (usually empty) queue — not a full-history scan. The model is released on idle AND on any
/// outage (it is never pinned resident). `reconcile()` (background, at start) seeds pre-existing gaps and re-enqueues
/// anything missing a vector, so even a bad batch is recoverable on the next launch.
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

        await reconcile()   // seed pre-v6 gaps / anything missing a vector — background, off the launch migration

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

    /// Drain the queue newest-first until empty (or blocked). `.embedded` = made progress, `.idle` = nothing to do,
    /// `.blocked` = an outage (model unavailable / DB read or write failing) — leave items queued and back off.
    private func drainQueue() async -> DrainStatus {
        var didWork = false
        var failStreak = 0
        while !Task.isCancelled {
            guard let batch = try? await nextBatch(limit: batchSize), !batch.isEmpty else {
                return didWork ? .embedded : .idle
            }
            for item in batch where !Task.isCancelled {
                let text: String?
                do { text = try await textFor(item) }
                catch {
                    // Transient DB read error — do NOT drop the item (it may still have text); back off and retry.
                    Log.app.error("embed-queue read failed: \(String(describing: error), privacy: .public)")
                    return didWork ? .embedded : .blocked
                }
                guard let text, !text.isEmpty else {
                    // The source row genuinely has no text (deleted / empty) — drop it so the queue can't stall.
                    try? await dequeue(item)
                    continue
                }
                guard let vec = await embedder.embed(passage: text), vec.count == ZBSEyeDatabase.embeddingDim else {
                    if await embedder.isReady {
                        // Model is loaded but THIS text can't be embedded (too short / untokenizable) — drop it so
                        // it can't block the queue. If a systematic model fault dropped good rows, reconcile()
                        // re-enqueues them (they still lack a vector) on the next launch — nothing is lost forever.
                        try? await dequeue(item)
                        continue
                    }
                    return didWork ? .embedded : .blocked   // offline / provider backoff — leave queued, retry later
                }
                let blob = floatBlob(vec)
                do {
                    try await writeVector(item, blob: blob)
                    didWork = true
                    failStreak = 0
                } catch {
                    failStreak += 1
                    Log.app.error("embed-queue write failed: \(String(describing: error), privacy: .public)")
                    if failStreak >= 10 { return didWork ? .embedded : .blocked }
                }
            }
            try? await Task.sleep(for: .seconds(2))   // pause between batches — background, not a load spike
        }
        return didWork ? .embedded : .idle
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

    /// Enqueue every text-bearing frame / transcript that lacks a vector and isn't already queued — gaps from before
    /// v6, rows written by a path that forgot to enqueue, or rows a systematic fault dropped. Reads gaps first (WAL
    /// reads don't block capture writes), then enqueues in small batches (short write locks) so a large store-forever
    /// history can't stall capture. Idempotent; runs once per launch.
    private func reconcile() async {
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
    }

    private func reconcileGaps(kind: Int64, sql: String) async {
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
