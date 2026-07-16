import GRDB
import XCTest

final class CallAPITests: XCTestCase {
    func testSharedContractListsAndReadsReadyMicOnlyCallWithoutLeakingPaths() async throws {
        let fixture = try CallAgentFixture()
        let ids = try await fixture.makeReadyCall(segmentCount: 3, micOnly: true)

        let list = try await fixture.service.listCalls(query: "line", limit: 10, offset: 0)
        XCTAssertEqual(list.calls.map(\.callId), [CallEvidenceIdentifier.call(ids.callID)])
        XCTAssertEqual(list.calls.first?.status, .degraded)
        XCTAssertFalse(list.calls.first?.retryable ?? true)

        let envelopeCandidate = try await fixture.service.envelope(callID: ids.callID)
        let envelope = try XCTUnwrap(envelopeCandidate)
        XCTAssertEqual(envelope.callId, CallEvidenceIdentifier.call(ids.callID))
        XCTAssertEqual(envelope.preferredRevision?.kind, .final)
        XCTAssertEqual(envelope.sources.first(where: { $0.source == .me })?.health, .available)
        XCTAssertEqual(envelope.sources.first(where: { $0.source == .system })?.health, .missing)
        XCTAssertEqual(envelope.bookmarkCount, 1)
        XCTAssertFalse(envelope.evidence.isEmpty)

        let bookmarks = try await fixture.service.bookmarks(callID: ids.callID, limit: 10, offset: 0)
        XCTAssertEqual(bookmarks.bookmarks.map(\.bookmarkId), [CallEvidenceIdentifier.bookmark(ids.bookmarkID)])

        let transcript = try await fixture.service.transcript(
            callID: ids.callID,
            selector: .preferred,
            bookmarkID: nil,
            limit: 2,
            offset: 0
        )
        XCTAssertEqual(transcript.segments.map(\.text), ["line 0", "line 1"])
        XCTAssertTrue(transcript.hasMore)
        XCTAssertEqual(transcript.nextOffset, 2)

        let checkpoint = try await fixture.service.transcript(
            callID: ids.callID,
            selector: .bookmark,
            bookmarkID: ids.bookmarkID,
            limit: 10,
            offset: 0
        )
        XCTAssertEqual(checkpoint.revision?.kind, .interval)
        XCTAssertEqual(checkpoint.segments.map(\.text), ["bookmark"])

        let evidenceID = try XCTUnwrap(envelope.evidence.first?.evidenceId)
        let resolvedEvidence = try await fixture.service.audioEvidence(reference: evidenceID)
        XCTAssertNotNil(resolvedEvidence)
        let forgedEvidence = try await fixture.service.audioEvidence(reference: "call-audio-chunk:999999")
        XCTAssertNil(forgedEvidence)

        let encoded = try JSONEncoder().encode(envelope)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains(fixture.root.path))
        XCTAssertFalse(json.contains("relativePath"))
        XCTAssertFalse(json.contains("speaker"))
    }

    func testContractRejectsForgedIDsUnknownSelectorsOversizedPagesAndUnsafeMediaPaths() throws {
        XCTAssertEqual(CallEvidenceIdentifier.parseCall("call:42"), 42)
        XCTAssertNil(CallEvidenceIdentifier.parseCall("42"))
        XCTAssertNil(CallEvidenceIdentifier.parseCall("call:-1"))
        XCTAssertNil(CallEvidenceIdentifier.parseBookmark("call:42"))
        XCTAssertNil(CallTranscriptSelector(rawValue: "latest"))
        XCTAssertThrowsError(try CallEvidencePageRequest(limit: 101, offset: 0))
        XCTAssertThrowsError(try CallEvidencePageRequest(limit: 10, offset: -1))
        XCTAssertThrowsError(try CallEvidencePageRequest(limit: 10, offset: Int.max))

        let root = URL(fileURLWithPath: "/tmp/managed-media", isDirectory: true)
        XCTAssertNil(ManagedMediaResolver.url(relativePath: "../secret", mediaRoot: root))
        XCTAssertNil(ManagedMediaResolver.url(relativePath: "/tmp/secret", mediaRoot: root))
        XCTAssertNotNil(ManagedMediaResolver.url(relativePath: "calls/1/chunk.pcm", mediaRoot: root))

        XCTAssertTrue(APILocalAuthorization.allows(
            hostHeader: "127.0.0.1:8731",
            authorizationHeader: "Bearer secret",
            token: "secret"
        ))
        XCTAssertFalse(APILocalAuthorization.allows(
            hostHeader: "127.0.0.1:8731",
            authorizationHeader: nil,
            token: "secret"
        ))
        XCTAssertFalse(APILocalAuthorization.allows(
            hostHeader: "127.0.0.1:8731",
            authorizationHeader: "Bearer wrong",
            token: "secret"
        ))
        XCTAssertFalse(APILocalAuthorization.allows(
            hostHeader: "example.com",
            authorizationHeader: "Bearer secret",
            token: "secret"
        ))
    }

    func testStatusMatrixIsHonestForRecordingProcessingFailedReadyAndDegraded() async throws {
        let recording = try CallAgentFixture()
        let processing = try CallAgentFixture()
        let failed = try CallAgentFixture()
        let ready = try CallAgentFixture()
        let degraded = try CallAgentFixture()

        let recordingID = try await recording.makeRecordingCall()
        let recordingStatus = try await recording.status(callID: recordingID)
        XCTAssertEqual(recordingStatus, .recording)
        let processingID = try await processing.makeProcessingCall()
        let processingStatus = try await processing.status(callID: processingID)
        XCTAssertEqual(processingStatus, .processing)
        let failedID = try await failed.makeFailedCall()
        let failedStatus = try await failed.status(callID: failedID)
        XCTAssertEqual(failedStatus, .retryable)
        let readyID = try await ready.makeReadyCall(segmentCount: 1, micOnly: false).callID
        let readyStatus = try await ready.status(callID: readyID)
        XCTAssertEqual(readyStatus, .ready)
        let degradedID = try await degraded.makeReadyCall(segmentCount: 1, micOnly: true).callID
        let degradedStatus = try await degraded.status(callID: degradedID)
        XCTAssertEqual(degradedStatus, .degraded)
    }
}

