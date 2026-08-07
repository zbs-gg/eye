import Foundation
import GRDB
import XCTest

final class CallAutomationDispatcherTests: XCTestCase {
    func testClaimPreservesPerCallOrderWithoutGloballyBlockingOtherCalls() async throws {
        let fixture = try CallAutomationFixture()
        try await fixture.enable(endpoint: "http://127.0.0.1:7777/events")
        let first = try await fixture.makeEndedCall(key: "first", startedAtMs: 1_000)
        try await fixture.finishTranscript(callID: first.callID, jobID: first.jobID, nowMs: 2_200)
        let second = try await fixture.makeEndedCall(key: "second", startedAtMs: 3_000)

        let firstClaim = try await fixture.automation.claimNext(nowMs: 4_000, leaseDurationMs: 1_000)
        XCTAssertEqual(firstClaim?.event.callId, first.callID)
        XCTAssertEqual(firstClaim?.event.eventType, .callEnded)
        try await fixture.automation.markBlocked(
            eventID: try XCTUnwrap(firstClaim?.event.eventID),
            statusCode: 400,
            errorCode: "receiver_rejected",
            nowMs: 4_010
        )

        let next = try await fixture.automation.claimNext(nowMs: 4_020, leaseDurationMs: 1_000)
        XCTAssertEqual(next?.event.callId, second.callID)
        XCTAssertEqual(next?.event.eventType, .callEnded)
    }

    func testEndpointChangeRequiresConfirmationAndNeverRedirectsOldBacklog() async throws {
        let fixture = try CallAutomationFixture()
        try await fixture.enable(endpoint: "http://127.0.0.1:7777/events")
        _ = try await fixture.makeEndedCall(key: "first", startedAtMs: 1_000)

        await assertThrowsAsync {
            try await fixture.automation.saveConfiguration(
                enabled: true,
                endpoint: try XCTUnwrap(URL(string: "http://127.0.0.1:8888/events")),
                discardUndeliveredOnEndpointChange: false,
                nowMs: 3_000
            )
        }

        let discarded = try await fixture.automation.saveConfiguration(
            enabled: true,
            endpoint: try XCTUnwrap(URL(string: "http://127.0.0.1:8888/events")),
            discardUndeliveredOnEndpointChange: true,
            nowMs: 3_100
        )
        XCTAssertEqual(discarded, 1)
        let redirectedClaim = try await fixture.automation.claimNext(
            nowMs: 3_200,
            leaseDurationMs: 1_000
        )
        XCTAssertNil(redirectedClaim)
    }

    func testStaleLeaseIsRecoveredButDisabledConfigurationSuspendsClaims() async throws {
        let fixture = try CallAutomationFixture()
        try await fixture.enable(endpoint: "http://127.0.0.1:7777/events")
        _ = try await fixture.makeEndedCall(key: "first", startedAtMs: 1_000)
        let first = try await fixture.automation.claimNext(nowMs: 3_000, leaseDurationMs: 100)
        XCTAssertNotNil(first)

        let recovered = try await fixture.automation.recoverStaleLeases(nowMs: 3_101)
        XCTAssertEqual(recovered, 1)
        try await fixture.automation.setEnabled(false, nowMs: 3_102)
        let suspendedClaim = try await fixture.automation.claimNext(
            nowMs: 3_103,
            leaseDurationMs: 100
        )
        XCTAssertNil(suspendedClaim)

        try await fixture.automation.setEnabled(true, nowMs: 3_104)
        let replay = try await fixture.automation.claimNext(nowMs: 3_105, leaseDurationMs: 100)
        XCTAssertEqual(replay?.event.eventID, first?.event.eventID)
    }

    func testDispatcherPersistsRetryThenDeliversTheSameEventID() async throws {
        let fixture = try CallAutomationFixture()
        try await fixture.enable(endpoint: "http://127.0.0.1:7777/events")
        _ = try await fixture.makeEndedCall(key: "first", startedAtMs: 1_000)
        let transport = ScriptedCallAutomationTransport(results: [
            .retry(afterMs: nil, errorCode: "receiver_offline"),
            .delivered(statusCode: 204),
        ])
        let dispatcher = CallAutomationDispatcher(repository: fixture.automation, transport: transport)

        let firstRun = await dispatcher.runOne(nowMs: 3_000)
        let earlyRun = await dispatcher.runOne(nowMs: 3_001)
        let retryRun = await dispatcher.runOne(nowMs: 4_000)
        XCTAssertTrue(firstRun)
        XCTAssertFalse(earlyRun)
        XCTAssertTrue(retryRun)

        let eventIDs = await transport.eventIDs
        XCTAssertEqual(eventIDs.count, 2)
        XCTAssertEqual(eventIDs.first, eventIDs.last)
        let deliveredCount = try await fixture.eventCount(state: .delivered)
        XCTAssertEqual(deliveredCount, 1)
        let status = try await fixture.automation.status()
        XCTAssertEqual(status.pendingCount, 0)
    }

