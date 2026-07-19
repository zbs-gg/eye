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

        let pendingBookmark = try await fixture.repository.createBookmark(
            callID: callID,
            idempotencyKey: "pending-bookmark",
            acceptedAtMs: 2_500,
            meIngressTarget: nil,
            systemIngressTarget: nil,
            logicalStartMs: 2_000,
            logicalEndMs: 2_500,
            contextStartMs: 1_000
        )
        _ = try await fixture.repository.freezeBookmarkCoverage(
            bookmarkID: try XCTUnwrap(pendingBookmark.bookmark.id),
            jobID: try XCTUnwrap(pendingBookmark.job.id),
            meEndSample: nil,
            systemEndSample: nil,
            degraded: false,
            nowMs: 2_500
        )
        let pendingTranscript = try await fixture.service.transcript(
            callID: callID,
            selector: .bookmark,
            bookmarkID: try XCTUnwrap(pendingBookmark.bookmark.id)
        )
        XCTAssertNil(pendingTranscript.revision)
        XCTAssertTrue(pendingTranscript.segments.isEmpty)

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

    func testBroadFTSSearchKeepsNewestMatchesBeforeSafetyCap() async throws {
        let fixture = try QueryFixture()
        try await fixture.database.pool.write { db in
            for index in 1...5_001 {
                try db.execute(
                    sql: """
                        INSERT INTO calls(
                            startIdempotencyKey, endIdempotencyKey, startTs, endTs,
                            state, interrupted, mediaGeneration, createdAtMs, updatedAtMs
                        ) VALUES (?, ?, ?, ?, 'ready', 0, 0, ?, ?)
                        """,
                    arguments: ["search-\(index)", "end-\(index)", index, index, index, index]
                )
                let callID = db.lastInsertedRowID
                try db.execute(
                    sql: "INSERT INTO call_transcript_fts(revision_id, call_id, text) VALUES (?, ?, 'needle')",
                    arguments: [callID, callID]
                )
            }
        }

        let page = try await fixture.service.listCalls(query: "needle", limit: 3, offset: 0)

        XCTAssertEqual(page.calls.map(\.startTs), [5_001, 5_000, 4_999])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextOffset, 3)

        let tail = try await fixture.service.listCalls(query: "needle", limit: 1, offset: 4_999)
        XCTAssertEqual(tail.calls.map(\.startTs), [2])
        XCTAssertTrue(tail.hasMore)
        XCTAssertEqual(tail.nextOffset, 5_000)
    }

    func testCallListUsesSharedMetadataSpeakerAndBookmarkProjection() async throws {
        let fixture = try QueryFixture()
        let call = try await fixture.repository.createCall(startedAtMs: 1_000, idempotencyKey: "library-call")
        let callID = try XCTUnwrap(call.id)
        try await fixture.repository.upsertCallContext(
            CallContextRow(
                callId: callID,
                captureOwner: .automatic,
                disposition: .confirmed,
                detectorFingerprintHash: "sha256:library",
                sourceAppBundleID: "us.zoom.xos",
                sourceAppName: "Zoom",
                trustedOriginHost: nil,
                title: "Client call Olga",
                participantsJSON: "[\"Olga\"]",
                createdAtMs: 1_000,
                updatedAtMs: 1_100
            )
        )
        _ = try await fixture.repository.createBookmark(
            callID: callID,
            idempotencyKey: "library-bookmark",
            acceptedAtMs: 1_200,
            meIngressTarget: nil,
            systemIngressTarget: nil,
            logicalStartMs: 1_000,
            logicalEndMs: 1_200,
            contextStartMs: 1_000
        )
        let revision = try await fixture.repository.createSpeakerRevision(
            callID: callID,
            mediaGeneration: 0,
            engine: "fixture",
            modelRevision: "fixture-v1",
            clusters: [
                CallSpeakerClusterDraft(
                    clusterKey: "speaker-1",
                    displayName: "Olga",
                    namingProvenance: .currentCall,
                    intervals: [.init(source: .system, startMs: 1_000, endMs: 1_200)]
                ),
            ],
            nowMs: 1_300
        )
        try await fixture.repository.setPreferredSpeakerRevision(
            callID: callID,
            revisionID: try XCTUnwrap(revision.id)
        )

        let page = try await fixture.service.listCalls(query: "Olga", limit: 10)
        let item = try XCTUnwrap(page.calls.first)
        XCTAssertEqual(item.callId, "call:\(callID)")
        XCTAssertEqual(item.title, "Client call Olga")
        XCTAssertEqual(item.participants, ["Olga"])
        XCTAssertEqual(item.sourceApp, "Zoom")
        XCTAssertEqual(item.bookmarkCount, 1)
        XCTAssertEqual(item.speakerStatus, .ready)

        let envelopeCandidate = try await fixture.service.envelope(callID: callID)
        let envelope = try XCTUnwrap(envelopeCandidate)
        XCTAssertEqual(envelope.context?.captureOwner, .automatic)
        XCTAssertEqual(envelope.context?.disposition, .confirmed)
        XCTAssertEqual(envelope.context?.title, "Client call Olga")
        XCTAssertEqual(envelope.context?.participants, ["Olga"])
        XCTAssertEqual(envelope.context?.sourceApp, "Zoom")
        XCTAssertEqual(envelope.preferredSpeakerRevision?.state, .ready)
        XCTAssertEqual(envelope.preferredSpeakerRevision?.speakers.map(\.label), ["Olga"])
        XCTAssertEqual(
            envelope.preferredSpeakerRevision?.speakers.first?.intervals,
            [CallEvidenceSpeakerInterval(source: .system, startMs: 1_000, endMs: 1_200)]
        )
        XCTAssertEqual(envelope.preferredSpeakerRevision?.intervalsTruncated, false)
    }

    func testCallListReportsLatestFailedSpeakerProcessingInsteadOfSpinningForever() async throws {
        let fixture = try QueryFixture()
        let call = try await fixture.repository.createCall(
            startedAtMs: 1_000,
            idempotencyKey: "speaker-failure"
        )
        let callID = try XCTUnwrap(call.id)
        let finalJob = try await fixture.repository.endCall(
            callID: callID,
            idempotencyKey: "speaker-failure-end",
            endedAtMs: 2_000
        )
        _ = try await fixture.repository.claimNextTranscriptJob(nowMs: 2_100)
        let finalRevision = try await fixture.repository.commitTranscriptJob(
            jobID: try XCTUnwrap(finalJob.id),
            segments: [segment(.system, 1_000, 2_000, "hello")],
            language: "en",
            engine: "fixture",
            modelRevision: "fixture",
            degraded: false,
            nowMs: 2_200
        )
        let writing = try await fixture.repository.beginInitialSpeakerRevision(
            callID: callID,
            mediaGeneration: 0,
            expectedTranscriptRevisionID: finalRevision.preferredRevisionID,
            engine: "FluidAudio",
            modelRevision: "fixture",
            nowMs: 2_300
        )
        try await fixture.repository.failInitialSpeakerRevision(
            revisionID: try XCTUnwrap(writing.id)
        )

        let page = try await fixture.service.listCalls(limit: 10)

        XCTAssertEqual(page.calls.first?.speakerStatus, .degraded)
        let envelopeCandidate = try await fixture.service.envelope(callID: callID)
        let envelope = try XCTUnwrap(envelopeCandidate)
        let encoded = try JSONEncoder().encode(envelope)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(json.contains(#""speakerStatus":"degraded""#))

        try await fixture.repository.retrySpeakerDiarization(callID: callID)
        let retried = try await fixture.service.listCalls(limit: 10)
        XCTAssertEqual(retried.calls.first?.speakerStatus, .unavailable)
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
