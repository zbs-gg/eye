import Foundation
import GRDB

/// Writer for capture data (actor). Capture/Transcription hand Sendable records here; here — a file +
/// one transaction (upsert app, insert screen_capture, insert text_blocks → triggers fill FTS).
/// Removes the Task.detached races of the old version.
/// NB: writes to the DB are serialized by the GRDB DatabasePool across RetentionManager AND IngestService (not one writer
/// object, but one serialized writer channel of the pool). Coordination with retention — via a grace window in
/// sweepOrphans (see RetentionManager), so the orphan sweep doesn't delete an in-flight frame.
actor IngestService {
    private let db: ZBSEyeDatabase
    private let storage: StorageManager
    private let writeBarrier = IngestWriteBarrier()

    // NB: ingest deliberately does NOT embed. Frames/transcripts are written without a vector; the continuous
    // VectorBackfill indexer fills vectors in the background (off the hot path, model unloaded on idle). FTS is
    // instant regardless; semantic search catches up within ~20s. This is what keeps the e5 model out of the
    // per-frame path (it used to be loaded 24/7 and embed every capture).
    init(db: ZBSEyeDatabase, storage: StorageManager) {
        self.db = db
        self.storage = storage
    }

    /// Reentrancy-safe barrier. Capture/audio producers are stopped before this
    /// call; the explicit counter still waits for writes already suspended in
    /// GRDB rather than assuming actor FIFO implies completion.
    func drain() async -> IngestDrainAcknowledgement {
        await writeBarrier.drain()
    }

    @discardableResult
    func ingest(_ rec: ScreenCaptureRecord) async throws -> Int64 {
        writeBarrier.beginWrite()
        defer { writeBarrier.finishWrite() }
        // 1) We write the frame file BEFORE the transaction (if capture handed over bytes), the path — into the record.
        //    let (not var) — otherwise Swift 6 won't allow capturing it in the concurrent write closure.
        let relativePath: String?
        let bytes: Int?
        switch rec.image {
        case .heicData(let data):
            relativePath = try storage.writeFrame(data, timestamp: rec.timestamp, displayIndex: 0)
            bytes = data.count
        case .fileWritten(let path):
            relativePath = path
            bytes = nil
        case .none:
            relativePath = nil
            bytes = nil
        }

        let tsMs = Int64(rec.timestamp.timeIntervalSince1970 * 1000)
        let blocks = rec.textBlocks

        do {
            return try await db.pool.write { dbc -> Int64 in
                // upsert app
                let appId = try Self.upsertApp(dbc, bundleId: rec.bundleId, name: rec.appName)
                let tel = rec.telemetry
                var cap = ScreenCaptureRow(
                    id: nil, ts: tsMs, appId: appId,
                    windowTitle: rec.windowTitle, browserUrl: rec.browserURL,
                    monitorId: rec.monitorId, relativePath: relativePath,
                    width: rec.pixelWidth, height: rec.pixelHeight,
                    bytes: bytes, axQuality: rec.axQuality.rawValue,
                    usefulTextChars: tel.usefulTextChars, nodeCount: tel.nodeCount,
                    treeWasEmpty: tel.treeWasEmpty, hitBudgetLimit: tel.hitBudgetLimit,
                    ocrFallbackReason: tel.ocrFallbackReason,
                    manualAccessibilityResult: tel.manualAccessibilityResult,
                    enhancedUiResult: tel.enhancedUiResult)
                try cap.insert(dbc)
                let captureId = cap.id!
                for b in blocks {
                    var tb = TextBlockRow(
                        id: nil, captureId: captureId, source: b.source.rawValue,
                        text: b.text, confidence: b.confidence,
                        bboxX: b.bbox.map { Double($0.origin.x) }, bboxY: b.bbox.map { Double($0.origin.y) },
                        bboxW: b.bbox.map { Double($0.size.width) }, bboxH: b.bbox.map { Double($0.size.height) })
                    try tb.insert(dbc)   // the text_blocks_ai trigger fills text_fts
                }
                // No vector here — enqueue for the background indexer (off the hot path). Only if there's text
                // to embed; enqueued atomically with the text so the indexer can never miss a frame.
                if !blocks.isEmpty {
                    try dbc.execute(sql: "INSERT OR IGNORE INTO embed_queue(row_id, kind, ts) VALUES (?, 0, ?)",
                                    arguments: [captureId, tsMs])
                }
                return captureId
            }
        } catch {
            // The transaction failed — clean up the file written by THIS layer (.heicData). Files of .fileWritten
            // belong to the capture layer — on failure sweepOrphans will pick them up (after the grace window).
            if case .heicData = rec.image, let p = relativePath { storage.deleteFile(relativePath: p) }
            throw error
        }
    }

    @discardableResult
    func ingest(_ rec: AudioCaptureRecord) async throws -> Int64 {
        writeBarrier.beginWrite()
        defer { writeBarrier.finishWrite() }
        let tsMs = Int64(rec.timestamp.timeIntervalSince1970 * 1000)
        let bytes = rec.bytes ?? storage.fileSize(relativePath: rec.relativePath)
        return try await db.pool.write { dbc -> Int64 in
            var row = AudioCaptureRow(id: nil, ts: tsMs, relativePath: rec.relativePath,
                                      durationSec: rec.durationSec, channel: rec.channel, bytes: bytes)
            try row.insert(dbc)
            return row.id!
        }
    }

    /// Segment transcript → transcriptions (the transcriptions_ai trigger fills transcription_fts)
    /// + a semantic vector into vec_transcripts (cross-lingual "a ru query finds an en call").
    @discardableResult
    func ingest(_ rec: TranscriptionRecord) async throws -> Int64 {
        writeBarrier.beginWrite()
        defer { writeBarrier.finishWrite() }
        // No vector here — enqueue for the background indexer (off the hot path). FTS stays instant; the
        // cross-lingual vector ('a ru query finds an en call') is filled by the indexer shortly after.
        let tsMs = Int64(rec.ts.timeIntervalSince1970 * 1000)
        return try await db.pool.write { dbc -> Int64 in
            var row = TranscriptionRow(
                id: nil, audioId: rec.audioId, text: rec.text, language: rec.language,
                speaker: rec.speaker, startOffset: rec.startOffset, endOffset: rec.endOffset, engine: rec.engine)
            try row.insert(dbc)
            let id = row.id!
            try dbc.execute(sql: "INSERT OR IGNORE INTO embed_queue(row_id, kind, ts) VALUES (?, 1, ?)",
                            arguments: [id, tsMs])
            return id
        }
    }

    /// upsert by the unique bundleId, returns the id.
    private static func upsertApp(_ db: Database, bundleId: String, name: String) throws -> Int64 {
        if let existing = try AppRow.filter(Column("bundleId") == bundleId).fetchOne(db) {
            return existing.id!
        }
        var row = AppRow(id: nil, bundleId: bundleId, name: name)
        try row.insert(db)
        return row.id!
    }
}
