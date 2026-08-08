import Foundation
import GRDB

struct PruneReport: Sendable {
    var framesDeleted = 0
    var audioDeleted = 0
    var callsDeleted = 0
    var callBytesDeleted: Int64 = 0
    var orphansDeleted = 0
}

enum CapturedMediaKind: Int, Sendable, Equatable {
    case frame = 0
    case audio = 1
}

struct AutomaticRetentionVictim: Sendable, Equatable {
    let kind: CapturedMediaKind
    let id: Int64
    let ts: Int64
    let relativePath: String
    let bytes: Int64
}

struct AutomaticRetentionRunReport: Sendable, Equatable {
    var victims: [AutomaticRetentionVictim] = []
    var callErasures: [CallEraseReport] = []
    var framesDeleted: Int { victims.count { $0.kind == .frame } }
    var audioDeleted: Int { victims.count { $0.kind == .audio } }
    var callsDeleted: Int { callErasures.count }
    var callBytesDeleted: Int64 {
        callErasures.reduce(0) { partial, erasure in
            let next = partial.addingReportingOverflow(erasure.bytesDeleted)
            return next.overflow ? Int64.max : next.partialValue
        }
    }
    var bytesCommitted: Int64 {
        let captured = victims.reduce(Int64(0)) { partial, victim in
            let next = partial.addingReportingOverflow(victim.bytes)
            return next.overflow ? Int64.max : next.partialValue
        }
        let total = captured.addingReportingOverflow(callBytesDeleted)
        return total.overflow ? Int64.max : total.partialValue
    }
}

struct AutomaticRetentionFailureLedger: Sendable, Equatable {
    let committedVictims: [AutomaticRetentionVictim]
    let physicallyDeletedPaths: [String]
    let failedPath: String
}

enum AutomaticRetentionError: Error, Sendable, Equatable {
    case invalidCandidateState
    case postCommitFileDeletionFailed(AutomaticRetentionFailureLedger)
}

