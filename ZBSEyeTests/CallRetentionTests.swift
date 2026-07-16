import Foundation
import GRDB
import XCTest

final class CallRetentionTests: XCTestCase {
    func testWholeEnvelopeEraseRemovesDatabaseSearchVectorsQueueAndPCM() async throws {
        let fixture = try CallRetentionFixture()
        let callID = try await fixture.makeEndedCall(key: "erase", startedAtMs: 1_000)
        let finalCandidate = try await fixture.repository.claimNextTranscriptJob(nowMs: 4_000)
        let final = try XCTUnwrap(finalCandidate)
        let commit = try await fixture.repository.commitTranscriptJob(
            jobID: try XCTUnwrap(final.id),
            segments: [.init(source: .me, startMs: 1_100, endMs: 2_900, text: "private words")],
            language: "en",
            engine: "fixture",
            modelRevision: "fixture",
            degraded: false,
            nowMs: 4_100
        )
        let vector = Data(count: ZBSEyeDatabase.embeddingDim * MemoryLayout<Float>.size)
        try await fixture.database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO vec_call_transcripts(revision_id, bucket_month, embedding)
                    VALUES (?, 202607, ?)
                    """,
                arguments: [commit.preferredRevisionID, vector]
            )
        }

        let report = try await fixture.deletion.erase(callID: callID, nowMs: 5_000)

        XCTAssertEqual(report.bytesDeleted, 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.mediaURL(callID: callID).path))
        let counts = try await fixture.database.pool.read { db in
            (
                calls: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM calls") ?? -1,
                chunks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_audio_chunks") ?? -1,
                revisions: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_transcript_revisions") ?? -1,
                fts: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_transcript_fts") ?? -1,
                vectors: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM vec_call_transcripts") ?? -1,
                queue: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embed_queue WHERE kind = 2") ?? -1,
                mutations: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_media_mutations") ?? -1
            )
        }
        XCTAssertEqual(counts.calls, 0)
        XCTAssertEqual(counts.chunks, 0)
        XCTAssertEqual(counts.revisions, 0)
        XCTAssertEqual(counts.fts, 0)
        XCTAssertEqual(counts.vectors, 0)
        XCTAssertEqual(counts.queue, 0)
        XCTAssertEqual(counts.mutations, 0)
    }

    func testRecoveryCompletesEraseAfterDatabaseTombstoneCrash() async throws {
        let fixture = try CallRetentionFixture()
        let callID = try await fixture.makeEndedCall(key: "erase-recovery", startedAtMs: 1_000)

        let preparation = try await fixture.repository.beginEraseCall(
            callID: callID,
            nowMs: 5_000
        )

        XCTAssertEqual(preparation.relativePaths.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mediaURL(callID: callID).path))
        let retainedTombstone = try await fixture.database.pool.read { db in
            (
                calls: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM calls") ?? -1,
                mutations: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_media_mutations") ?? -1
            )
        }
        XCTAssertEqual(retainedTombstone.calls, 1)
        XCTAssertEqual(retainedTombstone.mutations, 1)

        let recovery = CallRecoveryService(
            repository: fixture.repository,
            mediaRoot: fixture.mediaRoot
        )
        let report = try await recovery.recover(nowMs: 6_000)

        XCTAssertEqual(report.mutationsCompleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.mediaURL(callID: callID).path))
        let completed = try await fixture.database.pool.read { db in
            (
                calls: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM calls") ?? -1,
                mutations: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_media_mutations") ?? -1
            )
        }
        XCTAssertEqual(completed.calls, 0)
        XCTAssertEqual(completed.mutations, 0)
    }

    func testForeverWithExplicitByteCapEvictsWholeOldestCall() async throws {
        let fixture = try CallRetentionFixture()
        let callBytes = Int64(3) * KeepMediaPolicy.bytesPerGB
        let oldestCallID = try await fixture.makeEndedCall(
            key: "oldest", startedAtMs: 1_000, bytes: callBytes
        )
        let newestCallID = try await fixture.makeEndedCall(
            key: "newest", startedAtMs: 10_000, bytes: callBytes
        )
        let (admission, permit) = finiteAdmission()

        let report = try await fixture.retention.pruneAutomatically(
            permit: permit,
            admission: admission
        )

        XCTAssertEqual(report.framesDeleted, 0)
        XCTAssertEqual(report.audioDeleted, 0)
        XCTAssertEqual(report.callsDeleted, 1)
        XCTAssertEqual(report.callBytesDeleted, callBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.mediaURL(callID: oldestCallID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mediaURL(callID: newestCallID).path))
        let remainingCallIDs = try await fixture.database.pool.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM calls ORDER BY id")
        }
        XCTAssertEqual(remainingCallIDs, [newestCallID])
    }

    func testFiniteRetentionKeepsActiveCallAndErasesEndedCall() async throws {
        let fixture = try CallRetentionFixture()
        let callBytes = Int64(3) * KeepMediaPolicy.bytesPerGB
        let endedCallID = try await fixture.makeEndedCall(
            key: "ended-newer", startedAtMs: 10_000, bytes: callBytes
        )
        let recordingCallID = try await fixture.makeRecordingCall(
            key: "active-oldest", startedAtMs: 1_000, bytes: callBytes
        )
        let (admission, permit) = finiteAdmission()

        let report = try await fixture.retention.pruneAutomatically(
            permit: permit,
            admission: admission
        )

        XCTAssertEqual(report.callsDeleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.mediaURL(callID: endedCallID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mediaURL(callID: recordingCallID).path))
        let remainingCallIDs = try await fixture.database.pool.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM calls ORDER BY id")
        }
        XCTAssertEqual(remainingCallIDs, [recordingCallID])
    }

    func testPendingEraseStillCountsBytesAndNextRetentionPassCompletesCleanup() async throws {
        let fixture = try CallRetentionFixture()
        let callBytes = Int64(6) * KeepMediaPolicy.bytesPerGB
        let callID = try await fixture.makeEndedCall(
            key: "pending-retry", startedAtMs: 1_000, bytes: callBytes
        )
        _ = try await fixture.repository.beginEraseCall(callID: callID, nowMs: 5_000)

        let pendingBytes = try await fixture.deletion.evidenceBytes()
        XCTAssertGreaterThanOrEqual(pendingBytes, 8)
        let (admission, permit) = finiteAdmission()

        let report = try await fixture.retention.pruneAutomatically(
            permit: permit,
            admission: admission
        )

        XCTAssertEqual(report.callsDeleted, 1)
        XCTAssertEqual(report.callBytesDeleted, 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.mediaURL(callID: callID).path))
        let counts = try await fixture.database.pool.read { db in
            (
                calls: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM calls") ?? -1,
                mutations: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_media_mutations") ?? -1
            )
        }
        XCTAssertEqual(counts.calls, 0)
        XCTAssertEqual(counts.mutations, 0)
    }

    func testFullDeleteRefusesActiveCallBeforeDeletingLegacyEvidence() async throws {
        let fixture = try CallRetentionFixture()
        let callID = try await fixture.makeRecordingCall(key: "full-active", startedAtMs: 1_000)
        let legacyPath = "screen_fixture.heic"
        try Data([9, 8, 7]).write(to: fixture.mediaRoot.appendingPathComponent(legacyPath))
        try await fixture.database.pool.write { db in
            var row = ScreenCaptureRow(
                id: nil,
                ts: 1_500,
                appId: nil,
                windowTitle: nil,
                browserUrl: nil,
                monitorId: "fixture",
                relativePath: legacyPath,
                width: nil,
                height: nil,
                bytes: 3,
                axQuality: nil,
                usefulTextChars: nil,
                nodeCount: nil,
                treeWasEmpty: nil,
                hitBudgetLimit: nil,
                ocrFallbackReason: nil,
                manualAccessibilityResult: nil,
                enhancedUiResult: nil
            )
            try row.insert(db)
        }

        do {
            _ = try await fixture.retention.deleteRange(fromMs: 0, toMs: Int64.max)
            XCTFail("Expected full deletion to refuse an active Call Envelope")
        } catch {
            XCTAssertEqual(error as? CallRepositoryError, .activeCallMustEnd(callID))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mediaRoot.appendingPathComponent(legacyPath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mediaURL(callID: callID).path))
        let counts = try await fixture.database.pool.read { db in
            (
                frames: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM screen_captures") ?? -1,
                calls: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM calls") ?? -1
            )
        }
        XCTAssertEqual(counts.frames, 1)
        XCTAssertEqual(counts.calls, 1)
    }

    func testNarrowPrivacyRangeRedactsIntersectingCallWithoutErasingEnvelope() async throws {
        let fixture = try CallRetentionFixture()
        let callID = try await fixture.makeEndedCall(key: "range-redaction", startedAtMs: 1_000)

        let report = try await fixture.retention.deleteRange(fromMs: 1_500, toMs: 2_500)

        XCTAssertEqual(report.callsDeleted, 0)
        XCTAssertEqual(report.callBytesDeleted, 4)
        let snapshot = try await fixture.database.pool.read { db in
            (
                call: try CallRow.fetchOne(db, key: callID),
                chunks: try CallAudioChunkRow.fetchAll(
                    db,
                    sql: "SELECT * FROM call_audio_chunks WHERE callId = ? ORDER BY startSample",
                    arguments: [callID]
                ),
                gaps: try CallSourceGapRow.fetchAll(
                    db,
                    sql: "SELECT * FROM call_source_gaps WHERE callId = ?",
                    arguments: [callID]
                )
            )
        }
        XCTAssertNotNil(snapshot.call)
        XCTAssertEqual(snapshot.call?.mediaGeneration, 1)
        XCTAssertEqual(snapshot.chunks.count, 2)
        XCTAssertEqual(snapshot.gaps.count, 1)
        let gap = try XCTUnwrap(snapshot.gaps.first)
        XCTAssertEqual(gap.startMs, 1_500)
        XCTAssertEqual(gap.endMs, 2_500)
        var remaining = Data()
        for chunk in snapshot.chunks {
            remaining.append(try Data(contentsOf: fixture.mediaRoot.appendingPathComponent(chunk.relativePath)))
        }
        XCTAssertEqual(remaining, Data([1, 0, 4, 0]))
    }

    func testWholeEraseDrainsWorkerScavengesScratchAndConditionallyResumes() async throws {
        let fixture = try CallRetentionFixture()
        let callID = try await fixture.makeEndedCall(key: "worker-barrier", startedAtMs: 1_000)
        let scratch = CallHelperScratchStore(dataRoot: fixture.root)
        let jobRoot = scratch.jobsRoot.appendingPathComponent(
            UUID().uuidString.lowercased(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: jobRoot, withIntermediateDirectories: true)
        try Data("stale helper result".utf8).write(
            to: jobRoot.appendingPathComponent("result.json")
        )
        let probe = CallDeletionWorkerProbe()
        await fixture.deletion.attachTranscriptWorker(
            suspend: { await probe.suspend() },
            resume: { await probe.resume() }
        )

        _ = try await fixture.deletion.erase(callID: callID, nowMs: 5_000)

        let workerEvents = await probe.events()
        XCTAssertEqual(workerEvents, ["suspend", "resume"])
        XCTAssertEqual(try scratch.inventory().jobDirectories, 0)
    }

    func testPruneRemovesNestedCallFileAfterOrphanGraceWindow() async throws {
        let fixture = try CallRetentionFixture()
        let orphan = fixture.mediaRoot
            .appendingPathComponent("calls/999/me/epoch-0000/orphan.pcm")
        try FileManager.default.createDirectory(
            at: orphan.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1, 2, 3, 4]).write(to: orphan)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-120)],
            ofItemAtPath: orphan.path
        )

        let deleted = try await fixture.deletion.sweepOrphanedCallFiles(
            graceSeconds: 60
        )

        XCTAssertEqual(deleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testPruneSweepsOrphanedCallVectorAndEmbedQueueRows() async throws {
        let fixture = try CallRetentionFixture()
        let vector = Data(count: ZBSEyeDatabase.embeddingDim * MemoryLayout<Float>.size)
        try await fixture.database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO vec_call_transcripts(revision_id, bucket_month, embedding) VALUES (?, ?, ?)",
                arguments: [999_999, 202607, vector]
            )
            try db.execute(
                sql: "INSERT INTO embed_queue(row_id, kind, ts) VALUES (?, 2, ?)",
                arguments: [999_999, 1_000]
            )
        }

        try await fixture.retention.sweepVectorOrphans()

        let counts = try await fixture.database.pool.read { db in
            (
                vectors: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM vec_call_transcripts") ?? -1,
                queue: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embed_queue WHERE kind = 2") ?? -1
            )
        }
        XCTAssertEqual(counts.vectors, 0)
        XCTAssertEqual(counts.queue, 0)
    }

    func testActiveCallEraseFailsWithoutChangingBytesOrRows() async throws {
        let fixture = try CallRetentionFixture()
        let callID = try await fixture.makeRecordingCall(key: "active", startedAtMs: 1_000)
        let before = try Data(contentsOf: fixture.mediaURL(callID: callID))

        do {
            _ = try await fixture.deletion.erase(callID: callID, nowMs: 2_000)
            XCTFail("Expected an active call to reject whole-envelope deletion")
        } catch {
            XCTAssertEqual(error as? CallRepositoryError, .activeCallMustEnd(callID))
        }

        XCTAssertEqual(try Data(contentsOf: fixture.mediaURL(callID: callID)), before)
        let counts = try await fixture.database.pool.read { db in
            (
                calls: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM calls") ?? -1,
                chunks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_audio_chunks") ?? -1,
                mutations: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_media_mutations") ?? -1
            )
        }
        XCTAssertEqual(counts.calls, 1)
        XCTAssertEqual(counts.chunks, 1)
        XCTAssertEqual(counts.mutations, 0)
    }

    private func finiteAdmission() -> (
        AutomaticRetentionAdmission,
        AutomaticRetentionPermit
    ) {
        let admission = AutomaticRetentionAdmission(record: AutomaticRetentionRecord(
            revision: 1,
            policy: .fiveGB,
            phase: .finiteAdmitted,
            source: .explicitSelection
        ))
        return (admission, admission.currentPermit()!)
    }
}

private actor CallDeletionWorkerProbe {
    private var recorded: [String] = []

    func suspend() -> Bool {
        recorded.append("suspend")
        return true
    }

    func resume() {
        recorded.append("resume")
    }

    func events() -> [String] {
        recorded
    }
}

private final class CallRetentionFixture {
    let root: URL
    let mediaRoot: URL
    let database: ZBSEyeDatabase
    let repository: CallRepository
    let deletion: CallEvidenceDeletionService
    let retention: RetentionManager

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-call-retention-\(UUID().uuidString)", isDirectory: true)
        mediaRoot = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        repository = CallRepository(database: database)
        deletion = CallEvidenceDeletionService(repository: repository, mediaRoot: mediaRoot)
        let storage = try StorageManager(mediaDirectory: mediaRoot)
        retention = RetentionManager(
            db: database,
            storage: storage,
            callDeletion: deletion
        )
    }

    deinit {
        try? database.pool.close()
        try? FileManager.default.removeItem(at: root)
    }

    func makeRecordingCall(
        key: String,
        startedAtMs: Int64,
        bytes: Int64 = 8
    ) async throws -> Int64 {
        let call = try await repository.createCall(
            startedAtMs: startedAtMs,
            idempotencyKey: key
        )
        let callID = try XCTUnwrap(call.id)
        let span = try await repository.recordSourceSpan(
            .init(
                callId: callID,
                source: .me,
                epoch: 0,
                sampleRate: 2,
                startedAtMs: startedAtMs,
                startSample: 0,
                startHostTimeNs: 0,
                availability: .available
            )
        )
        let relative = "calls/\(callID)/me/epoch-0000/chunk-000000.pcm"
        let url = mediaRoot.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1, 0, 2, 0, 3, 0, 4, 0]).write(to: url)
        _ = try await repository.recordAudioChunk(
            .init(
                callId: callID,
                sourceSpanId: try XCTUnwrap(span.id),
                source: .me,
                epoch: 0,
                sequence: 0,
                mediaGeneration: 0,
                startSample: 0,
                endSample: 4,
                startMs: startedAtMs,
                endMs: startedAtMs + 2_000,
                relativePath: relative,
                bytes: bytes,
                sha256: nil,
                finalized: true
            )
        )
        return callID
    }

    func makeEndedCall(
        key: String,
        startedAtMs: Int64,
        bytes: Int64 = 8
    ) async throws -> Int64 {
        let callID = try await makeRecordingCall(
            key: key,
            startedAtMs: startedAtMs,
            bytes: bytes
        )
        _ = try await repository.endCall(
            callID: callID,
            idempotencyKey: "\(key)-end",
            endedAtMs: startedAtMs + 2_000
        )
        return callID
    }

    func mediaURL(callID: Int64) -> URL {
        mediaRoot.appendingPathComponent(
            "calls/\(callID)/me/epoch-0000/chunk-000000.pcm"
        )
    }
}
