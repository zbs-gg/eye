import Foundation
import GRDB

/// Writer for capture data (actor). Capture/Transcription hand Sendable records here; here — a file +
/// one transaction (upsert app, insert screen_capture, insert text_blocks → triggers fill FTS).
/// Removes the Task.detached races of the old version.
/// NB: writes to the DB are serialized by the GRDB DatabasePool across RetentionManager AND IngestService (not one writer
/// object, but one serialized writer channel of the pool). Automatic retention
/// never sweeps physical orphans; exact admission reconciliation detects them.
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

    func suspendAndDrainForRelocation() async -> IngestDrainAcknowledgement {
        await writeBarrier.suspendAndDrain()
    }

    func resumeAfterRelocation() {
        writeBarrier.resume()
    }

    func saveReviewSummary(_ summary: ReviewSummary) async throws {
        guard writeBarrier.beginWrite() else {
            throw DatabaseWriterMaintenanceError.suspendedForRelocation
        }
        defer { writeBarrier.finishWrite() }
        try await db.pool.write { database in
            try database.execute(
                sql: """
                    INSERT INTO review_summaries(
                        id, period_kind, period_start_ms, period_end_ms, generated_at_ms,
                        markdown, sessions, total_captures, provider_id, model_id,
                        executed_locally, broker_upstream, prompt_version, input_tokens,
                        cached_input_tokens, output_tokens, reasoning_output_tokens,
                        billing_amount, billing_unit, rate_card_date, source_truncated,
                        context_truncated, output_truncated, coverage_incomplete, trigger_kind
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(period_kind, period_start_ms, period_end_ms) DO UPDATE SET
                        id = excluded.id,
                        generated_at_ms = excluded.generated_at_ms,
                        markdown = excluded.markdown,
                        sessions = excluded.sessions,
                        total_captures = excluded.total_captures,
                        provider_id = excluded.provider_id,
                        model_id = excluded.model_id,
                        executed_locally = excluded.executed_locally,
                        broker_upstream = excluded.broker_upstream,
                        prompt_version = excluded.prompt_version,
                        input_tokens = excluded.input_tokens,
                        cached_input_tokens = excluded.cached_input_tokens,
                        output_tokens = excluded.output_tokens,
                        reasoning_output_tokens = excluded.reasoning_output_tokens,
                        billing_amount = excluded.billing_amount,
                        billing_unit = excluded.billing_unit,
                        rate_card_date = excluded.rate_card_date,
                        source_truncated = excluded.source_truncated,
                        context_truncated = excluded.context_truncated,
                        output_truncated = excluded.output_truncated,
                        coverage_incomplete = excluded.coverage_incomplete,
                        trigger_kind = excluded.trigger_kind
                    """,
                arguments: [
                    summary.id, summary.period.kind.rawValue, summary.period.startMs,
                    summary.period.endMs, msFromDate(summary.generatedAt), summary.markdown,
                    summary.sessions, summary.totalCaptures, summary.provenance.providerID,
                    summary.provenance.modelID, summary.provenance.executedLocally,
                    summary.provenance.brokerUpstream, summary.promptVersion,
                    summary.usage?.inputTokens, summary.usage?.cachedInputTokens,
                    summary.usage?.outputTokens, summary.usage?.reasoningOutputTokens,
                    summary.billing?.amount, summary.billing?.unit.rawValue,
                    summary.billing?.rateCardDate, summary.sourceTruncated,
                    summary.contextTruncated,
                    summary.outputTruncated, summary.coverageIncomplete,
                    summary.trigger.rawValue,
                ]
            )
        }
    }

    /// Privacy-first deletion of derived Review text. Overlap is half-open.
    func deleteReviewSummaries(overlappingFromMs fromMs: Int64, toMs: Int64) async throws {
        guard writeBarrier.beginWrite() else {
            throw DatabaseWriterMaintenanceError.suspendedForRelocation
        }
        defer { writeBarrier.finishWrite() }
        try await db.pool.write { database in
            try database.execute(
                sql: """
                    DELETE FROM review_summaries
                    WHERE period_start_ms < ? AND period_end_ms > ?
                    """,
                arguments: [toMs, fromMs]
            )
        }
    }

    /// Durably opens an uncertainty interval before recovery is published.
    /// Returns false for an exact replay or when the leg already has an open
    /// episode; callers must stay conservative instead of replacing ownership.
    @discardableResult
    func openCaptureCoverage(_ open: CaptureCoverageOpen) async throws -> Bool {
        guard writeBarrier.beginWrite() else {
            throw DatabaseWriterMaintenanceError.suspendedForRelocation
        }
        defer { writeBarrier.finishWrite() }
        return try await db.pool.write { dbc in
            if let existing = try Row.fetchOne(
                dbc,
                sql: """
                    SELECT leg, reason, start_ms
                    FROM capture_coverage_intervals
                    WHERE episode_id = ? AND generation = ?
                    """,
                arguments: [open.episodeID, open.generation]
            ) {
                let same = (existing["leg"] as String) == open.leg.rawValue
                    && (existing["reason"] as String) == open.reason.rawValue
                    && (existing["start_ms"] as Int64) == open.startMs
                if same { return false }
                throw CaptureCoverageWriteError.identityConflict
            }
            let alreadyOpen = try Bool.fetchOne(
                dbc,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM capture_coverage_intervals
                        WHERE leg = ? AND end_ms IS NULL
                    )
                    """,
                arguments: [open.leg.rawValue]
            ) ?? false
            guard !alreadyOpen else { return false }
            try dbc.execute(
                sql: """
                    INSERT INTO capture_coverage_intervals(
                        leg, reason, episode_id, generation, start_ms
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    open.leg.rawValue,
                    open.reason.rawValue,
                    open.episodeID,
                    open.generation,
                    open.startMs,
                ]
            )
            return true
        }
    }

    /// Compare-and-set close. A lost race returns false and deliberately leaves
    /// health conservative; only the exact episode/generation owner can close.
    @discardableResult
    func closeCaptureCoverage(_ close: CaptureCoverageClose) async throws -> Bool {
        guard writeBarrier.beginWrite() else {
            throw DatabaseWriterMaintenanceError.suspendedForRelocation
        }
        defer { writeBarrier.finishWrite() }
        return try await db.pool.write { dbc in
            try dbc.execute(
                sql: """
                    UPDATE capture_coverage_intervals
                    SET end_ms = ?, close_cause = ?
                    WHERE leg = ?
                      AND episode_id = ?
                      AND generation = ?
                      AND end_ms IS NULL
                      AND ? >= start_ms
                    """,
                arguments: [
                    close.endMs,
                    close.cause.rawValue,
                    close.leg.rawValue,
                    close.episodeID,
                    close.generation,
                    close.endMs,
                ]
            )
            return dbc.changesCount == 1
        }
    }

    @discardableResult
    func ingest(_ rec: ScreenCaptureRecord) async throws -> Int64 {
        try Task.checkCancellation()
        guard writeBarrier.beginWrite() else {
            throw DatabaseWriterMaintenanceError.suspendedForRelocation
        }
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
            // Capture admission can close while the synchronous file write is
            // finishing. Do not enter the database transaction with a frame
            // whose owning capture cycle was revoked; the catch below removes
            // this layer's staged HEIC.
            try Task.checkCancellation()
            return try await db.pool.write { dbc -> Int64 in
                // DatabasePool.write is cancellation-aware and rolls this
                // transaction back. Explicit checks bound both sides of our
                // insert sequence and make that privacy contract local.
                try Task.checkCancellation()
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
                try Task.checkCancellation()
                return captureId
            }
        } catch {
            // The transaction failed — clean up the file written by THIS layer (.heicData). Files of .fileWritten
            // belong to the capture layer. Cleanup here is best-effort; exact
            // admission reconciliation detects leftovers before deletion reopens.
            if case .heicData = rec.image, let p = relativePath {
                try? storage.deleteFile(relativePath: p)
            }
            throw error
        }
    }

    @discardableResult
    func ingest(_ rec: AudioCaptureRecord) async throws -> Int64 {
        guard writeBarrier.beginWrite() else {
            throw DatabaseWriterMaintenanceError.suspendedForRelocation
        }
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
        guard writeBarrier.beginWrite() else {
            throw DatabaseWriterMaintenanceError.suspendedForRelocation
        }
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

enum CaptureCoverageWriteError: Error, Sendable, Equatable {
    case identityConflict
}
