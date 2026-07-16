import GRDB
import XCTest

final class CallFinalPromotionTests: XCTestCase {
    func testFinalJobOutranksPendingCheckpoint() async throws {
        let fixture = try CallTranscriptRepositoryFixture()
        let call = try await fixture.makeCall(startedAtMs: 1_000)
        _ = try await fixture.makeBookmark(
            callID: call,
            key: "bookmark-1",
            ordinalStartMs: 1_000,
            endMs: 2_000
        )
        let final = try await fixture.repository.endCall(
            callID: call,
            idempotencyKey: "end",
            endedAtMs: 3_000
        )

        let claimed = try await fixture.repository.claimNextTranscriptJob(nowMs: 4_000)

        XCTAssertEqual(claimed?.id, final.id)
        XCTAssertEqual(claimed?.kind, .final)
        XCTAssertEqual(claimed?.state, .running)
        XCTAssertEqual(claimed?.attempts, 1)
    }

    func testCheckpointCommitRebuildsPreferredProjectionWithoutRepeatedOverlap() async throws {
        let fixture = try CallTranscriptRepositoryFixture()
        let call = try await fixture.makeCall(startedAtMs: 1_000)
        let first = try await fixture.makeBookmark(
            callID: call,
            key: "bookmark-1",
            ordinalStartMs: 1_000,
            endMs: 2_000
        )
        let firstCandidate = try await fixture.repository.claimNextTranscriptJob(nowMs: 2_100)
        let firstClaim = try XCTUnwrap(firstCandidate)
        XCTAssertEqual(firstClaim.id, first.job.id)
        _ = try await fixture.repository.commitTranscriptJob(
            jobID: try XCTUnwrap(firstClaim.id),
            segments: [
                .init(source: .me, startMs: 1_100, endMs: 1_900, text: "first phrase"),
            ],
            language: "en",
            engine: "fixture",
            modelRevision: "fixture-v1",
            degraded: false,
            nowMs: 2_200
        )

        let second = try await fixture.makeBookmark(
            callID: call,
            key: "bookmark-2",
            ordinalStartMs: 2_000,
            endMs: 3_000
        )
        let secondCandidate = try await fixture.repository.claimNextTranscriptJob(nowMs: 3_100)
        let secondClaim = try XCTUnwrap(secondCandidate)
        XCTAssertEqual(secondClaim.id, second.job.id)
        let result = try await fixture.repository.commitTranscriptJob(
            jobID: try XCTUnwrap(secondClaim.id),
            segments: [
                .init(source: .me, startMs: 1_500, endMs: 2_900, text: "first phrase next point"),
            ],
            language: "en",
            engine: "fixture",
            modelRevision: "fixture-v1",
            degraded: false,
            nowMs: 3_200
        )

        let snapshot = try await fixture.database.pool.read { db in
            (
                preferredText: try String.fetchOne(
                    db,
                    sql: "SELECT text FROM call_transcript_revisions WHERE id = ?",
                    arguments: [result.preferredRevisionID]
                ),
                ftsFirst: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_fts WHERE call_transcript_fts MATCH 'first'"
                ) ?? 0,
                ftsNext: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_fts WHERE call_transcript_fts MATCH 'next'"
                ) ?? 0
            )
        }
        XCTAssertEqual(snapshot.preferredText, "first phrase\nnext point")
        XCTAssertEqual(snapshot.ftsFirst, 1)
        XCTAssertEqual(snapshot.ftsNext, 1)
        XCTAssertFalse(result.final)
    }

    func testEarlierRetryRebasesProjectionInBookmarkOrder() async throws {
        let fixture = try CallTranscriptRepositoryFixture()
        let call = try await fixture.makeCall(startedAtMs: 1_000)
        let first = try await fixture.makeBookmark(
            callID: call,
            key: "bookmark-1",
            ordinalStartMs: 1_000,
            endMs: 2_000
        )
        let second = try await fixture.makeBookmark(
            callID: call,
            key: "bookmark-2",
            ordinalStartMs: 2_000,
            endMs: 3_000
        )

        try await fixture.database.pool.write { db in
            try db.execute(
                sql: "UPDATE call_transcript_jobs SET state = ? WHERE id = ?",
                arguments: [CallTranscriptJobState.failed.rawValue, first.job.id]
            )
            try db.execute(
                sql: "UPDATE call_bookmarks SET state = ? WHERE id = ?",
                arguments: [CallBookmarkState.failed.rawValue, first.bookmark.id]
            )
        }
        let secondCandidate = try await fixture.repository.claimNextTranscriptJob(nowMs: 3_100)
        let secondClaim = try XCTUnwrap(secondCandidate)
        XCTAssertEqual(secondClaim.id, second.job.id)
        _ = try await fixture.repository.commitTranscriptJob(
            jobID: try XCTUnwrap(secondClaim.id),
            segments: [.init(source: .system, startMs: 2_100, endMs: 2_900, text: "second")],
            language: "en",
            engine: "fixture",
            modelRevision: "fixture-v1",
            degraded: false,
            nowMs: 3_200
        )
        let gapBeforeRetry = try await fixture.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM call_transcript_projection_gaps g
                    JOIN calls c ON c.preferredRevisionId = g.revisionId
                    WHERE c.id = ?
                    """,
                arguments: [call]
            ) ?? 0
        }
        XCTAssertEqual(gapBeforeRetry, 1)
        try await fixture.database.pool.write { db in
            try db.execute(
                sql: "UPDATE call_transcript_jobs SET state = ?, errorCode = NULL WHERE id = ?",
                arguments: [CallTranscriptJobState.pending.rawValue, first.job.id]
            )
            try db.execute(
                sql: "UPDATE call_bookmarks SET state = ? WHERE id = ?",
                arguments: [CallBookmarkState.pending.rawValue, first.bookmark.id]
            )
        }
        let firstRetryCandidate = try await fixture.repository.claimNextTranscriptJob(nowMs: 3_300)
        let firstRetry = try XCTUnwrap(firstRetryCandidate)
        XCTAssertEqual(firstRetry.id, first.job.id)
        let result = try await fixture.repository.commitTranscriptJob(
            jobID: try XCTUnwrap(firstRetry.id),
            segments: [.init(source: .me, startMs: 1_100, endMs: 1_900, text: "first")],
            language: "en",
            engine: "fixture",
            modelRevision: "fixture-v1",
            degraded: false,
            nowMs: 3_400
        )

        let preferred = try await fixture.database.pool.read { db in
            (
                text: try String.fetchOne(
                    db,
                    sql: "SELECT text FROM call_transcript_revisions WHERE id = ?",
                    arguments: [result.preferredRevisionID]
                ),
                gaps: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_projection_gaps WHERE revisionId = ?",
                    arguments: [result.preferredRevisionID]
                ) ?? 0
            )
        }
        XCTAssertEqual(preferred.text, "first\nsecond")
        XCTAssertEqual(preferred.gaps, 0)
    }

    func testFinalPromotionIsCanonicalAndSatisfiesUnstartedCheckpoints() async throws {
        let fixture = try CallTranscriptRepositoryFixture()
        let call = try await fixture.makeCall(startedAtMs: 1_000)
        let checkpoint = try await fixture.makeBookmark(
            callID: call,
            key: "bookmark-1",
            ordinalStartMs: 1_000,
            endMs: 2_000
        )
        let checkpointCandidate = try await fixture.repository.claimNextTranscriptJob(nowMs: 2_100)
        let checkpointClaim = try XCTUnwrap(checkpointCandidate)
        _ = try await fixture.repository.commitTranscriptJob(
            jobID: try XCTUnwrap(checkpointClaim.id),
            segments: [.init(source: .me, startMs: 1_100, endMs: 1_900, text: "draft words")],
            language: "en",
            engine: "fixture",
            modelRevision: "fixture-v1",
            degraded: false,
            nowMs: 2_200
        )
        let late = try await fixture.makeBookmark(
            callID: call,
            key: "bookmark-2",
            ordinalStartMs: 2_000,
            endMs: 3_000
        )
        _ = try await fixture.repository.endCall(
            callID: call,
            idempotencyKey: "end",
            endedAtMs: 4_000
        )
        let finalCandidate = try await fixture.repository.claimNextTranscriptJob(nowMs: 4_100)
        let finalClaim = try XCTUnwrap(finalCandidate)
        XCTAssertEqual(finalClaim.kind, .final)
        let final = try await fixture.repository.commitTranscriptJob(
            jobID: try XCTUnwrap(finalClaim.id),
            segments: [
                .init(source: .me, startMs: 1_100, endMs: 1_900, text: "authoritative"),
                .init(source: .system, startMs: 2_100, endMs: 2_900, text: "final words"),
            ],
            language: "en",
            engine: "fixture",
            modelRevision: "fixture-v1",
            degraded: false,
            nowMs: 4_200
        )

        let snapshot = try await fixture.database.pool.read { db in
            (
                call: try XCTUnwrap(CallRow.fetchOne(db, key: call)),
                finalRevision: try XCTUnwrap(CallTranscriptRevisionRow.fetchOne(db, key: final.preferredRevisionID)),
                lateJob: try XCTUnwrap(CallTranscriptJobRow.fetchOne(db, key: late.job.id)),
                lateBookmark: try XCTUnwrap(CallBookmarkRow.fetchOne(db, key: late.bookmark.id)),
                indexedDrafts: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_fts WHERE call_transcript_fts MATCH 'draft'"
                ) ?? 0,
                indexedFinal: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_fts WHERE call_transcript_fts MATCH 'authoritative'"
                ) ?? 0,
                vectorJobs: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM embed_queue WHERE row_id = ? AND kind = 2",
                    arguments: [final.preferredRevisionID]
                ) ?? 0
            )
        }
        XCTAssertEqual(snapshot.call.state, .ready)
        XCTAssertEqual(snapshot.call.preferredRevisionId, final.preferredRevisionID)
        XCTAssertEqual(snapshot.finalRevision.kind, .final)
        XCTAssertEqual(snapshot.lateJob.state, .satisfiedByFinal)
        XCTAssertEqual(snapshot.lateBookmark.state, .satisfiedByFinal)
        XCTAssertEqual(snapshot.indexedDrafts, 0)
        XCTAssertEqual(snapshot.indexedFinal, 1)
        XCTAssertEqual(snapshot.vectorJobs, 1)
        XCTAssertEqual(checkpoint.bookmark.ordinal, 1)
        XCTAssertTrue(final.final)
    }

    func testPermanentFinalFailureKeepsDraftEvidenceButEndsInHonestFailedState() async throws {
        let fixture = try CallTranscriptRepositoryFixture()
        let call = try await fixture.makeCall(startedAtMs: 1_000)
        let checkpoint = try await fixture.makeBookmark(
            callID: call,
            key: "bookmark",
            ordinalStartMs: 1_000,
            endMs: 2_000
        )
        let checkpointCandidate = try await fixture.repository.claimNextTranscriptJob(nowMs: 2_100)
        let checkpointClaim = try XCTUnwrap(checkpointCandidate)
        _ = try await fixture.repository.commitTranscriptJob(
            jobID: try XCTUnwrap(checkpointClaim.id),
            segments: [.init(source: .me, startMs: 1_100, endMs: 1_900, text: "preserved draft")],
            language: "en",
            engine: "fixture",
            modelRevision: "fixture-v1",
            degraded: false,
            nowMs: 2_200
        )
        _ = try await fixture.repository.endCall(
            callID: call,
            idempotencyKey: "end",
            endedAtMs: 3_000
        )
        let finalCandidate = try await fixture.repository.claimNextTranscriptJob(nowMs: 3_100)
        let final = try XCTUnwrap(finalCandidate)
        XCTAssertEqual(final.kind, .final)

        try await fixture.repository.failTranscriptJob(
            jobID: try XCTUnwrap(final.id),
            errorCode: "invalid_helper_result",
            retryable: false,
            nowMs: 3_200
        )

        let snapshot = try await fixture.database.pool.read { db in
            (
                call: try XCTUnwrap(CallRow.fetchOne(db, key: call)),
                preferredText: try String.fetchOne(
                    db,
                    sql: """
                        SELECT r.text FROM calls c
                        JOIN call_transcript_revisions r ON r.id = c.preferredRevisionId
                        WHERE c.id = ?
                        """,
                    arguments: [call]
                ),
                bookmark: try XCTUnwrap(CallBookmarkRow.fetchOne(db, key: checkpoint.bookmark.id))
            )
        }
        XCTAssertEqual(snapshot.call.state, .failed)
        XCTAssertEqual(snapshot.call.degradationReason, "invalid_helper_result")
        XCTAssertEqual(snapshot.preferredText, "preserved draft")
        XCTAssertEqual(snapshot.bookmark.state, .ready)
    }

    func testFinalPromotionReleasesGlobalCapacityForOtherCallsFIFO() async throws {
        let fixture = try CallTranscriptRepositoryFixture()
        let firstCall = try await fixture.makeCall(startedAtMs: 1_000)
        for index in 0..<32 {
            _ = try await fixture.makeBookmark(
                callID: firstCall,
                key: "first-\(index)",
                ordinalStartMs: 1_000 + Int64(index) * 1_000,
                endMs: 2_000 + Int64(index) * 1_000
            )
        }
        _ = try await fixture.repository.endCall(
            callID: firstCall,
            idempotencyKey: "first-end",
            endedAtMs: 40_000
        )

        let secondCall = try await fixture.makeCall(startedAtMs: 100_000)
        for index in 0..<32 {
            _ = try await fixture.makeBookmark(
                callID: secondCall,
                key: "second-\(index)",
                ordinalStartMs: 100_000 + Int64(index) * 1_000,
                endMs: 101_000 + Int64(index) * 1_000
            )
        }
        _ = try await fixture.repository.endCall(
            callID: secondCall,
            idempotencyKey: "second-end",
            endedAtMs: 140_000
        )

        let thirdCall = try await fixture.makeCall(startedAtMs: 200_000)
        let deferred = try await fixture.makeBookmark(
            callID: thirdCall,
            key: "third-0",
            ordinalStartMs: 200_000,
            endMs: 201_000
        )
        _ = try await fixture.repository.endCall(
            callID: thirdCall,
            idempotencyKey: "third-end",
            endedAtMs: 202_000
        )
        let before = try await fixture.database.pool.read { db in
            try XCTUnwrap(CallTranscriptJobRow.fetchOne(db, key: deferred.job.id))
        }
        XCTAssertEqual(before.state, .deferredCapacity)

        let firstFinalCandidate = try await fixture.repository.claimNextTranscriptJob(nowMs: 300_000)
        let firstFinal = try XCTUnwrap(firstFinalCandidate)
        XCTAssertEqual(firstFinal.callId, firstCall)
        XCTAssertEqual(firstFinal.kind, .final)
        _ = try await fixture.repository.commitTranscriptJob(
            jobID: try XCTUnwrap(firstFinal.id),
            segments: [],
            language: "und",
            engine: "fixture",
            modelRevision: "fixture-v1",
            degraded: true,
            nowMs: 300_100
        )

        let admitted = try await fixture.database.pool.read { db in
            try XCTUnwrap(CallTranscriptJobRow.fetchOne(db, key: deferred.job.id))
        }
        XCTAssertEqual(admitted.state, .pending)
        XCTAssertNil(admitted.errorCode)
    }
}

private final class CallTranscriptRepositoryFixture {
    let root: URL
    let database: ZBSEyeDatabase
    let repository: CallRepository

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-call-transcript-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        repository = CallRepository(database: database)
    }

    func makeCall(startedAtMs: Int64) async throws -> Int64 {
        let call = try await repository.createCall(
            startedAtMs: startedAtMs,
            idempotencyKey: "call-\(startedAtMs)"
        )
        return try XCTUnwrap(call.id)
    }

    func makeBookmark(
        callID: Int64,
        key: String,
        ordinalStartMs: Int64,
        endMs: Int64
    ) async throws -> CallBookmarkCreation {
        let created = try await repository.createBookmark(
            callID: callID,
            idempotencyKey: key,
            acceptedAtMs: endMs,
            meIngressTarget: 16_000,
            systemIngressTarget: 16_000,
            logicalStartMs: ordinalStartMs,
            logicalEndMs: endMs,
            contextStartMs: max(1_000, ordinalStartMs - 45_000)
        )
        _ = try await repository.freezeBookmarkCoverage(
            bookmarkID: try XCTUnwrap(created.bookmark.id),
            jobID: try XCTUnwrap(created.job.id),
            meEndSample: 16_000,
            systemEndSample: 16_000,
            degraded: false,
            nowMs: endMs
        )
        return created
    }

    deinit {
        try? database.pool.close()
        try? FileManager.default.removeItem(at: root)
    }
}