    func testStartupScanDeliversExistingBacklogWithoutPolling() async throws {
        let fixture = try CallAutomationFixture()
        try await fixture.enable(endpoint: "http://127.0.0.1:7777/events")
        _ = try await fixture.makeEndedCall(key: "before-start", startedAtMs: 1_000)
        let transport = ScriptedCallAutomationTransport(results: [.delivered(statusCode: 204)])
        let dispatcher = CallAutomationDispatcher(
            repository: fixture.automation,
            transport: transport
        )
        await dispatcher.start()

        try await Task.sleep(for: .milliseconds(100))
        await dispatcher.shutdown()

        let eventCount = await transport.eventIDs.count
        let deliveredCount = try await fixture.eventCount(state: .delivered)
        XCTAssertEqual(eventCount, 1)
        XCTAssertEqual(deliveredCount, 1)
    }

    func testUnexpiredSendingLeaseWakesAndRecoversWithoutPolling() async throws {
        let fixture = try CallAutomationFixture()
        try await fixture.enable(endpoint: "http://127.0.0.1:7777/events")
        _ = try await fixture.makeEndedCall(key: "leased", startedAtMs: 1_000)
        let claimed = try await fixture.automation.claimNext(
            nowMs: 3_000,
            leaseDurationMs: 100
        )
        let eventID = try XCTUnwrap(claimed?.event.eventID)
        let clock = LockedTestClock(3_000)
        let transport = ScriptedCallAutomationTransport(results: [.delivered(statusCode: 204)])
        let dispatcher = CallAutomationDispatcher(
            repository: fixture.automation,
            transport: transport,
            clock: { clock.now() }
        )

        await dispatcher.start()
        try await Task.sleep(for: .milliseconds(20))
        clock.set(3_101)
        try await Task.sleep(for: .milliseconds(120))
        await dispatcher.shutdown()

        let deliveredIDs = await transport.eventIDs
        let deliveredCount = try await fixture.eventCount(state: .delivered)
        XCTAssertEqual(deliveredIDs, [eventID])
        XCTAssertEqual(deliveredCount, 1)
    }

    func testRetryBackoffStartsAfterTransportCompletes() async throws {
        let fixture = try CallAutomationFixture()
        try await fixture.enable(endpoint: "http://127.0.0.1:7777/events")
        _ = try await fixture.makeEndedCall(key: "slow", startedAtMs: 1_000)
        let clock = LockedTestClock(3_000)
        let transport = ScriptedCallAutomationTransport(
            results: [.retry(afterMs: nil, errorCode: "timed_out")],
            onDeliver: { clock.set(8_000) }
        )
        let dispatcher = CallAutomationDispatcher(
            repository: fixture.automation,
            transport: transport,
            clock: { clock.now() }
        )

        let ran = await dispatcher.runOne(nowMs: 3_000, completionClock: { clock.now() })
        XCTAssertTrue(ran)
        let row = try await fixture.firstEvent()
        XCTAssertEqual(row.nextAttemptAtMs, 9_000)
        XCTAssertEqual(row.updatedAtMs, 8_000)
    }

    func testSuspendAndDrainWaitsForInFlightDelivery() async throws {
        let fixture = try CallAutomationFixture()
        try await fixture.enable(endpoint: "http://127.0.0.1:7777/events")
        _ = try await fixture.makeEndedCall(key: "drain", startedAtMs: 1_000)
        let transport = PausingCallAutomationTransport()
        let dispatcher = CallAutomationDispatcher(repository: fixture.automation, transport: transport)
        let delivery = Task { await dispatcher.runOne(nowMs: 3_000) }
        await transport.waitUntilStarted()
        let drained = AsyncFlag()
        let drain = Task {
            await dispatcher.suspendAndDrainForRelocation()
            await drained.set()
        }

        await Task.yield()
        let drainedEarly = await drained.value()
        XCTAssertFalse(drainedEarly)
        await transport.release()
        let delivered = await delivery.value
        XCTAssertTrue(delivered)
        await drain.value
        let drainedFinally = await drained.value()
        XCTAssertTrue(drainedFinally)
        await dispatcher.resumeAfterRelocation(nowMs: 3_100)
    }

    func testPrivacyCanCloseAdmissionWithoutWaitingForAnOfflineTransport() async throws {
        let fixture = try CallAutomationFixture()
        try await fixture.enable(endpoint: "http://127.0.0.1:7777/events")
        _ = try await fixture.makeEndedCall(key: "privacy-fast-stop", startedAtMs: 1_000)
        let transport = PausingCallAutomationTransport()
        let dispatcher = CallAutomationDispatcher(repository: fixture.automation, transport: transport)
        let delivery = Task { await dispatcher.runOne(nowMs: 3_000) }
        await transport.waitUntilStarted()

        await dispatcher.suspendAdmissionForRelocation()
        let secondDeliveryStarted = await dispatcher.runOne(nowMs: 3_001)
        XCTAssertFalse(secondDeliveryStarted)

        let drained = AsyncFlag()
        let drain = Task {
            await dispatcher.drainSuspendedDelivery()
            await drained.set()
        }
        await Task.yield()
        let drainedBeforeTransportFinished = await drained.value()
        XCTAssertFalse(drainedBeforeTransportFinished)

        await transport.release()
        let didDeliver = await delivery.value
        XCTAssertTrue(didDeliver)
        await drain.value
        let drainedAfterTransportFinished = await drained.value()
        XCTAssertTrue(drainedAfterTransportFinished)
        await dispatcher.resumeAfterRelocation(nowMs: 3_100)
    }

