import Foundation
import XCTest

final class AutomaticRetentionAdmissionTests: XCTestCase {
    func testDefaultStateIsForeverAndClosed() {
        let record = AutomaticRetentionRecord.closedForever
        let admission = AutomaticRetentionAdmission(record: record)

        XCTAssertEqual(record.policy, .forever)
        XCTAssertEqual(record.phase, .closed)
        XCTAssertNil(admission.currentPermit())
    }

    func testStalePermitIsRejectedAfterRevisionChanges() throws {
        let admitted = AutomaticRetentionRecord(
            revision: 4,
            policy: .tenGB,
            phase: .finiteAdmitted,
            source: .explicitSelection
        )
        let admission = AutomaticRetentionAdmission(record: admitted)
        let permit = try XCTUnwrap(admission.currentPermit())

        admission.revoke(to: 5)

        XCTAssertThrowsError(try admission.withLease(permit) { 1 }) { error in
            XCTAssertEqual(error as? AutomaticRetentionAdmissionError, .stalePermit)
        }
        XCTAssertNil(admission.currentPermit())
    }

    func testLateActivationCannotReopenAfterNewerRevocation() {
        let pending = AutomaticRetentionRecord(
            revision: 3,
            policy: .tenGB,
            phase: .pendingFinite,
            source: .explicitSelection
        )
        let admission = AutomaticRetentionAdmission(record: pending)
        admission.revoke(to: 4)

        let late = AutomaticRetentionRecord(
            revision: 3,
            policy: .tenGB,
            phase: .finiteAdmitted,
            source: .explicitSelection
        )

        XCTAssertFalse(admission.activate(late))
        XCTAssertNil(admission.currentPermit())
    }

    func testPendingFiniteRevisionCanActivateAfterOldPermitIsRevoked() throws {
        let old = AutomaticRetentionRecord(
            revision: 2,
            policy: .fiveGB,
            phase: .finiteAdmitted,
            source: .explicitSelection
        )
        let pending = AutomaticRetentionRecord(
            revision: 3,
            policy: .tenGB,
            phase: .pendingFinite,
            source: .explicitSelection
        )
        let admitted = AutomaticRetentionRecord(
            revision: 3,
            policy: .tenGB,
            phase: .finiteAdmitted,
            source: .explicitSelection
        )
        let admission = AutomaticRetentionAdmission(record: old)

        XCTAssertTrue(admission.revokeAndStage(pending))
        XCTAssertNil(admission.currentPermit())
        XCTAssertTrue(admission.activate(admitted))
        XCTAssertEqual(try XCTUnwrap(admission.currentPermit()).policy, .tenGB)
    }

