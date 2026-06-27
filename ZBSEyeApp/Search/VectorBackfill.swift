import Foundation
import GRDB

/// Backfill of the semantic index: frames with text but no vector in vec_screen. Sources of the gaps:
/// (1) the v3 migration dropped the old 512-dim vectors; (2) offline first-run — frames were ingested while e5
/// had not yet been downloaded. Without backfill these frames stay forever invisible to semantic search.
/// Waits for the model to be ready (rather than bailing on "not ready" — that would bail in exactly the scenario
/// it exists for). Pages by a ts cursor (no full scan per batch), the Set of existing vectors is built once and
/// maintained incrementally.
actor VectorBackfill {
    private let db: ZBSEyeDatabase
    private let embedder: EmbeddingService
    private var running = false

    init(db: ZBSEyeDatabase, embedder: EmbeddingService) {
        self.db = db
        self.embedder = embedder
    }

    /// One pass until exhausted. A repeat call while already running is a no-op.
    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }

        // 1) Wait for the model: a warmup embed triggers the download; offline → retry once a minute
        //    (E5ModelProvider keeps its own backoff). Without this the first-run-offline case would bail forever.
        while !Task.isCancelled {
            if await embedder.embed(passage: "warmup") != nil { break }
            try? await Task.sleep(for: .seconds(60))
        }
        guard !Task.isCancelled else { return }

        // 2) Snapshot: existing vectors (once) + the upper ts bound. Frames newer than the snapshot are
        //    embedded by live ingest — we don't touch them (no race for a duplicate vector).
        guard let snapshot = try? await loadSnapshot() else { return }
        var have = snapshot.have
        var cursorTs = snapshot.maxTs + 1

        var total = 0
        var failStreak = 0
        while !Task.isCancelled {
            guard let page = try? await nextPage(before: cursorTs, limit: 300), !page.isEmpty else { break }
            cursorTs = page.last!.ts
            for item in page where !have.contains(item.id) {
                guard let text = try? await textFor(captureId: item.id), !text.isEmpty else { continue }
                guard let vec = await embedder.embed(passage: text),
                      vec.count == ZBSEyeDatabase.embeddingDim else { continue }
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
                    have.insert(item.id)
                    total += 1
                    failStreak = 0
                } catch {
                    // the write failed — don't count it and don't hammer forever (disk/DB are sick)
                    failStreak += 1
                    Log.app.error("backfill insert failed: \(String(describing: error), privacy: .public)")
                    if failStreak >= 10 { Log.app.error("backfill aborted: insert keeps failing"); return }
                }
            }
            try? await Task.sleep(for: .seconds(2))   // pause between pages — background, not a load
        }
        if total > 0 { Log.app.info("vector backfill: \(total) frames reindexed") }

        // 3) Transcripts without a vector (v4 migration / offline period): volumes are orders of magnitude
        //    smaller than frames — handled in a single pass without paging.
        await backfillTranscripts()
    }

    private func backfillTranscripts() async {
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
        guard !items.isEmpty else { return }
        var total = 0
        for item in items where !Task.isCancelled {
            guard !item.text.isEmpty,
                  let vec = await embedder.embed(passage: item.text),
                  vec.count == ZBSEyeDatabase.embeddingDim else { continue }
            let blob = floatBlob(vec)
            try? await db.pool.write { dbc in
                // WHERE EXISTS: the transcript could have been deleted during the multi-minute backfill inference
                try dbc.execute(sql: """
                    INSERT INTO vec_transcripts(transcription_id, bucket_month, embedding)
                    SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM transcriptions WHERE id = ?)
                    """, arguments: [item.id, monthBucket(dateFromMs(item.ts)), blob, item.id])
            }
            total += 1
        }
        if total > 0 { Log.app.info("transcript backfill: \(total) transcripts reindexed") }
    }

    private struct PageItem: Sendable { let id: Int64; let ts: Int64 }
    private struct Snapshot: Sendable { let have: Set<Int64>; let maxTs: Int64 }

    private func loadSnapshot() async throws -> Snapshot {
        try await db.pool.read { dbc in
            let have = Set(try Int64.fetchAll(dbc, sql: "SELECT capture_id FROM vec_screen"))
            let maxTs = try Int64.fetchOne(dbc, sql: "SELECT COALESCE(MAX(ts), 0) FROM screen_captures") ?? 0
            return Snapshot(have: have, maxTs: maxTs)
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
