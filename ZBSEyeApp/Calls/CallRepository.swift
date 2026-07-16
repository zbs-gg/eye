import Foundation
import GRDB

enum CallRepositoryError: LocalizedError, Sendable, Equatable {
    case callNotFound(Int64)
    case callNotRecording(Int64)
    case inconsistentBookmark(Int64)
    case inconsistentFinalJob(Int64)

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

    func endCall(callID: Int64, idempotencyKey: String, endedAtMs: Int64) async throws -> CallTranscriptJobRow {
        try await database.pool.write { db in
            guard var call = try CallRow.fetchOne(db, key: callID) else {
                throw CallRepositoryError.callNotFound(callID)
            }
            if call.state == .recording {
                call.state = .finalizing
                call.endTs = max(call.startTs, endedAtMs)
                call.endIdempotencyKey = idempotencyKey
                call.updatedAtMs = endedAtMs
                try call.update(db)
            }
            if let existing = try CallTranscriptJobRow
                .filter(
                    Column("callId") == callID
                        && Column("mediaGeneration") == call.mediaGeneration
                        && Column("kind") == CallTranscriptJobKind.final.rawValue
                )
                .fetchOne(db) {
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
                meEndSample: nil,
                systemEndSample: nil,
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
