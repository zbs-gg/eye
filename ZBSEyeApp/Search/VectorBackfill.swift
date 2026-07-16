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
/// auto-recovers), and `reconcile()` re-enqueues any gap every launch (self-healing — no fragile "done" flag). The
/// model is released on idle AND on any outage — it is never pinned resident.
actor VectorBackfill {
    private let db: ZBSEyeDatabase
    private let embedder: EmbeddingService
    private var running = false
    private weak var computeCoordinator: AIComputeCoordinator?
    private var suspended = false
    private var activeWorkSections = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
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
    /// This many consecutive per-row read errors means the whole DB is unreadable (not one bad row) — back off
    /// instead of bumping every row out of rotation.
    private let readErrorBlockThreshold = 20

    private enum Kind: Int64 {
        case screen = 0
        case transcript = 1
        case callTranscript = 2
    }
    private enum DrainStatus { case embedded, idle, blocked, suspended }
    private enum EmbedOutcome { case value([Float]?), deferred }
    private struct QueueItem: Sendable { let rowId: Int64; let kind: Int64; let ts: Int64 }

    init(db: ZBSEyeDatabase, embedder: EmbeddingService) {
        self.db = db
        self.embedder = embedder
    }

    /// Attached once by AppEnvironment after the coordinator has retained this
    /// actor through its suspend/resume hooks. The backlink is weak to avoid a
    /// process-lifetime retain cycle.
    func attachComputeCoordinator(_ coordinator: AIComputeCoordinator) {
        guard computeCoordinator == nil else { return }
        computeCoordinator = coordinator
    }

    /// Stops admitting durable-queue work and acknowledges only after the
    /// current DB/embed section has reached a safe boundary.
    func suspendAndDrain() async {
        suspended = true
        if activeWorkSections > 0 {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
        await embedder.unload()
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        let waiters = resumeWaiters
        resumeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Runs for the app's lifetime (a repeat call while already running is a no-op).
    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }

        beginWorkSection()
        await resetAttempts()   // give every queued row a fresh set of tries (a fixed model / past blip recovers)
        if !suspended {
            await reconcile()   // re-enqueue any gap (pre-v6 rows / anything missing) — self-healing, every launch
        }
        endWorkSection()

        var idleRounds = 0
        while !Task.isCancelled {
            if suspended {
                await embedder.unload()
                await waitUntilResumed()
                continue
            }
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
            case .suspended:
                await embedder.unload()
                await waitUntilResumed()
                continue
            }
            try? await Task.sleep(for: .seconds(idleRescanSec))
        }
    }

    /// Drain retryable rows newest-first. `.embedded` = made progress, `.idle` = nothing left to embed, `.blocked` =
    /// an outage (model unavailable / whole-DB read or write failing / no forward progress) — release + back off.
    /// A genuine block always returns `.blocked` even after partial progress (the committed work stays; the fault is
    /// real, so we must release the model and back off rather than spin every 20s).
    private func drainQueue() async -> DrainStatus {
        guard !suspended else { return .suspended }
        beginWorkSection()
        defer { endWorkSection() }
        var didWork = false
        var writeFailStreak = 0
        var readErrStreak = 0
        while !Task.isCancelled, !suspended {
            let batch: [QueueItem]
            do { batch = try await nextBatch(limit: batchSize) }
            catch {
                Log.app.error("embed-queue batch read failed: \(String(describing: error), privacy: .public)")
                return .blocked   // whole-DB read outage (not one bad row) — back off, leave everything queued
            }
            if suspended { return .suspended }
            if batch.isEmpty { return didWork ? .embedded : .idle }

            var progressed = false   // did the batch move at all (embed / dequeue / a successful bump)?
            for item in batch where !Task.isCancelled && !suspended {
                let text: String?
                do { text = try await textFor(item); readErrStreak = 0 }
                catch {
                    // Read error on THIS row. If it's the whole DB failing (many in a row), back off; otherwise treat
                    // it as one poison row — bump so it sinks (never drop, never head-of-line-block).
                    readErrStreak += 1
                    if readErrStreak >= readErrorBlockThreshold { return .blocked }
                    if await bumpAttempts(item) { progressed = true }
                    continue
                }
                guard let text, !text.isEmpty else {
                    if await dequeue(item) { progressed = true }   // source row genuinely gone/empty — safe to drop
                    continue
                }
                let outcome = await coordinatedEmbed(passage: text)
                guard case .value(let maybeVector) = outcome else {
                    return .suspended
                }
                guard let vec = maybeVector, vec.count == ZBSEyeDatabase.embeddingDim else {
                    if await embedder.isReady {
                        // Loaded model can't embed THIS text (too short / untokenizable). Keep it queued — bump so it
                        // sinks after maxAttempts. Never delete: a systematic fault must stay recoverable.
                        if await bumpAttempts(item) { progressed = true }
                        continue
                    }
                    return .blocked   // offline / provider backoff — release + back off, retry later
                }
                let blob = floatBlob(vec)
                do {
                    try await writeVector(item, blob: blob)
                    didWork = true
                    progressed = true
                    writeFailStreak = 0
                } catch {
                    writeFailStreak += 1
                    Log.app.error("embed-queue write failed: \(String(describing: error), privacy: .public)")
                    if writeFailStreak >= 10 { return .blocked }
                }
            }
            // A non-empty batch that moved nothing (e.g. writes silently failing) would otherwise spin forever with
            // the model resident — treat it as an outage.
            if !progressed { return .blocked }
            try? await Task.sleep(for: .seconds(2))   // pause between batches — background, not a load spike
        }
        return suspended ? .suspended : (didWork ? .embedded : .idle)
    }

    private func coordinatedEmbed(passage text: String) async -> EmbedOutcome {
        guard !suspended else { return .deferred }
        guard let computeCoordinator else {
            return .value(await embedder.embed(passage: text))
        }
        guard let lease = await computeCoordinator.acquireBackgroundEmbedding() else {
            return .deferred
        }
        if suspended {
            await lease.release()
            return .deferred
        }
        let vector = await embedder.embed(passage: text)
        await lease.release()
        return .value(vector)
    }

    private func beginWorkSection() {
        activeWorkSections += 1
    }

    private func endWorkSection() {
        activeWorkSections = max(0, activeWorkSections - 1)
        guard activeWorkSections == 0 else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitUntilResumed() async {
        guard suspended, !Task.isCancelled else { return }
        await withCheckedContinuation { resumeWaiters.append($0) }
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

    /// Returns whether the bump was actually written (false = write failed → not forward progress).
    private func bumpAttempts(_ item: QueueItem) async -> Bool {
        do {
            try await db.pool.write { dbc in
                try dbc.execute(sql: "UPDATE embed_queue SET attempts = attempts + 1 WHERE row_id = ? AND kind = ?",
                                arguments: [item.rowId, item.kind])
            }
            return true
        } catch { return false }
    }

    private func dequeue(_ item: QueueItem) async -> Bool {
        do {
            try await db.pool.write { dbc in
                try dbc.execute(sql: "DELETE FROM embed_queue WHERE row_id = ? AND kind = ?",
                                arguments: [item.rowId, item.kind])
            }
            return true
        } catch { return false }
    }

    /// Reset the retry counter for rows that had sunk out of rotation — batched (WAL-friendly, short write locks) so
    /// a large outage backlog can't stall capture at launch.
    private func resetAttempts() async {
        let ids: [(Int64, Int64)] = (try? await db.pool.read { dbc in
            try Row.fetchAll(dbc, sql: "SELECT row_id, kind FROM embed_queue WHERE attempts > 0")
                .map { row -> (Int64, Int64) in (row["row_id"], row["kind"]) }
        }) ?? []
        guard !ids.isEmpty else { return }
        var i = 0
        while i < ids.count, !Task.isCancelled, !suspended {
            let chunk = ids[i..<min(i + batchSize, ids.count)]
            try? await db.pool.write { dbc in
                for (rowId, kind) in chunk {
                    try dbc.execute(sql: "UPDATE embed_queue SET attempts = 0 WHERE row_id = ? AND kind = ?",
                                    arguments: [rowId, kind])
                }
            }
            i += batchSize
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func textFor(_ item: QueueItem) async throws -> String? {
        try await db.pool.read { dbc in
            switch item.kind {
            case Kind.screen.rawValue:
                return try String.fetchOne(dbc, sql:
                    "SELECT group_concat(text, ' ') FROM text_blocks WHERE captureId = ?", arguments: [item.rowId])
            case Kind.transcript.rawValue:
                return try String.fetchOne(dbc, sql: "SELECT text FROM transcriptions WHERE id = ?", arguments: [item.rowId])
            case Kind.callTranscript.rawValue:
                return try String.fetchOne(dbc, sql: """
                    SELECT r.text
                    FROM call_transcript_revisions r
                    JOIN calls c ON c.preferredRevisionId = r.id
                    WHERE r.id = ? AND r.state = 'ready'
                    """, arguments: [item.rowId])
            default:
                return nil
            }
        }
    }

    /// Idempotent per-item write: replace any existing vector, insert the fresh one, and remove the queue row — all
    /// in one transaction. WHERE EXISTS guards a row deleted (retention/privacy) mid-embed. If the source row is gone
    /// we still drop the queue entry (no orphan vector, no stuck queue item).
    private func writeVector(_ item: QueueItem, blob: Data) async throws {
        let bucket = monthBucket(dateFromMs(item.ts))
        try await db.pool.write { dbc in
            switch item.kind {
            case Kind.screen.rawValue:
                if try Bool.fetchOne(dbc, sql: "SELECT EXISTS(SELECT 1 FROM screen_captures WHERE id = ?)",
                                     arguments: [item.rowId]) ?? false {
                    try dbc.execute(sql: "DELETE FROM vec_screen WHERE capture_id = ?", arguments: [item.rowId])
                    try dbc.execute(sql: "INSERT INTO vec_screen(capture_id, bucket_month, embedding) VALUES (?, ?, ?)",
                                    arguments: [item.rowId, bucket, blob])
                }
            case Kind.transcript.rawValue:
                if try Bool.fetchOne(dbc, sql: "SELECT EXISTS(SELECT 1 FROM transcriptions WHERE id = ?)",
                                     arguments: [item.rowId]) ?? false {
                    try dbc.execute(sql: "DELETE FROM vec_transcripts WHERE transcription_id = ?", arguments: [item.rowId])
                    try dbc.execute(sql: "INSERT INTO vec_transcripts(transcription_id, bucket_month, embedding) VALUES (?, ?, ?)",
                                    arguments: [item.rowId, bucket, blob])
                }
            case Kind.callTranscript.rawValue:
                if try Bool.fetchOne(dbc, sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM call_transcript_revisions r
                        JOIN calls c ON c.preferredRevisionId = r.id
                        WHERE r.id = ? AND r.state = 'ready'
                    )
                    """, arguments: [item.rowId]) ?? false {
                    try dbc.execute(
                        sql: "DELETE FROM vec_call_transcripts WHERE revision_id = ?",
                        arguments: [item.rowId]
                    )
                    try dbc.execute(
                        sql: "INSERT INTO vec_call_transcripts(revision_id, bucket_month, embedding) VALUES (?, ?, ?)",
                        arguments: [item.rowId, bucket, blob]
                    )
                }
            default:
                break
            }
            try dbc.execute(sql: "DELETE FROM embed_queue WHERE row_id = ? AND kind = ?",
                            arguments: [item.rowId, item.kind])
        }
    }

    /// Re-enqueue every text-bearing frame / transcript that lacks a vector and isn't already queued — pre-v6 rows,
    /// or anything a fault dropped. Reads gaps first (WAL reads don't block capture writes), then enqueues in small
    /// batches (short write locks) so a large store-forever history can't stall capture. Idempotent; a no-op once the
    /// queue is complete (the usual steady state, since all live write sites enqueue at write time).
    private func reconcile() async {
        guard !suspended else { return }
        await reconcileGaps(kind: Kind.screen.rawValue, sql: """
            SELECT c.id AS id, c.ts AS ts FROM screen_captures c
            WHERE EXISTS (SELECT 1 FROM text_blocks tb WHERE tb.captureId = c.id)
              AND c.id NOT IN (SELECT capture_id FROM vec_screen)
              AND c.id NOT IN (SELECT row_id FROM embed_queue WHERE kind = 0)
            """)
        guard !suspended else { return }
        await reconcileGaps(kind: Kind.transcript.rawValue, sql: """
            SELECT t.id AS id, a.ts AS ts FROM transcriptions t JOIN audio_captures a ON a.id = t.audioId
            WHERE t.id NOT IN (SELECT transcription_id FROM vec_transcripts)
              AND t.id NOT IN (SELECT row_id FROM embed_queue WHERE kind = 1)
            """)
        guard !suspended else { return }
        await reconcileGaps(kind: Kind.callTranscript.rawValue, sql: """
            SELECT r.id AS id, c.startTs AS ts
            FROM calls c
            JOIN call_transcript_revisions r ON r.id = c.preferredRevisionId
            WHERE r.state = 'ready'
              AND r.id NOT IN (SELECT revision_id FROM vec_call_transcripts)
              AND r.id NOT IN (SELECT row_id FROM embed_queue WHERE kind = 2)
            """)
    }

    private func reconcileGaps(kind: Int64, sql: String) async {
        let gaps: [(Int64, Int64)] = (try? await db.pool.read { dbc in
            try Row.fetchAll(dbc, sql: sql).map { row -> (Int64, Int64) in (row["id"], row["ts"]) }
        }) ?? []
        guard !gaps.isEmpty else { return }
        var i = 0
        while i < gaps.count, !Task.isCancelled, !suspended {
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
