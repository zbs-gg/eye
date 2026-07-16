import Foundation
import GRDB

enum CallRepositoryError: LocalizedError, Sendable, Equatable {
    case callNotFound(Int64)
    case callNotRecording(Int64)
    case inconsistentBookmark(Int64)
    case inconsistentFinalJob(Int64)
    case transcriptJobNotFound(Int64)
    case transcriptJobNotRunning(Int64)
    case staleTranscriptJob(Int64)
    case preferredRevisionMissing(Int64)

    var errorDescription: String? {
        switch self {
        case .callNotFound:
            return "The call no longer exists."
        case .callNotRecording:
            return "Bookmarks are accepted only while the call is recording."
        case .inconsistentBookmark:
            return "The durable bookmark is missing its transcript job."
        case .inconsistentFinalJob:
            return "The call is missing its deterministic final transcript job."
        case .transcriptJobNotFound:
            return "The transcript job no longer exists."
        case .transcriptJobNotRunning:
            return "The transcript job is not running."
        case .staleTranscriptJob:
            return "The transcript job references an obsolete media generation."
        case .preferredRevisionMissing:
            return "The transcript revision was saved without a preferred projection."
        }
    }
}

/// The only writer for the first-class call tables. Capture code hands Sendable drafts to this actor;
/// helper and MCP processes never receive this type.
actor CallRepository {
    private let database: ZBSEyeDatabase

    init(database: ZBSEyeDatabase) {
        self.database = database
    }

    func createCall(startedAtMs: Int64, idempotencyKey: String) async throws -> CallRow {
        try await database.pool.write { db in
            if let existing = try CallRow
                .filter(Column("startIdempotencyKey") == idempotencyKey)
                .fetchOne(db) {
                return existing
            }
            var row = CallRow(
                id: nil,
                startIdempotencyKey: idempotencyKey,
                endIdempotencyKey: nil,
                startTs: startedAtMs,
                endTs: nil,
                state: .recording,
                interrupted: false,
                degradationReason: nil,
                mediaGeneration: 0,
                preferredRevisionId: nil,
                createdAtMs: startedAtMs,
                updatedAtMs: startedAtMs
            )
            try row.insert(db)
            return row
        }
    }

    func discardEmptyCall(id: Int64) async throws {
        try await database.pool.write { db in
            let evidenceCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT
                        (SELECT COUNT(*) FROM call_audio_chunks WHERE callId = ?) +
                        (SELECT COUNT(*) FROM call_bookmarks WHERE callId = ?)
                    """,
                arguments: [id, id]
            ) ?? 0
            guard evidenceCount == 0 else { return }
            try db.execute(
                sql: "DELETE FROM calls WHERE id = ? AND state = ?",
                arguments: [id, CallLifecycleState.recording.rawValue]
            )
        }
    }

    func markCallDegraded(callID: Int64, reason: String?, nowMs: Int64) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE calls
                    SET degradationReason = COALESCE(?, degradationReason), updatedAtMs = ?
                    WHERE id = ?
                    """,
                arguments: [reason, nowMs, callID]
            )
        }
    }

    func createBookmark(
        callID: Int64,
        idempotencyKey: String,
        acceptedAtMs: Int64,
        meIngressTarget: Int64?,
        systemIngressTarget: Int64?,
        logicalStartMs: Int64,
        logicalEndMs: Int64,
        contextStartMs: Int64
    ) async throws -> CallBookmarkCreation {
        try await database.pool.write { db in
            if let existing = try CallBookmarkRow
                .filter(Column("callId") == callID && Column("idempotencyKey") == idempotencyKey)
                .fetchOne(db) {
                guard let bookmarkID = existing.id,
                      let job = try CallTranscriptJobRow
                        .filter(Column("bookmarkId") == bookmarkID)
                        .fetchOne(db) else {
                    throw CallRepositoryError.inconsistentBookmark(callID)
                }
                return CallBookmarkCreation(bookmark: existing, job: job)
            }
            guard let call = try CallRow.fetchOne(db, key: callID) else {
                throw CallRepositoryError.callNotFound(callID)
            }
            guard call.state == .recording else {
                throw CallRepositoryError.callNotRecording(callID)
            }
            let ordinal = (try Int.fetchOne(
                db,
                sql: "SELECT MAX(ordinal) FROM call_bookmarks WHERE callId = ?",
                arguments: [callID]
            ) ?? 0) + 1
            var bookmark = CallBookmarkRow(
                id: nil,
                callId: callID,
                idempotencyKey: idempotencyKey,
                ordinal: ordinal,
                acceptedAtMs: acceptedAtMs,
                meIngressTarget: meIngressTarget,
                systemIngressTarget: systemIngressTarget,
                logicalStartMs: logicalStartMs,
                logicalEndMs: logicalEndMs,
                contextStartMs: contextStartMs,
                state: .preparing,
                mediaGeneration: call.mediaGeneration
            )
            try bookmark.insert(db)
            guard let bookmarkID = bookmark.id else {
                throw CallRepositoryError.inconsistentBookmark(callID)
            }
            var job = CallTranscriptJobRow(
                id: nil,
                identity: "checkpoint:\(callID):\(idempotencyKey)",
                callId: callID,
                bookmarkId: bookmarkID,
                kind: .checkpoint,
                mediaGeneration: call.mediaGeneration,
                state: .preparing,
                priority: 100,
                logicalStartMs: logicalStartMs,
                logicalEndMs: logicalEndMs,
                contextStartMs: contextStartMs,
                meEndSample: nil,
                systemEndSample: nil,
                coverageFrozen: false,
                attempts: 0,
                errorCode: nil,
                createdAtMs: acceptedAtMs,
                updatedAtMs: acceptedAtMs
            )
            try job.insert(db)
            return CallBookmarkCreation(bookmark: bookmark, job: job)
        }
    }

    func freezeBookmarkCoverage(
        bookmarkID: Int64,
        jobID: Int64,
        meEndSample: Int64?,
        systemEndSample: Int64?,
        degraded: Bool,
        nowMs: Int64
    ) async throws -> CallBookmarkRow {
        try await database.pool.write { db in
            guard var bookmark = try CallBookmarkRow.fetchOne(db, key: bookmarkID),
                  var job = try CallTranscriptJobRow.fetchOne(db, key: jobID),
                  bookmark.callId == job.callId,
                  job.bookmarkId == bookmarkID else {
                throw CallRepositoryError.inconsistentBookmark(bookmarkID)
            }
            if job.coverageFrozen {
                return bookmark
            }

            let perCall = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM call_transcript_jobs
                    WHERE callId = ? AND kind = ?
                      AND state IN (?, ?)
                    """,
                arguments: [
                    job.callId,
                    CallTranscriptJobKind.checkpoint.rawValue,
                    CallTranscriptJobState.pending.rawValue,
                    CallTranscriptJobState.running.rawValue,
                ]
            ) ?? 0
            let global = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM call_transcript_jobs
                    WHERE kind = ? AND state IN (?, ?)
                    """,
                arguments: [
                    CallTranscriptJobKind.checkpoint.rawValue,
                    CallTranscriptJobState.pending.rawValue,
                    CallTranscriptJobState.running.rawValue,
                ]
            ) ?? 0
            let admitted = perCall < 32 && global < 64
            job.meEndSample = meEndSample
            job.systemEndSample = systemEndSample
            job.coverageFrozen = true
            job.state = admitted ? .pending : .deferredCapacity
            job.errorCode = degraded ? "source_gap" : (admitted ? nil : "deferred_capacity")
            job.updatedAtMs = nowMs
            try job.update(db)

            bookmark.state = admitted ? .pending : .deferredCapacity
            try bookmark.update(db)
            return bookmark
        }
    }

    func endCall(
        callID: Int64,
        idempotencyKey: String,
        endedAtMs: Int64,
        meEndSample: Int64? = nil,
        systemEndSample: Int64? = nil,
        degradationReason: String? = nil
    ) async throws -> CallTranscriptJobRow {
        try await database.pool.write { db in
            guard var call = try CallRow.fetchOne(db, key: callID) else {
                throw CallRepositoryError.callNotFound(callID)
            }
            if call.state == .recording {
                call.state = .finalizing
                call.endTs = max(call.startTs, endedAtMs)
                call.endIdempotencyKey = idempotencyKey
                if let degradationReason {
                    call.degradationReason = degradationReason
                }
                call.updatedAtMs = endedAtMs
                try call.update(db)
            }
            if var existing = try CallTranscriptJobRow
                .filter(
                    Column("callId") == callID
                        && Column("mediaGeneration") == call.mediaGeneration
                        && Column("kind") == CallTranscriptJobKind.final.rawValue
                )
                .fetchOne(db) {
                if existing.meEndSample == nil { existing.meEndSample = meEndSample }
                if existing.systemEndSample == nil { existing.systemEndSample = systemEndSample }
                existing.coverageFrozen = true
                existing.updatedAtMs = max(existing.updatedAtMs, endedAtMs)
                try existing.update(db)
                return existing
            }
            let logicalEnd = call.endTs ?? max(call.startTs, endedAtMs)
            var job = CallTranscriptJobRow(
                id: nil,
                identity: "final:\(callID):\(call.mediaGeneration)",
                callId: callID,
                bookmarkId: nil,
                kind: .final,
                mediaGeneration: call.mediaGeneration,
                state: .pending,
                priority: 0,
                logicalStartMs: call.startTs,
                logicalEndMs: logicalEnd,
                contextStartMs: call.startTs,
                meEndSample: meEndSample,
                systemEndSample: systemEndSample,
                coverageFrozen: true,
                attempts: 0,
                errorCode: nil,
                createdAtMs: endedAtMs,
                updatedAtMs: endedAtMs
            )
            try job.insert(db)
            return job
        }
    }

    func setPreferredRevision(callID: Int64, revisionID: Int64) async throws {
        try await database.pool.write { db in
            guard try CallRow.fetchOne(db, key: callID) != nil else {
                throw CallRepositoryError.callNotFound(callID)
            }
            try db.execute(
                sql: "UPDATE calls SET preferredRevisionId = ?, updatedAtMs = MAX(updatedAtMs, ?) WHERE id = ?",
                arguments: [revisionID, Int64(Date().timeIntervalSince1970 * 1_000), callID]
            )
        }
    }

    /// Claims exactly one immutable, coverage-frozen job. Final work has priority zero, so End
    /// jumps ahead of every checkpoint that has not started without disturbing an active helper.
    func claimNextTranscriptJob(nowMs: Int64) async throws -> CallTranscriptJobRow? {
        try await database.pool.write { db in
            guard let candidate = try CallTranscriptJobRow.fetchOne(
                db,
                sql: """
                    SELECT j.*
                    FROM call_transcript_jobs j
                    JOIN calls c ON c.id = j.callId
                    WHERE j.state = ?
                      AND j.coverageFrozen = 1
                      AND j.mediaGeneration = c.mediaGeneration
                    ORDER BY j.priority, j.createdAtMs, j.id
                    LIMIT 1
                    """,
                arguments: [CallTranscriptJobState.pending.rawValue]
            ), let jobID = candidate.id else { return nil }

            try db.execute(
                sql: """
                    UPDATE call_transcript_jobs
                    SET state = ?, attempts = attempts + 1, errorCode = NULL, updatedAtMs = ?
                    WHERE id = ? AND state = ? AND coverageFrozen = 1
                    """,
                arguments: [
                    CallTranscriptJobState.running.rawValue,
                    nowMs,
                    jobID,
                    CallTranscriptJobState.pending.rawValue,
                ]
            )
            guard db.changesCount == 1 else { return nil }
            return try CallTranscriptJobRow.fetchOne(db, key: jobID)
        }
    }

    func hasClaimableFinalTranscriptJob() async -> Bool {
        (try? await database.pool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1
                        FROM call_transcript_jobs j
                        JOIN calls c ON c.id = j.callId
                        WHERE j.kind = ? AND j.state = ?
                          AND j.coverageFrozen = 1
                          AND j.mediaGeneration = c.mediaGeneration
                    )
                    """,
                arguments: [
                    CallTranscriptJobKind.final.rawValue,
                    CallTranscriptJobState.pending.rawValue,
                ]
            ) ?? false
        }) ?? false
    }

    func retryFinalTranscript(callID: Int64, nowMs: Int64) async throws {
        try await database.pool.write { db in
            guard var call = try CallRow.fetchOne(db, key: callID) else {
                throw CallRepositoryError.callNotFound(callID)
            }
            guard var job = try CallTranscriptJobRow.fetchOne(
                db,
                sql: """
                    SELECT * FROM call_transcript_jobs
                    WHERE callId = ? AND mediaGeneration = ? AND kind = ?
                    ORDER BY id DESC LIMIT 1
                    """,
                arguments: [
                    callID,
                    call.mediaGeneration,
                    CallTranscriptJobKind.final.rawValue,
                ]
            ) else {
                throw CallRepositoryError.inconsistentFinalJob(callID)
            }
            guard job.state == .failed || job.state == .cancelled else { return }
            let transientFailure = job.errorCode
            job.state = .pending
            job.errorCode = nil
            job.updatedAtMs = nowMs
            try job.update(db)
            call.state = .finalizing
            if call.degradationReason == transientFailure {
                call.degradationReason = nil
            }
            call.updatedAtMs = nowMs
            try call.update(db)
        }
    }

    func transcriptJobEvidence(jobID: Int64) async throws -> CallTranscriptJobEvidence {
        try await database.pool.read { db in
            guard let job = try CallTranscriptJobRow.fetchOne(db, key: jobID) else {
                throw CallRepositoryError.transcriptJobNotFound(jobID)
            }
            guard let call = try CallRow.fetchOne(db, key: job.callId) else {
                throw CallRepositoryError.callNotFound(job.callId)
            }
            guard call.mediaGeneration == job.mediaGeneration else {
                throw CallRepositoryError.staleTranscriptJob(jobID)
            }
            let bookmark = try job.bookmarkId.flatMap { bookmarkID in
                try CallBookmarkRow.fetchOne(db, key: bookmarkID)
            }
            let chunks = try CallAudioChunkRow.fetchAll(
                db,
                sql: """
                    SELECT * FROM call_audio_chunks
                    WHERE callId = ? AND mediaGeneration = ?
                      AND finalized = 1 AND bytes > 0
                      AND endMs > ? AND startMs < ?
                    ORDER BY source, epoch, sequence
                    """,
                arguments: [
                    job.callId,
                    job.mediaGeneration,
                    job.contextStartMs,
                    job.logicalEndMs,
                ]
            )
            return CallTranscriptJobEvidence(
                call: call,
                job: job,
                bookmark: bookmark,
                chunks: chunks
            )
        }
    }

    func failTranscriptJob(
        jobID: Int64,
        errorCode: String,
        retryable: Bool,
        nowMs: Int64
    ) async throws {
        try await database.pool.write { db in
            guard let job = try CallTranscriptJobRow.fetchOne(db, key: jobID) else {
                throw CallRepositoryError.transcriptJobNotFound(jobID)
            }
            guard job.state == .running else { return }
            let nextState: CallTranscriptJobState = retryable ? .pending : .failed
            try db.execute(
                sql: """
                    UPDATE call_transcript_jobs
                    SET state = ?, errorCode = ?, updatedAtMs = ?
                    WHERE id = ? AND state = ?
                    """,
                arguments: [
                    nextState.rawValue,
                    errorCode,
                    nowMs,
                    jobID,
                    CallTranscriptJobState.running.rawValue,
                ]
            )
            if let bookmarkID = job.bookmarkId {
                let bookmarkState: CallBookmarkState = retryable ? .pending : .failed
                try db.execute(
                    sql: "UPDATE call_bookmarks SET state = ? WHERE id = ?",
                    arguments: [bookmarkState.rawValue, bookmarkID]
                )
            } else if !retryable {
                try db.execute(
                    sql: """
                        UPDATE calls
                        SET state = ?, degradationReason = COALESCE(degradationReason, ?), updatedAtMs = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        CallLifecycleState.failed.rawValue,
                        errorCode,
                        nowMs,
                        job.callId,
                    ]
                )
            }
            try Self.admitDeferredCheckpoints(db: db, nowMs: nowMs)
        }
    }

    /// Commits one helper result and switches the call's preferred projection in the same database
    /// transaction. A final revision is terminal: no later checkpoint can replace it.
    func commitTranscriptJob(
        jobID: Int64,
        segments suppliedSegments: [CallTranscriptSegmentDraft],
        language: String,
        engine: String,
        modelRevision: String,
        degraded: Bool,
        nowMs: Int64
    ) async throws -> CallTranscriptCommitResult {
        try await database.pool.write { db in
            guard var job = try CallTranscriptJobRow.fetchOne(db, key: jobID) else {
                throw CallRepositoryError.transcriptJobNotFound(jobID)
            }
            guard var call = try CallRow.fetchOne(db, key: job.callId) else {
                throw CallRepositoryError.callNotFound(job.callId)
            }

            if let existing = try CallTranscriptRevisionRow
                .filter(Column("jobId") == jobID)
                .fetchOne(db),
               let existingID = existing.id,
               let preferredID = call.preferredRevisionId {
                return CallTranscriptCommitResult(
                    intervalOrFinalRevisionID: existingID,
                    preferredRevisionID: preferredID,
                    final: existing.kind == .final
                )
            }
            guard call.mediaGeneration == job.mediaGeneration else {
                throw CallRepositoryError.staleTranscriptJob(jobID)
            }
            guard job.state == .running else {
                throw CallRepositoryError.transcriptJobNotRunning(jobID)
            }

            let bounded = TranscriptOverlapReconciler.reconcile(
                committed: [],
                incoming: suppliedSegments,
                logicalStartMs: job.logicalStartMs,
                logicalEndMs: job.logicalEndMs
            ).sorted(by: Self.segmentOrder)
            var revision = CallTranscriptRevisionRow(
                id: nil,
                callId: job.callId,
                jobId: jobID,
                projectionKey: nil,
                kind: job.kind == .final ? .final : .interval,
                mediaGeneration: job.mediaGeneration,
                state: .ready,
                text: bounded.map(\.text).joined(separator: "\n"),
                language: language,
                engine: engine,
                modelRevision: modelRevision,
                logicalStartMs: job.logicalStartMs,
                logicalEndMs: job.logicalEndMs,
                createdAtMs: nowMs
            )
            try revision.insert(db)
            guard let revisionID = revision.id else {
                throw CallRepositoryError.preferredRevisionMissing(job.callId)
            }
            try Self.insertSegments(bounded, revisionID: revisionID, db: db)

            let readyJobState: CallTranscriptJobState = degraded ? .readyDegraded : .ready
            job.state = readyJobState
            job.errorCode = degraded ? "source_gap" : nil
            job.updatedAtMs = nowMs
            try job.update(db)

            if job.kind == .final {
                call.preferredRevisionId = revisionID
                call.state = .ready
                call.updatedAtMs = nowMs
                try call.update(db)

                let supersededStates = [
                    CallTranscriptJobState.preparing.rawValue,
                    CallTranscriptJobState.deferredCapacity.rawValue,
                    CallTranscriptJobState.pending.rawValue,
                    CallTranscriptJobState.running.rawValue,
                    CallTranscriptJobState.failed.rawValue,
                ]
                try db.execute(
                    sql: """
                        UPDATE call_transcript_jobs
                        SET state = ?, errorCode = NULL, updatedAtMs = ?
                        WHERE callId = ? AND mediaGeneration = ? AND kind = ?
                          AND id != ? AND state IN (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        CallTranscriptJobState.satisfiedByFinal.rawValue,
                        nowMs,
                        job.callId,
                        job.mediaGeneration,
                        CallTranscriptJobKind.checkpoint.rawValue,
                        jobID,
                        supersededStates[0],
                        supersededStates[1],
                        supersededStates[2],
                        supersededStates[3],
                        supersededStates[4],
                    ]
                )
                try db.execute(
                    sql: """
                        UPDATE call_bookmarks
                        SET state = ?
                        WHERE callId = ? AND mediaGeneration = ?
                          AND state NOT IN (?, ?)
                        """,
                    arguments: [
                        CallBookmarkState.satisfiedByFinal.rawValue,
                        job.callId,
                        job.mediaGeneration,
                        CallBookmarkState.ready.rawValue,
                        CallBookmarkState.readyDegraded.rawValue,
                    ]
                )
                try db.execute(
                    sql: "INSERT OR REPLACE INTO embed_queue(row_id, kind, ts, attempts) VALUES (?, 2, ?, 0)",
                    arguments: [revisionID, call.startTs]
                )
                try Self.admitDeferredCheckpoints(db: db, nowMs: nowMs)
                return CallTranscriptCommitResult(
                    intervalOrFinalRevisionID: revisionID,
                    preferredRevisionID: revisionID,
                    final: true
                )
            }

            if let bookmarkID = job.bookmarkId {
                let bookmarkState: CallBookmarkState = degraded ? .readyDegraded : .ready
                try db.execute(
                    sql: "UPDATE call_bookmarks SET state = ? WHERE id = ?",
                    arguments: [bookmarkState.rawValue, bookmarkID]
                )
            }

            let coverage = try Self.projectionCoverage(
                callID: job.callId,
                mediaGeneration: job.mediaGeneration,
                db: db
            )
            guard let projection = CallTranscriptProjection.build(
                callID: job.callId,
                mediaGeneration: job.mediaGeneration,
                intervals: coverage.intervals,
                gaps: coverage.gaps
            ) else {
                throw CallRepositoryError.preferredRevisionMissing(job.callId)
            }
            let preferredID: Int64
            if let existingProjection = try CallTranscriptRevisionRow
                .filter(Column("projectionKey") == projection.key)
                .fetchOne(db), let existingProjectionID = existingProjection.id {
                preferredID = existingProjectionID
            } else {
                var projectedRevision = CallTranscriptRevisionRow(
                    id: nil,
                    callId: job.callId,
                    jobId: nil,
                    projectionKey: projection.key,
                    kind: .projection,
                    mediaGeneration: job.mediaGeneration,
                    state: .ready,
                    text: projection.text,
                    language: language,
                    engine: "projection",
                    modelRevision: modelRevision,
                    logicalStartMs: projection.logicalStartMs,
                    logicalEndMs: projection.logicalEndMs,
                    createdAtMs: nowMs
                )
                try projectedRevision.insert(db)
                guard let projectedRevisionID = projectedRevision.id else {
                    throw CallRepositoryError.preferredRevisionMissing(job.callId)
                }
                try Self.insertSegments(
                    projection.segments,
                    revisionID: projectedRevisionID,
                    db: db
                )
                for gap in projection.gaps {
                    let row = CallTranscriptProjectionGapRow(
                        revisionId: projectedRevisionID,
                        bookmarkId: gap.bookmarkID,
                        ordinal: gap.bookmarkOrdinal,
                        state: gap.state,
                        logicalStartMs: gap.logicalStartMs,
                        logicalEndMs: gap.logicalEndMs
                    )
                    try row.insert(db)
                }
                preferredID = projectedRevisionID
            }

            let preferredKind = try String.fetchOne(
                db,
                sql: """
                    SELECT r.kind FROM calls c
                    LEFT JOIN call_transcript_revisions r ON r.id = c.preferredRevisionId
                    WHERE c.id = ?
                    """,
                arguments: [job.callId]
            )
            if preferredKind != CallTranscriptRevisionKind.final.rawValue {
                call.preferredRevisionId = preferredID
                call.updatedAtMs = nowMs
                try call.update(db)
            }
            try Self.admitDeferredCheckpoints(db: db, nowMs: nowMs)
            return CallTranscriptCommitResult(
                intervalOrFinalRevisionID: revisionID,
                preferredRevisionID: preferredKind == CallTranscriptRevisionKind.final.rawValue
                    ? (call.preferredRevisionId ?? preferredID)
                    : preferredID,
                final: false
            )
        }
    }

    private static func segmentOrder(
        _ lhs: CallTranscriptSegmentDraft,
        _ rhs: CallTranscriptSegmentDraft
    ) -> Bool {
        (lhs.startMs, lhs.endMs, lhs.source.rawValue, lhs.text)
            < (rhs.startMs, rhs.endMs, rhs.source.rawValue, rhs.text)
    }

    private static func insertSegments(
        _ segments: [CallTranscriptSegmentDraft],
        revisionID: Int64,
        db: Database
    ) throws {
        for (ordinal, segment) in segments.enumerated() {
            var row = CallTranscriptSegmentRow(
                id: nil,
                revisionId: revisionID,
                ordinal: ordinal,
                source: segment.source,
                startMs: segment.startMs,
                endMs: segment.endMs,
                text: segment.text
            )
            try row.insert(db)
        }
    }

    private static func projectionCoverage(
        callID: Int64,
        mediaGeneration: Int,
        db: Database
    ) throws -> (intervals: [CallTranscriptInterval], gaps: [CallTranscriptGap]) {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT b.id AS bookmarkID, b.ordinal, b.state,
                       b.logicalStartMs, b.logicalEndMs,
                       r.id AS revisionID
                FROM call_bookmarks b
                LEFT JOIN call_transcript_jobs j
                  ON j.bookmarkId = b.id
                 AND j.callId = b.callId
                 AND j.mediaGeneration = b.mediaGeneration
                LEFT JOIN call_transcript_revisions r
                  ON r.jobId = j.id
                 AND r.kind = ?
                 AND r.state = ?
                WHERE b.callId = ? AND b.mediaGeneration = ?
                ORDER BY b.ordinal, r.id
                """,
            arguments: [
                CallTranscriptRevisionKind.interval.rawValue,
                CallTranscriptRevisionState.ready.rawValue,
                callID,
                mediaGeneration,
            ]
        )
        var intervals: [CallTranscriptInterval] = []
        var gaps: [CallTranscriptGap] = []
        for row in rows {
            let bookmarkID: Int64 = row["bookmarkID"]
            let ordinal: Int = row["ordinal"]
            let logicalStartMs: Int64 = row["logicalStartMs"]
            let logicalEndMs: Int64 = row["logicalEndMs"]
            guard let revisionID: Int64 = row["revisionID"] else {
                guard let state = CallBookmarkState(rawValue: row["state"]) else {
                    throw CallRepositoryError.inconsistentBookmark(bookmarkID)
                }
                gaps.append(
                    CallTranscriptGap(
                        bookmarkID: bookmarkID,
                        bookmarkOrdinal: ordinal,
                        state: state,
                        logicalStartMs: logicalStartMs,
                        logicalEndMs: logicalEndMs
                    )
                )
                continue
            }
            let segmentRows = try CallTranscriptSegmentRow
                .filter(Column("revisionId") == revisionID)
                .order(Column("ordinal"))
                .fetchAll(db)
            intervals.append(
                CallTranscriptInterval(
                    bookmarkOrdinal: ordinal,
                    revisionID: revisionID,
                    logicalStartMs: logicalStartMs,
                    logicalEndMs: logicalEndMs,
                    segments: segmentRows.map {
                        CallTranscriptSegmentDraft(
                            source: $0.source,
                            startMs: $0.startMs,
                            endMs: $0.endMs,
                            text: $0.text
                        )
                    }
                )
            )
        }
        return (intervals, gaps)
    }

    private static func admitDeferredCheckpoints(db: Database, nowMs: Int64) throws {
        var globalActive = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM call_transcript_jobs j
                JOIN calls c ON c.id = j.callId
                WHERE j.kind = ? AND j.state IN (?, ?)
                  AND j.mediaGeneration = c.mediaGeneration
                """,
            arguments: [
                CallTranscriptJobKind.checkpoint.rawValue,
                CallTranscriptJobState.pending.rawValue,
                CallTranscriptJobState.running.rawValue,
            ]
        ) ?? 0
        guard globalActive < 64 else { return }

        let deferred = try CallTranscriptJobRow.fetchAll(
            db,
            sql: """
                SELECT j.* FROM call_transcript_jobs j
                JOIN calls c ON c.id = j.callId
                WHERE j.kind = ? AND j.state = ? AND j.coverageFrozen = 1
                  AND j.mediaGeneration = c.mediaGeneration
                ORDER BY j.createdAtMs, j.id
                """,
            arguments: [
                CallTranscriptJobKind.checkpoint.rawValue,
                CallTranscriptJobState.deferredCapacity.rawValue,
            ]
        )
        var activeByCall: [Int64: Int] = [:]
        for job in deferred {
            guard globalActive < 64, let jobID = job.id else { break }
            let active = try activeByCall[job.callId] ?? Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM call_transcript_jobs
                    WHERE callId = ? AND kind = ? AND state IN (?, ?)
                    """,
                arguments: [
                    job.callId,
                    CallTranscriptJobKind.checkpoint.rawValue,
                    CallTranscriptJobState.pending.rawValue,
                    CallTranscriptJobState.running.rawValue,
                ]
            ) ?? 0
            activeByCall[job.callId] = active
            guard active < 32 else { continue }
            try db.execute(
                sql: """
                    UPDATE call_transcript_jobs
                    SET state = ?, errorCode = NULL, updatedAtMs = ?
                    WHERE id = ? AND state = ?
                    """,
                arguments: [
                    CallTranscriptJobState.pending.rawValue,
                    nowMs,
                    jobID,
                    CallTranscriptJobState.deferredCapacity.rawValue,
                ]
            )
            guard db.changesCount == 1 else { continue }
            if let bookmarkID = job.bookmarkId {
                try db.execute(
                    sql: "UPDATE call_bookmarks SET state = ? WHERE id = ?",
                    arguments: [CallBookmarkState.pending.rawValue, bookmarkID]
                )
            }
            activeByCall[job.callId] = active + 1
            globalActive += 1
        }
    }

    func recordSourceSpan(_ draft: CallSourceSpanDraft) async throws -> CallSourceSpanRow {
        try await database.pool.write { db in
            if let existing = try CallSourceSpanRow.filter(
                Column("callId") == draft.callId
                    && Column("source") == draft.source.rawValue
                    && Column("epoch") == draft.epoch
            ).fetchOne(db) {
                return existing
            }
            var row = CallSourceSpanRow(
                id: nil,
                callId: draft.callId,
                source: draft.source,
                epoch: draft.epoch,
                sampleRate: draft.sampleRate,
                startedAtMs: draft.startedAtMs,
                endedAtMs: nil,
                startSample: draft.startSample,
                endSample: nil,
                startHostTimeNs: draft.startHostTimeNs,
                endHostTimeNs: nil,
                availability: draft.availability,
                gapReason: draft.gapReason
            )
            try row.insert(db)
            return row
        }
    }

    func recordAudioChunk(_ draft: CallAudioChunkDraft) async throws -> CallAudioChunkRow {
        try await database.pool.write { db in
            if let existing = try CallAudioChunkRow.filter(
                Column("callId") == draft.callId
                    && Column("source") == draft.source.rawValue
                    && Column("epoch") == draft.epoch
                    && Column("sequence") == draft.sequence
            ).fetchOne(db) {
                return existing
            }
            var row = CallAudioChunkRow(
                id: nil,
                callId: draft.callId,
                sourceSpanId: draft.sourceSpanId,
                source: draft.source,
                epoch: draft.epoch,
                sequence: draft.sequence,
                mediaGeneration: draft.mediaGeneration,
                startSample: draft.startSample,
                endSample: draft.endSample,
                startMs: draft.startMs,
                endMs: draft.endMs,
                relativePath: draft.relativePath,
                bytes: draft.bytes,
                sha256: draft.sha256,
                finalized: draft.finalized
            )
            try row.insert(db)
            return row
        }
    }

    func unfinalizedChunks() async throws -> [CallAudioChunkRow] {
        try await database.pool.read { db in
            try CallAudioChunkRow
                .filter(Column("finalized") == false)
                .order(Column("callId"), Column("source"), Column("epoch"), Column("sequence"))
                .fetchAll(db)
        }
    }

    func finalizeRecoveredChunk(
        id: Int64,
        bytes: Int64,
        endSample: Int64,
        sha256: String
    ) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE call_audio_chunks
                    SET bytes = ?, endSample = ?, sha256 = ?, finalized = 1
                    WHERE id = ? AND finalized = 0
                    """,
                arguments: [bytes, endSample, sha256, id]
            )
        }
    }

    func discardRecoveredChunk(id: Int64) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM call_audio_chunks WHERE id = ? AND finalized = 0",
                arguments: [id]
            )
        }
    }

    func updateAudioChunkProgress(
        id: Int64,
        endSample: Int64,
        endMs: Int64,
        bytes: Int64,
        sha256: String?,
        finalized: Bool
    ) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE call_audio_chunks
                    SET endSample = ?, endMs = ?, bytes = ?, sha256 = ?, finalized = ?
                    WHERE id = ? AND finalized = 0
                    """,
                arguments: [endSample, endMs, bytes, sha256, finalized, id]
            )
        }
    }

    func closeSourceSpan(
        id: Int64,
        endedAtMs: Int64,
        endSample: Int64,
        endHostTimeNs: Int64
    ) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE call_source_spans
                    SET endedAtMs = ?, endSample = ?, endHostTimeNs = ?
                    WHERE id = ? AND endedAtMs IS NULL
                    """,
                arguments: [endedAtMs, endSample, endHostTimeNs, id]
            )
        }
    }

    func recoverDatabaseState(nowMs: Int64) async throws -> CallRecoveryDatabaseReport {
        try await database.pool.write { db in
            let interruptedCallIDs = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM calls WHERE state = 'recording' ORDER BY id"
            )
            for callID in interruptedCallIDs {
                let durableEnd = try Int64.fetchOne(
                    db,
                    sql: "SELECT MAX(endMs) FROM call_audio_chunks WHERE callId = ? AND finalized = 1",
                    arguments: [callID]
                )
                try db.execute(
                    sql: """
                        UPDATE calls
                        SET state = 'interrupted', interrupted = 1,
                            degradationReason = 'recovered_after_interruption',
                            endTs = MAX(startTs, COALESCE(?, startTs)), updatedAtMs = ?
                        WHERE id = ? AND state = 'recording'
                        """,
                    arguments: [durableEnd, nowMs, callID]
                )
            }

            // A media rewrite invalidates every uncommitted job from older generations. Recovery must
            // never republish those jobs against current media.
            try db.execute(sql: """
                UPDATE call_transcript_jobs
                SET state = 'cancelled', updatedAtMs = ?, errorCode = 'stale_media_generation'
                WHERE state NOT IN ('cancelled', 'satisfied_by_final')
                  AND mediaGeneration != (
                    SELECT mediaGeneration FROM calls WHERE calls.id = call_transcript_jobs.callId
                  )
                """, arguments: [nowMs])

            let runningReset = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM call_transcript_jobs j
                    JOIN calls c ON c.id = j.callId
                    WHERE j.state = 'running' AND j.mediaGeneration = c.mediaGeneration
                    """
            ) ?? 0

            // Rebuild the bounded checkpoint admission set deterministically. Preparing jobs remain
            // unclaimable: only U2 can translate persisted ingress targets into exact sample watermarks.
            let checkpointJobs = try CallTranscriptJobRow.fetchAll(db, sql: """
                SELECT j.* FROM call_transcript_jobs j
                JOIN calls c ON c.id = j.callId
                WHERE j.kind = 'checkpoint'
                  AND j.state IN ('pending', 'running', 'deferred_capacity')
                  AND j.mediaGeneration = c.mediaGeneration
                ORDER BY j.createdAtMs, j.id
                """)
            var pendingByCall: [Int64: Int] = [:]
            var pendingGlobal = 0
            for job in checkpointJobs {
                let callPending = pendingByCall[job.callId, default: 0]
                let admits = callPending < 32 && pendingGlobal < 64
                let state: CallTranscriptJobState = admits ? .pending : .deferredCapacity
                if admits {
                    pendingByCall[job.callId] = callPending + 1
                    pendingGlobal += 1
                }
                try db.execute(
                    sql: """
                        UPDATE call_transcript_jobs
                        SET state = ?, updatedAtMs = ?,
                            errorCode = CASE WHEN ? = 'pending'
                                THEN 'recovered_after_interruption'
                                ELSE 'deferred_capacity' END
                        WHERE id = ?
                        """,
                    arguments: [state.rawValue, nowMs, state.rawValue, job.id]
                )
                if let bookmarkID = job.bookmarkId {
                    try db.execute(
                        sql: "UPDATE call_bookmarks SET state = ? WHERE id = ?",
                        arguments: [
                            state == .pending
                                ? CallBookmarkState.pending.rawValue
                                : CallBookmarkState.deferredCapacity.rawValue,
                            bookmarkID,
                        ]
                    )
                }
            }

            // Finals are never capacity-deferred and outrank checkpoints once the active helper exits.
            try db.execute(sql: """
                UPDATE call_transcript_jobs
                SET state = 'pending', priority = 0, updatedAtMs = ?,
                    errorCode = CASE WHEN state = 'running'
                        THEN 'recovered_after_interruption' ELSE errorCode END
                WHERE kind = 'final'
                  AND state IN ('running', 'deferred_capacity')
                  AND mediaGeneration = (
                    SELECT mediaGeneration FROM calls WHERE calls.id = call_transcript_jobs.callId
                  )
                """, arguments: [nowMs])

            var finalJobsCreated = 0
            let recoverable = try Row.fetchAll(db, sql: """
                SELECT c.id, c.startTs, c.endTs, c.mediaGeneration
                FROM calls c
                WHERE c.state = 'interrupted'
                  AND EXISTS (
                    SELECT 1 FROM call_audio_chunks a
                    WHERE a.callId = c.id AND a.finalized = 1 AND a.bytes > 0
                  )
                ORDER BY c.id
                """)
            for row in recoverable {
                let callID: Int64 = row["id"]
                let generation: Int = row["mediaGeneration"]
                let startTs: Int64 = row["startTs"]
                let endTs: Int64 = row["endTs"]
                try db.execute(sql: """
                    INSERT OR IGNORE INTO call_transcript_jobs(
                        identity, callId, bookmarkId, kind, mediaGeneration, state, priority,
                        logicalStartMs, logicalEndMs, contextStartMs,
                        meEndSample, systemEndSample, coverageFrozen, attempts,
                        errorCode, createdAtMs, updatedAtMs
                    ) VALUES (?, ?, NULL, 'final', ?, 'pending', 0, ?, ?, ?,
                        (SELECT MAX(endSample) FROM call_audio_chunks WHERE callId = ? AND source = 'me' AND finalized = 1),
                        (SELECT MAX(endSample) FROM call_audio_chunks WHERE callId = ? AND source = 'system' AND finalized = 1),
                        1, 0, 'recovered_final', ?, ?)
                    """, arguments: [
                        "final:\(callID):\(generation)", callID, generation,
                        startTs, endTs, startTs, callID, callID, nowMs, nowMs,
                    ])
                if db.changesCount > 0 { finalJobsCreated += 1 }
            }

            return CallRecoveryDatabaseReport(
                callsInterrupted: interruptedCallIDs.count,
                jobsReset: runningReset,
                finalJobsCreated: finalJobsCreated
            )
        }
    }

    func recoverableMutations() async throws -> [CallMediaMutationRow] {
        try await database.pool.read { db in
            try CallMediaMutationRow
                .filter(
                    Column("state") != CallMediaMutationState.rolledBack.rawValue
                        && Column("state") != CallMediaMutationState.completed.rawValue
                        && Column("state") != CallMediaMutationState.failed.rawValue
                )
                .order(Column("id"))
                .fetchAll(db)
        }
    }

    func mediaGeneration(callID: Int64) async throws -> Int? {
        try await database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT mediaGeneration FROM calls WHERE id = ?",
                arguments: [callID]
            )
        }
    }

    func isMediaPathReferenced(_ relativePath: String) async throws -> Bool {
        try await database.pool.read { db in
            (try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM call_audio_chunks WHERE relativePath = ? LIMIT 1",
                arguments: [relativePath]
            )) != nil
        }
    }

    func markMutation(_ id: Int64, state: CallMediaMutationState, nowMs: Int64, errorCode: String? = nil) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE call_media_mutations SET state = ?, updatedAtMs = ?, errorCode = ? WHERE id = ?",
                arguments: [state.rawValue, nowMs, errorCode, id]
            )
        }
    }
}
