import AppKit
import GRDB
import XCTest

@MainActor
final class CallAutomationStoreTests: XCTestCase {
    func testSecretPasteboardIsConcealedTransientAndClearsOnlyIfUnchanged() throws {
        let pasteboard = NSPasteboard(name: .init("call-automation-\(UUID().uuidString)"))
        let copiedChange = CallAutomationSecretPasteboard.write("secret", to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "secret")
        XCTAssertNotNil(pasteboard.data(forType: CallAutomationSecretPasteboard.concealedType))
        XCTAssertNotNil(pasteboard.data(forType: CallAutomationSecretPasteboard.transientType))

        pasteboard.clearContents()
        pasteboard.setString("new user content", forType: .string)
        XCTAssertFalse(
            CallAutomationSecretPasteboard.clearIfUnchanged(
                pasteboard,
                expectedChangeCount: copiedChange
            )
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "new user content")

        let secondCopy = CallAutomationSecretPasteboard.write("secret", to: pasteboard)
        XCTAssertTrue(
            CallAutomationSecretPasteboard.clearIfUnchanged(
                pasteboard,
                expectedChangeCount: secondCopy
            )
        )
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testDraftIsStagedUntilSaveAndCancelRestoresPersistedEndpoint() async throws {
        let fixture = try CallAutomationStoreFixture()
        let store = fixture.makeStore()
        await store.load()

        XCTAssertEqual(store.phase, .disabled)
        store.draftEndpoint = "not a loopback URL"
        XCTAssertEqual(store.phase, .invalidDraft)
        XCTAssertFalse(store.canEnable)

        store.draftEndpoint = "http://localhost:8765/hooks/call"
        XCTAssertTrue(store.canSave)
        await store.saveReceiver()

        XCTAssertEqual(store.persistedEndpoint, "http://127.0.0.1:8765/hooks/call")
        XCTAssertEqual(store.phase, .disabled)
        store.draftEndpoint = "http://localhost:9999/changed"
        store.cancelDraft()
        XCTAssertEqual(store.draftEndpoint, "http://127.0.0.1:8765/hooks/call")
    }

    func testChangedReceiverRequiresConfirmationAndDiscardsOldBacklogOnlyAfterConfirm() async throws {
        let fixture = try CallAutomationStoreFixture()
        try await fixture.enable(endpoint: "http://127.0.0.1:8765/hooks/call")
        _ = try await fixture.makeEndedCall()
        let store = fixture.makeStore()
        await store.load()

        store.draftEndpoint = "http://localhost:9999/new"
        await store.saveReceiver()
        XCTAssertEqual(store.endpointChangeConfirmationCount, 1)
        XCTAssertEqual(store.persistedEndpoint, "http://127.0.0.1:8765/hooks/call")

        await store.confirmEndpointChange()
        XCTAssertNil(store.endpointChangeConfirmationCount)
        XCTAssertEqual(store.persistedEndpoint, "http://127.0.0.1:9999/new")
        XCTAssertEqual(store.pendingCount, 0)
    }

    func testEnableTestCopySecretAndBlockedRetryHaveDeterministicStates() async throws {
        let fixture = try CallAutomationStoreFixture(
            testResults: [.delivered(statusCode: 204)],
            secret: .success("stable-secret")
        )
        let store = fixture.makeStore()
        await store.load()
        store.draftEndpoint = "http://localhost:8765/hooks/call"
        await store.saveReceiver()
        await store.setEnabled(true)
        XCTAssertEqual(store.phase, .ready)

        await store.testReceiver()
        XCTAssertEqual(store.phase, .testSucceeded)
        let testCount = await fixture.transport.testCount
        XCTAssertEqual(testCount, 1)
        let callCount = try await fixture.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM calls") ?? 0
        }
        XCTAssertEqual(callCount, 0)

        store.copySecret()
        XCTAssertEqual(fixture.copiedSecret, "stable-secret")

        try await fixture.makeBlockedEvent()
        await store.refresh()
        XCTAssertEqual(store.phase, .blocked)
        XCTAssertEqual(store.blockedCount, 1)
        await store.retryBlocked()
        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(store.blockedCount, 0)
    }

    func testKeychainAndTestFailureAreVisibleWithoutSecretReplacement() async throws {
        let keychainFixture = try CallAutomationStoreFixture(secret: .failure(TestFailure.keychain))
        let keychainStore = keychainFixture.makeStore()
        await keychainStore.load()
        keychainStore.draftEndpoint = "http://localhost:8765/hooks/call"
        await keychainStore.saveReceiver()
        await keychainStore.setEnabled(true)
        XCTAssertEqual(keychainStore.phase, .keychainUnavailable)
        XCTAssertFalse(keychainStore.isEnabled)

        let failureFixture = try CallAutomationStoreFixture(
            testResults: [.retry(afterMs: nil, errorCode: "receiver_offline")]
        )
        let failureStore = failureFixture.makeStore()
        await failureStore.load()
        failureStore.draftEndpoint = "http://localhost:8765/hooks/call"
        await failureStore.saveReceiver()
        await failureStore.testReceiver()
        XCTAssertEqual(failureStore.phase, .testFailed)
        XCTAssertEqual(failureStore.statusCode, "receiver_offline")
    }

