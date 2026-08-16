import CryptoKit
import XCTest
import GRDB

final class CallRecoveryTests: XCTestCase {
    func testRecoveryDoesNotFreezePreparingBookmarkWithoutIngressCoverageMapping() async throws {
        let store = try CallRecoveryTestStore()
        let repository = CallRepository(database: store.database)
        let call = try await repository.createCall(startedAtMs: 1_000, idempotencyKey: "call-preparing")
        let callID = try XCTUnwrap(call.id)
        let bookmark = try await repository.createBookmark(
            callID: callID,
            idempotencyKey: "bookmark-preparing",
            acceptedAtMs: 2_000,
            meIngressTarget: 12,
            systemIngressTarget: nil,
            logicalStartMs: 1_000,
            logicalEndMs: 2_000,
            contextStartMs: 1_000
        )

        let recovery = CallRecoveryService(repository: repository, mediaRoot: store.mediaRoot)
        let report = try await recovery.recover(nowMs: 3_000)

        let recovered = try await store.database.pool.read { db in
            try XCTUnwrap(CallTranscriptJobRow.fetchOne(db, key: bookmark.job.id))
        }
        XCTAssertEqual(recovered.state, .preparing)
        XCTAssertFalse(recovered.coverageFrozen)
        XCTAssertNil(recovered.meEndSample)
        XCTAssertEqual(report.jobsReset, 0)
    }

    func testUnreadableChunkBecomesDurableGapWithoutBlockingOtherRecovery() async throws {
        let store = try CallRecoveryTestStore()
        let repository = CallRepository(database: store.database)
        let call = try await repository.createCall(startedAtMs: 1_000, idempotencyKey: "unreadable")
        let callID = try XCTUnwrap(call.id)
        let span = try await repository.recordSourceSpan(
            CallSourceSpanDraft(
                callId: callID,
                source: .me,
                epoch: 0,
                sampleRate: 16_000,
                startedAtMs: 1_000,
                startSample: 0,
                startHostTimeNs: 0,
                availability: .available
            )
        )
        let spanID = try XCTUnwrap(span.id)
        let unreadablePath = "calls/\(callID)/me/unreadable.pcm"
        try FileManager.default.createDirectory(
            at: store.url(for: unreadablePath),
            withIntermediateDirectories: true
        )
        let goodPath = "calls/\(callID)/me/good.pcm"
        try store.write(Data([1, 2, 3, 4]), relativePath: goodPath)
        for (sequence, path) in [(0, unreadablePath), (1, goodPath)] {
            _ = try await repository.recordAudioChunk(
                CallAudioChunkDraft(
                    callId: callID,
                    sourceSpanId: spanID,
                    source: .me,
                    epoch: 0,
                    sequence: sequence,
                    mediaGeneration: 0,
                    startSample: Int64(sequence * 2),
                    endSample: Int64(sequence * 2 + 2),
                    startMs: 1_000 + Int64(sequence * 1_000),
                    endMs: 2_000 + Int64(sequence * 1_000),
                    relativePath: path,
                    bytes: 4,
                    sha256: nil,
                    finalized: false
                )
            )
        }

        let report = try await CallRecoveryService(
            repository: repository,
            mediaRoot: store.mediaRoot
        ).recover(nowMs: 4_000)

        let snapshot = try await store.database.pool.read { db in
            (
                chunks: try CallAudioChunkRow
                    .filter(Column("callId") == callID)
                    .fetchAll(db),
                gaps: try CallSourceGapRow
                    .filter(Column("callId") == callID)
                    .fetchAll(db)
            )
        }
        XCTAssertEqual(report.chunksDiscarded, 1)
        XCTAssertEqual(report.chunksFinalized, 1)
        XCTAssertEqual(snapshot.chunks.map(\.relativePath), [goodPath])
        XCTAssertEqual(snapshot.gaps.map(\.reason), ["unreadable_recovered_chunk"])
    }

