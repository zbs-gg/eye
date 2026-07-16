import GRDB
import XCTest

final class CallEvidenceQueryServiceTests: XCTestCase {
    func testReadsOneEnvelopeAndBoundsTranscriptPages() async throws {
        let fixture = try QueryFixture()
        let call = try await fixture.repository.createCall(
            startedAtMs: 1_000,
            idempotencyKey: "call"
        )
        let callID = try XCTUnwrap(call.id)
        _ = try await fixture.repository.recordSourceSpan(
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
        let bookmark = try await fixture.repository.createBookmark(
            callID: callID,
            idempotencyKey: "bookmark",
            acceptedAtMs: 2_000,
            meIngressTarget: nil,
            systemIngressTarget: nil,
            logicalStartMs: 1_000,
            logicalEndMs: 2_000,
            contextStartMs: 1_000
        )
        _ = try await fixture.repository.freezeBookmarkCoverage(
            bookmarkID: try XCTUnwrap(bookmark.bookmark.id),
            jobID: try XCTUnwrap(bookmark.job.id),
            meEndSample: nil,
            systemEndSample: nil,
            degraded: false,
            nowMs: 2_000
        )
        let claimedCheckpoint = try await fixture.repository.claimNextTranscriptJob(nowMs: 2_001)
        let checkpoint = try XCTUnwrap(claimedCheckpoint)
        _ = try await fixture.repository.commitTranscriptJob(
            jobID: try XCTUnwrap(checkpoint.id),
            segments: [segment(.me, 1_100, 1_900, "bookmark text")],
            language: "en",
            engine: "fixture",
            modelRevision: "fixture",
            degraded: false,
            nowMs: 2_100
        )

        let provisionalPage = try await fixture.service.call(id: callID, segmentLimit: 20)
        let provisional = try XCTUnwrap(provisionalPage)
        XCTAssertEqual(provisional.call.id, callID)
        XCTAssertEqual(provisional.bookmarks.map(\.ordinal), [1])
        XCTAssertEqual(provisional.sourceSpans.map(\.source), [.me])
        XCTAssertEqual(provisional.preferredRevision?.kind, .projection)
        XCTAssertEqual(provisional.segments.map(\.text), ["bookmark text"])

        _ = try await fixture.repository.endCall(
            callID: callID,
            idempotencyKey: "end",
            endedAtMs: 3_000
        )
        let claimedFinal = try await fixture.repository.claimNextTranscriptJob(nowMs: 3_001)
        let final = try XCTUnwrap(claimedFinal)
        let finalSegments = (0..<205).map { index in
            segment(.me, 1_000 + Int64(index), 1_001 + Int64(index), "line \(index)")
        }
        _ = try await fixture.repository.commitTranscriptJob(
            jobID: try XCTUnwrap(final.id),
            segments: finalSegments,
            language: "en",
            engine: "fixture",
            modelRevision: "fixture",
            degraded: false,
            nowMs: 3_100
        )

        let firstPage = try await fixture.service.call(id: callID, segmentLimit: 500)
        let first = try XCTUnwrap(firstPage)
        XCTAssertEqual(first.segments.count, CallEvidenceQueryService.maximumSegmentPage)
        XCTAssertTrue(first.hasMoreSegments)
        XCTAssertEqual(first.preferredRevision?.kind, .final)
        let secondPage = try await fixture.service.call(
            id: callID,
            segmentOffset: first.segments.count,
            segmentLimit: 80
        )
        let second = try XCTUnwrap(secondPage)
        XCTAssertEqual(second.segments.count, 5)
        XCTAssertFalse(second.hasMoreSegments)
    }

    func testLatestCallUsesStartTimeThenIdentityDeterministically() async throws {
        let fixture = try QueryFixture()
        let old = try await fixture.repository.createCall(startedAtMs: 1_000, idempotencyKey: "old")
        _ = try await fixture.repository.endCall(
            callID: try XCTUnwrap(old.id),
            idempotencyKey: "old-end",
            endedAtMs: 1_500
        )
        let latest = try await fixture.repository.createCall(startedAtMs: 2_000, idempotencyKey: "new")

        let latestPage = try await fixture.service.latestCall(segmentLimit: 1)
        let page = try XCTUnwrap(latestPage)

        XCTAssertEqual(page.call.id, latest.id)
    }

    func testRetryRequeuesOnlyTheCurrentFailedFinalAndKeepsEvidence() async throws {
        let fixture = try QueryFixture()
        let call = try await fixture.repository.createCall(
            startedAtMs: 1_000,
            idempotencyKey: "retry-call"
        )
        let callID = try XCTUnwrap(call.id)
        _ = try await fixture.repository.endCall(
            callID: callID,
            idempotencyKey: "retry-end",
            endedAtMs: 2_000
        )
        let claimed = try await fixture.repository.claimNextTranscriptJob(nowMs: 2_100)
        let final = try XCTUnwrap(claimed)
        try await fixture.repository.failTranscriptJob(
            jobID: try XCTUnwrap(final.id),
            errorCode: "helper_failed",
            retryable: false,
            nowMs: 2_200
        )

        try await fixture.repository.retryFinalTranscript(callID: callID, nowMs: 2_300)

        let retryPage = try await fixture.service.call(id: callID, segmentLimit: 1)
        let page = try XCTUnwrap(retryPage)
        XCTAssertEqual(page.call.state, .finalizing)
        XCTAssertEqual(page.finalJob?.state, .pending)
        XCTAssertNil(page.finalJob?.errorCode)
    }

    func testSuccessfulRetryClearsOnlyTransientFailureAndPresentsCleanFinal() async throws {
        let fixture = try QueryFixture()
        let call = try await fixture.repository.createCall(
            startedAtMs: 1_000,
            idempotencyKey: "retry-clean-call"
        )
        let callID = try XCTUnwrap(call.id)
        _ = try await fixture.repository.endCall(
            callID: callID,
            idempotencyKey: "retry-clean-end",
            endedAtMs: 2_000
        )
        let firstClaimCandidate = try await fixture.repository.claimNextTranscriptJob(nowMs: 2_100)
        let firstClaim = try XCTUnwrap(firstClaimCandidate)
        try await fixture.repository.failTranscriptJob(
            jobID: try XCTUnwrap(firstClaim.id),
            errorCode: "invalid_helper_result",
            retryable: false,
            nowMs: 2_200
        )

        try await fixture.repository.retryFinalTranscript(callID: callID, nowMs: 2_300)
        let retryClaimCandidate = try await fixture.repository.claimNextTranscriptJob(nowMs: 2_400)
        let retryClaim = try XCTUnwrap(retryClaimCandidate)
        _ = try await fixture.repository.commitTranscriptJob(
            jobID: try XCTUnwrap(retryClaim.id),
            segments: [segment(.me, 1_100, 1_900, "clean final")],
            language: "en",
            engine: "fixture",
            modelRevision: "fixture",
            degraded: false,
            nowMs: 2_500
        )

        let pageCandidate = try await fixture.service.call(id: callID, segmentLimit: 10)
        let page = try XCTUnwrap(pageCandidate)
        XCTAssertEqual(page.call.state, .ready)
        XCTAssertNil(page.call.degradationReason)
        XCTAssertEqual(page.preferredRevision?.kind, .final)
        XCTAssertEqual(
            CallPresentationState.resolve(evidence: page, modelState: .ready).kind,
            .ready
        )
    }

    private func segment(
        _ source: CallAudioSource,
        _ startMs: Int64,
        _ endMs: Int64,
        _ text: String
    ) -> CallTranscriptSegmentDraft {
        CallTranscriptSegmentDraft(
            source: source,
            startMs: startMs,
            endMs: endMs,
            text: text
        )
    }
}

private final class QueryFixture {
    let root: URL
    let database: ZBSEyeDatabase
    let repository: CallRepository
    let service: CallEvidenceQueryService

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-call-query-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        repository = CallRepository(database: database)
        service = CallEvidenceQueryService(database: database)
    }

    deinit {
        try? database.pool.close()
        try? FileManager.default.removeItem(at: root)
    }
}
