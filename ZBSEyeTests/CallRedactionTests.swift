import CryptoKit
import Foundation
import GRDB
import XCTest

final class CallRedactionTests: XCTestCase {
    func testMiddleRedactionPreservesOutsidePCMAndInvalidatesDerivedEvidence() async throws {
        let fixture = try CallRedactionFixture()
        let callID = try await fixture.makeEndedCall()
        let claimedFinal = try await fixture.repository.claimNextTranscriptJob(nowMs: 2_100)
        let finalJob = try XCTUnwrap(claimedFinal)
        let commit = try await fixture.repository.commitTranscriptJob(
            jobID: try XCTUnwrap(finalJob.id),
            segments: [.init(source: .me, startMs: 1_000, endMs: 2_000, text: "secret middle")],
            language: "en",
            engine: "fixture",
            modelRevision: "fixture",
            degraded: false,
            nowMs: 2_200
        )
        let vector = Data(count: ZBSEyeDatabase.embeddingDim * MemoryLayout<Float>.size)
        try await fixture.database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO vec_call_transcripts(revision_id, bucket_month, embedding) VALUES (?, 202607, ?)",
                arguments: [commit.preferredRevisionID, vector]
            )
        }

        let report = try await fixture.deletion.redact(
            callID: callID,
            fromMs: 1_400,
            toMs: 1_600,
            nowMs: 3_000
        )

        XCTAssertEqual(report.callID, callID)
        XCTAssertEqual(report.fromGeneration, 0)
        XCTAssertEqual(report.toGeneration, 1)
        XCTAssertEqual(report.bytesRemoved, 4)

        let snapshot = try await fixture.database.pool.read { db in
            (
                call: try XCTUnwrap(CallRow.fetchOne(db, key: callID)),
                chunks: try CallAudioChunkRow.fetchAll(
                    db,
                    sql: "SELECT * FROM call_audio_chunks WHERE callId = ? ORDER BY startSample",
                    arguments: [callID]
                ),
                gaps: try CallSourceGapRow.fetchAll(
                    db,
                    sql: "SELECT * FROM call_source_gaps WHERE callId = ? ORDER BY source, startMs",
                    arguments: [callID]
                ),
                jobs: try CallTranscriptJobRow.fetchAll(
                    db,
                    sql: "SELECT * FROM call_transcript_jobs WHERE callId = ? ORDER BY id",
                    arguments: [callID]
                ),
                revisions: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_revisions WHERE callId = ?",
                    arguments: [callID]
                ) ?? -1,
                fts: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_fts WHERE call_id = ?",
                    arguments: [callID]
                ) ?? -1,
                vectors: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM vec_call_transcripts WHERE revision_id = ?",
                    arguments: [commit.preferredRevisionID]
                ) ?? -1,
                queue: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM embed_queue WHERE row_id = ? AND kind = 2",
                    arguments: [commit.preferredRevisionID]
                ) ?? -1,
                mutationState: try String.fetchOne(
                    db,
                    sql: "SELECT state FROM call_media_mutations WHERE callId = ? AND kind = 'redaction'",
                    arguments: [callID]
                )
            )
        }

        XCTAssertEqual(snapshot.call.mediaGeneration, 1)
        XCTAssertNil(snapshot.call.preferredRevisionId)
        XCTAssertEqual(snapshot.call.state, CallLifecycleState.finalizing)
        XCTAssertEqual(snapshot.call.degradationReason, "redacted")
        XCTAssertEqual(snapshot.chunks.count, 2)
        XCTAssertEqual(snapshot.chunks.map { $0.mediaGeneration }, [1, 1])
        XCTAssertEqual(snapshot.gaps.count, 1)
        XCTAssertEqual(snapshot.gaps[0].startMs, 1_400)
        XCTAssertEqual(snapshot.gaps[0].endMs, 1_600)
        XCTAssertEqual(snapshot.gaps[0].reason, "redacted")
        XCTAssertEqual(snapshot.jobs.count, 1)
        XCTAssertEqual(snapshot.jobs[0].identity, "final:\(callID):1")
        XCTAssertEqual(snapshot.jobs[0].state, CallTranscriptJobState.pending)
        XCTAssertEqual(snapshot.revisions, 0)
        XCTAssertEqual(snapshot.fts, 0)
        XCTAssertEqual(snapshot.vectors, 0)
        XCTAssertEqual(snapshot.queue, 0)
        XCTAssertEqual(snapshot.mutationState, CallMediaMutationState.completed.rawValue)

        let evidencePage = try await CallEvidenceQueryService(database: fixture.database).call(id: callID)
        let evidence = try XCTUnwrap(evidencePage)
        XCTAssertEqual(evidence.sourceGaps.count, 1)
        XCTAssertEqual(evidence.sourceGaps[0].reason, "redacted")
        XCTAssertFalse(evidence.sourceGapsTruncated)

        var remaining = Data()
        for chunk in snapshot.chunks {
            remaining.append(try Data(contentsOf: fixture.mediaRoot.appendingPathComponent(chunk.relativePath)))
        }
        XCTAssertEqual(remaining, fixture.pcm(samples: [0, 1, 2, 3, 6, 7, 8, 9]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.originalURL.path))
    }

    func testActiveCallRedactionFailsWithoutChangingBytesOrDatabase() async throws {
        let fixture = try CallRedactionFixture()
        let callID = try await fixture.makeRecordingCall()
        let before = try Data(contentsOf: fixture.originalURL)

        do {
            _ = try await fixture.deletion.redact(
                callID: callID,
                fromMs: 1_400,
                toMs: 1_600,
                nowMs: 3_000
            )
            XCTFail("Expected active call redaction to be rejected")
        } catch {
            XCTAssertEqual(error as? CallRepositoryError, .activeCallMustEnd(callID))
        }

        XCTAssertEqual(try Data(contentsOf: fixture.originalURL), before)
        let snapshot = try await fixture.database.pool.read { db in
            (
                generation: try Int.fetchOne(
                    db,
                    sql: "SELECT mediaGeneration FROM calls WHERE id = ?",
                    arguments: [callID]
                ),
                chunks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_audio_chunks") ?? -1,
                mutations: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_media_mutations") ?? -1
            )
        }
        XCTAssertEqual(snapshot.generation, 0)
        XCTAssertEqual(snapshot.chunks, 1)
        XCTAssertEqual(snapshot.mutations, 0)
    }

    func testRecoveryMovesAcceptedStagedRedactionForwardInsteadOfRestoringEvidence() async throws {
        let fixture = try CallRedactionFixture()
        let callID = try await fixture.makeEndedCall()
        let snapshot = try await fixture.repository.redactionSnapshot(callID: callID)
        let manifest = try CallRedactionPlanner(mediaRoot: fixture.mediaRoot).makeManifest(
            snapshot: snapshot,
            fromMs: 1_400,
            toMs: 1_600
        )
        _ = try await fixture.repository.beginRedaction(manifest: manifest, nowMs: 3_000)

        let report = try await CallRecoveryService(
            repository: fixture.repository,
            mediaRoot: fixture.mediaRoot
        ).recover(nowMs: 4_000)

        XCTAssertEqual(report.mutationsCompleted, 1)
        XCTAssertEqual(report.mutationsRolledBack, 0)
        let state = try await fixture.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT state FROM call_media_mutations WHERE callId = ?",
                arguments: [callID]
            )
        }
        XCTAssertEqual(state, CallMediaMutationState.completed.rawValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.originalURL.path))
        let chunks = try await fixture.database.pool.read { db in
            try CallAudioChunkRow.fetchAll(
                db,
                sql: "SELECT * FROM call_audio_chunks WHERE callId = ? ORDER BY startSample",
                arguments: [callID]
            )
        }
        var remaining = Data()
        for chunk in chunks {
            remaining.append(try Data(contentsOf: fixture.mediaRoot.appendingPathComponent(chunk.relativePath)))
        }
        XCTAssertEqual(remaining, fixture.pcm(samples: [0, 1, 2, 3, 6, 7, 8, 9]))
    }

    func testAcceptedRedactionImmediatelyRemovesSpeakerEvidenceBeforeFileCleanup() async throws {
        let fixture = try CallRedactionFixture()
        let callID = try await fixture.makeEndedCall()
        _ = try await fixture.makePreferredSpeakerRevision(callID: callID)
        let before = try await fixture.speakerPrivacyState(callID: callID)
        XCTAssertNotNil(before.preferredRevisionID)
        XCTAssertEqual(before.revisions, 2)
        XCTAssertEqual(before.clusters, 2)
        XCTAssertEqual(before.intervals, 2)
        let snapshot = try await fixture.repository.redactionSnapshot(callID: callID)
        let manifest = try CallRedactionPlanner(mediaRoot: fixture.mediaRoot).makeManifest(
            snapshot: snapshot,
            fromMs: 1_400,
            toMs: 1_600
        )

        _ = try await fixture.repository.beginRedaction(manifest: manifest, nowMs: 3_000)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.originalURL.path),
            "beginRedaction must revoke derived evidence before physical cleanup starts"
        )
        let privacyState = try await fixture.speakerPrivacyState(callID: callID)
        XCTAssertNil(privacyState.preferredRevisionID)
        XCTAssertEqual(privacyState.revisions, 0)
        XCTAssertEqual(privacyState.clusters, 0)
        XCTAssertEqual(privacyState.intervals, 0)
    }

    func testAcceptedEraseImmediatelyRemovesSpeakerEvidenceBeforeFileCleanup() async throws {
        let fixture = try CallRedactionFixture()
        let callID = try await fixture.makeEndedCall()
        _ = try await fixture.makePreferredSpeakerRevision(callID: callID)
        let before = try await fixture.speakerPrivacyState(callID: callID)
        XCTAssertNotNil(before.preferredRevisionID)
        XCTAssertEqual(before.revisions, 2)
        XCTAssertEqual(before.clusters, 2)
        XCTAssertEqual(before.intervals, 2)

        _ = try await fixture.repository.beginEraseCall(callID: callID, nowMs: 3_000)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.originalURL.path),
            "beginEraseCall must revoke derived evidence before physical cleanup starts"
        )
        let privacyState = try await fixture.speakerPrivacyState(callID: callID)
        XCTAssertNil(privacyState.preferredRevisionID)
        XCTAssertEqual(privacyState.revisions, 0)
        XCTAssertEqual(privacyState.clusters, 0)
        XCTAssertEqual(privacyState.intervals, 0)
    }

    func testRangeRedactionJournalsEveryIntersectingCallBeforeFileWork() async throws {
        let fixture = try CallRedactionFixture()
        let firstID = try await fixture.makeEndedCall(key: "range-first", startMs: 1_000)
        let secondID = try await fixture.makeEndedCall(key: "range-second", startMs: 1_200)
        let planner = try CallRedactionPlanner(mediaRoot: fixture.mediaRoot)
        var manifests: [CallRedactionManifestV1] = []
        for callID in [firstID, secondID] {
            let snapshot = try await fixture.repository.redactionSnapshot(callID: callID)
            manifests.append(
                try planner.makeManifest(
                    snapshot: snapshot,
                    fromMs: 1_400,
                    toMs: 1_600
                )
            )
        }

        let accepted = try await fixture.repository.beginRedactions(
            manifests: manifests,
            nowMs: 3_000
        )
        XCTAssertEqual(accepted.count, 2)

        let report = try await CallRecoveryService(
            repository: fixture.repository,
            mediaRoot: fixture.mediaRoot
        ).recover(nowMs: 4_000)

        XCTAssertEqual(report.mutationsCompleted, 2)
        let state = try await fixture.database.pool.read { db in
            (
                mutations: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_media_mutations WHERE state = 'completed'"
                ) ?? 0,
                generations: try Int.fetchAll(
                    db,
                    sql: "SELECT mediaGeneration FROM calls ORDER BY startTs, id"
                )
            )
        }
        XCTAssertEqual(state.mutations, 2)
        XCTAssertEqual(state.generations, [1, 1])
        for manifest in manifests {
            for path in manifest.obsoleteRelativePaths {
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: fixture.mediaRoot.appendingPathComponent(path).path
                    )
                )
            }
        }
    }

    func testRangeRedactionBatchRollsBackWhenAnyManifestIsInvalid() async throws {
        let fixture = try CallRedactionFixture()
        let firstID = try await fixture.makeEndedCall(key: "rollback-first", startMs: 1_000)
        let secondID = try await fixture.makeEndedCall(key: "rollback-second", startMs: 1_200)
        let planner = try CallRedactionPlanner(mediaRoot: fixture.mediaRoot)
        let first = try planner.makeManifest(
            snapshot: await fixture.repository.redactionSnapshot(callID: firstID),
            fromMs: 1_400,
            toMs: 1_600
        )
        let validSecond = try planner.makeManifest(
            snapshot: await fixture.repository.redactionSnapshot(callID: secondID),
            fromMs: 1_400,
            toMs: 1_600
        )
        let invalidSecond = CallRedactionManifestV1(
            formatVersion: validSecond.formatVersion,
            callID: validSecond.callID,
            fromGeneration: validSecond.fromGeneration,
            toGeneration: validSecond.toGeneration + 1,
            fromMs: validSecond.fromMs,
            toMs: validSecond.toMs,
            bytesRemoved: validSecond.bytesRemoved,
            obsoleteRelativePaths: validSecond.obsoleteRelativePaths,
            redactedGaps: validSecond.redactedGaps,
            survivors: validSecond.survivors
        )

        do {
            _ = try await fixture.repository.beginRedactions(
                manifests: [first, invalidSecond],
                nowMs: 3_000
            )
            XCTFail("Expected the whole batch to roll back")
        } catch {
            XCTAssertEqual(
                error as? CallRepositoryError,
                .invalidMediaMutation(secondID)
            )
        }
        let state = try await fixture.database.pool.read { db in
            (
                mutations: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_media_mutations") ?? -1,
                generations: try Int.fetchAll(
                    db,
                    sql: "SELECT mediaGeneration FROM calls ORDER BY startTs, id"
                )
            )
        }
        XCTAssertEqual(state.mutations, 0)
        XCTAssertEqual(state.generations, [0, 0])
    }

    func testRedactionDeletesInsideBookmarkAndCarriesOutsideBookmarkToNewGeneration() async throws {
        let fixture = try CallRedactionFixture()
        let callID = try await fixture.makeRecordingCall()
        let outside = try await fixture.repository.createBookmark(
            callID: callID,
            idempotencyKey: "outside",
            acceptedAtMs: 1_300,
            meIngressTarget: 3,
            systemIngressTarget: nil,
            logicalStartMs: 1_000,
            logicalEndMs: 1_300,
            contextStartMs: 1_000
        )
        _ = try await fixture.repository.createBookmark(
            callID: callID,
            idempotencyKey: "inside",
            acceptedAtMs: 1_500,
            meIngressTarget: 5,
            systemIngressTarget: nil,
            logicalStartMs: 1_300,
            logicalEndMs: 1_300,
            contextStartMs: 1_000
        )
        _ = try await fixture.repository.endCall(
            callID: callID,
            idempotencyKey: "bookmarks-end",
            endedAtMs: 2_000,
            meEndSample: 10
        )

        _ = try await fixture.deletion.redact(
            callID: callID,
            fromMs: 1_400,
            toMs: 1_600,
            nowMs: 3_000
        )

        let bookmarks = try await fixture.database.pool.read { db in
            try CallBookmarkRow.fetchAll(
                db,
                sql: "SELECT * FROM call_bookmarks WHERE callId = ? ORDER BY ordinal",
                arguments: [callID]
            )
        }
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks[0].id, outside.bookmark.id)
        XCTAssertEqual(bookmarks[0].mediaGeneration, 1)
        XCTAssertEqual(bookmarks[0].state, CallBookmarkState.pending)
    }

    func testRepeatedNonAlignedRedactionRoundsOutwardAndMergesPrivacyGap() async throws {
        let fixture = try CallRedactionFixture()
        let callID = try await fixture.makeEndedCall()

        _ = try await fixture.deletion.redact(
            callID: callID,
            fromMs: 1_450,
            toMs: 1_550,
            nowMs: 3_000
        )
        _ = try await fixture.deletion.redact(
            callID: callID,
            fromMs: 1_550,
            toMs: 1_650,
            nowMs: 4_000
        )

        let snapshot = try await fixture.database.pool.read { db in
            (
                generation: try Int.fetchOne(
                    db,
                    sql: "SELECT mediaGeneration FROM calls WHERE id = ?",
                    arguments: [callID]
                ),
                chunks: try CallAudioChunkRow.fetchAll(
                    db,
                    sql: "SELECT * FROM call_audio_chunks WHERE callId = ? ORDER BY startSample",
                    arguments: [callID]
                ),
                gaps: try CallSourceGapRow.fetchAll(
                    db,
                    sql: "SELECT * FROM call_source_gaps WHERE callId = ? ORDER BY startMs",
                    arguments: [callID]
                ),
                finalJobs: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_jobs WHERE callId = ? AND kind = 'final'",
                    arguments: [callID]
                ) ?? -1
            )
        }
        XCTAssertEqual(snapshot.generation, 2)
        XCTAssertEqual(snapshot.gaps.count, 1)
        let gap = try XCTUnwrap(snapshot.gaps.first)
        XCTAssertEqual(gap.startMs, 1_400)
        XCTAssertEqual(gap.endMs, 1_700)
        XCTAssertEqual(snapshot.finalJobs, 1)
        var remaining = Data()
        for chunk in snapshot.chunks {
            remaining.append(try Data(contentsOf: fixture.mediaRoot.appendingPathComponent(chunk.relativePath)))
        }
        XCTAssertEqual(remaining, fixture.pcm(samples: [0, 1, 2, 3, 7, 8, 9]))
    }

    func testRedactionCarriesUntouchedChunkWithoutDeletingItsFile() async throws {
        let fixture = try CallRedactionFixture()
        let callID = try await fixture.makeRecordingCall()
        let untouchedURL = try await fixture.appendSecondChunk(callID: callID)
        _ = try await fixture.repository.endCall(
            callID: callID,
            idempotencyKey: "two-chunks-end",
            endedAtMs: 3_000,
            meEndSample: 20
        )

        _ = try await fixture.deletion.redact(
            callID: callID,
            fromMs: 1_400,
            toMs: 1_600,
            nowMs: 4_000
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: untouchedURL.path))
        XCTAssertEqual(
            try Data(contentsOf: untouchedURL),
            fixture.pcm(samples: Array(10...19))
        )
        let carried = try await fixture.database.pool.read { db in
            try CallAudioChunkRow.fetchOne(
                db,
                sql: "SELECT * FROM call_audio_chunks WHERE callId = ? AND startSample = 10",
                arguments: [callID]
            )
        }
        XCTAssertEqual(carried?.relativePath, "calls/\(callID)/me/epoch-0000/chunk-000001.pcm")
        XCTAssertEqual(carried?.mediaGeneration, 1)
    }

    func testRedactionAppliesToBothIndependentAudioSources() async throws {
        let fixture = try CallRedactionFixture()
        let callID = try await fixture.makeRecordingCall()
        try await fixture.appendSystemChunk(callID: callID)
        _ = try await fixture.repository.endCall(
            callID: callID,
            idempotencyKey: "dual-source-end",
            endedAtMs: 2_000,
            meEndSample: 10,
            systemEndSample: 10
        )

        let report = try await fixture.deletion.redact(
            callID: callID,
            fromMs: 1_400,
            toMs: 1_600,
            nowMs: 3_000
        )

        XCTAssertEqual(report.bytesRemoved, 8)
        let snapshot = try await fixture.database.pool.read { db in
            (
                chunks: try CallAudioChunkRow.fetchAll(
                    db,
                    sql: "SELECT * FROM call_audio_chunks WHERE callId = ? ORDER BY source, startSample",
                    arguments: [callID]
                ),
                gaps: try CallSourceGapRow.fetchAll(
                    db,
                    sql: "SELECT * FROM call_source_gaps WHERE callId = ? ORDER BY source",
                    arguments: [callID]
                )
            )
        }
        XCTAssertEqual(Set(snapshot.gaps.map { $0.source.rawValue }), Set(["me", "system"]))
        for source in [CallAudioSource.me, .system] {
            var remaining = Data()
            for chunk in snapshot.chunks.filter({ $0.source == source }) {
                remaining.append(try Data(contentsOf: fixture.mediaRoot.appendingPathComponent(chunk.relativePath)))
            }
            let expected = source == .me
                ? fixture.pcm(samples: [0, 1, 2, 3, 6, 7, 8, 9])
                : fixture.pcm(samples: [100, 101, 102, 103, 106, 107, 108, 109])
            XCTAssertEqual(remaining, expected)
        }
    }

    func testRecoveryFinishesOldFileCleanupAfterReferenceSwapCrash() async throws {
        let fixture = try CallRedactionFixture()
        let callID = try await fixture.makeEndedCall()
        let snapshot = try await fixture.repository.redactionSnapshot(callID: callID)
        let manifest = try CallRedactionPlanner(mediaRoot: fixture.mediaRoot).makeManifest(
            snapshot: snapshot,
            fromMs: 1_400,
            toMs: 1_600
        )
        let mutation = try await fixture.repository.beginRedaction(manifest: manifest, nowMs: 3_000)
        let mutationID = try XCTUnwrap(mutation.id)
        try CallRedactionFileStore(mediaRoot: fixture.mediaRoot).stageAndVerify(manifest)
        try await fixture.repository.commitRedactionReferenceSwap(
            mutationID: mutationID,
            manifest: manifest,
            nowMs: 3_100
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.originalURL.path))

        let report = try await CallRecoveryService(
            repository: fixture.repository,
            mediaRoot: fixture.mediaRoot
        ).recover(nowMs: 4_000)

        XCTAssertEqual(report.mutationsCompleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.originalURL.path))
        let state = try await fixture.database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM call_media_mutations WHERE id = ?", arguments: [mutationID])
        }
        XCTAssertEqual(state, CallMediaMutationState.completed.rawValue)
    }

    func testCorruptAcceptedManifestFallsBackToWholeEnvelopeErase() async throws {
        let fixture = try CallRedactionFixture()
        let callID = try await fixture.makeEndedCall()
        let snapshot = try await fixture.repository.redactionSnapshot(callID: callID)
        let manifest = try CallRedactionPlanner(mediaRoot: fixture.mediaRoot).makeManifest(
            snapshot: snapshot,
            fromMs: 1_400,
            toMs: 1_600
        )
        let mutation = try await fixture.repository.beginRedaction(manifest: manifest, nowMs: 3_000)
        let mutationID = try XCTUnwrap(mutation.id)
        try await fixture.database.pool.write { db in
            try db.execute(
                sql: "UPDATE call_media_mutations SET newRelativePathsJSON = '{broken' WHERE id = ?",
                arguments: [mutationID]
            )
        }

        let report = try await CallRecoveryService(
            repository: fixture.repository,
            mediaRoot: fixture.mediaRoot
        ).recover(nowMs: 4_000)

        XCTAssertEqual(report.mutationsCompleted, 0)
        XCTAssertEqual(report.mutationsRolledBack, 0)
        let counts = try await fixture.database.pool.read { db in
            (
                calls: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM calls WHERE id = ?", arguments: [callID]) ?? -1,
                mutations: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_media_mutations WHERE id = ?", arguments: [mutationID]) ?? -1
            )
        }
        XCTAssertEqual(counts.calls, 0)
        XCTAssertEqual(counts.mutations, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.originalURL.path))
    }

    func testStagedAndCleanupPendingRedactionFilesCountTowardEvidenceCap() async throws {
        let fixture = try CallRedactionFixture()
        let callID = try await fixture.makeEndedCall()
        let snapshot = try await fixture.repository.redactionSnapshot(callID: callID)
        let manifest = try CallRedactionPlanner(mediaRoot: fixture.mediaRoot).makeManifest(
            snapshot: snapshot,
            fromMs: 1_400,
            toMs: 1_600
        )
        let mutation = try await fixture.repository.beginRedaction(manifest: manifest, nowMs: 3_000)
        let mutationID = try XCTUnwrap(mutation.id)
        try CallRedactionFileStore(mediaRoot: fixture.mediaRoot).stageAndVerify(manifest)

        let stagedBytes = try await fixture.deletion.evidenceBytes()
        XCTAssertEqual(stagedBytes, 36)

        try await fixture.repository.commitRedactionReferenceSwap(
            mutationID: mutationID,
            manifest: manifest,
            nowMs: 3_100
        )
        try await fixture.repository.markMutation(
            mutationID,
            state: .cleanupPending,
            nowMs: 3_200,
            errorCode: "fixture"
        )
        let cleanupPendingBytes = try await fixture.deletion.evidenceBytes()
        XCTAssertEqual(cleanupPendingBytes, 36)
    }

    func testObsoleteCleanupRefusesIntermediateDirectorySymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-redaction-symlink-\(UUID().uuidString)", isDirectory: true)
        let mediaRoot = root.appendingPathComponent("media", isDirectory: true)
        let callsRoot = mediaRoot.appendingPathComponent("calls", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: callsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("secret.pcm")
        try Data([1, 2, 3, 4]).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: callsRoot.appendingPathComponent("999"),
            withDestinationURL: outside
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = CallRedactionManifestV1(
            formatVersion: 1,
            callID: 999,
            fromGeneration: 0,
            toGeneration: 1,
            fromMs: 1,
            toMs: 2,
            bytesRemoved: 4,
            obsoleteRelativePaths: ["calls/999/secret.pcm"],
            redactedGaps: [],
            survivors: []
        )

        XCTAssertThrowsError(
            try CallRedactionFileStore(mediaRoot: mediaRoot).removeObsolete(manifest)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    func testConcurrentWholeEraseCannotInterleaveWithAcceptedRedaction() async throws {
        let fixture = try CallRedactionFixture()
        let callID = try await fixture.makeEndedCall()
        let barrier = CallMutationBarrierProbe()
        await fixture.deletion.attachTranscriptWorker(
            suspend: { await barrier.suspend() },
            resume: {}
        )
        let redaction = Task {
            try await fixture.deletion.redact(
                callID: callID,
                fromMs: 1_400,
                toMs: 1_600,
                nowMs: 3_000
            )
        }
        await barrier.waitUntilEntered()

        var rejected = false
        do {
            _ = try await fixture.deletion.erase(callID: callID, nowMs: 3_100)
        } catch {
            rejected = true
        }
        XCTAssertTrue(rejected)
        await barrier.release()
        _ = try await redaction.value
        let generation = try await fixture.repository.mediaGeneration(callID: callID)
        XCTAssertNotNil(generation)
    }
}

private actor CallMutationBarrierProbe {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var suspensions = 0

    func suspend() async -> Bool {
        suspensions += 1
        guard suspensions == 1 else { return true }
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
        return true
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiter = continuation
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class CallRedactionFixture {
    let root: URL
    let mediaRoot: URL
    let database: ZBSEyeDatabase
    let repository: CallRepository
    let deletion: CallEvidenceDeletionService
    private(set) var callID: Int64?
    private(set) var originalURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-call-redaction-\(UUID().uuidString)", isDirectory: true)
        mediaRoot = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        repository = CallRepository(database: database)
        deletion = CallEvidenceDeletionService(repository: repository, mediaRoot: mediaRoot)
        originalURL = mediaRoot.appendingPathComponent("uninitialized")
    }

    deinit {
        try? database.pool.close()
        try? FileManager.default.removeItem(at: root)
    }

    func makeRecordingCall(
        key: String = "redaction",
        startMs: Int64 = 1_000
    ) async throws -> Int64 {
        let call = try await repository.createCall(startedAtMs: startMs, idempotencyKey: key)
        let callID = try XCTUnwrap(call.id)
        self.callID = callID
        let span = try await repository.recordSourceSpan(
            .init(
                callId: callID,
                source: .me,
                epoch: 0,
                sampleRate: 10,
                startedAtMs: startMs,
                startSample: 0,
                startHostTimeNs: 0,
                availability: .available
            )
        )
        let relativePath = "calls/\(callID)/me/epoch-0000/chunk-000000.pcm"
        originalURL = mediaRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: originalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let audio = pcm(samples: Array(0...9))
        try audio.write(to: originalURL)
        let digest = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
        _ = try await repository.recordAudioChunk(
            .init(
                callId: callID,
                sourceSpanId: try XCTUnwrap(span.id),
                source: .me,
                epoch: 0,
                sequence: 0,
                mediaGeneration: 0,
                startSample: 0,
                endSample: 10,
                startMs: startMs,
                endMs: startMs + 1_000,
                relativePath: relativePath,
                bytes: Int64(audio.count),
                sha256: digest,
                finalized: true
            )
        )
        return callID
    }

    func makeEndedCall(
        key: String = "redaction",
        startMs: Int64 = 1_000
    ) async throws -> Int64 {
        let callID = try await makeRecordingCall(key: key, startMs: startMs)
        _ = try await repository.endCall(
            callID: callID,
            idempotencyKey: "\(key)-end",
            endedAtMs: startMs + 1_000,
            meEndSample: 10
        )
        return callID
    }

    func makePreferredSpeakerRevision(callID: Int64) async throws -> CallSpeakerRevisionRow {
        let first = try await repository.createSpeakerRevision(
            callID: callID,
            mediaGeneration: 0,
            engine: "fixture",
            modelRevision: "fixture-v1",
            clusters: [
                CallSpeakerClusterDraft(
                    clusterKey: "system:S1",
                    displayName: "Olga",
                    namingProvenance: .manual,
                    intervals: [
                        CallSpeakerIntervalDraft(
                            source: .system,
                            startMs: 1_100,
                            endMs: 1_900
                        ),
                    ]
                ),
            ],
            nowMs: 2_500
        )
        try await repository.setPreferredSpeakerRevision(
            callID: callID,
            revisionID: try XCTUnwrap(first.id)
        )
        let corrected = try await repository.createSpeakerRevision(
            callID: callID,
            mediaGeneration: 0,
            engine: "manual",
            modelRevision: "annotation-v1",
            clusters: [
                CallSpeakerClusterDraft(
                    clusterKey: "system:S1",
                    displayName: "Olga Makhova",
                    namingProvenance: .manual,
                    intervals: [
                        CallSpeakerIntervalDraft(
                            source: .system,
                            startMs: 1_100,
                            endMs: 1_900
                        ),
                    ]
                ),
            ],
            nowMs: 2_600
        )
        try await repository.setPreferredSpeakerRevision(
            callID: callID,
            revisionID: try XCTUnwrap(corrected.id)
        )
        return corrected
    }

    func speakerPrivacyState(callID: Int64) async throws -> (
        preferredRevisionID: Int64?,
        revisions: Int,
        clusters: Int,
        intervals: Int
    ) {
        try await database.pool.read { db in
            (
                preferredRevisionID: try Int64.fetchOne(
                    db,
                    sql: "SELECT preferredSpeakerRevisionId FROM calls WHERE id = ?",
                    arguments: [callID]
                ),
                revisions: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_speaker_revisions WHERE callId = ?",
                    arguments: [callID]
                ) ?? -1,
                clusters: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_speaker_clusters"
                ) ?? -1,
                intervals: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_speaker_intervals"
                ) ?? -1
            )
        }
    }

    func appendSecondChunk(callID: Int64) async throws -> URL {
        let spanID = try await database.pool.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT id FROM call_source_spans WHERE callId = ? AND source = 'me' AND epoch = 0",
                arguments: [callID]
            )
        }
        let relativePath = "calls/\(callID)/me/epoch-0000/chunk-000001.pcm"
        let url = mediaRoot.appendingPathComponent(relativePath)
        let audio = pcm(samples: Array(10...19))
        try audio.write(to: url)
        let digest = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
        _ = try await repository.recordAudioChunk(
            .init(
                callId: callID,
                sourceSpanId: try XCTUnwrap(spanID),
                source: .me,
                epoch: 0,
                sequence: 1,
                mediaGeneration: 0,
                startSample: 10,
                endSample: 20,
                startMs: 2_000,
                endMs: 3_000,
                relativePath: relativePath,
                bytes: Int64(audio.count),
                sha256: digest,
                finalized: true
            )
        )
        return url
    }

    func appendSystemChunk(callID: Int64) async throws {
        let span = try await repository.recordSourceSpan(
            .init(
                callId: callID,
                source: .system,
                epoch: 0,
                sampleRate: 10,
                startedAtMs: 1_000,
                startSample: 0,
                startHostTimeNs: 0,
                availability: .available
            )
        )
        let relativePath = "calls/\(callID)/system/epoch-0000/chunk-000000.pcm"
        let url = mediaRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let audio = pcm(samples: Array(100...109))
        try audio.write(to: url)
        let digest = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
        _ = try await repository.recordAudioChunk(
            .init(
                callId: callID,
                sourceSpanId: try XCTUnwrap(span.id),
                source: .system,
                epoch: 0,
                sequence: 0,
                mediaGeneration: 0,
                startSample: 0,
                endSample: 10,
                startMs: 1_000,
                endMs: 2_000,
                relativePath: relativePath,
                bytes: Int64(audio.count),
                sha256: digest,
                finalized: true
            )
        )
    }

    func pcm(samples: [Int16]) -> Data {
        var result = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for var sample in samples {
            withUnsafeBytes(of: &sample) { result.append(contentsOf: $0) }
        }
        return result
    }
}