/// Automatic Keep Media retention is a separate, permit-gated operation from
/// manual privacy deletion and vector hygiene. A permit lease spans the whole
/// GRDB write transaction, so Forever can wait for one already-authorized
/// commit and prevent every later batch.
actor RetentionManager {
    private struct CommittedBatch: Sendable {
        let victims: [AutomaticRetentionVictim]
    }

    private enum AutomaticRetentionStep: Sendable {
        case captured(CommittedBatch)
        case call(Int64)
        case done
    }

    private let db: ZBSEyeDatabase
    private let storage: StorageManager
    private let callDeletion: CallEvidenceDeletionService?
    private let maintenanceGate = DatabaseWriterMaintenanceGate()
    private let automaticBatchSize: Int
    private var automaticFailure: AutomaticRetentionFailureLedger?

    init(
        db: ZBSEyeDatabase,
        storage: StorageManager,
        callDeletion: CallEvidenceDeletionService? = nil,
        automaticBatchSize: Int = 500
    ) {
        precondition(automaticBatchSize > 0)
        self.db = db
        self.storage = storage
        self.callDeletion = callDeletion
        self.automaticBatchSize = automaticBatchSize
    }

    func pruneAutomatically(
        permit: AutomaticRetentionPermit,
        admission: AutomaticRetentionAdmission
    ) async throws -> AutomaticRetentionRunReport {
        if let automaticFailure {
            throw AutomaticRetentionError.postCommitFileDeletionFailed(automaticFailure)
        }
        guard permit.maxBytes > 0,
              permit.policy.maxCapturedMediaBytes == permit.maxBytes else {
            throw AutomaticRetentionError.invalidCandidateState
        }
        guard maintenanceGate.beginOperation() else {
            throw DatabaseWriterMaintenanceError.suspendedForRelocation
        }
        defer { maintenanceGate.finishOperation() }

        var report = AutomaticRetentionRunReport()
        if let callDeletion {
            report.callErasures.append(contentsOf: try await callDeletion.resumePendingErases(
                nowMs: Int64(Date().timeIntervalSince1970 * 1_000)
            ))
        }
        var physicallyDeletedPaths: [String] = []
        while !Task.isCancelled && !maintenanceGate.snapshot().suspended {
            try checkOperationContinuation()
            // This synchronous lease deliberately contains the complete GRDB
            // transaction, including COMMIT on return from pool.write.
            let step = try admission.withLease(permit) {
                try db.pool.write { database in
                    try Self.nextAutomaticStep(
                        in: database,
                        storage: storage,
                        maxBytes: permit.maxBytes,
                        batchSize: automaticBatchSize
                    )
                }
            }
            switch step {
            case .done:
                break
            case .call(let callID):
                guard let callDeletion else {
                    throw AutomaticRetentionError.invalidCandidateState
                }
                let erasure = try await admission.withAsyncLease(permit) {
                    try await callDeletion.erase(
                        callID: callID,
                        nowMs: Int64(Date().timeIntervalSince1970 * 1_000)
                    )
                }
                report.callErasures.append(erasure)
                continue
            case .captured(let batch):
                report.victims.append(contentsOf: batch.victims)
                for victim in batch.victims {
                    do {
                        try storage.deleteFile(relativePath: victim.relativePath)
                        physicallyDeletedPaths.append(victim.relativePath)
                    } catch {
                        // Rows and all dependent indexes already committed. Stop
                        // immediately and expose the exact reconcilable orphan.
                        let ledger = AutomaticRetentionFailureLedger(
                            committedVictims: report.victims,
                            physicallyDeletedPaths: physicallyDeletedPaths,
                            failedPath: victim.relativePath
                        )
                        admission.revoke(to: permit.revision &+ 1)
                        automaticFailure = ledger
                        throw AutomaticRetentionError.postCommitFileDeletionFailed(ledger)
                    }
                }
                continue
            }
            break
        }
        try checkOperationContinuation()
        if !report.victims.isEmpty || !report.callErasures.isEmpty {
            try await checkpoint()
        }
        return report
    }

    func suspendAndDrainForRelocation() async -> DatabaseWriterDrainAcknowledgement {
        await maintenanceGate.suspendAndDrain()
    }

    func resumeAfterRelocation() {
        maintenanceGate.resume()
    }

    /// Safe database-only hygiene. It is intentionally separate from
    /// scheduled retention and never walks or deletes physical media.
    func sweepVectorOrphans() async throws {
        guard maintenanceGate.beginOperation() else {
            throw DatabaseWriterMaintenanceError.suspendedForRelocation
        }
        defer { maintenanceGate.finishOperation() }
        try await db.pool.write { database in
            try database.execute(
                sql: "DELETE FROM vec_screen WHERE capture_id NOT IN (SELECT id FROM screen_captures)"
            )
            try database.execute(
                sql: "DELETE FROM vec_transcripts WHERE transcription_id NOT IN (SELECT id FROM transcriptions)"
            )
            try database.execute(
                sql: "DELETE FROM vec_call_transcripts WHERE revision_id NOT IN (SELECT id FROM call_transcript_revisions)"
            )
            try database.execute(
                sql: "DELETE FROM embed_queue WHERE kind = 2 AND row_id NOT IN (SELECT id FROM call_transcript_revisions)"
            )
        }
    }

    /// Manual privacy deletion remains independent of automatic admission.
    func deleteRange(fromMs: Int64, toMs: Int64) async throws -> PruneReport {
        guard maintenanceGate.beginOperation() else {
            throw DatabaseWriterMaintenanceError.suspendedForRelocation
        }
        defer { maintenanceGate.finishOperation() }
        var report = PruneReport()
        let isFullDeletion = fromMs == 0 && toMs == Int64.max
        if isFullDeletion, let callDeletion {
            try await callDeletion.requireNoActiveCall()
        }
        if isFullDeletion, let callDeletion {
            for erasure in try await callDeletion.resumePendingErases(
                nowMs: Int64(Date().timeIntervalSince1970 * 1_000)
            ) {
                add(erasure, to: &report)
            }
            try checkOperationContinuation()
        } else if let callDeletion {
            let redactions = try await callDeletion.redactIntersectingRange(
                fromMs: fromMs,
                toMs: toMs,
                nowMs: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            for redaction in redactions {
                let next = report.callBytesDeleted.addingReportingOverflow(redaction.bytesRemoved)
                report.callBytesDeleted = next.overflow ? Int64.max : next.partialValue
            }
            try checkOperationContinuation()
        }
        while !Task.isCancelled && !maintenanceGate.snapshot().suspended {
            let (count, paths): (Int, [String]) = try await db.pool.write { database in
                let rows = try ScreenCaptureRow
                    .filter(Column("ts") >= fromMs && Column("ts") <= toMs)
                    .order(Column("ts"), Column("id"))
                    .limit(500)
                    .fetchAll(database)
                guard !rows.isEmpty else { return (0, []) }
                let ids = rows.compactMap(\.id)
                try ScreenCaptureRow.filter(ids.contains(Column("id"))).deleteAll(database)
                try Self.deleteVectors(database, captureIds: ids)
                let endExclusive = toMs == Int64.max ? Int64.max : toMs + 1
                try ActivityDaySummaryRepository.deleteOverlapping(
                    in: database,
                    fromMs: fromMs,
                    toMs: endExclusive
                )
                return (rows.count, rows.compactMap(\.relativePath).filter { $0 != "imported" })
            }
            guard count > 0 else { break }
            // Manual privacy deletion keeps the historical best-effort file
            // cleanup semantics: one already-missing file must not abort the
            // rest of the requested range after its DB rows committed.
            for path in paths { try? storage.deleteFile(relativePath: path) }
            report.framesDeleted += count
        }
        try checkOperationContinuation()
        while !Task.isCancelled && !maintenanceGate.snapshot().suspended {
            let (count, paths): (Int, [String]) = try await db.pool.write { database in
                let rows = try AudioCaptureRow
                    .filter(Column("ts") >= fromMs && Column("ts") <= toMs)
                    .order(Column("ts"), Column("id"))
                    .limit(500)
                    .fetchAll(database)
                guard !rows.isEmpty else { return (0, []) }
                let ids = rows.compactMap(\.id)
                try Self.deleteTranscriptVectors(database, audioIds: ids)
                try AudioCaptureRow.filter(ids.contains(Column("id"))).deleteAll(database)
                return (rows.count, rows.map(\.relativePath).filter { $0 != "imported" })
            }
            guard count > 0 else { break }
            for path in paths { try? storage.deleteFile(relativePath: path) }
            report.audioDeleted += count
        }
        try checkOperationContinuation()
        if isFullDeletion, let callDeletion {
            while !Task.isCancelled && !maintenanceGate.snapshot().suspended {
                guard let erasure = try await callDeletion.eraseOldest(
                    nowMs: Int64(Date().timeIntervalSince1970 * 1_000)
                ) else { break }
                add(erasure, to: &report)
            }
            try checkOperationContinuation()
        }
        // Update uncertainty metadata only after every requested history
        // writer has completed. If deletion is cancelled midway, retaining a
        // wider gap is conservative; subtracting first could falsely claim
        // complete coverage for source rows that were never deleted.
        let coverageEndExclusive = toMs == Int64.max ? Int64.max : toMs + 1
        try await db.pool.write { database in
            try CaptureCoverageMaintenance.subtractDeletedRange(
                in: database,
                fromMs: fromMs,
                toMs: coverageEndExclusive
            )
            if isFullDeletion {
                try ActivityDaySummaryRepository.deleteAll(in: database)
            } else {
                // The terminal bump closes snapshots opened between batches
                // and invalidates an already-stale cache even when the source
                // loop found no remaining screen row in this range.
                try ActivityDaySummaryRepository.deleteOverlapping(
                    in: database,
                    fromMs: fromMs,
                    toMs: coverageEndExclusive
                )
            }
        }
        try? await checkpoint()
        try checkOperationContinuation()
        if isFullDeletion {
            try? await db.pool.writeWithoutTransaction { database in
                try database.execute(sql: "VACUUM")
            }
        }
        return report
    }

    private func add(_ erasure: CallEraseReport, to report: inout PruneReport) {
        report.callsDeleted += 1
        let next = report.callBytesDeleted.addingReportingOverflow(erasure.bytesDeleted)
        report.callBytesDeleted = next.overflow ? Int64.max : next.partialValue
    }

    private nonisolated static func nextAutomaticStep(
        in database: Database,
        storage: StorageManager,
        maxBytes: Int64,
        batchSize: Int
    ) throws -> AutomaticRetentionStep {
        let invalidCount = try Int.fetchOne(database, sql: """
            SELECT COUNT(*) FROM (
                SELECT relativePath, bytes FROM screen_captures
                WHERE relativePath IS NOT NULL AND relativePath <> 'imported'
                UNION ALL
                SELECT relativePath, bytes FROM audio_captures
                WHERE relativePath <> 'imported'
                UNION ALL
                SELECT relativePath, bytes FROM call_audio_chunks
            ) WHERE bytes IS NULL OR bytes <= 0
            """) ?? 0
        guard invalidCount == 0 else {
            throw AutomaticRetentionError.invalidCandidateState
        }
        let duplicateCount = try Int.fetchOne(database, sql: """
            SELECT COUNT(*) FROM (
                SELECT relativePath FROM (
                    SELECT relativePath FROM screen_captures
                    WHERE relativePath IS NOT NULL AND relativePath <> 'imported'
                    UNION ALL
                    SELECT relativePath FROM audio_captures
                    WHERE relativePath <> 'imported'
                    UNION ALL
                    SELECT relativePath FROM call_audio_chunks
                ) GROUP BY relativePath HAVING COUNT(*) > 1
            )
            """) ?? 0
        guard duplicateCount == 0 else {
            throw AutomaticRetentionError.invalidCandidateState
        }

        let total = try Int64.fetchOne(database, sql: """
            SELECT COALESCE(SUM(bytes), 0) FROM (
                SELECT bytes FROM screen_captures
                WHERE relativePath IS NOT NULL AND relativePath <> 'imported'
                UNION ALL
                SELECT bytes FROM audio_captures
                WHERE relativePath <> 'imported'
                UNION ALL
                SELECT bytes FROM call_audio_chunks
            )
            """) ?? 0
        guard total > maxBytes else { return .done }
        let overage = total - maxBytes

        let rows = try Row.fetchAll(database, sql: """
            SELECT id, ts, kind, relativePath, bytes FROM (
                SELECT id, ts, 0 AS kind, relativePath, bytes FROM screen_captures
                WHERE relativePath IS NOT NULL AND relativePath <> 'imported'
                UNION ALL
                SELECT id, ts, 1 AS kind, relativePath, bytes FROM audio_captures
                WHERE relativePath <> 'imported'
                UNION ALL
                SELECT calls.id AS id,
                       calls.startTs AS ts,
                       2 AS kind,
                       NULL AS relativePath,
                       SUM(call_audio_chunks.bytes) AS bytes
                FROM calls
                JOIN call_audio_chunks ON call_audio_chunks.callId = calls.id
                WHERE calls.state != 'recording'
                  AND (calls.degradationReason IS NULL OR calls.degradationReason != 'erase_pending')
                GROUP BY calls.id
                HAVING SUM(call_audio_chunks.bytes) > 0
            )
            ORDER BY ts ASC, kind ASC, id ASC
            LIMIT ?
            """, arguments: [batchSize])
        guard !rows.isEmpty else { return .done }

        var victims: [AutomaticRetentionVictim] = []
        var selectedBytes: Int64 = 0
        for row in rows {
            let kindRaw: Int = row["kind"]
            if kindRaw == 2 {
                if victims.isEmpty { return .call(row["id"]) }
                break
            }
            let path: String? = row["relativePath"]
            let bytes: Int64 = row["bytes"]
            guard let kind = CapturedMediaKind(rawValue: kindRaw),
                  let path,
                  CapturedMediaReconciler.isSafeRelativePath(path),
                  bytes > 0 else {
                throw AutomaticRetentionError.invalidCandidateState
            }
            victims.append(AutomaticRetentionVictim(
                kind: kind,
                id: row["id"],
                ts: row["ts"],
                relativePath: path,
                bytes: bytes
            ))
            let next = selectedBytes.addingReportingOverflow(bytes)
            guard !next.overflow else {
                throw AutomaticRetentionError.invalidCandidateState
            }
            selectedBytes = next.partialValue
            if selectedBytes >= overage { break }
        }
        guard !victims.isEmpty else { return .done }

        // Revalidate every selected file before deleting any database row.
        // This remains inside both the permit lease and GRDB transaction.
        do {
            for victim in victims {
                try storage.validateCapturedMediaFile(
                    relativePath: victim.relativePath,
                    expectedBytes: victim.bytes
                )
            }
        } catch {
            throw AutomaticRetentionError.invalidCandidateState
        }

        let frameIDs = victims.filter { $0.kind == .frame }.map(\.id)
        let audioIDs = victims.filter { $0.kind == .audio }.map(\.id)
        try deleteTranscriptVectors(database, audioIds: audioIDs)
        if !frameIDs.isEmpty {
            try database.execute(
                sql: "DELETE FROM screen_captures WHERE id IN (\(idList(frameIDs)))"
            )
            try deleteVectors(database, captureIds: frameIDs)
            try ActivityDaySummaryRepository.deleteSummariesContainingSources(
                in: database,
                sourceTimestampsMs: victims.filter { $0.kind == .frame }.map(\.ts)
            )
        }
        if !audioIDs.isEmpty {
            try database.execute(
                sql: "DELETE FROM audio_captures WHERE id IN (\(idList(audioIDs)))"
            )
        }
        return .captured(CommittedBatch(victims: victims))
    }

    private nonisolated static func idList(_ ids: [Int64]) -> String {
        ids.map(String.init).joined(separator: ",")
    }

    private nonisolated static func deleteVectors(
        _ database: Database,
        captureIds: [Int64]
    ) throws {
        guard !captureIds.isEmpty else { return }
        try database.execute(
            sql: "DELETE FROM vec_screen WHERE capture_id IN (\(idList(captureIds)))"
        )
    }

    private nonisolated static func deleteTranscriptVectors(
        _ database: Database,
        audioIds: [Int64]
    ) throws {
        guard !audioIds.isEmpty else { return }
        let transcriptionIDs = try Int64.fetchAll(database, sql: """
            SELECT id FROM transcriptions WHERE audioId IN (\(idList(audioIds)))
            """)
        guard !transcriptionIDs.isEmpty else { return }
        try database.execute(sql: """
            DELETE FROM vec_transcripts
            WHERE transcription_id IN (\(idList(transcriptionIDs)))
            """)
    }

    private func checkOperationContinuation() throws {
        try Task.checkCancellation()
        guard !maintenanceGate.snapshot().suspended else {
            throw DatabaseWriterMaintenanceError.suspendedForRelocation
        }
    }

    private func checkpoint() async throws {
        try await db.pool.write { database in
            try database.execute(sql: "INSERT INTO text_fts(text_fts) VALUES('optimize')")
            try database.execute(sql: "INSERT INTO transcription_fts(transcription_fts) VALUES('optimize')")
            try database.execute(sql: "INSERT INTO call_transcript_fts(call_transcript_fts) VALUES('optimize')")
        }
        try? await db.pool.writeWithoutTransaction { database in
            try database.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
}