    func testSuspensionWaitsForActiveOperationAndKeepsSuspendedPhase() async throws {
        let fixture = try CallAutomationStoreFixture()
        try await fixture.enable(endpoint: "http://127.0.0.1:8765/hooks/call")
        let transport = PausingStoreTransport()
        let store = CallAutomationStore(repository: fixture.repository, transport: transport)
        await store.load()
        let testTask = Task { @MainActor in await store.testReceiver() }
        await transport.waitUntilStarted()
        let drained = StoreAsyncFlag()
        let suspendTask = Task { @MainActor in
            await store.suspendAndDrain()
            await drained.set()
        }

        await Task.yield()
        let drainedEarly = await drained.value()
        XCTAssertFalse(drainedEarly)
        await transport.release()
        await testTask.value
        await suspendTask.value
        XCTAssertEqual(store.phase, .suspended)

        await store.resumeAfterSuspension()
        XCTAssertEqual(store.phase, .ready)
    }
}

private enum TestFailure: Error { case keychain }

private actor StoreTransport: CallAutomationTransport {
    private var testResults: [CallAutomationDeliveryResult]
    private(set) var testCount = 0

    init(testResults: [CallAutomationDeliveryResult]) {
        self.testResults = testResults
    }

    func deliver(_ delivery: CallAutomationDelivery) async -> CallAutomationDeliveryResult {
        .delivered(statusCode: 204)
    }

    func test(endpoint: URL, eventID: String, occurredAtMs: Int64) async -> CallAutomationDeliveryResult {
        testCount += 1
        return testResults.isEmpty ? .delivered(statusCode: 204) : testResults.removeFirst()
    }
}

private actor PausingStoreTransport: CallAutomationTransport {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func deliver(_ delivery: CallAutomationDelivery) async -> CallAutomationDeliveryResult {
        .delivered(statusCode: 204)
    }

    func test(endpoint: URL, eventID: String, occurredAtMs: Int64) async -> CallAutomationDeliveryResult {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
        return .delivered(statusCode: 204)
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

private actor StoreAsyncFlag {
    private var isSet = false
    func set() { isSet = true }
    func value() -> Bool { isSet }
}

@MainActor
private final class CallAutomationStoreFixture {
    let root: URL
    let database: ZBSEyeDatabase
    let calls: CallRepository
    let repository: CallAutomationRepository
    let transport: StoreTransport
    let secret: Result<String, Error>
    private(set) var copiedSecret: String?

    init(
        testResults: [CallAutomationDeliveryResult] = [],
        secret: Result<String, Error> = .success("stable-secret")
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-call-automation-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        calls = CallRepository(database: database)
        repository = CallAutomationRepository(database: database)
        transport = StoreTransport(testResults: testResults)
        self.secret = secret
    }

    func makeStore() -> CallAutomationStore {
        CallAutomationStore(
            repository: repository,
            transport: transport,
            secretProvider: { [secret] in try secret.get() },
            copyToPasteboard: { [weak self] in self?.copiedSecret = $0 }
        )
    }

    func enable(endpoint: String) async throws {
        let canonical = try CallAutomationEndpoint.canonicalURL(from: endpoint)
        _ = try await repository.saveConfiguration(
            enabled: true,
            endpoint: canonical,
            discardUndeliveredOnEndpointChange: false,
            nowMs: 900
        )
    }

    @discardableResult
    func makeEndedCall() async throws -> Int64 {
        let call = try await calls.createCall(startedAtMs: 1_000, idempotencyKey: UUID().uuidString)
        let callID = try XCTUnwrap(call.id)
        _ = try await calls.endCall(
            callID: callID,
            idempotencyKey: UUID().uuidString,
            endedAtMs: 2_000
        )
        return callID
    }

    func makeBlockedEvent() async throws {
        _ = try await makeEndedCall()
        let claimed = try await repository.claimNext(nowMs: 3_000, leaseDurationMs: 1_000)
        let delivery = try XCTUnwrap(claimed)
        try await repository.markBlocked(
            eventID: delivery.event.eventID,
            statusCode: 400,
            errorCode: "receiver_rejected",
            nowMs: 3_010
        )
    }
}