final class CallAgentFixture {
    let root: URL
    let database: ZBSEyeDatabase
    let repository: CallRepository
    let service: CallEvidenceQueryService

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-call-agent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        repository = CallRepository(database: database)
        service = CallEvidenceQueryService(database: database)
    }

    deinit {
        try? database.pool.close()
        try? FileManager.default.removeItem(at: root)
    }

    func makeReadyCall(segmentCount: Int, micOnly: Bool) async throws -> (callID: Int64, bookmarkID: Int64) {
        let call = try await repository.createCall(startedAtMs: 1_000, idempotencyKey: UUID().uuidString)
        let callID = try XCTUnwrap(call.id)
        let span = try await repository.recordSourceSpan(CallSourceSpanDraft(
            callId: callID,
            source: .me,
            epoch: 0,
            sampleRate: 16_000,
            startedAtMs: 1_000,
            startSample: 0,
            startHostTimeNs: 0,
            availability: .available
        ))
        _ = try await repository.recordAudioChunk(CallAudioChunkDraft(
            callId: callID,
            sourceSpanId: try XCTUnwrap(span.id),
            source: .me,
            epoch: 0,
            sequence: 0,
            mediaGeneration: 0,
            startSample: 0,
            endSample: 32_000,
            startMs: 1_000,
            endMs: 3_000,
            relativePath: "calls/\(callID)/me/chunk.pcm",
            bytes: 64_000,
            sha256: nil,
            finalized: true
        ))
        if micOnly {
            _ = try await repository.recordSourceSpan(CallSourceSpanDraft(
                callId: callID,
                source: .system,
                epoch: 0,
                sampleRate: 16_000,
                startedAtMs: 1_000,
                startSample: 0,
                startHostTimeNs: 0,
                availability: .unavailable,
                gapReason: "permission_denied"
            ))
        }
        let created = try await repository.createBookmark(
            callID: callID,
            idempotencyKey: UUID().uuidString,
            acceptedAtMs: 2_000,
            meIngressTarget: 16_000,
            systemIngressTarget: nil,
            logicalStartMs: 1_000,
            logicalEndMs: 2_000,
            contextStartMs: 1_000
        )
        let bookmarkID = try XCTUnwrap(created.bookmark.id)
        _ = try await repository.freezeBookmarkCoverage(
            bookmarkID: bookmarkID,
            jobID: try XCTUnwrap(created.job.id),
            meEndSample: 16_000,
            systemEndSample: nil,
            degraded: micOnly,
            nowMs: 2_000
        )
        let checkpointCandidate = try await repository.claimNextTranscriptJob(nowMs: 2_001)
        let checkpoint = try XCTUnwrap(checkpointCandidate)
        _ = try await repository.commitTranscriptJob(
            jobID: try XCTUnwrap(checkpoint.id),
            segments: [CallTranscriptSegmentDraft(source: .me, startMs: 1_100, endMs: 1_900, text: "bookmark")],
            language: "en",
            engine: "fixture",
            modelRevision: "fixture",
            degraded: micOnly,
            nowMs: 2_100
        )
        _ = try await repository.endCall(callID: callID, idempotencyKey: UUID().uuidString, endedAtMs: 3_000)
        let finalCandidate = try await repository.claimNextTranscriptJob(nowMs: 3_001)
        let final = try XCTUnwrap(finalCandidate)
        let segments = (0..<segmentCount).map {
            CallTranscriptSegmentDraft(
                source: .me,
                startMs: 1_000 + Int64($0 * 10),
                endMs: 1_009 + Int64($0 * 10),
                text: "line \($0)"
            )
        }
        _ = try await repository.commitTranscriptJob(
            jobID: try XCTUnwrap(final.id),
            segments: segments,
            language: "en",
            engine: "fixture",
            modelRevision: "fixture",
            degraded: micOnly,
            nowMs: 3_100
        )
        return (callID, bookmarkID)
    }

    func makeRecordingCall() async throws -> Int64 {
        let call = try await repository.createCall(
            startedAtMs: Int64.random(in: 10_000...20_000),
            idempotencyKey: UUID().uuidString
        )
        return try XCTUnwrap(call.id)
    }

    func makeProcessingCall() async throws -> Int64 {
        let callID = try await makeRecordingCall()
        _ = try await repository.endCall(
            callID: callID,
            idempotencyKey: UUID().uuidString,
            endedAtMs: 21_000
        )
        return callID
    }

    func makeFailedCall() async throws -> Int64 {
        let callID = try await makeProcessingCall()
        let candidate = try await repository.claimNextTranscriptJob(nowMs: 22_000)
        let job = try XCTUnwrap(candidate)
        try await repository.failTranscriptJob(
            jobID: try XCTUnwrap(job.id),
            errorCode: "fixture_failed",
            retryable: false,
            nowMs: 22_100
        )
        return callID
    }

    func status(callID: Int64) async throws -> CallEvidenceStatus {
        let envelope = try await service.envelope(callID: callID)
        return try XCTUnwrap(envelope).status
    }
}
