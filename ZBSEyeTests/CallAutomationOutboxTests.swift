import GRDB
import XCTest

final class CallAutomationOutboxTests: XCTestCase {
    func testProcessingReadyWaitsForTranscriptAndSpeakersThenEnqueuesOnce() async throws {
        let fixture = try CallAutomationOutboxFixture()
        try await fixture.enable()
        let call = try await fixture.repository.createCall(
            startedAtMs: 1_000,
            idempotencyKey: "processing-ready-call"
        )
        let callID = try XCTUnwrap(call.id)
        let job = try await fixture.repository.endCall(
            callID: callID,
            idempotencyKey: "processing-ready-end",
            endedAtMs: 2_000
        )

        let transcriptID = try await fixture.database.pool.write { db -> Int64 in
            var revision = CallTranscriptRevisionRow(
                id: nil,
                callId: callID,
                jobId: try XCTUnwrap(job.id),
                projectionKey: nil,
                kind: .final,
                mediaGeneration: 0,
                state: .ready,
                text: "private fixture transcript",
                language: "en",
                engine: "fixture",
                modelRevision: "fixture",
                logicalStartMs: 1_000,
                logicalEndMs: 2_000,
                createdAtMs: 2_500
            )
            try revision.insert(db)
            let revisionID = try XCTUnwrap(revision.id)
            try db.execute(
                sql: "UPDATE calls SET state = 'ready', preferredRevisionId = ?, updatedAtMs = 2500 WHERE id = ?",
                arguments: [revisionID, callID]
            )
            return revisionID
        }
        XCTAssertGreaterThan(transcriptID, 0)
        let beforeSpeakers = try await fixture.eventCount(type: .processingReady)
        XCTAssertEqual(beforeSpeakers, 0)

        let speakers = try await fixture.repository.createSpeakerRevision(
            callID: callID,
            mediaGeneration: 0,
            engine: "fixture",
            modelRevision: "fixture",
            clusters: [
                CallSpeakerClusterDraft(
                    clusterKey: "system:S1",
                    displayName: nil,
                    namingProvenance: .anonymous,
                    intervals: [
                        CallSpeakerIntervalDraft(source: .system, startMs: 1_000, endMs: 2_000)
                    ]
                )
            ],
            nowMs: 2_600
        )
        let speakerID = try XCTUnwrap(speakers.id)
        try await fixture.repository.setPreferredSpeakerRevision(callID: callID, revisionID: speakerID)
        try await fixture.repository.setPreferredSpeakerRevision(callID: callID, revisionID: speakerID)

        let afterSpeakers = try await fixture.eventCount(type: .processingReady)
        XCTAssertEqual(afterSpeakers, 1)
        let payload = try await fixture.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT payloadJSON FROM call_automation_outbox WHERE eventType = ?",
                arguments: [CallAutomationEventType.processingReady.rawValue]
            )
        }
        XCTAssertFalse(try XCTUnwrap(payload).contains("private fixture transcript"))
    }

    func testOnlyTerminalFinalFailureEnqueuesAndEraseSuppressesUndeliveredEvents() async throws {
        let fixture = try CallAutomationOutboxFixture()
        try await fixture.enable()
        let call = try await fixture.repository.createCall(
            startedAtMs: 1_000,
            idempotencyKey: "failure-call"
        )
        let callID = try XCTUnwrap(call.id)
        _ = try await fixture.repository.endCall(
            callID: callID,
            idempotencyKey: "failure-end",
            endedAtMs: 2_000
        )

        let firstCandidate = try await fixture.repository.claimNextTranscriptJob(nowMs: 2_100)
        let first = try XCTUnwrap(firstCandidate)
        let firstState = try await fixture.repository.failTranscriptJob(
            jobID: try XCTUnwrap(first.id),
            errorCode: "receiver_fixture",
            retryable: true,
            nowMs: 2_200
        )
        XCTAssertEqual(firstState, .pending)
        let transientFailureEvents = try await fixture.eventCount(type: .transcriptFailed)
        XCTAssertEqual(transientFailureEvents, 0)

        let secondCandidate = try await fixture.repository.claimNextTranscriptJob(nowMs: 2_300)
        let second = try XCTUnwrap(secondCandidate)
        let terminalState = try await fixture.repository.failTranscriptJob(
            jobID: try XCTUnwrap(second.id),
            errorCode: "invalid_helper_result",
            retryable: false,
            nowMs: 2_400
        )
        XCTAssertEqual(terminalState, .failed)
        let terminalFailureEvents = try await fixture.eventCount(type: .transcriptFailed)
        XCTAssertEqual(terminalFailureEvents, 1)

        _ = try await fixture.repository.beginEraseCall(callID: callID, nowMs: 2_500)
        let undelivered = try await fixture.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM call_automation_outbox WHERE callId = ? AND state != 'delivered'",
                arguments: [callID]
            ) ?? 0
        }
        XCTAssertEqual(undelivered, 0)
    }

    func testInterruptedRecoveryEnqueuesEndedOnceOnlyForNonemptyCallWithFinalJob() async throws {
        let fixture = try CallAutomationOutboxFixture()
        try await fixture.enable()
        let call = try await fixture.repository.createCall(
            startedAtMs: 1_000,
            idempotencyKey: "recovery-call"
        )
        let callID = try XCTUnwrap(call.id)
        let span = try await fixture.repository.recordSourceSpan(
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
        _ = try await fixture.repository.recordAudioChunk(
            CallAudioChunkDraft(
                callId: callID,
                sourceSpanId: try XCTUnwrap(span.id),
                source: .me,
                epoch: 0,
                sequence: 0,
                mediaGeneration: 0,
                startSample: 0,
                endSample: 16_000,
                startMs: 1_000,
                endMs: 2_000,
                relativePath: "calls/\(callID)/me/0.pcm",
                bytes: 32_000,
                sha256: "fixture",
                finalized: true
            )
        )

        let first = try await fixture.repository.recoverDatabaseState(nowMs: 3_000)
        let second = try await fixture.repository.recoverDatabaseState(nowMs: 3_100)

        XCTAssertEqual(first.callsInterrupted, 1)
        XCTAssertEqual(first.finalJobsCreated, 1)
        XCTAssertEqual(second.callsInterrupted, 0)
        let endedEvents = try await fixture.eventCount(type: .callEnded)
        XCTAssertEqual(endedEvents, 1)
    }

    func testEraseWaitsForInFlightDeliveryBeforePrivacyIntentCommits() async throws {
        let fixture = try CallAutomationOutboxFixture()
        try await fixture.enable()
        let call = try await fixture.repository.createCall(
            startedAtMs: 1_000,
            idempotencyKey: "erase-race-call"
        )
        let callID = try XCTUnwrap(call.id)
        _ = try await fixture.repository.endCall(
            callID: callID,
            idempotencyKey: "erase-race-end",
            endedAtMs: 2_000
        )
        let automation = CallAutomationRepository(database: fixture.database)
        let transport = ErasePausingTransport()
        let dispatcher = CallAutomationDispatcher(repository: automation, transport: transport)
        let deletion = CallEvidenceDeletionService(
            repository: fixture.repository,
            mediaRoot: fixture.root
        )
        await deletion.attachCallAutomation(
            suspend: { await dispatcher.suspendAndDrainForRelocation() },
            resume: { await dispatcher.resumeAfterRelocation(nowMs: 4_100) }
        )

        let delivery = Task { await dispatcher.runOne(nowMs: 3_000) }
        await transport.waitUntilStarted()
        let erase = Task { try await deletion.erase(callID: callID, nowMs: 4_000) }
        try await Task.sleep(for: .milliseconds(20))
        let degradationBeforeRelease = try await fixture.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT degradationReason FROM calls WHERE id = ?",
                arguments: [callID]
            )
        }
        XCTAssertNil(degradationBeforeRelease)

        await transport.release()
        let delivered = await delivery.value
        XCTAssertTrue(delivered)
        _ = try await erase.value
        let remainingCall = try await fixture.database.pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM calls WHERE id = ?", arguments: [callID])
        }
        let remainingEvents = try await fixture.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM call_automation_outbox WHERE callId = ?",
                arguments: [callID]
            ) ?? 0
        }
        XCTAssertNil(remainingCall)
        XCTAssertEqual(remainingEvents, 0)
    }
}

private final class CallAutomationOutboxFixture {
    let root: URL
    let database: ZBSEyeDatabase
    let repository: CallRepository

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-call-outbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        repository = CallRepository(database: database)
    }

    func enable() async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE call_automation_config
                    SET enabled = 1, endpointURL = 'http://127.0.0.1:7777/events',
                        endpointFingerprint = 'receiver-a', updatedAtMs = 900
                    WHERE id = 1
                    """
            )
        }
    }

    func eventCount(type: CallAutomationEventType) async throws -> Int {
        try await database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM call_automation_outbox WHERE eventType = ?",
                arguments: [type.rawValue]
            ) ?? 0
        }
    }
}

private actor ErasePausingTransport: CallAutomationTransport {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func deliver(_ delivery: CallAutomationDelivery) async -> CallAutomationDeliveryResult {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
        return .delivered(statusCode: 204)
    }

    func test(endpoint: URL, eventID: String, occurredAtMs: Int64) async -> CallAutomationDeliveryResult {
        .delivered(statusCode: 204)
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
