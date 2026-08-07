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
    case speakerRevisionMissing(Int64)
    case invalidSpeakerCorrection(Int64)
    case noSpeakerCorrectionToUndo(Int64)
    case activeCallMustEnd(Int64)
    case invalidMediaMutation(Int64)
    case invalidPrivacyIntent(Int64)

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
        case .speakerRevisionMissing:
            return "The call has no current speaker revision."
        case .invalidSpeakerCorrection:
            return "The speaker correction is invalid or does not change the call."
        case .noSpeakerCorrectionToUndo:
            return "There is no earlier speaker correction to restore."
        case .activeCallMustEnd:
            return "End the active call before deleting its evidence. Nothing was deleted."
        case .invalidMediaMutation:
            return "The call deletion journal is inconsistent."
        case .invalidPrivacyIntent:
            return "The call privacy receipt does not match its recorded call."
        }
    }
}

private struct PreferredSpeakerSnapshot {
    let call: CallRow
    let revision: CallSpeakerRevisionRow
    let clusters: [CallSpeakerClusterDraft]
}

/// The only writer for the first-class call tables. Capture code hands Sendable drafts to this actor;
/// helper and MCP processes never receive this type.
actor CallRepository {
    private let database: ZBSEyeDatabase
    let evidenceStorage: CallRepositoryEvidenceStorage

    init(database: ZBSEyeDatabase) {
        self.database = database
        evidenceStorage = CallRepositoryEvidenceStorage(database: database)
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
            let endedNow = call.state == .recording
            if endedNow {
                call.state = .finalizing
                call.endTs = max(call.startTs, endedAtMs)
                call.endIdempotencyKey = idempotencyKey
                if let degradationReason {
                    call.degradationReason = degradationReason
                }
                call.updatedAtMs = endedAtMs
                try call.update(db)
            }
            let finalJob: CallTranscriptJobRow
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
                finalJob = existing
            } else {
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
                finalJob = job
            }
            if endedNow {
                try Self.enqueueCallEndedAutomation(call: call, callID: callID, occurredAtMs: endedAtMs, db: db)
            }
            return finalJob
        }
    }

    func setPreferredRevision(callID: Int64, revisionID: Int64) async throws {
        try await database.pool.write { db in
            guard try CallRow.fetchOne(db, key: callID) != nil else {
                throw CallRepositoryError.callNotFound(callID)
            }
            try db.execute(
                sql: "UPDATE calls SET preferredRevisionId = ?, updatedAtMs = MAX(updatedAtMs, ?) WHERE id = ?",
                arguments: [revisionID, msFromDate(Date()), callID]
            )
        }
    }

    func upsertCallContext(_ context: CallContextRow) async throws {
        try await database.pool.write { db in
            guard try CallRow.fetchOne(db, key: context.callId) != nil else {
                throw CallRepositoryError.callNotFound(context.callId)
            }
            try context.save(db)
        }
    }

    /// Universal microphone admission intentionally precedes slower AX/browser inspection. This
    /// upsert creates the initial automatic context and later fills only stronger missing fields.
    /// A caller may explicitly promote a generic owner to a freshly verified native/browser call
    /// surface; it never rewrites the activation fingerprint, creation time, or terminal disposition.
    func enrichAutomaticCallContext(
        callID: Int64,
        detectorFingerprint: String,
        sourceAppBundleID: String?,
        sourceAppName: String?,
        trustedOriginHost: String?,
        replaceExistingSource: Bool = false,
        nowMs: Int64
    ) async throws {
        try await database.pool.write { db in
            guard try CallRow.fetchOne(db, key: callID) != nil else {
                throw CallRepositoryError.callNotFound(callID)
            }
            try db.execute(
                sql: """
                    INSERT INTO call_context(
                        callId, captureOwner, disposition, detectorFingerprintHash,
                        sourceAppBundleID, sourceAppName, trustedOriginHost, title,
                        participantsJSON, createdAtMs, updatedAtMs
                    ) VALUES (?, 'automatic', 'active', ?, ?, ?, ?, NULL, '[]', ?, ?)
                    ON CONFLICT(callId) DO UPDATE SET
                        sourceAppName = CASE
                            WHEN ? = 1
                              OR call_context.sourceAppBundleID IS NULL
                              OR call_context.sourceAppBundleID LIKE 'process:%'
                              OR call_context.sourceAppBundleID LIKE 'process-pid:%'
                                THEN COALESCE(excluded.sourceAppName, call_context.sourceAppName)
                            ELSE COALESCE(call_context.sourceAppName, excluded.sourceAppName)
                        END,
                        sourceAppBundleID = CASE
                            WHEN ? = 1
                              OR call_context.sourceAppBundleID IS NULL
                              OR call_context.sourceAppBundleID LIKE 'process:%'
                              OR call_context.sourceAppBundleID LIKE 'process-pid:%'
                                THEN COALESCE(excluded.sourceAppBundleID, call_context.sourceAppBundleID)
                            ELSE call_context.sourceAppBundleID
                        END,
                        trustedOriginHost = COALESCE(
                            call_context.trustedOriginHost,
                            excluded.trustedOriginHost
                        ),
                        detectorFingerprintHash = COALESCE(
                            call_context.detectorFingerprintHash,
                            excluded.detectorFingerprintHash
                        ),
                        updatedAtMs = MAX(call_context.updatedAtMs, excluded.updatedAtMs)
                    WHERE call_context.captureOwner = 'automatic'
                      AND call_context.disposition != 'rejected'
                    """,
                arguments: [
                    callID,
                    detectorFingerprint,
                    sourceAppBundleID,
                    sourceAppName,
                    trustedOriginHost,
                    nowMs,
                    nowMs,
                    replaceExistingSource,
                    replaceExistingSource,
                ]
            )
        }
    }

    func updateCallCaptureContext(
        callID: Int64,
        owner: CallCaptureOwner,
        disposition: CallCaptureDisposition,
        nowMs: Int64
    ) async throws {
        try await database.pool.write { db in
            guard try CallRow.fetchOne(db, key: callID) != nil else {
                throw CallRepositoryError.callNotFound(callID)
            }
            try db.execute(
                sql: """
                    UPDATE call_context
                    SET captureOwner = ?, disposition = ?, updatedAtMs = ?
                    WHERE callId = ?
                    """,
                arguments: [owner.rawValue, disposition.rawValue, nowMs, callID]
            )
        }
    }

    /// Saves one complete immutable per-call speaker revision. Acoustic
    /// embeddings never cross this boundary; only anonymous timed clusters do.
    func createSpeakerRevision(
        callID: Int64,
        mediaGeneration: Int,
        engine: String,
        modelRevision: String,
        clusters: [CallSpeakerClusterDraft],
        nowMs: Int64
    ) async throws -> CallSpeakerRevisionRow {
        try await database.pool.write { db in
            guard let call = try CallRow.fetchOne(db, key: callID) else {
                throw CallRepositoryError.callNotFound(callID)
            }
            guard call.mediaGeneration == mediaGeneration else {
                throw CallRepositoryError.invalidMediaMutation(callID)
            }

            return try Self.insertSpeakerRevision(
                callID: callID,
                mediaGeneration: mediaGeneration,
                previousRevisionID: call.preferredSpeakerRevisionId,
                engine: engine,
                modelRevision: modelRevision,
                clusters: clusters,
                nowMs: nowMs,
                db: db
            )
        }
    }

    func setPreferredSpeakerRevision(callID: Int64, revisionID: Int64) async throws {
        try await database.pool.write { db in
            guard try CallRow.fetchOne(db, key: callID) != nil else {
                throw CallRepositoryError.callNotFound(callID)
            }
            let nowMs = msFromDate(Date())
            try db.execute(
                sql: """
                    UPDATE calls
                    SET preferredSpeakerRevisionId = ?, updatedAtMs = MAX(updatedAtMs, ?)
                    WHERE id = ?
                    """,
                arguments: [revisionID, nowMs, callID]
            )
            try Self.enqueueProcessingReadyAutomationIfComplete(
                callID: callID,
                occurredAtMs: nowMs,
                db: db
            )
        }
    }

    /// Renaming never edits diarization output in place. It writes a complete
    /// successor revision and promotes it in the same transaction.
    func renameSpeakerCluster(
        callID: Int64,
        clusterKey: String,
        displayName: String,
        nowMs: Int64
    ) async throws -> CallSpeakerRevisionRow {
        try await database.pool.write { db in
            let snapshot = try Self.preferredSpeakerSnapshot(callID: callID, db: db)
            let normalizedName = try Self.normalizedSpeakerName(displayName, callID: callID)
            guard let index = snapshot.clusters.firstIndex(where: { $0.clusterKey == clusterKey }) else {
                throw CallRepositoryError.invalidSpeakerCorrection(callID)
            }

            var clusters = snapshot.clusters
            let current = clusters[index]
            guard current.displayName != normalizedName || current.namingProvenance != .manual else {
                throw CallRepositoryError.invalidSpeakerCorrection(callID)
            }
            clusters[index] = CallSpeakerClusterDraft(
                clusterKey: current.clusterKey,
                displayName: normalizedName,
                namingProvenance: .manual,
                intervals: current.intervals
            )
            return try Self.insertAndPromoteSpeakerRevision(
                snapshot: snapshot,
                clusters: clusters,
                callID: callID,
                nowMs: nowMs,
                db: db
            )
        }
    }

    /// Moves the selected time range while retaining the original mic/system
    /// provenance on every split interval.
    func reassignSpeakerInterval(
        callID: Int64,
        selection: CallSpeakerIntervalSelection,
        target: CallSpeakerCorrectionTarget,
        nowMs: Int64
    ) async throws -> CallSpeakerRevisionRow {
        try await database.pool.write { db in
            guard selection.startMs < selection.endMs else {
                throw CallRepositoryError.invalidSpeakerCorrection(callID)
            }
            let snapshot = try Self.preferredSpeakerSnapshot(callID: callID, db: db)
            var clusters = snapshot.clusters

            let targetKey: String
            switch target {
            case let .existingCluster(clusterKey):
                guard clusters.contains(where: { $0.clusterKey == clusterKey }) else {
                    throw CallRepositoryError.invalidSpeakerCorrection(callID)
                }
                targetKey = clusterKey
            case let .newNamedSpeaker(name):
                let normalizedName = try Self.normalizedSpeakerName(name, callID: callID)
                let existingKeys = Set(clusters.map(\.clusterKey))
                var suffix = 1
                while existingKeys.contains("manual:S\(suffix)") { suffix += 1 }
                targetKey = "manual:S\(suffix)"
                clusters.append(
                    CallSpeakerClusterDraft(
                        clusterKey: targetKey,
                        displayName: normalizedName,
                        namingProvenance: .manual,
                        intervals: []
                    )
                )
            }

            var moved: [CallSpeakerIntervalDraft] = []
            var didMove = false
            clusters = clusters.map { cluster in
                guard cluster.clusterKey != targetKey else { return cluster }
                var retained: [CallSpeakerIntervalDraft] = []
                for interval in cluster.intervals {
                    let overlapStart = max(interval.startMs, selection.startMs)
                    let overlapEnd = min(interval.endMs, selection.endMs)
                    guard interval.source == selection.source, overlapStart < overlapEnd else {
                        retained.append(interval)
                        continue
                    }
                    didMove = true
                    if interval.startMs < overlapStart {
                        retained.append(
                            .init(source: interval.source, startMs: interval.startMs, endMs: overlapStart)
                        )
                    }
                    moved.append(.init(source: interval.source, startMs: overlapStart, endMs: overlapEnd))
                    if overlapEnd < interval.endMs {
                        retained.append(
                            .init(source: interval.source, startMs: overlapEnd, endMs: interval.endMs)
                        )
                    }
                }
                return CallSpeakerClusterDraft(
                    clusterKey: cluster.clusterKey,
                    displayName: cluster.displayName,
                    namingProvenance: cluster.namingProvenance,
                    intervals: Self.mergedSpeakerIntervals(retained)
                )
            }
            guard didMove else {
                throw CallRepositoryError.invalidSpeakerCorrection(callID)
            }
            guard let targetIndex = clusters.firstIndex(where: { $0.clusterKey == targetKey }) else {
                throw CallRepositoryError.invalidSpeakerCorrection(callID)
            }
            let targetCluster = clusters[targetIndex]
            clusters[targetIndex] = CallSpeakerClusterDraft(
                clusterKey: targetCluster.clusterKey,
                displayName: targetCluster.displayName,
                namingProvenance: targetCluster.namingProvenance,
                intervals: Self.mergedSpeakerIntervals(targetCluster.intervals + moved)
            )
            clusters.removeAll { $0.clusterKey != targetKey && $0.intervals.isEmpty }

            return try Self.insertAndPromoteSpeakerRevision(
                snapshot: snapshot,
                clusters: clusters,
                callID: callID,
                nowMs: nowMs,
                db: db
            )
        }
    }

    /// Undo is a pointer move to the immutable predecessor; it never deletes
    /// correction history or creates another synthetic revision.
    func undoSpeakerCorrection(callID: Int64, nowMs: Int64) async throws -> CallSpeakerRevisionRow {
        try await database.pool.write { db in
            let snapshot = try Self.preferredSpeakerSnapshot(callID: callID, db: db)
            guard let previousID = snapshot.revision.previousRevisionId,
                  let previous = try CallSpeakerRevisionRow.fetchOne(db, key: previousID),
                  previous.callId == callID,
                  previous.mediaGeneration == snapshot.call.mediaGeneration,
                  previous.state == .ready else {
                throw CallRepositoryError.noSpeakerCorrectionToUndo(callID)
            }
            try db.execute(
                sql: """
                    UPDATE calls
                    SET preferredSpeakerRevisionId = ?, updatedAtMs = MAX(updatedAtMs, ?)
                    WHERE id = ?
                    """,
                arguments: [previousID, nowMs, callID]
            )
            return previous
        }
    }

    private static func preferredSpeakerSnapshot(
        callID: Int64,
        db: Database
    ) throws -> PreferredSpeakerSnapshot {
        guard let call = try CallRow.fetchOne(db, key: callID) else {
            throw CallRepositoryError.callNotFound(callID)
        }
        guard let revisionID = call.preferredSpeakerRevisionId,
              let revision = try CallSpeakerRevisionRow.fetchOne(db, key: revisionID),
              revision.callId == callID,
              revision.mediaGeneration == call.mediaGeneration,
              revision.state == .ready else {
            throw CallRepositoryError.speakerRevisionMissing(callID)
        }

        let clusterRows = try CallSpeakerClusterRow.fetchAll(
            db,
            sql: """
                SELECT * FROM call_speaker_clusters
                WHERE revisionId = ?
                ORDER BY ordinal, id
                """,
            arguments: [revisionID]
        )
        let clusters = try clusterRows.map { cluster -> CallSpeakerClusterDraft in
            guard let clusterID = cluster.id else {
                throw CallRepositoryError.speakerRevisionMissing(callID)
            }
            let intervals = try CallSpeakerIntervalRow.fetchAll(
                db,
                sql: """
                    SELECT * FROM call_speaker_intervals
                    WHERE revisionId = ? AND clusterId = ?
                    ORDER BY ordinal, id
                    """,
                arguments: [revisionID, clusterID]
            )
            return CallSpeakerClusterDraft(
                clusterKey: cluster.clusterKey,
                displayName: cluster.displayName,
                namingProvenance: cluster.namingProvenance,
                intervals: intervals.map {
                    .init(source: $0.source, startMs: $0.startMs, endMs: $0.endMs)
                }
            )
        }
        return PreferredSpeakerSnapshot(call: call, revision: revision, clusters: clusters)
    }

    private static func insertAndPromoteSpeakerRevision(
        snapshot: PreferredSpeakerSnapshot,
        clusters: [CallSpeakerClusterDraft],
        callID: Int64,
        nowMs: Int64,
        db: Database
    ) throws -> CallSpeakerRevisionRow {
        guard let previousRevisionID = snapshot.revision.id else {
            throw CallRepositoryError.speakerRevisionMissing(callID)
        }
        let revision = try insertSpeakerRevision(
            callID: callID,
            mediaGeneration: snapshot.call.mediaGeneration,
            previousRevisionID: previousRevisionID,
            engine: snapshot.revision.engine,
            modelRevision: snapshot.revision.modelRevision,
            clusters: clusters,
            nowMs: nowMs,
            db: db
        )
        guard let revisionID = revision.id else {
            throw CallRepositoryError.speakerRevisionMissing(callID)
        }
        try db.execute(
            sql: """
                UPDATE calls
                SET preferredSpeakerRevisionId = ?, updatedAtMs = MAX(updatedAtMs, ?)
                WHERE id = ? AND mediaGeneration = ? AND preferredSpeakerRevisionId = ?
                """,
            arguments: [
                revisionID,
                nowMs,
                callID,
                snapshot.call.mediaGeneration,
                previousRevisionID,
            ]
        )
        guard db.changesCount == 1 else {
            throw CallRepositoryError.speakerRevisionMissing(callID)
        }
        return revision
    }

    private static func insertSpeakerRevision(
        callID: Int64,
        mediaGeneration: Int,
        previousRevisionID: Int64?,
        engine: String,
        modelRevision: String,
        clusters: [CallSpeakerClusterDraft],
        nowMs: Int64,
        db: Database
    ) throws -> CallSpeakerRevisionRow {
        var revision = CallSpeakerRevisionRow(
            id: nil,
            callId: callID,
            mediaGeneration: mediaGeneration,
            previousRevisionId: previousRevisionID,
            state: .ready,
            engine: engine,
            modelRevision: modelRevision,
            createdAtMs: nowMs
        )
        try revision.insert(db)
        guard let revisionID = revision.id else {
            throw CallRepositoryError.speakerRevisionMissing(callID)
        }

        try insertSpeakerClusters(
            revisionID: revisionID,
            callID: callID,
            clusters: clusters,
            db: db
        )
        return revision
    }

    private static func insertSpeakerClusters(
        revisionID: Int64,
        callID: Int64,
        clusters: [CallSpeakerClusterDraft],
        db: Database
    ) throws {
        guard Set(clusters.map(\.clusterKey)).count == clusters.count else {
            throw CallRepositoryError.invalidSpeakerCorrection(callID)
        }

        var intervalOrdinal = 0
        for (clusterOrdinal, draft) in clusters.enumerated() {
            var cluster = CallSpeakerClusterRow(
                id: nil,
                revisionId: revisionID,
                ordinal: clusterOrdinal,
                clusterKey: draft.clusterKey,
                displayName: draft.displayName,
                namingProvenance: draft.namingProvenance
            )
            try cluster.insert(db)
            guard let clusterID = cluster.id else {
                throw CallRepositoryError.speakerRevisionMissing(callID)
            }
            for interval in draft.intervals.sorted(by: {
                ($0.source.rawValue, $0.startMs, $0.endMs)
                    < ($1.source.rawValue, $1.startMs, $1.endMs)
            }) {
                guard interval.endMs >= interval.startMs else {
                    throw CallRepositoryError.invalidSpeakerCorrection(callID)
                }
                var row = CallSpeakerIntervalRow(
                    id: nil,
                    revisionId: revisionID,
                    clusterId: clusterID,
                    ordinal: intervalOrdinal,
                    source: interval.source,
                    startMs: interval.startMs,
                    endMs: interval.endMs
                )
                try row.insert(db)
                intervalOrdinal += 1
            }
        }
    }

    private static func normalizedSpeakerName(_ rawName: String, callID: Int64) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.count <= 128,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw CallRepositoryError.invalidSpeakerCorrection(callID)
        }
        return name
    }

    private static func mergedSpeakerIntervals(
        _ intervals: [CallSpeakerIntervalDraft]
    ) -> [CallSpeakerIntervalDraft] {
        let sorted = intervals
            .filter { $0.startMs < $0.endMs }
            .sorted {
                ($0.source.rawValue, $0.startMs, $0.endMs)
                    < ($1.source.rawValue, $1.startMs, $1.endMs)
            }
        var merged: [CallSpeakerIntervalDraft] = []
        for interval in sorted {
            if let previous = merged.last,
               previous.source == interval.source,
               interval.startMs <= previous.endMs {
                merged[merged.count - 1] = CallSpeakerIntervalDraft(
                    source: previous.source,
                    startMs: previous.startMs,
                    endMs: max(previous.endMs, interval.endMs)
                )
            } else {
                merged.append(interval)
            }
        }
        return merged
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
                      AND COALESCE(c.degradationReason, '') NOT LIKE 'automatic_reject%'
                      AND NOT EXISTS (
                          SELECT 1 FROM call_context x
                          WHERE x.callId = c.id AND x.disposition = 'rejected'
                      )
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
                          AND COALESCE(c.degradationReason, '') NOT LIKE 'automatic_reject%'
                          AND NOT EXISTS (
                              SELECT 1 FROM call_context x
                              WHERE x.callId = c.id AND x.disposition = 'rejected'
                          )
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
                      AND bytes > 0
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

    /// Returns the next authoritative final transcript that has not yet gained
    /// a speaker projection. This is read-only: an absent optional model never
    /// claims or mutates work.
    func nextSpeakerDiarizationEvidence(
        excluding identities: Set<String> = []
    ) async throws -> CallSpeakerDiarizationEvidence? {
        try await database.pool.read { db in
            let candidates = try CallRow.fetchAll(
                db,
                sql: """
                    SELECT c.*
                    FROM calls c
                    JOIN call_transcript_revisions r ON r.id = c.preferredRevisionId
                    WHERE c.state = ?
                      AND c.preferredSpeakerRevisionId IS NULL
                      AND NOT EXISTS (
                          SELECT 1 FROM call_speaker_revisions sr
                          WHERE sr.callId = c.id AND sr.mediaGeneration = c.mediaGeneration
                      )
                      AND r.callId = c.id
                      AND r.mediaGeneration = c.mediaGeneration
                      AND r.kind = ?
                      AND r.state = ?
                    ORDER BY c.updatedAtMs, c.id
                    LIMIT 100
                    """,
                arguments: [
                    CallLifecycleState.ready.rawValue,
                    CallTranscriptRevisionKind.final.rawValue,
                    CallTranscriptRevisionState.ready.rawValue,
                ]
            )
            for call in candidates {
                guard let callID = call.id,
                      let transcriptID = call.preferredRevisionId,
                      let transcript = try CallTranscriptRevisionRow.fetchOne(db, key: transcriptID)
                else { continue }
                let identity = "\(callID):\(call.mediaGeneration):\(transcriptID)"
                guard !identities.contains(identity) else { continue }
                let segments = try CallTranscriptSegmentRow.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM call_transcript_segments
                        WHERE revisionId = ? ORDER BY ordinal, id
                        """,
                    arguments: [transcriptID]
                )
                let chunks = try CallAudioChunkRow.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM call_audio_chunks
                        WHERE callId = ? AND mediaGeneration = ?
                          AND finalized = 1 AND bytes > 0
                        ORDER BY source, startMs, epoch, sequence, id
                        """,
                    arguments: [callID, call.mediaGeneration]
                )
                return CallSpeakerDiarizationEvidence(
                    call: call,
                    transcriptRevision: transcript,
                    transcriptSegments: segments,
                    chunks: chunks
                )
            }
            return nil
        }
    }

    /// Claims speaker processing durably before the helper starts. A failed or
    /// interrupted helper therefore becomes inspectable state instead of an
    /// endless in-memory "processing" loop.
    func beginInitialSpeakerRevision(
        callID: Int64,
        mediaGeneration: Int,
        expectedTranscriptRevisionID: Int64,
        engine: String,
        modelRevision: String,
        nowMs: Int64
    ) async throws -> CallSpeakerRevisionRow {
        try await database.pool.write { db in
            guard let call = try CallRow.fetchOne(db, key: callID) else {
                throw CallRepositoryError.callNotFound(callID)
            }
            guard call.state == .ready,
                  call.mediaGeneration == mediaGeneration,
                  call.preferredRevisionId == expectedTranscriptRevisionID,
                  call.preferredSpeakerRevisionId == nil,
                  let transcript = try CallTranscriptRevisionRow.fetchOne(
                    db,
                    key: expectedTranscriptRevisionID
                  ),
                  transcript.callId == callID,
                  transcript.mediaGeneration == mediaGeneration,
                  transcript.kind == .final,
                  transcript.state == .ready else {
                throw CallRepositoryError.invalidMediaMutation(callID)
            }
            guard try CallSpeakerRevisionRow
                .filter(Column("callId") == callID && Column("mediaGeneration") == mediaGeneration)
                .fetchCount(db) == 0 else {
                throw CallRepositoryError.invalidMediaMutation(callID)
            }
            var revision = CallSpeakerRevisionRow(
                id: nil,
                callId: callID,
                mediaGeneration: mediaGeneration,
                previousRevisionId: nil,
                state: .writing,
                engine: engine,
                modelRevision: modelRevision,
                createdAtMs: nowMs
            )
            try revision.insert(db)
            return revision
        }
    }

    /// Commits timed clusters into an existing writing revision and promotes
    /// it only if the call still points at the same final transcript and media.
    func completeInitialSpeakerRevision(
        revisionID: Int64,
        callID: Int64,
        mediaGeneration: Int,
        expectedTranscriptRevisionID: Int64,
        clusters: [CallSpeakerClusterDraft],
        nowMs: Int64
    ) async throws -> CallSpeakerRevisionRow {
        try await database.pool.write { db in
            guard let call = try CallRow.fetchOne(db, key: callID),
                  var revision = try CallSpeakerRevisionRow.fetchOne(db, key: revisionID),
                  revision.callId == callID,
                  revision.mediaGeneration == mediaGeneration,
                  revision.state == .writing,
                  call.state == .ready,
                  call.mediaGeneration == mediaGeneration,
                  call.preferredRevisionId == expectedTranscriptRevisionID,
                  call.preferredSpeakerRevisionId == nil else {
                throw CallRepositoryError.invalidMediaMutation(callID)
            }
            try Self.insertSpeakerClusters(
                revisionID: revisionID,
                callID: callID,
                clusters: clusters,
                db: db
            )
            revision.state = .ready
            try revision.update(db)
            guard let revisionID = revision.id else {
                throw CallRepositoryError.speakerRevisionMissing(callID)
            }
            try db.execute(
                sql: """
                    UPDATE calls
                    SET preferredSpeakerRevisionId = ?, updatedAtMs = MAX(updatedAtMs, ?)
                    WHERE id = ? AND state = ? AND mediaGeneration = ?
                      AND preferredRevisionId = ? AND preferredSpeakerRevisionId IS NULL
                    """,
                arguments: [
                    revisionID,
                    nowMs,
                    callID,
                    CallLifecycleState.ready.rawValue,
                    mediaGeneration,
                    expectedTranscriptRevisionID,
                ]
            )
            guard db.changesCount == 1 else {
                throw CallRepositoryError.invalidMediaMutation(callID)
            }
            try Self.enqueueProcessingReadyAutomationIfComplete(
                callID: callID,
                occurredAtMs: nowMs,
                db: db
            )
            return revision
        }
    }

    func failInitialSpeakerRevision(revisionID: Int64) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE call_speaker_revisions SET state = ? WHERE id = ? AND state = ?",
                arguments: [
                    CallSpeakerRevisionState.failed.rawValue,
                    revisionID,
                    CallSpeakerRevisionState.writing.rawValue,
                ]
            )
        }
    }

    func cancelInitialSpeakerRevision(revisionID: Int64) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM call_speaker_revisions WHERE id = ? AND state = ?",
                arguments: [revisionID, CallSpeakerRevisionState.writing.rawValue]
            )
        }
    }

    func retrySpeakerDiarization(callID: Int64) async throws {
        try await database.pool.write { db in
            guard let call = try CallRow.fetchOne(db, key: callID),
                  call.preferredSpeakerRevisionId == nil else {
                throw CallRepositoryError.invalidMediaMutation(callID)
            }
            try db.execute(
                sql: """
                    DELETE FROM call_speaker_revisions
                    WHERE callId = ? AND mediaGeneration = ? AND state = ?
                    """,
                arguments: [
                    callID,
                    call.mediaGeneration,
                    CallSpeakerRevisionState.failed.rawValue,
                ]
            )
        }
    }

    @discardableResult
    func failTranscriptJob(
        jobID: Int64,
        errorCode: String,
        retryable: Bool,
        nowMs: Int64
    ) async throws -> CallTranscriptJobState {
        try await database.pool.write { db in
            guard let job = try CallTranscriptJobRow.fetchOne(db, key: jobID) else {
                throw CallRepositoryError.transcriptJobNotFound(jobID)
            }
            guard job.state == .running else { return job.state }
            let maintenanceCancellation = errorCode == "helper_cancelled"
            let shouldRetry = retryable
                && (maintenanceCancellation || job.attempts < Self.maximumAutomaticTranscriptAttempts)
            let nextState: CallTranscriptJobState = shouldRetry ? .pending : .failed
            try db.execute(
                sql: """
                    UPDATE call_transcript_jobs
                    SET state = ?, errorCode = ?, attempts = ?, updatedAtMs = ?
                    WHERE id = ? AND state = ?
                    """,
                arguments: [
                    nextState.rawValue,
                    errorCode,
                    maintenanceCancellation ? max(0, job.attempts - 1) : job.attempts,
                    nowMs,
                    jobID,
                    CallTranscriptJobState.running.rawValue,
                ]
            )
            if let bookmarkID = job.bookmarkId {
                let bookmarkState: CallBookmarkState = shouldRetry ? .pending : .failed
                try db.execute(
                    sql: "UPDATE call_bookmarks SET state = ? WHERE id = ?",
                    arguments: [bookmarkState.rawValue, bookmarkID]
                )
            } else if !shouldRetry {
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
                try Self.enqueueTranscriptFailedAutomation(
                    job: job, jobID: jobID, errorCode: errorCode, occurredAtMs: nowMs, db: db)
            }
            try Self.admitDeferredCheckpoints(db: db, nowMs: nowMs)
            return nextState
        }
    }

    static let maximumAutomaticTranscriptAttempts = 3

    func recordSourceGap(
        callID: Int64,
        mediaGeneration: Int,
        source: CallAudioSource,
        startMs: Int64,
        endMs: Int64,
        reason: String,
        nowMs: Int64
    ) async throws {
        guard endMs > startMs else { return }
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO call_source_gaps (
                        callId, mediaGeneration, source, startMs, endMs, reason, createdAtMs
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    callID, mediaGeneration, source.rawValue,
                    startMs, endMs, reason, nowMs,
                ]
            )
        }
    }

    func markCallInterrupted(
        callID: Int64,
        endedAtMs: Int64,
        reason: String,
        nowMs: Int64
    ) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE calls
                    SET state = ?, interrupted = 1, endTs = MAX(startTs, ?),
                        degradationReason = ?, updatedAtMs = ?
                    WHERE id = ? AND state IN ('recording', 'finalizing')
                    """,
                arguments: [
                    CallLifecycleState.interrupted.rawValue,
                    endedAtMs,
                    reason,
                    nowMs,
                    callID,
                ]
            )
            let interrupted = db.changesCount > 0
            if interrupted, reason.hasPrefix("automatic_reject") {
                // "Not a call" is a durable privacy/erase intent, not merely a terminal label.
                // Persist it in the same transaction as the interrupted transition so a crash can
                // never route the rejected envelope into recovered transcription or automation.
                try db.execute(
                    sql: """
                        INSERT INTO call_context(
                            callId, captureOwner, disposition, detectorFingerprintHash,
                            sourceAppBundleID, sourceAppName, trustedOriginHost, title,
                            participantsJSON, createdAtMs, updatedAtMs
                        ) VALUES (?, 'automatic', 'rejected', NULL, NULL, NULL, NULL, NULL, '[]', ?, ?)
                        ON CONFLICT(callId) DO UPDATE SET
                            captureOwner = 'automatic',
                            disposition = 'rejected',
                            updatedAtMs = excluded.updatedAtMs
                        """,
                    arguments: [callID, nowMs, nowMs]
                )
            }
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
                try db.execute(
                    sql: """
                        DELETE FROM embed_queue
                        WHERE kind = 2 AND row_id IN (
                            SELECT id FROM call_transcript_revisions
                            WHERE callId = ? AND id != ?
                        )
                        """,
                    arguments: [job.callId, revisionID]
                )
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
                try Self.enqueueTranscriptReadyAutomation(
                    call: call, job: job, revisionID: revisionID, degraded: degraded,
                    occurredAtMs: nowMs, db: db)
                try Self.enqueueProcessingReadyAutomationIfComplete(
                    callID: job.callId,
                    occurredAtMs: nowMs,
                    db: db
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
                try db.execute(
                    sql: """
                        DELETE FROM embed_queue
                        WHERE kind = 2 AND row_id IN (
                            SELECT id FROM call_transcript_revisions
                            WHERE callId = ? AND id != ?
                        )
                        """,
                    arguments: [job.callId, preferredID]
                )
                call.preferredRevisionId = preferredID
                call.updatedAtMs = nowMs
                try call.update(db)
                try db.execute(
                    sql: "INSERT OR REPLACE INTO embed_queue(row_id, kind, ts, attempts) VALUES (?, 2, ?, 0)",
                    arguments: [preferredID, call.startTs]
                )
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
}
