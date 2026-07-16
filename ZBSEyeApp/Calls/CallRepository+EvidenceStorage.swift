import Foundation
import GRDB

/// A file-scoped transaction capability for the repository extension below.
/// Other production files can see the opaque holder but cannot obtain the
/// database or invoke its fileprivate transaction methods.
final class CallRepositoryEvidenceStorage: Sendable {
    private let database: ZBSEyeDatabase

    init(database: ZBSEyeDatabase) {
        self.database = database
    }

    fileprivate func read<Value: Sendable>(
        _ body: @escaping @Sendable (Database) throws -> Value
    ) async throws -> Value {
        try await database.pool.read(body)
    }

    fileprivate func write<Value: Sendable>(
        _ body: @escaping @Sendable (Database) throws -> Value
    ) async throws -> Value {
        try await database.pool.write(body)
    }
}

extension CallRepository {
    func recordSourceSpan(_ draft: CallSourceSpanDraft) async throws -> CallSourceSpanRow {
        try await evidenceStorage.write { db in
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
        try await evidenceStorage.write { db in
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
        try await evidenceStorage.read { db in
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
        try await evidenceStorage.write { db in
            guard let chunk = try CallAudioChunkRow.fetchOne(db, key: id),
                  !chunk.finalized,
                  let span = try CallSourceSpanRow.fetchOne(db, key: chunk.sourceSpanId),
                  span.sampleRate > 0,
                  endSample >= chunk.startSample else {
                throw CallRepositoryError.invalidMediaMutation(id)
            }
            let sampleCount = endSample - chunk.startSample
            let scaled = sampleCount.multipliedReportingOverflow(by: 1_000)
            guard !scaled.overflow else { throw CallRepositoryError.invalidMediaMutation(id) }
            let sampleRate = Int64(span.sampleRate)
            let durationMs = sampleCount == 0
                ? 0
                : max(
                    1,
                    scaled.partialValue / sampleRate
                        + (scaled.partialValue.isMultiple(of: sampleRate) ? 0 : 1)
                )
            let recoveredEnd = chunk.startMs.addingReportingOverflow(durationMs)
            guard !recoveredEnd.overflow else { throw CallRepositoryError.invalidMediaMutation(id) }
            try db.execute(
                sql: """
                    UPDATE call_audio_chunks
                    SET bytes = ?, endSample = ?, endMs = ?, sha256 = ?, finalized = 1
                    WHERE id = ? AND finalized = 0
                    """,
                arguments: [bytes, endSample, recoveredEnd.partialValue, sha256, id]
            )
            try db.execute(
                sql: """
                    UPDATE call_source_spans
                    SET endedAtMs = MAX(COALESCE(endedAtMs, ?), ?),
                        endSample = MAX(COALESCE(endSample, ?), ?)
                    WHERE id = ?
                    """,
                arguments: [
                    recoveredEnd.partialValue,
                    recoveredEnd.partialValue,
                    endSample,
                    endSample,
                    chunk.sourceSpanId,
                ]
            )
        }
    }

    func discardRecoveredChunk(id: Int64) async throws {
        try await evidenceStorage.write { db in
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
        try await evidenceStorage.write { db in
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
        try await evidenceStorage.write { db in
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
        try await evidenceStorage.write { db in
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
        try await evidenceStorage.read { db in
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
        try await evidenceStorage.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT mediaGeneration FROM calls WHERE id = ?",
                arguments: [callID]
            )
        }
    }

    func isMediaPathReferenced(_ relativePath: String) async throws -> Bool {
        try await evidenceStorage.read { db in
            (try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM call_audio_chunks WHERE relativePath = ? LIMIT 1",
                arguments: [relativePath]
            )) != nil
        }
    }

    func markMutation(_ id: Int64, state: CallMediaMutationState, nowMs: Int64, errorCode: String? = nil) async throws {
        try await evidenceStorage.write { db in
            try db.execute(
                sql: "UPDATE call_media_mutations SET state = ?, updatedAtMs = ?, errorCode = ? WHERE id = ?",
                arguments: [state.rawValue, nowMs, errorCode, id]
            )
        }
    }

    func callEvidenceBytes() async throws -> Int64 {
        try await evidenceStorage.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(bytes), 0) FROM call_audio_chunks"
            ) ?? 0
        }
    }

    func recordingCallID() async throws -> Int64? {
        try await evidenceStorage.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT id FROM calls WHERE state = 'recording' ORDER BY id LIMIT 1"
            )
        }
    }