    func testStatusCallbackRefreshesAfterBackgroundBlock() async throws {
        let fixture = try CallAutomationFixture()
        try await fixture.enable(endpoint: "http://127.0.0.1:7777/events")
        _ = try await fixture.makeEndedCall(key: "blocked", startedAtMs: 1_000)
        let transport = ScriptedCallAutomationTransport(
            results: [.blocked(statusCode: 400, errorCode: "http_400")]
        )
        let dispatcher = CallAutomationDispatcher(repository: fixture.automation, transport: transport)
        let callbacks = AsyncCounter()
        await dispatcher.setStatusDidChange { await callbacks.increment() }

        await dispatcher.start()
        try await Task.sleep(for: .milliseconds(100))
        await dispatcher.shutdown()

        let callbackCount = await callbacks.value()
        let blockedCount = try await fixture.automation.status().blockedCount
        XCTAssertGreaterThan(callbackCount, 0)
        XCTAssertEqual(blockedCount, 1)
    }
}

private func assertThrowsAsync(
    _ operation: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected operation to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}

private actor ScriptedCallAutomationTransport: CallAutomationTransport {
    private var results: [CallAutomationDeliveryResult]
    private(set) var eventIDs: [String] = []
    private let onDeliver: @Sendable () -> Void

    init(
        results: [CallAutomationDeliveryResult],
        onDeliver: @escaping @Sendable () -> Void = {}
    ) {
        self.results = results
        self.onDeliver = onDeliver
    }

    func deliver(_ delivery: CallAutomationDelivery) async -> CallAutomationDeliveryResult {
        eventIDs.append(delivery.event.eventID)
        onDeliver()
        return results.removeFirst()
    }

    func test(endpoint: URL, eventID: String, occurredAtMs: Int64) async -> CallAutomationDeliveryResult {
        results.removeFirst()
    }
}

private final class CallAutomationFixture {
    let root: URL
    let database: ZBSEyeDatabase
    let calls: CallRepository
    let automation: CallAutomationRepository

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-call-automation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        calls = CallRepository(database: database)
        automation = CallAutomationRepository(database: database)
    }

    func enable(endpoint: String) async throws {
        _ = try await automation.saveConfiguration(
            enabled: true,
            endpoint: try XCTUnwrap(URL(string: endpoint)),
            discardUndeliveredOnEndpointChange: false,
            nowMs: 900
        )
    }

    func makeEndedCall(key: String, startedAtMs: Int64) async throws -> (callID: Int64, jobID: Int64) {
        let call = try await calls.createCall(startedAtMs: startedAtMs, idempotencyKey: "\(key)-call")
        let callID = try XCTUnwrap(call.id)
        let job = try await calls.endCall(
            callID: callID,
            idempotencyKey: "\(key)-end",
            endedAtMs: startedAtMs + 1_000
        )
        return (callID, try XCTUnwrap(job.id))
    }

    func finishTranscript(callID: Int64, jobID: Int64, nowMs: Int64) async throws {
        let claimed = try await calls.claimNextTranscriptJob(nowMs: nowMs - 100)
        XCTAssertEqual(claimed?.id, jobID)
        _ = try await calls.commitTranscriptJob(
            jobID: jobID,
            segments: [],
            language: "und",
            engine: "fixture",
            modelRevision: "fixture-v1",
            degraded: false,
            nowMs: nowMs
        )
    }

    func eventCount(state: CallAutomationDeliveryState) async throws -> Int {
        try await database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM call_automation_outbox WHERE state = ?",
                arguments: [state.rawValue]
            ) ?? 0
        }
    }

    func firstEvent() async throws -> CallAutomationOutboxRow {
        try await database.pool.read { db in
            try XCTUnwrap(
                CallAutomationOutboxRow.fetchOne(
                    db,
                    sql: "SELECT * FROM call_automation_outbox ORDER BY sequence LIMIT 1"
                )
            )
        }
    }
}

private final class LockedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var milliseconds: Int64

    init(_ milliseconds: Int64) {
        self.milliseconds = milliseconds
    }

    func now() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return milliseconds
    }

    func set(_ milliseconds: Int64) {
        lock.lock()
        self.milliseconds = milliseconds
        lock.unlock()
    }
}

private actor AsyncFlag {
    private var isSet = false
    func set() { isSet = true }
    func value() -> Bool { isSet }
}

private actor AsyncCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

private actor PausingCallAutomationTransport: CallAutomationTransport {
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