    func testRecoveryReappliesCheckpointAdmissionBudgetsAndKeepsFinalPriority() async throws {
        let store = try CallRecoveryTestStore()
        let repository = CallRepository(database: store.database)
        var callIDs: [Int64] = []

        for callIndex in 0..<2 {
            let start = Int64(callIndex * 100_000 + 1_000)
            let call = try await repository.createCall(
                startedAtMs: start,
                idempotencyKey: "budget-call-\(callIndex)"
            )
            let callID = try XCTUnwrap(call.id)
            callIDs.append(callID)
            for bookmarkIndex in 0..<40 {
                let accepted = start + Int64(bookmarkIndex + 1) * 1_000
                let bookmark = try await repository.createBookmark(
                    callID: callID,
                    idempotencyKey: "budget-bookmark-\(callIndex)-\(bookmarkIndex)",
                    acceptedAtMs: accepted,
                    meIngressTarget: Int64(bookmarkIndex + 1),
                    systemIngressTarget: nil,
                    logicalStartMs: bookmarkIndex == 0 ? start : accepted - 1_000,
                    logicalEndMs: accepted,
                    contextStartMs: max(start, accepted - 46_000)
                )
                try await store.database.pool.write { db in
                    try db.execute(
                        sql: "UPDATE call_transcript_jobs SET state = 'running', coverageFrozen = 1 WHERE id = ?",
                        arguments: [bookmark.job.id]
                    )
                }
            }
            _ = try await repository.endCall(
                callID: callID,
                idempotencyKey: "budget-end-\(callIndex)",
                endedAtMs: start + 41_000
            )
        }

        let recovery = CallRecoveryService(repository: repository, mediaRoot: store.mediaRoot)
        let report = try await recovery.recover(nowMs: 300_000)

        let counts = try await store.database.pool.read { db in
            (
                pending: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_jobs WHERE kind = 'checkpoint' AND state = 'pending'"
                ) ?? 0,
                deferred: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_jobs WHERE kind = 'checkpoint' AND state = 'deferred_capacity'"
                ) ?? 0,
                maxPendingPerCall: try Int.fetchOne(
                    db,
                    sql: """
                        SELECT MAX(n) FROM (
                            SELECT COUNT(*) AS n FROM call_transcript_jobs
                            WHERE kind = 'checkpoint' AND state = 'pending'
                            GROUP BY callId
                        )
                        """
                ) ?? 0,
                pendingFinals: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_jobs WHERE kind = 'final' AND state = 'pending'"
                ) ?? 0
            )
        }
        XCTAssertEqual(counts.pending, 64)
        XCTAssertEqual(counts.deferred, 16)
        XCTAssertEqual(counts.maxPendingPerCall, 32)
        XCTAssertEqual(counts.pendingFinals, callIDs.count)
        XCTAssertEqual(report.jobsReset, 80)
    }

    func testRecoveryTruncatesOnlyIncompleteSampleAndResetsInterruptedWorkIdempotently() async throws {
        let store = try CallRecoveryTestStore()
        let repository = CallRepository(database: store.database)
        let call = try await repository.createCall(startedAtMs: 1_000, idempotencyKey: "call")
        let callID = try XCTUnwrap(call.id)
        let span = try await repository.recordSourceSpan(
            CallSourceSpanDraft(
                callId: callID,
                source: .me,
                epoch: 0,
                sampleRate: 16_000,
                startedAtMs: 1_000,
                startSample: 0,
                startHostTimeNs: 100,
                availability: .available
            )
        )
        let spanID = try XCTUnwrap(span.id)

        let finalizedPath = "calls/\(callID)/me/0000.pcm"
        let trailingPath = "calls/\(callID)/me/0001.pcm"
        try store.write(Data([1, 2, 3, 4]), relativePath: finalizedPath)
        try store.write(Data([5, 6, 7, 8, 9]), relativePath: trailingPath)
        _ = try await repository.recordAudioChunk(
            CallAudioChunkDraft(
                callId: callID,
                sourceSpanId: spanID,
                source: .me,
                epoch: 0,
                sequence: 0,
                mediaGeneration: 0,
                startSample: 0,
                endSample: 2,
                startMs: 1_000,
                endMs: 2_000,
                relativePath: finalizedPath,
                bytes: 4,
                sha256: "fixture",
                finalized: true
            )
        )
        let trailing = try await repository.recordAudioChunk(
            CallAudioChunkDraft(
                callId: callID,
                sourceSpanId: spanID,
                source: .me,
                epoch: 0,
                sequence: 1,
                mediaGeneration: 0,
                startSample: 2,
                endSample: 5,
                startMs: 2_000,
                endMs: 2_000,
                relativePath: trailingPath,
                bytes: 5,
                sha256: nil,
                finalized: false
            )
        )
        let bookmark = try await repository.createBookmark(
            callID: callID,
            idempotencyKey: "bookmark",
            acceptedAtMs: 2_500,
            meIngressTarget: 10,
            systemIngressTarget: nil,
            logicalStartMs: 1_000,
            logicalEndMs: 2_500,
            contextStartMs: 1_000
        )
        try await store.database.pool.write { db in
            try db.execute(
                sql: "UPDATE call_transcript_jobs SET state = 'running' WHERE id = ?",
                arguments: [bookmark.job.id]
            )
        }

        let recovery = CallRecoveryService(repository: repository, mediaRoot: store.mediaRoot)
        let firstReport = try await recovery.recover(nowMs: 4_000)
        let secondReport = try await recovery.recover(nowMs: 5_000)

        let snapshot = try await store.database.pool.read { db in
            (
                call: try XCTUnwrap(CallRow.fetchOne(db, key: callID)),
                trailing: try XCTUnwrap(CallAudioChunkRow.fetchOne(db, key: trailing.id)),
                span: try XCTUnwrap(CallSourceSpanRow.fetchOne(db, key: spanID)),
                checkpointState: try String.fetchOne(
                    db,
                    sql: "SELECT state FROM call_transcript_jobs WHERE id = ?",
                    arguments: [bookmark.job.id]
                ),
                finalJobs: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_jobs WHERE callId = ? AND kind = 'final'",
                    arguments: [callID]
                ) ?? 0
            )
        }
        XCTAssertEqual(snapshot.call.state, .interrupted)
        XCTAssertTrue(snapshot.call.interrupted)
        XCTAssertEqual(snapshot.call.endTs, 2_001)
        XCTAssertTrue(snapshot.trailing.finalized)
        XCTAssertEqual(snapshot.trailing.bytes, 4)
        XCTAssertEqual(snapshot.trailing.endSample, 4)
        XCTAssertEqual(snapshot.trailing.endMs, 2_001)
        XCTAssertEqual(snapshot.span.endedAtMs, 2_001)
        XCTAssertEqual(snapshot.span.endSample, 4)
        XCTAssertEqual(try Data(contentsOf: store.url(for: trailingPath)).count, 4)
        XCTAssertEqual(snapshot.checkpointState, CallTranscriptJobState.pending.rawValue)
        XCTAssertEqual(snapshot.finalJobs, 1)
        XCTAssertEqual(firstReport.callsInterrupted, 1)
        XCTAssertEqual(firstReport.jobsReset, 1)
        XCTAssertEqual(secondReport.callsInterrupted, 0)
    }

    func testRecoveryReplaysMutationJournalWithoutDeletingReferencedEvidence() async throws {
        let store = try CallRecoveryTestStore()
        let repository = CallRepository(database: store.database)

        let stagedCall = try await makeEndedCall(repository, key: "staged", start: 1_000)
        let stagedNew = "calls/\(stagedCall)/staged-new.pcm"
        try store.write(Data([1, 2]), relativePath: stagedNew)
        try await insertMutation(
            store.database,
            callID: stagedCall,
            state: .staged,
            fromGeneration: 0,
            toGeneration: 1,
            oldPaths: [],
            newPaths: [stagedNew]
        )

        let swappedCall = try await makeEndedCall(repository, key: "swapped", start: 3_000)
        let swappedOld = "calls/\(swappedCall)/old.pcm"
        let swappedNew = "calls/\(swappedCall)/new.pcm"
        try store.write(Data([3, 4]), relativePath: swappedOld)
        try store.write(Data([5, 6]), relativePath: swappedNew)
        try await installReferencedChunk(
            repository,
            database: store.database,
            callID: swappedCall,
            relativePath: swappedNew,
            generation: 1
        )
        try await insertMutation(
            store.database,
            callID: swappedCall,
            state: .referenceSwapped,
            fromGeneration: 0,
            toGeneration: 1,
            oldPaths: [swappedOld],
            newPaths: [swappedNew]
        )

        let blockedCall = try await makeEndedCall(repository, key: "blocked", start: 5_000)
        let stillReferencedOld = "calls/\(blockedCall)/still-current.pcm"
        try store.write(Data([7, 8]), relativePath: stillReferencedOld)
        try await installReferencedChunk(
            repository,
            database: store.database,
            callID: blockedCall,
            relativePath: stillReferencedOld,
            generation: 1
        )
        try await insertMutation(
            store.database,
            callID: blockedCall,
            state: .cleanupPending,
            fromGeneration: 0,
            toGeneration: 1,
            oldPaths: [stillReferencedOld],
            newPaths: []
        )

        let recovery = CallRecoveryService(repository: repository, mediaRoot: store.mediaRoot)
        let firstReport = try await recovery.recover(nowMs: 10_000)
        let secondReport = try await recovery.recover(nowMs: 11_000)

        let states = try await store.database.pool.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(
                db,
                sql: "SELECT callId, state FROM call_media_mutations"
            ).map { row in
                (row["callId"] as Int64, row["state"] as String)
            })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: stagedNew).path))
        XCTAssertEqual(states[stagedCall], CallMediaMutationState.rolledBack.rawValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: swappedOld).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: swappedNew).path))
        XCTAssertEqual(states[swappedCall], CallMediaMutationState.completed.rawValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: stillReferencedOld).path))
        XCTAssertEqual(states[blockedCall], CallMediaMutationState.cleanupPending.rawValue)
        XCTAssertEqual(firstReport.mutationsCompleted, 1)
        XCTAssertEqual(firstReport.mutationsRolledBack, 1)
        XCTAssertEqual(secondReport.mutationsCompleted, 0)
        XCTAssertEqual(secondReport.mutationsRolledBack, 0)
    }

    func testRecoveryErasesRejectedAutomaticCallsWithoutTranscriptOrWebhookWork() async throws {
        let store = try CallRecoveryTestStore()
        let repository = CallRepository(database: store.database)
        try await store.database.pool.write { db in
            var config = try XCTUnwrap(CallAutomationConfigRow.fetchOne(db, key: 1))
            config.enabled = true
            config.endpointURL = "http://127.0.0.1:9876/call-event"
            config.endpointFingerprint = "fixture-receiver"
            config.updatedAtMs = 1
            try config.update(db)
        }

        let committed = try await repository.createCall(
            startedAtMs: 1_000,
            idempotencyKey: "rejected-committed"
        )
        let committedID = try XCTUnwrap(committed.id)
        let committedPath = "calls/\(committedID)/me/committed.pcm"
        try store.write(Data([1, 2]), relativePath: committedPath)
        try await installReferencedChunk(
            repository,
            database: store.database,
            callID: committedID,
            relativePath: committedPath,
            generation: 0
        )
        try await repository.markCallInterrupted(
            callID: committedID,
            endedAtMs: 2_000,
            reason: "automatic_rejected",
            nowMs: 2_000
        )

        // Simulate a crash after AppEnvironment durably marked the privacy intent, but before the
        // coordinator's interrupted transition committed.
        let preCommit = try await repository.createCall(
            startedAtMs: 3_000,
            idempotencyKey: "rejected-before-commit"
        )
        let preCommitID = try XCTUnwrap(preCommit.id)
        let preCommitPath = "calls/\(preCommitID)/system/pre-commit.pcm"
        try store.write(Data([3, 4]), relativePath: preCommitPath)
        try await installReferencedChunk(
            repository,
            database: store.database,
            callID: preCommitID,
            relativePath: preCommitPath,
            generation: 0
        )
        try await repository.upsertCallContext(
            CallContextRow(
                callId: preCommitID,
                captureOwner: .automatic,
                disposition: .rejected,
                detectorFingerprintHash: nil,
                sourceAppBundleID: nil,
                sourceAppName: nil,
                trustedOriginHost: nil,
                title: nil,
                participantsJSON: "[]",
                createdAtMs: 3_500,
                updatedAtMs: 3_500
            )
        )

        let dispositions = try await store.database.pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT disposition FROM call_context
                    WHERE callId IN (?, ?)
                    ORDER BY callId
                    """,
                arguments: [committedID, preCommitID]
            )
        }
        XCTAssertEqual(dispositions, ["rejected", "rejected"])

        let report = try await CallRecoveryService(
            repository: repository,
            mediaRoot: store.mediaRoot
        ).recover(nowMs: 5_000)

        let remaining = try await store.database.pool.read { db in
            (
                calls: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM calls WHERE id IN (?, ?)",
                    arguments: [committedID, preCommitID]
                ) ?? -1,
                jobs: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_jobs WHERE callId IN (?, ?)",
                    arguments: [committedID, preCommitID]
                ) ?? -1,
                events: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_automation_outbox WHERE callId IN (?, ?)",
                    arguments: [committedID, preCommitID]
                ) ?? -1
            )
        }
        XCTAssertEqual(report.callsInterrupted, 1)
        XCTAssertEqual(report.finalJobsCreated, 0)
        XCTAssertEqual(report.mutationsCompleted, 2)
        XCTAssertEqual(remaining.calls, 0)
        XCTAssertEqual(remaining.jobs, 0)
        XCTAssertEqual(remaining.events, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: committedPath).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: preCommitPath).path))
    }

    func testRecoveryErasesReceiptAfterBothRuntimeDatabaseWritesFailed() async throws {
        let store = try CallRecoveryTestStore()
        let repository = CallRepository(database: store.database)
        let fingerprint = String(repeating: "b", count: 64)
        try await store.database.pool.write { db in
            var config = try XCTUnwrap(CallAutomationConfigRow.fetchOne(db, key: 1))
            config.enabled = true
            config.endpointURL = "http://127.0.0.1:9876/call-event"
            config.endpointFingerprint = "fixture-receiver"
            config.updatedAtMs = 1
            try config.update(db)
        }
        let call = try await repository.createCall(
            startedAtMs: 1_000,
            idempotencyKey: "automatic:\(fingerprint)"
        )
        let callID = try XCTUnwrap(call.id)
        let path = "calls/\(callID)/me/receipt-only.pcm"
        try store.write(Data([1, 2]), relativePath: path)
        try await installReferencedChunk(
            repository,
            database: store.database,
            callID: callID,
            relativePath: path,
            generation: 0
        )
        let receipt = try CallPrivacyIntentJournal(mediaRoot: store.mediaRoot)
            .persistAutomaticRejection(
                callID: callID,
                detectorFingerprint: fingerprint
            )

        let report = try await CallRecoveryService(
            repository: repository,
            mediaRoot: store.mediaRoot
        ).recover(nowMs: 5_000)

        let remaining = try await store.database.pool.read { db in
            (
                calls: try CallRow.filter(Column("id") == callID).fetchCount(db),
                jobs: try CallTranscriptJobRow
                    .filter(Column("callId") == callID)
                    .fetchCount(db),
                events: try CallAutomationOutboxRow
                    .filter(Column("callId") == callID)
                    .fetchCount(db)
            )
        }
        XCTAssertEqual(report.callsInterrupted, 0)
        XCTAssertEqual(report.finalJobsCreated, 0)
        XCTAssertEqual(report.mutationsCompleted, 1)
        XCTAssertEqual(remaining.calls, 0)
        XCTAssertEqual(remaining.jobs, 0)
        XCTAssertEqual(remaining.events, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: path).path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.url(for: receipt.relativePath).path
            )
        )
    }

    func testMismatchedReceiptBlocksRecoveryBeforeFinalJobOrWebhook() async throws {
        let store = try CallRecoveryTestStore()
        let repository = CallRepository(database: store.database)
        let expected = String(repeating: "c", count: 64)
        let mismatched = String(repeating: "d", count: 64)
        let call = try await repository.createCall(
            startedAtMs: 1_000,
            idempotencyKey: "automatic:\(expected)"
        )
        let callID = try XCTUnwrap(call.id)
        let receipt = try CallPrivacyIntentJournal(mediaRoot: store.mediaRoot)
            .persistAutomaticRejection(
                callID: callID,
                detectorFingerprint: mismatched
            )

        do {
            _ = try await CallRecoveryService(
                repository: repository,
                mediaRoot: store.mediaRoot
            ).recover(nowMs: 5_000)
            XCTFail("A mismatched privacy receipt must fail recovery closed.")
        } catch {
            XCTAssertEqual(
                error as? CallRepositoryError,
                .invalidPrivacyIntent(callID)
            )
        }

        let remaining = try await store.database.pool.read { db in
            (
                call: try XCTUnwrap(CallRow.fetchOne(db, key: callID)),
                jobs: try CallTranscriptJobRow
                    .filter(Column("callId") == callID)
                    .fetchCount(db),
                events: try CallAutomationOutboxRow
                    .filter(Column("callId") == callID)
                    .fetchCount(db)
            )
        }
        XCTAssertEqual(remaining.call.state, .recording)
        XCTAssertEqual(remaining.jobs, 0)
        XCTAssertEqual(remaining.events, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: store.url(for: receipt.relativePath).path
            )
        )
    }

    func testRecoveryRestoresSilentVideoWhenMuxDatabaseCommitDidNotHappen() async throws {
        let store = try CallRecoveryTestStore()
        let repository = CallRepository(database: store.database)
        let silent = Data("authoritative-silent-video".utf8)
        let muxed = Data("replacement-muxed-video".utf8)
        let fixture = try await installVideoSegmentForRecovery(
            repository,
            store: store,
            key: "mux-before-db",
            data: silent
        )
        let backupPath = fixture.relativePath + ".silent-backup"
        try store.write(muxed, relativePath: fixture.relativePath)
        try store.write(silent, relativePath: backupPath)

        let recovery = CallRecoveryService(repository: repository, mediaRoot: store.mediaRoot)
        _ = try await recovery.recover(nowMs: 5_000)
        _ = try await recovery.recover(nowMs: 6_000)

        XCTAssertEqual(try Data(contentsOf: store.url(for: fixture.relativePath)), silent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: backupPath).path))
        let row = try await store.database.pool.read { db in
            try XCTUnwrap(CallVideoSegmentRow.fetchOne(db, key: fixture.segmentID))
        }
        XCTAssertFalse(row.audioMuxed)
        XCTAssertEqual(row.bytes, Int64(silent.count))
        XCTAssertEqual(row.sha256, videoRecoveryDigest(silent))
    }

    func testRecoveryKeepsCommittedMuxAndRemovesObsoleteSilentBackup() async throws {
        let store = try CallRecoveryTestStore()
        let repository = CallRepository(database: store.database)
        let silent = Data("authoritative-silent-video".utf8)
        let muxed = Data("committed-muxed-video".utf8)
        let fixture = try await installVideoSegmentForRecovery(
            repository,
            store: store,
            key: "db-after-mux",
            data: silent
        )
        let backupPath = fixture.relativePath + ".silent-backup"
        try store.write(muxed, relativePath: fixture.relativePath)
        try store.write(silent, relativePath: backupPath)
        try await repository.markVideoSegmentAudioMuxed(
            id: fixture.segmentID,
            mediaGeneration: 0,
            bytes: Int64(muxed.count),
            sha256: videoRecoveryDigest(muxed)
        )

        let recovery = CallRecoveryService(repository: repository, mediaRoot: store.mediaRoot)
        _ = try await recovery.recover(nowMs: 5_000)
        _ = try await recovery.recover(nowMs: 6_000)

        XCTAssertEqual(try Data(contentsOf: store.url(for: fixture.relativePath)), muxed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: backupPath).path))
        let row = try await store.database.pool.read { db in
            try XCTUnwrap(CallVideoSegmentRow.fetchOne(db, key: fixture.segmentID))
        }
        XCTAssertTrue(row.audioMuxed)
        XCTAssertEqual(row.bytes, Int64(muxed.count))
        XCTAssertEqual(row.sha256, videoRecoveryDigest(muxed))
    }

    func testCommittedMuxClearsOnlyItsOwnTransientCallDegradation() async throws {
        let store = try CallRecoveryTestStore()
        let repository = CallRepository(database: store.database)
        let fixture = try await installVideoSegmentForRecovery(
            repository,
            store: store,
            key: "mux-clears-own-failure",
            data: Data("silent-video".utf8)
        )
        try await repository.markCallDegraded(
            callID: fixture.callID,
            reason: "video_audio_mux_unavailable",
            nowMs: 3_000
        )

        try await repository.markVideoSegmentAudioMuxed(
            id: fixture.segmentID,
            mediaGeneration: 0,
            bytes: 42,
            sha256: String(repeating: "a", count: 64)
        )

        let cleared = try await store.database.pool.read { db in
            try XCTUnwrap(CallRow.fetchOne(db, key: fixture.callID)).degradationReason
        }
        XCTAssertNil(cleared)

        try await repository.markCallDegraded(
            callID: fixture.callID,
            reason: "source_gap",
            nowMs: 4_000
        )
        try await repository.markVideoSegmentAudioMuxed(
            id: fixture.segmentID,
            mediaGeneration: 0,
            bytes: 43,
            sha256: String(repeating: "b", count: 64)
        )
        let preserved = try await store.database.pool.read { db in
            try XCTUnwrap(CallRow.fetchOne(db, key: fixture.callID)).degradationReason
        }
        XCTAssertEqual(preserved, "source_gap")
    }

    func testRecoveryPreservesUnknownVideoRollbackCopy() async throws {
        let store = try CallRecoveryTestStore()
        let repository = CallRepository(database: store.database)
        let backupPath = "calls/unknown/orphan.mp4.silent-backup"
        let bytes = Data("only-recovery-copy".utf8)
        try store.write(bytes, relativePath: backupPath)

        _ = try await CallRecoveryService(
            repository: repository,
            mediaRoot: store.mediaRoot
        ).recover(nowMs: 5_000)

        XCTAssertEqual(try Data(contentsOf: store.url(for: backupPath)), bytes)
    }

    func testRecoveryPreservesBothFilesWhenNeitherMatchesVideoRow() async throws {
        let store = try CallRecoveryTestStore()
        let repository = CallRepository(database: store.database)
        let fixture = try await installVideoSegmentForRecovery(
            repository,
            store: store,
            key: "mux-hash-mismatch",
            data: Data("expected-segment".utf8)
        )
        let backupPath = fixture.relativePath + ".silent-backup"
        let unexpectedCurrent = Data("unexpected-current".utf8)
        let unexpectedBackup = Data("unexpected-backup".utf8)
        try store.write(unexpectedCurrent, relativePath: fixture.relativePath)
        try store.write(unexpectedBackup, relativePath: backupPath)

        _ = try await CallRecoveryService(
            repository: repository,
            mediaRoot: store.mediaRoot
        ).recover(nowMs: 5_000)

        XCTAssertEqual(
            try Data(contentsOf: store.url(for: fixture.relativePath)),
            unexpectedCurrent
        )
        XCTAssertEqual(try Data(contentsOf: store.url(for: backupPath)), unexpectedBackup)
        let degradation = try await store.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT degradationReason FROM calls WHERE id = ?",
                arguments: [fixture.callID]
            )
        }
        XCTAssertEqual(degradation, "video_postprocess_recovery_mismatch")
    }
}

private final class CallRecoveryTestStore {
    let root: URL
    let mediaRoot: URL
    let database: ZBSEyeDatabase

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "zbseye-call-recovery-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        mediaRoot = root.appending(path: "media", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(path: root.appending(path: "eye.sqlite").path)
    }

    func url(for relativePath: String) -> URL {
        mediaRoot.appending(path: relativePath)
    }

    func write(_ data: Data, relativePath: String) throws {
        let url = url(for: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    deinit {
        try? database.pool.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeEndedCall(
    _ repository: CallRepository,
    key: String,
    start: Int64
) async throws -> Int64 {
    let call = try await repository.createCall(startedAtMs: start, idempotencyKey: key)
    let callID = try XCTUnwrap(call.id)
    _ = try await repository.endCall(
        callID: callID,
        idempotencyKey: "end-\(key)",
        endedAtMs: start + 1_000
    )
    return callID
}

private func installVideoSegmentForRecovery(
    _ repository: CallRepository,
    store: CallRecoveryTestStore,
    key: String,
    data: Data
) async throws -> (callID: Int64, segmentID: Int64, relativePath: String) {
    let call = try await repository.createCall(
        startedAtMs: 1_000,
        idempotencyKey: key,
        recordingMode: .audioVideo
    )
    let callID = try XCTUnwrap(call.id)
    let span = try await repository.beginVideoSpan(
        callID: callID,
        epoch: 0,
        displayID: "1",
        startedAtMs: 1_000,
        width: 2,
        height: 2,
        fps: 15
    )
    let spanID = try XCTUnwrap(span.id)
    let relativePath = "calls/\(callID)/video/0000.mp4"
    try store.write(data, relativePath: relativePath)
    let segment = try await repository.appendVideoSegment(CallVideoSegmentDraft(
        callId: callID,
        videoSpanId: spanID,
        mediaGeneration: 0,
        epoch: 0,
        sequence: 0,
        startMs: 1_000,
        endMs: 2_000,
        relativePath: relativePath,
        bytes: Int64(data.count),
        sha256: videoRecoveryDigest(data),
        width: 2,
        height: 2,
        fps: 15,
        codec: .h264,
        audioMuxed: false
    ))
    try await repository.finishVideoSpan(
        spanID: spanID,
        endedAtMs: 2_000,
        codec: .h264,
        availability: .available,
        reason: nil
    )
    _ = try await repository.endCall(
        callID: callID,
        idempotencyKey: "end-\(key)",
        endedAtMs: 2_000
    )
    return (callID, try XCTUnwrap(segment.id), relativePath)
}

private func videoRecoveryDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func installReferencedChunk(
    _ repository: CallRepository,
    database: ZBSEyeDatabase,
    callID: Int64,
    relativePath: String,
    generation: Int
) async throws {
    try await database.pool.write { db in
        try db.execute(
            sql: "UPDATE calls SET mediaGeneration = ?, preferredRevisionId = NULL WHERE id = ?",
            arguments: [generation, callID]
        )
    }
    let span = try await repository.recordSourceSpan(
        CallSourceSpanDraft(
            callId: callID,
            source: .me,
            epoch: 0,
            sampleRate: 16_000,
            startedAtMs: 1_000,
            startSample: 0,
            startHostTimeNs: 0,
            availability: .available
        )
    )
    _ = try await repository.recordAudioChunk(
        CallAudioChunkDraft(
            callId: callID,
            sourceSpanId: try XCTUnwrap(span.id),
            source: .me,
            epoch: 0,
            sequence: 0,
            mediaGeneration: generation,
            startSample: 0,
            endSample: 1,
            startMs: 1_000,
            endMs: 2_000,
            relativePath: relativePath,
            bytes: 2,
            sha256: "fixture",
            finalized: true
        )
    )
}

private func insertMutation(
    _ database: ZBSEyeDatabase,
    callID: Int64,
    state: CallMediaMutationState,
    fromGeneration: Int,
    toGeneration: Int,
    oldPaths: [String],
    newPaths: [String]
) async throws {
    let encoder = JSONEncoder()
    let oldJSON = String(decoding: try encoder.encode(oldPaths), as: UTF8.self)
    let newJSON = String(decoding: try encoder.encode(newPaths), as: UTF8.self)
    try await database.pool.write { db in
        try db.execute(
            sql: """
                INSERT INTO call_media_mutations(
                    identity, callId, kind, state, fromGeneration, toGeneration,
                    oldRelativePathsJSON, newRelativePathsJSON, createdAtMs, updatedAtMs
                ) VALUES (?, ?, 'redaction', ?, ?, ?, ?, ?, 1, 1)
                """,
            arguments: [
                "mutation-\(callID)", callID, state.rawValue, fromGeneration, toGeneration,
                oldJSON, newJSON,
            ]
        )
    }
}