    func redactionSnapshot(callID: Int64) async throws -> CallRedactionSourceSnapshot {
        try await evidenceStorage.read { db in
            guard let call = try CallRow.fetchOne(db, key: callID) else {
                throw CallRepositoryError.callNotFound(callID)
            }
            guard call.state != .recording else {
                throw CallRepositoryError.activeCallMustEnd(callID)
            }
            let pendingMutation = try Int.fetchOne(
                db,
                sql: """
                    SELECT 1 FROM call_media_mutations
                    WHERE callId = ? AND kind = ? AND state IN (?, ?, ?)
                    LIMIT 1
                    """,
                arguments: [
                    callID,
                    CallMediaMutationKind.redaction.rawValue,
                    CallMediaMutationState.staged.rawValue,
                    CallMediaMutationState.referenceSwapped.rawValue,
                    CallMediaMutationState.cleanupPending.rawValue,
                ]
            )
            guard pendingMutation == nil else {
                throw CallRepositoryError.invalidMediaMutation(callID)
            }
            let spans = try CallSourceSpanRow.fetchAll(
                db,
                sql: "SELECT * FROM call_source_spans WHERE callId = ? ORDER BY source, epoch",
                arguments: [callID]
            )
            let chunks = try CallAudioChunkRow.fetchAll(
                db,
                sql: "SELECT * FROM call_audio_chunks WHERE callId = ? ORDER BY source, epoch, sequence",
                arguments: [callID]
            )
            return CallRedactionSourceSnapshot(call: call, spans: spans, chunks: chunks)
        }
    }

