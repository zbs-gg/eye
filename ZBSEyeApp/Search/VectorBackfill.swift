import Foundation
import GRDB

/// Continuous semantic indexer: fills vec_screen / vec_transcripts for rows that have text but no vector.
/// Since ingest no longer embeds on the hot path (that used to keep the e5 model resident 24/7 and burn CPU on
/// every capture), ALL embedding happens here — off the capture path, at .utility, with the model UNLOADED once
/// the backlog is drained. FTS is instant regardless; a fresh frame gets its vector within ~idleRescanSec.
///
/// Loop: reload the set of already-vectored ids (vec0 has no efficient correlated NOT EXISTS) → drain the
/// newest-first frames that are missing a vector until we reach already-indexed territory → drain transcripts →
/// if nothing was done, unload the model and sleep, then rescan. During active use rounds keep finding work and
/// the model stays hot; when the user goes idle it is released.
actor VectorBackfill {
    private let db: ZBSEyeDatabase
    private let embedder: EmbeddingService
    private var running = false
    private let idleRescanSec: Double = 20

    init(db: ZBSEyeDatabase, embedder: EmbeddingService) {
        self.db = db
        self.embedder = embedder
    }

    /// Runs for the app's lifetime (a repeat call while already running is a no-op).
    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }

        while !Task.isCancelled {
            let have = (try? await loadHave()) ?? []
            let didFrames = await drainFrames(have: have)
            let didTx = await drainTranscripts()
            if !didFrames && !didTx {
                // caught up (or the model is offline) → release the ~150MB model and idle-rescan for new work
                await embedder.unload()
            }
            try? await Task.sleep(for: .seconds(idleRescanSec))
        }
    }

    /// One newest-first pass over frames with text and no vector. Returns whether anything was embedded.
    /// Stops as soon as a page reaches already-indexed territory (fresh.isEmpty) — after the initial backlog
    /// drain, only the handful of just-captured frames at the top are missing, so idle rounds are cheap.
    private func drainFrames(have: Set<Int64>) async -> Bool {
        var didWork = false
        var cursorTs = Int64.max
        var failStreak = 0
        while !Task.isCancelled {
            guard let page = try? await nextPage(before: cursorTs, limit: 300), !page.isEmpty else { break }
            cursorTs = page.last!.ts
            let fresh = page.filter { !have.contains($0.id) }
            if fresh.isEmpty { break }   // reached indexed rows (newest-first) → backlog is caught up
            for item in fresh where !Task.isCancelled {
                guard let text = try? await textFor(captureId: item.id), !text.isEmpty else { continue }
                guard let vec = await embedder.embed(passage: text),
                      vec.count == ZBSEyeDatabase.embeddingDim else {
                    // model not ready (offline / provider backoff) → stop; the outer loop retries after idleRescan
                    return didWork
                }
                let blob = floatBlob(vec)
                do {
                    try await db.pool.write { dbc in
                        // WHERE EXISTS: the frame could have been deleted (retention/privacy) while we embedded —
                        // otherwise an orphan vector of deleted content would live forever
                        try dbc.execute(sql: """
                            INSERT INTO vec_screen(capture_id, bucket_month, embedding)
                            SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM screen_captures WHERE id = ?)
                            """, arguments: [item.id, monthBucket(dateFromMs(item.ts)), blob, item.id])
                    }
                    didWork = true
                    failStreak = 0
                } catch {
                    failStreak += 1
                    Log.app.error("backfill insert failed: \(String(describing: error), privacy: .public)")
                    if failStreak >= 10 { Log.app.error("backfill aborted: insert keeps failing"); return didWork }
                }
            }
            try? await Task.sleep(for: .seconds(2))   // pause between pages — background, not a load spike
        }
        return didWork
    }

    /// Transcripts without a vector (volumes are orders of magnitude smaller than frames — one pass, no paging).
    /// Returns whether anything was embedded.
    private func drainTranscripts() async -> Bool {
        struct TItem: Sendable { let id: Int64; let ts: Int64; let text: String }
        let items: [TItem] = (try? await db.pool.read { dbc in
            let have = Set(try Int64.fetchAll(dbc, sql: "SELECT transcription_id FROM vec_transcripts"))
            return try Row.fetchAll(dbc, sql: """
                SELECT t.id AS id, a.ts AS ts, t.text AS text
                FROM transcriptions t JOIN audio_captures a ON a.id = t.audioId
                """).compactMap { row in
                let id: Int64 = row["id"]
                return have.contains(id) ? nil : TItem(id: id, ts: row["ts"], text: row["text"])
            }
        }) ?? []
        guard !items.isEmpty else { return false }
        var didWork = false
        for item in items where !Task.isCancelled {
            guard !item.text.isEmpty else { continue }
            guard let vec = await embedder.embed(passage: item.text),
                  vec.count == ZBSEyeDatabase.embeddingDim else { return didWork }   // model unavailable → stop
            let blob = floatBlob(vec)
            try? await db.pool.write { dbc in
                // WHERE EXISTS: the transcript could have been deleted during the multi-minute backfill inference
                try dbc.execute(sql: """
                    INSERT INTO vec_transcripts(transcription_id, bucket_month, embedding)
                    SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM transcriptions WHERE id = ?)
                    """, arguments: [item.id, monthBucket(dateFromMs(item.ts)), blob, item.id])
            }
            didWork = true
        }
        return didWork
    }

    private struct PageItem: Sendable { let id: Int64; let ts: Int64 }

    /// Ids that already have a screen vector (rebuilt each round — bounds memory to the current vector count).
    private func loadHave() async throws -> Set<Int64> {
        try await db.pool.read { dbc in
            Set(try Int64.fetchAll(dbc, sql: "SELECT capture_id FROM vec_screen"))
        }
    }

    /// A page of candidates (frames with text) strictly older than the cursor — O(page), not a full scan.
    private func nextPage(before ts: Int64, limit: Int) async throws -> [PageItem] {
        try await db.pool.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT c.id AS id, c.ts AS ts FROM screen_captures c
                WHERE c.ts < ? AND EXISTS (SELECT 1 FROM text_blocks tb WHERE tb.captureId = c.id)
                ORDER BY c.ts DESC LIMIT ?
                """, arguments: [ts, limit]).map { PageItem(id: $0["id"], ts: $0["ts"]) }
        }
    }

    private func textFor(captureId: Int64) async throws -> String? {
        try await db.pool.read { dbc in
            try String.fetchOne(dbc, sql:
                "SELECT group_concat(text, ' ') FROM text_blocks WHERE captureId = ?",
                arguments: [captureId])
        }
    }
}