    func testRevokeWaitsForHeldLeaseAndNoSecondLeaseCanEnter() async throws {
        let admitted = AutomaticRetentionRecord(
            revision: 8,
            policy: .fiveGB,
            phase: .finiteAdmitted,
            source: .migration
        )
        let admission = AutomaticRetentionAdmission(record: admitted)
        let permit = try XCTUnwrap(admission.currentPermit())
        let leaseEntered = expectation(description: "lease entered")
        let revokeProbe = AutomaticRetentionRevokeProbe()
        let releaseLease = DispatchSemaphore(value: 0)

        let leaseTask = Task.detached {
            try admission.withLease(permit) {
                leaseEntered.fulfill()
                releaseLease.wait()
                return 1
            }
        }
        await fulfillment(of: [leaseEntered], timeout: 1)

        let revokeTask = Task.detached {
            admission.revoke(to: 9)
            revokeProbe.markFinished()
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(revokeProbe.isFinished)

        releaseLease.signal()
        let leaseResult = try await leaseTask.value
        XCTAssertEqual(leaseResult, 1)
        _ = await revokeTask.value

        XCTAssertNil(admission.currentPermit())
        XCTAssertThrowsError(try admission.withLease(permit) { 2 }) { error in
            XCTAssertEqual(error as? AutomaticRetentionAdmissionError, .stalePermit)
        }
    }

    func testRevokeWaitsForAsyncLeaseAndNoNewLeaseCanEnter() async throws {
        let admitted = AutomaticRetentionRecord(
            revision: 10,
            policy: .fiveGB,
            phase: .finiteAdmitted,
            source: .explicitSelection
        )
        let admission = AutomaticRetentionAdmission(record: admitted)
        let permit = try XCTUnwrap(admission.currentPermit())
        let leaseEntered = expectation(description: "async lease entered")
        let gate = AutomaticRetentionAsyncLeaseGate()
        let revokeProbe = AutomaticRetentionRevokeProbe()

        let leaseTask = Task {
            try await admission.withAsyncLease(permit) {
                leaseEntered.fulfill()
                await gate.waitUntilReleased()
                return 3
            }
        }
        await fulfillment(of: [leaseEntered], timeout: 1)

        let revokeTask = Task.detached {
            admission.revoke(to: 11)
            revokeProbe.markFinished()
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(revokeProbe.isFinished)
        XCTAssertThrowsError(try admission.withLease(permit) { 4 }) { error in
            XCTAssertEqual(error as? AutomaticRetentionAdmissionError, .stalePermit)
        }

        await gate.release()
        let leaseResult = try await leaseTask.value
        XCTAssertEqual(leaseResult, 3)
        _ = await revokeTask.value
        XCTAssertTrue(revokeProbe.isFinished)
        XCTAssertNil(admission.currentPermit())
    }

    @MainActor
    func testPendingForeverFinalizesClosedOnRestart() throws {
        let defaults = isolatedDefaults()
        defer { clear(defaults) }
        let pending = AutomaticRetentionRecord(
            revision: 12,
            policy: .forever,
            phase: .pendingForever,
            source: .explicitSelection
        )
        defaults.set(try JSONEncoder().encode(pending), forKey: StorageSettingsStore.admissionRecordKey)
        defaults.set(KeepMediaPolicy.tenGB.rawValue, forKey: StorageSettingsStore.keepMediaPolicyKey)

        let restarted = StorageSettingsStore(defaults: defaults)

        XCTAssertEqual(restarted.keepMediaPolicy, .forever)
        XCTAssertFalse(restarted.automaticDeletionAdmitted)
        XCTAssertEqual(restarted.automaticRetentionRecord.revision, 12)
        XCTAssertEqual(restarted.automaticRetentionRecord.phase, .closed)
        XCTAssertNil(AutomaticRetentionAdmission(record: restarted.automaticRetentionRecord).currentPermit())
    }

    @MainActor
    func testStorePersistsPendingForeverBeforePublishingFinalPolicy() {
        let defaults = isolatedDefaults()
        defer { clear(defaults) }
        let store = StorageSettingsStore(defaults: defaults)
        _ = store.initializeKeepMediaPolicy(inventory: .positivelyEmpty)

        let pending = try! XCTUnwrap(store.beginForeverRevocation())

        XCTAssertEqual(pending.phase, .pendingForever)
        XCTAssertEqual(store.keepMediaPolicy, .fiveGB)
        XCTAssertFalse(store.automaticDeletionAdmitted)
        store.finishForeverRevocation()
        XCTAssertEqual(store.keepMediaPolicy, .forever)
        XCTAssertEqual(store.automaticRetentionRecord.phase, .closed)
    }

    @MainActor
    func testFailedForeverPersistenceStaysClosedAndReportsFailure() {
        let defaults = isolatedDefaults()
        defer { clear(defaults) }
        var rejectForever = false
        let store = StorageSettingsStore(
            defaults: defaults,
            admissionPersistenceGate: { record in
                !(rejectForever && record.phase == .pendingForever)
            }
        )
        _ = store.initializeKeepMediaPolicy(inventory: .positivelyEmpty)
        let admittedRevision = store.automaticRetentionRecord.revision
        rejectForever = true

        let pending = store.beginForeverRevocation()

        XCTAssertNil(pending)
        XCTAssertFalse(store.automaticDeletionAdmitted)
        XCTAssertEqual(store.automaticRetentionRecord.revision, admittedRevision)
        XCTAssertEqual(store.automaticRetentionRecord.phase, .closed)
        XCTAssertEqual(store.keepMediaPolicy, .forever)
    }

    @MainActor
    func testFiniteIncreaseIsDurablyPendingBeforeOldPolicyIsReplaced() throws {
        let defaults = isolatedDefaults()
        defer { clear(defaults) }
        let store = StorageSettingsStore(defaults: defaults)
        _ = store.initializeKeepMediaPolicy(inventory: .positivelyEmpty)
        XCTAssertEqual(store.keepMediaPolicy, .fiveGB)

        let pending = try XCTUnwrap(store.beginFiniteTransition(.fiftyGB))

        XCTAssertEqual(pending.policy, .fiftyGB)
        XCTAssertEqual(pending.phase, .pendingFinite)
        XCTAssertFalse(store.automaticDeletionAdmitted)
        XCTAssertEqual(store.keepMediaPolicy, .fiveGB)

        let restarted = StorageSettingsStore(defaults: defaults)
        XCTAssertEqual(restarted.keepMediaPolicy, .fiftyGB)
        XCTAssertEqual(restarted.automaticRetentionRecord.phase, .pendingFinite)
        XCTAssertFalse(restarted.automaticDeletionAdmitted)
        _ = restarted.initializeKeepMediaPolicy(inventory: .positivelyEmpty)
        XCTAssertEqual(restarted.keepMediaPolicy, .fiftyGB)
        XCTAssertTrue(restarted.automaticDeletionAdmitted)
    }

    @MainActor
    func testFailedFiniteTransitionDoesNotPublishRequestedPolicy() {
        let defaults = isolatedDefaults()
        defer { clear(defaults) }
        var rejectPending = false
        let store = StorageSettingsStore(
            defaults: defaults,
            admissionPersistenceGate: { record in
                !(rejectPending && record.phase == .pendingFinite)
            }
        )
        _ = store.initializeKeepMediaPolicy(inventory: .positivelyEmpty)
        rejectPending = true

        XCTAssertNil(store.beginFiniteTransition(.fiftyGB))
        XCTAssertFalse(store.automaticDeletionAdmitted)
        XCTAssertEqual(store.keepMediaPolicy, .forever)

        let restarted = StorageSettingsStore(defaults: defaults)
        XCTAssertEqual(restarted.keepMediaPolicy, .fiveGB)
        XCTAssertFalse(restarted.automaticDeletionAdmitted)
    }

    @MainActor
    func testCorruptRecordFailsClosedToForever() {
        let defaults = isolatedDefaults()
        defer { clear(defaults) }
        defaults.set(Data("not-json".utf8), forKey: StorageSettingsStore.admissionRecordKey)
        defaults.set(KeepMediaPolicy.fiveGB.rawValue, forKey: StorageSettingsStore.keepMediaPolicyKey)

        let restarted = StorageSettingsStore(defaults: defaults)

        XCTAssertEqual(restarted.keepMediaPolicy, .forever)
        XCTAssertFalse(restarted.automaticDeletionAdmitted)
        XCTAssertEqual(restarted.automaticRetentionRecord, .closedForever)
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "AutomaticRetentionAdmissionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func clear(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
    }
}

private final class AutomaticRetentionRevokeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}

private actor AutomaticRetentionAsyncLeaseGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