    func callIDsIntersecting(fromMs: Int64, toMs: Int64) async throws -> [Int64] {
        guard fromMs < toMs else { return [] }
        return try await evidenceStorage.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT id FROM calls
                    WHERE startTs < ? AND COALESCE(endTs, 9223372036854775807) > ?
                      AND (degradationReason IS NULL OR degradationReason != 'erase_pending')
                    ORDER BY startTs, id
                    """,
                arguments: [toMs, fromMs]
            )
        }
    }

    func beginRedaction(
        manifest: CallRedactionManifestV1,
        nowMs: Int64
    ) async throws -> CallMediaMutationRow {
        guard let mutation = try await beginRedactions(
            manifests: [manifest],
            nowMs: nowMs
        ).first else {
            throw CallRepositoryError.invalidMediaMutation(manifest.callID)
        }
        return mutation
    }

    /// Accept every call touched by one privacy range in a single transaction.
    /// File rewriting can then proceed call-by-call while recovery still knows
    /// the complete accepted intent after a crash.
    func beginRedactions(
        manifests: [CallRedactionManifestV1],
        nowMs: Int64
    ) async throws -> [CallMediaMutationRow] {
        guard !manifests.isEmpty,
              Set(manifests.map(\.callID)).count == manifests.count else {
            throw CallRepositoryError.invalidMediaMutation(manifests.first?.callID ?? 0)
        }
        return try await evidenceStorage.write { db in
            try manifests.map { manifest in
                try Self.beginRedaction(manifest: manifest, nowMs: nowMs, db: db)
            }
        }
    }

    private static func beginRedaction(
        manifest: CallRedactionManifestV1,
        nowMs: Int64,
        db: Database
    ) throws -> CallMediaMutationRow {
            guard var call = try CallRow.fetchOne(db, key: manifest.callID) else {
                throw CallRepositoryError.callNotFound(manifest.callID)
            }
            guard call.state != .recording else {
                throw CallRepositoryError.activeCallMustEnd(manifest.callID)
            }
            let identity = "redaction:\(manifest.callID):\(manifest.fromGeneration):\(manifest.fromMs):\(manifest.toMs)"
            if let existing = try CallMediaMutationRow
                .filter(Column("identity") == identity)
                .fetchOne(db) {
                return existing
            }
            guard manifest.formatVersion == CallRedactionManifestV1.formatVersion,
                  manifest.fromMs < manifest.toMs,
                  call.mediaGeneration == manifest.fromGeneration,
                  manifest.toGeneration == manifest.fromGeneration + 1 else {
                throw CallRepositoryError.invalidMediaMutation(manifest.callID)
            }
            let oldJSON = String(
                decoding: try JSONEncoder().encode(manifest.obsoleteRelativePaths),
                as: UTF8.self
            )
            var mutation = CallMediaMutationRow(
                id: nil,
                identity: identity,
                callId: manifest.callID,
                kind: .redaction,
                state: .staged,
                fromGeneration: manifest.fromGeneration,
                toGeneration: manifest.toGeneration,
                oldRelativePathsJSON: oldJSON,
                newRelativePathsJSON: try manifest.encodedJSON(),
                createdAtMs: nowMs,
                updatedAtMs: nowMs,
                errorCode: nil
            )
            try mutation.insert(db)

            call.preferredRevisionId = nil
            call.mediaGeneration = manifest.toGeneration
            call.state = .failed
            call.degradationReason = "redaction_pending"
            call.updatedAtMs = nowMs
            try call.update(db)

            try db.execute(
                sql: """
                    DELETE FROM embed_queue WHERE kind = 2 AND row_id IN (
                        SELECT id FROM call_transcript_revisions WHERE callId = ?
                    )
                    """,
                arguments: [manifest.callID]
            )
            // Revisions precede jobs: deleting jobs first SET NULLs jobId and violates
            // the revision identity CHECK before the revision can be invalidated.
            try db.execute(
                sql: "DELETE FROM call_transcript_revisions WHERE callId = ?",
                arguments: [manifest.callID]
            )
            try db.execute(
                sql: "DELETE FROM call_transcript_jobs WHERE callId = ?",
                arguments: [manifest.callID]
            )
            try db.execute(
                sql: """
                    DELETE FROM call_bookmarks
                    WHERE callId = ? AND acceptedAtMs >= ? AND acceptedAtMs < ?
                    """,
                arguments: [manifest.callID, manifest.fromMs, manifest.toMs]
            )
            try db.execute(
                sql: """
                    UPDATE call_bookmarks
                    SET mediaGeneration = ?, state = ?
                    WHERE callId = ?
                    """,
                arguments: [
                    manifest.toGeneration,
                    CallBookmarkState.pending.rawValue,
                    manifest.callID,
                ]
            )
            try db.execute(
                sql: "UPDATE call_source_gaps SET mediaGeneration = ? WHERE callId = ?",
                arguments: [manifest.toGeneration, manifest.callID]
            )
            return mutation
    }

    func commitRedactionReferenceSwap(
        mutationID: Int64,
        manifest: CallRedactionManifestV1,
        nowMs: Int64
    ) async throws {
        try await evidenceStorage.write { db in
            guard var mutation = try CallMediaMutationRow.fetchOne(db, key: mutationID),
                  mutation.kind == .redaction,
                  mutation.callId == manifest.callID,
                  mutation.fromGeneration == manifest.fromGeneration,
                  mutation.toGeneration == manifest.toGeneration,
                  let call = try CallRow.fetchOne(db, key: manifest.callID),
                  call.mediaGeneration == manifest.toGeneration else {
                throw CallRepositoryError.invalidMediaMutation(mutationID)
            }
            if mutation.state == .referenceSwapped
                || mutation.state == .cleanupPending
                || mutation.state == .completed {
                return
            }
            guard mutation.state == .staged else {
                throw CallRepositoryError.invalidMediaMutation(mutationID)
            }

            try db.execute(
                sql: "DELETE FROM call_audio_chunks WHERE callId = ?",
                arguments: [manifest.callID]
            )
            for survivor in manifest.survivors {
                var chunk = CallAudioChunkRow(
                    id: nil,
                    callId: manifest.callID,
                    sourceSpanId: survivor.sourceSpanID,
                    source: survivor.source,
                    epoch: survivor.epoch,
                    sequence: survivor.sequence,
                    mediaGeneration: manifest.toGeneration,
                    startSample: survivor.startSample,
                    endSample: survivor.endSample,
                    startMs: survivor.startMs,
                    endMs: survivor.endMs,
                    relativePath: survivor.relativePath,
                    bytes: survivor.bytes,
                    sha256: survivor.sha256,
                    finalized: true
                )
                try chunk.insert(db)
            }

            for requestedGap in manifest.redactedGaps {
                let overlapping = try CallSourceGapRow.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM call_source_gaps
                        WHERE callId = ? AND mediaGeneration = ? AND source = ?
                          AND reason = 'redacted' AND endMs >= ? AND startMs <= ?
                        """,
                    arguments: [
                        manifest.callID,
                        manifest.toGeneration,
                        requestedGap.source.rawValue,
                        requestedGap.startMs,
                        requestedGap.endMs,
                    ]
                )
                let mergedStart = overlapping.reduce(requestedGap.startMs) { min($0, $1.startMs) }
                let mergedEnd = overlapping.reduce(requestedGap.endMs) { max($0, $1.endMs) }
                if !overlapping.isEmpty {
                    let ids = overlapping.compactMap(\.id)
                    try CallSourceGapRow.filter(ids.contains(Column("id"))).deleteAll(db)
                }
                var gap = CallSourceGapRow(
                    id: nil,
                    callId: manifest.callID,
                    mediaGeneration: manifest.toGeneration,
                    source: requestedGap.source,
                    startMs: mergedStart,
                    endMs: mergedEnd,
                    reason: "redacted",
                    createdAtMs: nowMs
                )
                try gap.insert(db)
            }

            let meEndSample = manifest.survivors
                .filter { $0.source == .me }
                .map(\.endSample)
                .max()
            let systemEndSample = manifest.survivors
                .filter { $0.source == .system }
                .map(\.endSample)
                .max()
            guard let logicalEndMs = call.endTs else {
                throw CallRepositoryError.invalidMediaMutation(mutationID)
            }
            var final = CallTranscriptJobRow(
                id: nil,
                identity: "final:\(manifest.callID):\(manifest.toGeneration)",
                callId: manifest.callID,
                bookmarkId: nil,
                kind: .final,
                mediaGeneration: manifest.toGeneration,
                state: .pending,
                priority: 0,
                logicalStartMs: call.startTs,
                logicalEndMs: logicalEndMs,
                contextStartMs: call.startTs,
                meEndSample: meEndSample,
                systemEndSample: systemEndSample,
                coverageFrozen: true,
                attempts: 0,
                errorCode: "redaction_rebuild",
                createdAtMs: nowMs,
                updatedAtMs: nowMs
            )
            try final.insert(db)
            try db.execute(
                sql: """
                    UPDATE calls
                    SET state = ?, degradationReason = 'redacted', updatedAtMs = ?
                    WHERE id = ?
                    """,
                arguments: [CallLifecycleState.finalizing.rawValue, nowMs, manifest.callID]
            )
            mutation.state = .referenceSwapped
            mutation.updatedAtMs = nowMs
            mutation.errorCode = nil
            try mutation.update(db)
        }
    }

    func completeRedaction(mutationID: Int64, nowMs: Int64) async throws {
        try await evidenceStorage.write { db in
            guard let mutation = try CallMediaMutationRow.fetchOne(db, key: mutationID),
                  mutation.kind == .redaction,
                  mutation.state == .referenceSwapped || mutation.state == .cleanupPending else {
                throw CallRepositoryError.invalidMediaMutation(mutationID)
            }
            try db.execute(
                sql: """
                    UPDATE call_media_mutations
                    SET state = ?, updatedAtMs = ?, errorCode = NULL
                    WHERE id = ?
                    """,
                arguments: [CallMediaMutationState.completed.rawValue, nowMs, mutationID]
            )
        }
    }

    func pendingRedactions() async throws -> [CallMediaMutationRow] {
        try await evidenceStorage.read { db in
            try CallMediaMutationRow.fetchAll(
                db,
                sql: """
                    SELECT * FROM call_media_mutations
                    WHERE kind = ? AND state IN (?, ?, ?)
                    ORDER BY id
                    """,
                arguments: [
                    CallMediaMutationKind.redaction.rawValue,
                    CallMediaMutationState.staged.rawValue,
                    CallMediaMutationState.referenceSwapped.rawValue,
                    CallMediaMutationState.cleanupPending.rawValue,
                ]
            )
        }
    }

    func pendingErasePreparations() async throws -> [CallErasePreparation] {
        try await evidenceStorage.read { db in
            let mutations = try CallMediaMutationRow.fetchAll(
                db,
                sql: """
                    SELECT * FROM call_media_mutations
                    WHERE kind = ? AND state NOT IN (?, ?, ?)
                    ORDER BY id
                    """,
                arguments: [
                    CallMediaMutationKind.erase.rawValue,
                    CallMediaMutationState.completed.rawValue,
                    CallMediaMutationState.rolledBack.rawValue,
                    CallMediaMutationState.failed.rawValue,
                ]
            )
            return try mutations.map { mutation in
                guard let mutationID = mutation.id,
                      let data = mutation.oldRelativePathsJSON.data(using: .utf8),
                      let paths = try? JSONDecoder().decode([String].self, from: data) else {
                    throw CallRepositoryError.invalidMediaMutation(mutation.id ?? mutation.callId)
                }
                return CallErasePreparation(
                    mutationID: mutationID,
                    callID: mutation.callId,
                    relativePaths: paths,
                    bytes: 0
                )
            }
        }
    }

    func referencedCallMediaPaths() async throws -> Set<String> {
        try await evidenceStorage.read { db in
            Set(try String.fetchAll(db, sql: "SELECT relativePath FROM call_audio_chunks"))
        }
    }

    func oldestErasableCallID(before cutoffMs: Int64?) async throws -> Int64? {
        try await evidenceStorage.read { db in
            if let cutoffMs {
                return try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT id FROM calls
                        WHERE state != 'recording'
                          AND COALESCE(endTs, startTs) < ?
                          AND (degradationReason IS NULL OR degradationReason != 'erase_pending')
                        ORDER BY startTs, id LIMIT 1
                        """,
                    arguments: [cutoffMs]
                )
            }
            return try Int64.fetchOne(
                db,
                sql: """
                    SELECT id FROM calls
                    WHERE state != 'recording'
                      AND (degradationReason IS NULL OR degradationReason != 'erase_pending')
                    ORDER BY startTs, id LIMIT 1
                    """
            )
        }
    }

    func beginEraseCall(
        callID: Int64,
        nowMs: Int64,
        additionalRelativePaths: [String] = []
    ) async throws -> CallErasePreparation {
        try await evidenceStorage.write { db in
            guard var call = try CallRow.fetchOne(db, key: callID) else {
                throw CallRepositoryError.callNotFound(callID)
            }
            guard call.state != .recording else {
                throw CallRepositoryError.activeCallMustEnd(callID)
            }
            if let existing = try CallMediaMutationRow.fetchOne(
                db,
                sql: """
                    SELECT * FROM call_media_mutations
                    WHERE callId = ? AND kind = ?
                      AND state NOT IN (?, ?, ?)
                    ORDER BY id DESC LIMIT 1
                    """,
                arguments: [
                    callID,
                    CallMediaMutationKind.erase.rawValue,
                    CallMediaMutationState.completed.rawValue,
                    CallMediaMutationState.rolledBack.rawValue,
                    CallMediaMutationState.failed.rawValue,
                ]
            ), let mutationID = existing.id,
               let data = existing.oldRelativePathsJSON.data(using: .utf8),
               let paths = try? JSONDecoder().decode([String].self, from: data) {
                return CallErasePreparation(
                    mutationID: mutationID,
                    callID: callID,
                    relativePaths: paths,
                    bytes: 0
                )
            }

            let chunks = try CallAudioChunkRow
                .filter(Column("callId") == callID)
                .order(Column("id"))
                .fetchAll(db)
            let redactionMutations = try CallMediaMutationRow.fetchAll(
                db,
                sql: """
                    SELECT * FROM call_media_mutations
                    WHERE callId = ? AND kind = ?
                      AND state NOT IN (?, ?, ?)
                    """,
                arguments: [
                    callID,
                    CallMediaMutationKind.redaction.rawValue,
                    CallMediaMutationState.completed.rawValue,
                    CallMediaMutationState.rolledBack.rawValue,
                    CallMediaMutationState.failed.rawValue,
                ]
            )
            var paths = Set(chunks.map(\.relativePath))
            paths.formUnion(additionalRelativePaths)
            for redaction in redactionMutations {
                guard let data = redaction.oldRelativePathsJSON.data(using: .utf8),
                      let oldPaths = try? JSONDecoder().decode([String].self, from: data) else {
                    continue
                }
                paths.formUnion(oldPaths)
            }
            let sortedPaths = paths.sorted()
            let bytes = chunks.reduce(Int64(0)) { partial, chunk in
                let next = partial.addingReportingOverflow(chunk.bytes)
                return next.overflow ? Int64.max : next.partialValue
            }
            let pathData = try JSONEncoder().encode(sortedPaths)
            guard let pathJSON = String(data: pathData, encoding: .utf8) else {
                throw CallRepositoryError.invalidMediaMutation(callID)
            }
            let generation = call.mediaGeneration.addingReportingOverflow(1)
            guard !generation.overflow else {
                throw CallRepositoryError.invalidMediaMutation(callID)
            }
            let nextGeneration = generation.partialValue
            var mutation = CallMediaMutationRow(
                id: nil,
                identity: "erase:\(callID):\(call.mediaGeneration)",
                callId: callID,
                kind: .erase,
                state: .cleanupPending,
                fromGeneration: call.mediaGeneration,
                toGeneration: nextGeneration,
                oldRelativePathsJSON: pathJSON,
                newRelativePathsJSON: "[]",
                createdAtMs: nowMs,
                updatedAtMs: nowMs,
                errorCode: nil
            )
            try mutation.insert(db)
            guard let mutationID = mutation.id else {
                throw CallRepositoryError.invalidMediaMutation(callID)
            }

            call.preferredRevisionId = nil
            call.mediaGeneration = nextGeneration
            call.state = .failed
            call.degradationReason = "erase_pending"
            call.updatedAtMs = nowMs
            try call.update(db)

            try db.execute(
                sql: """
                    DELETE FROM embed_queue WHERE kind = 2 AND row_id IN (
                        SELECT id FROM call_transcript_revisions WHERE callId = ?
                    )
                    """,
                arguments: [callID]
            )
            // Revisions go before jobs: deleting a job first SET NULLs jobId
            // and violates the revision identity CHECK.
            try db.execute(
                sql: "DELETE FROM call_transcript_revisions WHERE callId = ?",
                arguments: [callID]
            )
            try db.execute(
                sql: "DELETE FROM call_transcript_jobs WHERE callId = ?",
                arguments: [callID]
            )
            try db.execute(
                sql: "DELETE FROM call_bookmarks WHERE callId = ?",
                arguments: [callID]
            )
            try db.execute(
                sql: "DELETE FROM call_audio_chunks WHERE callId = ?",
                arguments: [callID]
            )
            try db.execute(
                sql: "DELETE FROM call_source_spans WHERE callId = ?",
                arguments: [callID]
            )
            return CallErasePreparation(
                mutationID: mutationID,
                callID: callID,
                relativePaths: sortedPaths,
                bytes: bytes
            )
        }
    }

    func finalizeEraseCall(mutationID: Int64, nowMs: Int64) async throws {
        try await evidenceStorage.write { db in
            guard let mutation = try CallMediaMutationRow.fetchOne(db, key: mutationID),
                  mutation.kind == .erase,
                  mutation.state == .cleanupPending || mutation.state == .referenceSwapped,
                  (try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_audio_chunks WHERE callId = ?",
                    arguments: [mutation.callId]
                  ) ?? -1) == 0 else {
                throw CallRepositoryError.invalidMediaMutation(mutationID)
            }
            try db.execute(
                sql: "UPDATE call_media_mutations SET updatedAtMs = ? WHERE id = ?",
                arguments: [nowMs, mutationID]
            )
            try db.execute(sql: "DELETE FROM calls WHERE id = ?", arguments: [mutation.callId])
        }
    }
}
