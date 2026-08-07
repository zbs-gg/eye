import GRDB
import XCTest

@MainActor
final class CallRecordingStoreTests: XCTestCase {
    func testPrivacyEndJoinsAnInFlightStartAndLeavesNoActiveCall() async throws {
        try await assertTerminalEndJoinsAutomaticStart(reason: .privacy)
    }

    func testMaintenanceEndJoinsAnInFlightStartAndLeavesNoActiveCall() async throws {
        try await assertTerminalEndJoinsAutomaticStart(reason: .maintenance)
    }

    private func assertTerminalEndJoinsAutomaticStart(reason: CallStopReason) async throws {
        let fixture = try CallRecordingStoreFixture(
            suspendAudioStart: true,
            suspendAudioStop: true
        )
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }

        let automaticStart = Task { @MainActor in
            await store.startAutomatic(idempotencyKey: "automatic:privacy-race")
        }
        await fixture.waitUntilAudioStartIsBlocked()
        XCTAssertEqual(store.snapshot.phase, .starting)
        let endEntered = expectation(description: "\(reason.rawValue) end entered")
        let privacyEnd = Task { @MainActor in
            endEntered.fulfill()
            await store.endAndWait(reason: reason)
        }
        await fulfillment(of: [endEntered], timeout: 1)
        await fixture.resumeAudioStart()
        await fixture.waitUntilAudioStopIsBlocked()

        let inFlightCallID = try XCTUnwrap(store.snapshot.callID)
        XCTAssertEqual(store.snapshot.phase, .recording)
        XCTAssertFalse(
            store.canPublishAutomaticStart(callID: inFlightCallID),
            "An accepted \(reason.rawValue) end must close the automatic publish gate."
        )

        await fixture.resumeAudioStop()
        await privacyEnd.value

        let automaticResult = await automaticStart.value
        guard case .interruptedByEnd = automaticResult else {
            return XCTFail("Expected the joined terminal end to own detector teardown.")
        }
        XCTAssertEqual(store.snapshot.phase, .pendingTranscription)
        XCTAssertFalse(store.isActive)
        let calls = try await fixture.database.pool.read { db in
            try CallRow.fetchAll(db)
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].degradationReason, reason.persistenceCode)
        XCTAssertNotNil(calls[0].endTs)
    }

    func testStartRechecksAdmissionInsideScheduledTask() async throws {
        let fixture = try CallRecordingStoreFixture()
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }
        let admission = StoreAdmissionFlag()
        store.admissionAllowed = { admission.value }

        store.start()
        admission.value = false
        await Task.yield()
        await Task.yield()

        let count = try await fixture.database.pool.read { try CallRow.fetchCount($0) }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(store.snapshot.phase, .idle)
    }

    func testAutomaticStartReturnsAdmissionClosedWhenInitialBarrierIsClosed() async throws {
        let fixture = try CallRecordingStoreFixture()
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }
        store.admissionAllowed = { false }

        let result = await store.startAutomatic(idempotencyKey: "automatic:barrier-initial")

        guard case .admissionClosed = result else {
            return XCTFail("Expected the transient admission result.")
        }
        let count = try await fixture.database.pool.read { try CallRow.fetchCount($0) }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(store.snapshot.phase, .idle)
    }

    func testAutomaticStartLatchesScheduledAdmissionClosureEvenIfBarrierReopens() async throws {
        let fixture = try CallRecordingStoreFixture()
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }
        var checks = 0
        store.admissionAllowed = {
            checks += 1
            return checks != 2
        }

        let result = await store.startAutomatic(idempotencyKey: "automatic:barrier-race")

        guard case .admissionClosed = result else {
            return XCTFail("The exact failed admission check must remain latched.")
        }
        XCTAssertGreaterThanOrEqual(checks, 2)
        let count = try await fixture.database.pool.read { try CallRow.fetchCount($0) }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(store.snapshot.phase, .idle)
    }

    func testAutomaticStartRealAudioFailureDoesNotReportAdmissionClosed() async throws {
        let fixture = try CallRecordingStoreFixture(actualSources: CallSourceSelection.none)
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }

        let result = await store.startAutomatic(idempotencyKey: "automatic:capture-failure")

        guard case .failed = result else {
            return XCTFail("A real capture failure must remain suppressible.")
        }
    }

    func testAutomaticStartLatchesPermissionGateCycleDuringAudioStart() async throws {
        let fixture = try CallRecordingStoreFixture(
            actualSources: CallSourceSelection.none,
            suspendAudioStart: true
        )
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: true) }
        let permissionAdmission = StoreAdmissionFlag()
        store.automaticStartAdmissionAllowed = { permissionAdmission.value }

        let start = Task { @MainActor in
            await store.startAutomatic(idempotencyKey: "automatic:permission-race")
        }
        await fixture.waitUntilAudioStartIsBlocked()
        permissionAdmission.value = false
        store.automaticStartAdmissionChanged(isClosed: true)
        permissionAdmission.value = true
        store.automaticStartAdmissionChanged(isClosed: false)
        await fixture.resumeAudioStart()

        guard case .admissionClosed = await start.value else {
            return XCTFail("A gate that closed mid-start must release/re-probe after grant.")
        }
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(store.snapshot.phase, .idle)
    }

    func testAutomaticStartIgnoresOpeningAdmissionEdgeDuringAudioStart() async throws {
        let fixture = try CallRecordingStoreFixture(
            actualSources: CallSourceSelection(me: true, system: false),
            suspendAudioStart: true
        )
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }

        let start = Task { @MainActor in
            await store.startAutomatic(idempotencyKey: "automatic:opening-edge")
        }
        await fixture.waitUntilAudioStartIsBlocked()
        store.automaticStartAdmissionChanged(isClosed: false)
        await fixture.resumeAudioStart()

        guard case .started = await start.value else {
            return XCTFail("An opening or irrelevant edge must not fragment a healthy start.")
        }
        XCTAssertTrue(store.isActive)
        let stopCount = await fixture.audioStopCount()
        XCTAssertEqual(stopCount, 0)
        await store.endAndWait(reason: .user)
    }

    func testStartScopedLeaseRemainsInvalidAfterAClosingEdgeReopens() async throws {
        let fixture = try CallRecordingStoreFixture(
            actualSources: CallSourceSelection(me: true, system: false),
            suspendAudioStart: true
        )
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }

        let start = Task { @MainActor in
            await store.startAutomatic(idempotencyKey: "automatic:start-lease-aba")
        }
        await fixture.waitUntilAudioStartIsBlocked()
        let capturedLease = await fixture.capturedStartAdmissionLease()
        let lease = try XCTUnwrap(capturedLease)
        XCTAssertTrue(store.permitsCallAudioStart(lease))

        store.automaticStartAdmissionChanged(isClosed: true)
        store.automaticStartAdmissionChanged(isClosed: false)
        XCTAssertFalse(
            store.permitsCallAudioStart(lease),
            "A close-and-reopen before sink admission must not validate the stale in-flight start"
        )

        await fixture.resumeAudioStart()
        guard case .admissionClosed = await start.value else {
            return XCTFail("The stale start must be discarded and re-probed after the closing edge")
        }
    }

    func testConcurrentTerminalEndWaitersJoinTheSamePhysicalStop() async throws {
        let fixture = try CallRecordingStoreFixture(suspendAudioStop: true)
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }

        let started = await store.startAutomatic(idempotencyKey: "automatic:end-join")
        XCTAssertNotNil(started.snapshot)

        let firstEnd = Task { @MainActor in
            await store.endAndWait(reason: .maintenance)
        }
        await fixture.waitUntilAudioStopIsBlocked()

        var secondReturned = false
        let secondEntered = expectation(description: "second terminal waiter entered")
        let secondEnd = Task { @MainActor in
            secondEntered.fulfill()
            await store.endAndWait(reason: .privacy)
            secondReturned = true
        }
        await fulfillment(of: [secondEntered], timeout: 1)
        XCTAssertFalse(secondReturned)

        await fixture.resumeAudioStop()
        await firstEnd.value
        await secondEnd.value
        XCTAssertTrue(secondReturned)
        XCTAssertFalse(store.isActive)
    }

    func testUserEndUpgradesInFlightLowDiskStopBeforeCompletion() async throws {
        try await assertJoinedEndUpgradesLowDisk(to: .user)
    }

    func testPrivacyEndUpgradesInFlightLowDiskStopBeforeCompletion() async throws {
        try await assertJoinedEndUpgradesLowDisk(to: .privacy)
    }

    func testUserEndRegistersTerminalIntentBeforeQueuedLowDiskCompletionRuns() async throws {
        let fixture = try CallRecordingStoreFixture(suspendAudioStop: true)
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }
        var completions: [(CallStopReason, Bool)] = []
        store.onEndCompleted = { completions.append(($0, $1)) }

        let started = await store.startAutomatic(
            idempotencyKey: "automatic:user-ui-low-disk"
        )
        XCTAssertNotNil(started.snapshot)
        let lowDiskEnd = Task { @MainActor in
            await store.endAndWait(reason: .lowDisk)
        }
        await fixture.waitUntilAudioStopIsBlocked()

        store.end()
        await fixture.resumeAudioStop()
        await lowDiskEnd.value

        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while completions.isEmpty, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertEqual(completions.map(\.0), [.user])
        XCTAssertEqual(completions.map(\.1), [true])
    }

    func testConcurrentAutomaticFinishRequestsShareOnePhysicalStop() async throws {
        let fixture = try CallRecordingStoreFixture(suspendAudioStop: true)
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }

        let started = await store.startAutomatic(
            idempotencyKey: "automatic:finish-once"
        )
        let callID = try XCTUnwrap(started.snapshot?.callID)
        let first = Task { @MainActor in
            await store.finishAutomaticAndWait(reason: .automatic)
        }
        await fixture.waitUntilAudioStopIsBlocked()

        var duplicateReturned = false
        let duplicate = Task { @MainActor in
            let snapshot = await store.finishAutomaticAndWait(reason: .automatic)
            duplicateReturned = true
            return snapshot
        }
        await Task.yield()
        XCTAssertFalse(duplicateReturned)

        await fixture.resumeAudioStop()
        let firstResult = await first.value
        let duplicateResult = await duplicate.value
        XCTAssertEqual(firstResult?.phase, .pendingTranscription)
        XCTAssertEqual(firstResult?.callID, callID)
        XCTAssertEqual(duplicateResult, firstResult)
        let stopCount = await fixture.audioStopCount()
        XCTAssertEqual(stopCount, 1)
        let finalJobs = try await fixture.database.pool.read { db in
            try CallTranscriptJobRow
                .filter(
                    Column("callId") == callID
                        && Column("kind") == CallTranscriptJobKind.final.rawValue
                )
                .fetchCount(db)
        }
        XCTAssertEqual(finalJobs, 1)
    }

    func testExternalEndPreflightCompletesBeforePhysicalAudioStop() async throws {
        let fixture = try CallRecordingStoreFixture()
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }
        let preflight = StoreAutomaticRejectionPreflight()
        var observedReason: CallStopReason?
        store.onEndWillPrepare = { reason in
            observedReason = reason
            _ = await preflight.run()
        }

        let started = await store.startAutomatic(
            idempotencyKey: "automatic:external-end-preflight"
        )
        XCTAssertNotNil(started.snapshot)
        let end = Task { @MainActor in
            await store.endAndWait(reason: .privacy)
        }
        await preflight.waitUntilBlocked()

        XCTAssertEqual(observedReason, .privacy)
        let stopsBeforePreflight = await fixture.audioStopCount()
        XCTAssertEqual(stopsBeforePreflight, 0)

        await preflight.resume(result: true)
        await end.value
        let stopsAfterPreflight = await fixture.audioStopCount()
        XCTAssertEqual(stopsAfterPreflight, 1)
    }

    func testStrongerUserIntentRunsItsBoundaryHookWhenItJoinsPhysicalStop() async throws {
        let fixture = try CallRecordingStoreFixture(suspendAudioStop: true)
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }
        var observedReasons: [CallStopReason] = []
        store.onEndWillPrepare = { reason in observedReasons.append(reason) }

        let started = await store.startAutomatic(
            idempotencyKey: "automatic:joined-boundary-hook"
        )
        XCTAssertNotNil(started.snapshot)
        let lowDiskEnd = Task { @MainActor in
            await store.endAndWait(reason: .lowDisk)
        }
        await fixture.waitUntilAudioStopIsBlocked()
        XCTAssertEqual(observedReasons, [.lowDisk])

        store.end()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !observedReasons.contains(.user), ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertEqual(observedReasons, [.lowDisk, .user])

        await fixture.resumeAudioStop()
        await lowDiskEnd.value
        XCTAssertEqual(store.snapshot.stopReason, .user)
    }

    func testAutomaticFinishAcceptsStrongerIntentMatrixBeforeSeal() async throws {
        for disposition: SealedCallEndDisposition in [
            .finish(.user),
            .finish(.privacy),
            .finish(.maintenance),
        ] {
            try await assertAutomaticFinishAccepts(disposition)
        }
    }

    private func assertAutomaticFinishAccepts(
        _ disposition: SealedCallEndDisposition
    ) async throws {
        let fixture = try CallRecordingStoreFixture(suspendAudioStop: true)
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }

        let started = await store.startAutomatic(
            idempotencyKey: "automatic:finish-upgrade:\(disposition.stopReason.rawValue)"
        )
        let callID = try XCTUnwrap(started.snapshot?.callID)

        let automaticCommit = Task { @MainActor in
            await store.finishAutomaticAndWait(reason: .automatic)
        }
        await fixture.waitUntilAudioStopIsBlocked()

        let strongerEnd = Task<Int64?, Never> { @MainActor in
            switch disposition {
            case .finish(let reason):
                await store.endAndWait(reason: reason)
                return callID
            case .rejectAutomatic:
                guard let request = store.requestAutomaticRejection(
                    preflight: { true }
                ) else { return nil }
                return await store.rejectAutomaticAndWait(request: request)
            }
        }
        await Task.yield()
        await fixture.resumeAudioStop()
        let committed = await automaticCommit.value
        let completedCallID = await strongerEnd.value
        XCTAssertEqual(completedCallID, callID)

        let persisted = try await fixture.database.pool.read { db in
            try XCTUnwrap(CallRow.fetchOne(db, key: callID))
        }
        switch disposition {
        case .finish(let reason):
            XCTAssertEqual(committed?.phase, .pendingTranscription)
            XCTAssertEqual(committed?.stopReason, reason)
            XCTAssertEqual(store.snapshot.stopReason, reason)
            XCTAssertEqual(persisted.degradationReason, reason.persistenceCode)
        case .rejectAutomatic:
            XCTAssertEqual(committed?.phase, .idle)
            XCTAssertEqual(store.snapshot, .idle)
            XCTAssertEqual(persisted.state, .interrupted)
            XCTAssertEqual(persisted.degradationReason, "automatic_rejected")
        }
        let stopCount = await fixture.audioStopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testUserJoinBeforeSealPublishesOnlyFinalReason() async throws {
        let fixture = try CallRecordingStoreFixture(suspendAudioStop: true)
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }
        var completions: [(CallStopReason, Bool)] = []
        store.onEndCompleted = { completions.append(($0, $1)) }
        try await fixture.enableAutomation()

        let started = await store.startAutomatic(
            idempotencyKey: "automatic:user-before-seal"
        )
        let callID = try XCTUnwrap(started.snapshot?.callID)
        let lowDiskEnd = Task { @MainActor in
            await store.endAndWait(reason: .lowDisk)
        }
        await fixture.waitUntilAudioStopIsBlocked()

        let beforeSeal = try await fixture.database.pool.read { db in
            try XCTUnwrap(CallRow.fetchOne(db, key: callID))
        }
        XCTAssertEqual(beforeSeal.state, .recording)
        let eventCountBeforeSeal = try await fixture.database.pool.read { db in
            try CallAutomationOutboxRow
                .filter(Column("callId") == callID)
                .fetchCount(db)
        }
        XCTAssertEqual(eventCountBeforeSeal, 0)

        let userEnd = Task { @MainActor in
            await store.endAndWait(reason: .user)
        }
        await Task.yield()
        await fixture.resumeAudioStop()
        await lowDiskEnd.value
        await userEnd.value

        let persisted = try await fixture.database.pool.read { db in
            try XCTUnwrap(CallRow.fetchOne(db, key: callID))
        }
        XCTAssertNil(persisted.degradationReason)
        XCTAssertEqual(store.snapshot.stopReason, .user)
        XCTAssertEqual(completions.map(\.0), [.user])
        XCTAssertEqual(completions.map(\.1), [true])
        let event = try await fixture.database.pool.read { db in
            try XCTUnwrap(
                CallAutomationOutboxRow
                    .filter(
                        Column("callId") == callID
                            && Column("eventType") == CallAutomationEventType.callEnded.rawValue
                    )
                    .fetchOne(db)
            )
        }
        let eventData = try XCTUnwrap(event.payloadJSON.data(using: .utf8))
        XCTAssertFalse(try JSONDecoder().decode(CallEndedAutomationData.self, from: eventData).degraded)
    }

    func testUserJoinPreservesPreexistingSourceUnavailableEvidence() async throws {
        let fixture = try CallRecordingStoreFixture(
            actualSources: CallSourceSelection(me: true, system: false),
            suspendAudioStop: true
        )
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: true) }
        try await fixture.enableAutomation()

        let started = await store.startAutomatic(
            idempotencyKey: "automatic:partial-source-before-user"
        )
        let callID = try XCTUnwrap(started.snapshot?.callID)
        XCTAssertEqual(started.snapshot?.system, .unavailable)

        let lowDiskEnd = Task { @MainActor in
            await store.endAndWait(reason: .lowDisk)
        }
        await fixture.waitUntilAudioStopIsBlocked()
        let userEnd = Task { @MainActor in
            await store.endAndWait(reason: .user)
        }
        await Task.yield()
        await fixture.resumeAudioStop()
        await lowDiskEnd.value
        await userEnd.value

        let persisted = try await fixture.database.pool.read { db in
            (
                call: try XCTUnwrap(CallRow.fetchOne(db, key: callID)),
                event: try XCTUnwrap(
                    CallAutomationOutboxRow
                        .filter(
                            Column("callId") == callID
                                && Column("eventType")
                                    == CallAutomationEventType.callEnded.rawValue
                        )
                        .fetchOne(db)
                )
            )
        }
        XCTAssertEqual(persisted.call.degradationReason, "source_unavailable")
        XCTAssertEqual(store.snapshot.stopReason, .user)
        let eventData = try XCTUnwrap(persisted.event.payloadJSON.data(using: .utf8))
        XCTAssertTrue(
            try JSONDecoder().decode(CallEndedAutomationData.self, from: eventData).degraded
        )
    }

    func testAutomaticRejectionPreflightCompletesBeforePhysicalStop() async throws {
        let fixture = try CallRecordingStoreFixture()
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }
        let preflight = StoreAutomaticRejectionPreflight()

        let started = await store.startAutomatic(
            idempotencyKey: "automatic:receipt-before-stop"
        )
        let callID = try XCTUnwrap(started.snapshot?.callID)
        let request = try XCTUnwrap(
            store.requestAutomaticRejection {
                await preflight.run()
            }
        )
        await preflight.waitUntilBlocked()

        let stopCountBeforeReceipt = await fixture.audioStopCount()
        XCTAssertEqual(stopCountBeforeReceipt, 0)
        XCTAssertTrue(store.isActive)
        await preflight.resume(result: true)

        let rejectedCallID = await store.rejectAutomaticAndWait(request: request)
        XCTAssertEqual(rejectedCallID, callID)
        let stopCountAfterReceipt = await fixture.audioStopCount()
        XCTAssertEqual(stopCountAfterReceipt, 1)
        XCTAssertEqual(store.snapshot, .idle)
    }

    func testFailedAutomaticRejectionPreflightLeavesRecordingActive() async throws {
        let fixture = try CallRecordingStoreFixture()
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }
        let preflight = StoreAutomaticRejectionPreflight()

        let started = await store.startAutomatic(
            idempotencyKey: "automatic:receipt-failure-keeps-recording"
        )
        let callID = try XCTUnwrap(started.snapshot?.callID)
        let request = try XCTUnwrap(
            store.requestAutomaticRejection {
                await preflight.run()
            }
        )
        await preflight.waitUntilBlocked()
        await preflight.resume(result: false)

        let rejectedCallID = await store.rejectAutomaticAndWait(request: request)
        XCTAssertNil(rejectedCallID)
        let stopCount = await fixture.audioStopCount()
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(store.snapshot.phase, .recording)
        XCTAssertEqual(store.snapshot.callID, callID)
        XCTAssertTrue(store.isActive)
    }

    func testAutomaticRejectionDominatesLowDiskFallbackAfterDurablePreflight() async throws {
        try await assertAutomaticRejectionPreflight(
            succeeds: true,
            expectedDisposition: .rejectAutomatic
        )
    }

    func testFailedAutomaticRejectionPreflightFallsBackToJoinedLowDiskEnd() async throws {
        try await assertAutomaticRejectionPreflight(
            succeeds: false,
            expectedDisposition: .finish(.lowDisk)
        )
    }

    func testAutomaticRejectionRequestRetainsItsCompletedTaskForPrivacyCleanup() async throws {
        let fixture = try CallRecordingStoreFixture()
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }
        try await fixture.enableAutomation()

        let started = await store.startAutomatic(
            idempotencyKey: "automatic:rejection-completes-before-wait"
        )
        let callID = try XCTUnwrap(started.snapshot?.callID)
        let request = try XCTUnwrap(
            store.requestAutomaticRejection(preflight: { true })
        )

        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while store.snapshot.phase != .idle, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertEqual(store.snapshot.phase, .idle)

        // AppEnvironment may persist the rejection context before awaiting teardown. The exact
        // request handle must still expose the completed result after Store has cleared endTask.
        let rejectedID = await store.rejectAutomaticAndWait(request: request)
        XCTAssertEqual(rejectedID, callID)

        let persisted = try await fixture.database.pool.read { db in
            (
                call: try XCTUnwrap(CallRow.fetchOne(db, key: callID)),
                jobs: try CallTranscriptJobRow
                    .filter(Column("callId") == callID)
                    .fetchCount(db),
                events: try CallAutomationOutboxRow
                    .filter(Column("callId") == callID)
                    .fetchCount(db)
            )
        }
        XCTAssertEqual(persisted.call.degradationReason, "automatic_rejected")
        XCTAssertEqual(persisted.jobs, 0)
        XCTAssertEqual(persisted.events, 0)
    }

    private func assertAutomaticRejectionPreflight(
        succeeds: Bool,
        expectedDisposition: SealedCallEndDisposition
    ) async throws {
        let fixture = try CallRecordingStoreFixture(suspendAudioStop: true)
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }
        try await fixture.enableAutomation()
        let preflight = StoreAutomaticRejectionPreflight()

        let started = await store.startAutomatic(
            idempotencyKey: "automatic:reject-low-disk:\(succeeds)"
        )
        let callID = try XCTUnwrap(started.snapshot?.callID)

        let rejectionRequest = try XCTUnwrap(
            store.requestAutomaticRejection {
                await preflight.run()
            }
        )
        XCTAssertEqual(rejectionRequest.callID, callID)
        await preflight.waitUntilBlocked()
        let stopCountBeforePreflight = await fixture.audioStopCount()
        XCTAssertEqual(stopCountBeforePreflight, 0)

        let lowDiskEntered = expectation(description: "low-disk fallback joined")
        let lowDiskEnd = Task { @MainActor in
            lowDiskEntered.fulfill()
            await store.endAndWait(reason: .lowDisk)
        }
        await fulfillment(of: [lowDiskEntered], timeout: 1)
        await preflight.resume(result: succeeds)
        await fixture.waitUntilAudioStopIsBlocked()
        let rejection = Task { @MainActor in
            await store.rejectAutomaticAndWait(request: rejectionRequest)
        }
        await fixture.resumeAudioStop()
        await lowDiskEnd.value
        let rejectedID = await rejection.value
        XCTAssertEqual(
            rejectedID,
            expectedDisposition == .rejectAutomatic ? callID : nil
        )

        let persisted = try await fixture.database.pool.read { db in
            (
                call: try XCTUnwrap(CallRow.fetchOne(db, key: callID)),
                jobs: try CallTranscriptJobRow
                    .filter(Column("callId") == callID)
                    .fetchCount(db),
                events: try CallAutomationOutboxRow
                    .filter(Column("callId") == callID)
                    .fetchCount(db)
            )
        }
        if expectedDisposition == .rejectAutomatic {
            XCTAssertEqual(persisted.call.state, .interrupted)
            XCTAssertEqual(persisted.call.degradationReason, "automatic_rejected")
            XCTAssertEqual(persisted.jobs, 0)
            XCTAssertEqual(persisted.events, 0)
            XCTAssertEqual(store.snapshot, .idle)
        } else {
            XCTAssertEqual(
                persisted.call.degradationReason,
                CallStopReason.lowDisk.persistenceCode
            )
            XCTAssertEqual(store.snapshot.stopReason, .lowDisk)
        }
        let stopCount = await fixture.audioStopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testRequestsAfterSealCannotRewriteCommittedLowDiskEnd() async throws {
        let fixture = try CallRecordingStoreFixture(
            suspendAudioStop: true,
            suspendAfterSourceTransition: true
        )
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }
        try await fixture.enableAutomation()
        var userEndRequests = 0
        store.onUserEndRequested = { userEndRequests += 1 }

        let started = await store.startAutomatic(
            idempotencyKey: "automatic:post-seal-low-disk"
        )
        let callID = try XCTUnwrap(started.snapshot?.callID)
        XCTAssertEqual(store.automaticRejectionCandidateCallID(), callID)
        let lowDiskEnd = Task { @MainActor in
            await store.endAndWait(reason: .lowDisk)
        }
        await fixture.waitUntilAudioStopIsBlocked()
        XCTAssertNil(store.automaticRejectionCandidateCallID())
        await fixture.resumeAudioStop()
        await fixture.waitUntilAfterSourceTransitionIsBlocked()

        XCTAssertNil(store.automaticRejectionCandidateCallID())
        XCTAssertNil(store.requestAutomaticRejection(preflight: { true }))
        store.end()
        XCTAssertEqual(userEndRequests, 0)
        XCTAssertEqual(store.snapshot.phase, .finalizing)
        XCTAssertEqual(store.snapshot.stopReason, .lowDisk)

        let committed = try await fixture.database.pool.read { db in
            (
                call: try XCTUnwrap(CallRow.fetchOne(db, key: callID)),
                event: try XCTUnwrap(
                    CallAutomationOutboxRow
                        .filter(
                            Column("callId") == callID
                                && Column("eventType")
                                    == CallAutomationEventType.callEnded.rawValue
                        )
                        .fetchOne(db)
                )
            )
        }
        XCTAssertEqual(
            committed.call.degradationReason,
            CallStopReason.lowDisk.persistenceCode
        )

        await fixture.resumeAfterSourceTransition()
        await lowDiskEnd.value
        XCTAssertNil(store.automaticRejectionCandidateCallID())
        XCTAssertEqual(store.snapshot.stopReason, .lowDisk)
        let eventData = try XCTUnwrap(committed.event.payloadJSON.data(using: .utf8))
        XCTAssertTrue(
            try JSONDecoder().decode(CallEndedAutomationData.self, from: eventData).degraded
        )
    }

    func testAutomaticSaveObservesTheSameCallWhenAnotherFinishAlreadySealed() async throws {
        let fixture = try CallRecordingStoreFixture(
            suspendAfterSourceTransition: true
        )
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }

        let started = await store.startAutomatic(
            idempotencyKey: "automatic:observe-sealed-finish"
        )
        let callID = try XCTUnwrap(started.snapshot?.callID)
        let userEnd = Task { @MainActor in
            await store.endAndWait(reason: .user)
        }
        await fixture.waitUntilAfterSourceTransitionIsBlocked()
        XCTAssertEqual(store.snapshot.phase, .finalizing)
        XCTAssertEqual(store.snapshot.callID, callID)

        var observerReturned = false
        let automaticObserver = Task { @MainActor in
            let result = await store.finishAutomaticAndWait(reason: .automatic)
            observerReturned = true
            return result
        }
        await Task.yield()
        XCTAssertFalse(observerReturned)

        await fixture.resumeAfterSourceTransition()
        await userEnd.value
        let observed = await automaticObserver.value
        XCTAssertEqual(observed?.callID, callID)
        XCTAssertEqual(observed?.phase, .pendingTranscription)
        XCTAssertEqual(observed?.stopReason, .user)
        let stopCount = await fixture.audioStopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testQueuedEndWithNoActiveCallCannotLeakReasonIntoNextCall() async throws {
        let fixture = try CallRecordingStoreFixture(suspendAudioStop: true)
        defer { fixture.cleanup() }
        let requested = CallSourceSelection(me: true, system: false)

        _ = try await fixture.coordinator.start(
            request: requested,
            idempotencyKey: "coordinator:stale-reason:first"
        )
        let reject = Task {
            try await fixture.coordinator.rejectAutomatic()
        }
        await fixture.waitUntilAudioStopIsBlocked()
        let queuedEnd = Task {
            try await fixture.coordinator.end(reason: .privacy)
        }
        await fixture.resumeAudioStop()
        _ = try await reject.value
        _ = try await queuedEnd.value

        let second = try await fixture.coordinator.start(
            request: requested,
            idempotencyKey: "coordinator:stale-reason:second"
        )
        let secondID = try XCTUnwrap(second.callID)
        _ = try await fixture.coordinator.end(reason: .lowDisk)

        let persisted = try await fixture.database.pool.read { db in
            try XCTUnwrap(CallRow.fetchOne(db, key: secondID))
        }
        XCTAssertEqual(
            persisted.degradationReason,
            CallStopReason.lowDisk.persistenceCode
        )
    }

    private func assertJoinedEndUpgradesLowDisk(to terminalReason: CallStopReason) async throws {
        let fixture = try CallRecordingStoreFixture(suspendAudioStop: true)
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }
        var completions: [(CallStopReason, Bool)] = []
        store.onEndCompleted = { completions.append(($0, $1)) }

        let started = await store.startAutomatic(
            idempotencyKey: "automatic:low-disk-upgrade:\(terminalReason.rawValue)"
        )
        XCTAssertNotNil(started.snapshot)

        let lowDiskEnd = Task { @MainActor in
            await store.endAndWait(reason: .lowDisk)
        }
        await fixture.waitUntilAudioStopIsBlocked()

        var joinedReturned = false
        let joinedEnd = Task { @MainActor in
            await store.endAndWait(reason: terminalReason)
            joinedReturned = true
        }
        await Task.yield()
        XCTAssertFalse(joinedReturned)

        await fixture.resumeAudioStop()
        await lowDiskEnd.value
        await joinedEnd.value

        XCTAssertEqual(completions.map(\.0), [terminalReason])
        XCTAssertEqual(completions.map(\.1), [true])
        XCTAssertEqual(store.snapshot.stopReason, terminalReason)
        let call = try await fixture.database.pool.read { db in
            try XCTUnwrap(CallRow.fetchOne(db))
        }
        XCTAssertEqual(call.degradationReason, terminalReason.persistenceCode)
        XCTAssertNotEqual(call.degradationReason, CallStopReason.lowDisk.persistenceCode)
    }

    func testFailedAutomaticRejectStillReturnsCallIDForPrivacyCleanup() async throws {
        let fixture = try CallRecordingStoreFixture()
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }

        let startedCandidate = await store.startAutomatic(idempotencyKey: "automatic:test")
        let started = try XCTUnwrap(startedCandidate.snapshot)
        let callID = try XCTUnwrap(started.callID)
        try fixture.database.pool.close()

        let request = try XCTUnwrap(
            store.requestAutomaticRejection(preflight: { true })
        )
        let rejectedID = await store.rejectAutomaticAndWait(request: request)

        XCTAssertEqual(rejectedID, callID)
        XCTAssertEqual(store.snapshot.phase, .idle)
        XCTAssertNotNil(store.errorMessage)
    }

    func testFailedAutomaticCommitReturnsInactiveFailureForLifecycleCleanup() async throws {
        let fixture = try CallRecordingStoreFixture()
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }

        let started = await store.startAutomatic(
            idempotencyKey: "automatic:failed-deadline-commit"
        )
        XCTAssertNotNil(started.snapshot)
        try fixture.database.pool.close()

        let committed = await store.finishAutomaticAndWait(reason: .automatic)

        XCTAssertEqual(committed?.phase, .failed)
        XCTAssertEqual(store.snapshot.phase, .failed)
        XCTAssertFalse(store.isActive)
        XCTAssertNotNil(store.errorMessage)
        let stopCount = await fixture.audioStopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testFailedTerminalPersistenceReportsDidFinishFalse() async throws {
        let fixture = try CallRecordingStoreFixture()
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }
        var completions: [(CallStopReason, Bool)] = []
        store.onEndCompleted = { completions.append(($0, $1)) }

        let started = await store.startAutomatic(
            idempotencyKey: "automatic:failed-completion-signal"
        )
        XCTAssertNotNil(started.snapshot)
        try fixture.database.pool.close()

        await store.endAndWait(reason: .user)

        XCTAssertEqual(completions.map(\.0), [.user])
        XCTAssertEqual(completions.map(\.1), [false])
        XCTAssertEqual(store.snapshot.phase, .failed)
        XCTAssertNotNil(store.errorMessage)
    }

    func testUserEndSignalsSynchronouslyWithoutClassifyingInternalEndsAsUserStops() async throws {
        let fixture = try CallRecordingStoreFixture()
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }
        var userEndRequests = 0
        var endCompletions: [(CallStopReason, Bool)] = []
        var completionObservedInactive = false
        store.onUserEndRequested = { userEndRequests += 1 }
        store.onEndCompleted = { reason, didFinish in
            endCompletions.append((reason, didFinish))
            completionObservedInactive = !store.isActive
        }

        let automaticStart = await store.startAutomatic(idempotencyKey: "automatic:direct-end")
        let automaticCommit = await store.finishAutomaticAndWait(reason: .automatic)
        XCTAssertNotNil(automaticStart.snapshot)
        XCTAssertNotNil(automaticCommit)
        XCTAssertEqual(userEndRequests, 0)

        let userStart = await store.startAutomatic(idempotencyKey: "automatic:user-end")
        XCTAssertNotNil(userStart.snapshot)
        store.end()
        XCTAssertEqual(
            userEndRequests,
            1,
            "The lifecycle owner must be notified before the asynchronous user stop begins."
        )

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while store.isActive, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(endCompletions.map(\.0), [.user])
        XCTAssertEqual(endCompletions.map(\.1), [true])
        XCTAssertTrue(
            completionObservedInactive,
            "Detector release must not be requested until the recording store is physically idle."
        )

        let privacyStart = await store.startAutomatic(idempotencyKey: "automatic:privacy-end")
        XCTAssertNotNil(privacyStart.snapshot)
        await store.endAndWait(reason: .privacy)
        XCTAssertEqual(userEndRequests, 1)
        XCTAssertEqual(endCompletions.map(\.0), [.user, .privacy])
        XCTAssertEqual(endCompletions.map(\.1), [true, true])
    }
}

@MainActor
private final class StoreAdmissionFlag {
    var value = true
}

private final class CallRecordingStoreFixture {
    let root: URL
    let database: ZBSEyeDatabase
    let coordinator: CallCoordinator
    private let audio: StoreCallAudio
    private let transition: StoreCallTransitionGate

    init(
        actualSources: CallSourceSelection? = nil,
        suspendAudioStart: Bool = false,
        suspendAudioStop: Bool = false,
        suspendAfterSourceTransition: Bool = false
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-call-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        audio = StoreCallAudio(
            actual: actualSources,
            suspendStart: suspendAudioStart,
            suspendStop: suspendAudioStop
        )
        transition = StoreCallTransitionGate(suspended: suspendAfterSourceTransition)
        coordinator = CallCoordinator(
            repository: CallRepository(database: database),
            mediaRoot: root.appendingPathComponent("media", isDirectory: true),
            audio: audio.control(),
            now: { Date(timeIntervalSince1970: 1) },
            afterSourceTransition: { [transition] in
                await transition.cross()
            }
        )
    }

    func waitUntilAudioStartIsBlocked() async {
        await audio.waitUntilStartIsBlocked()
    }

    func resumeAudioStart() async {
        await audio.resumeStart()
    }

    func waitUntilAudioStopIsBlocked() async {
        await audio.waitUntilStopIsBlocked()
    }

    func resumeAudioStop() async {
        await audio.resumeStop()
    }

    func audioStopCount() async -> Int {
        await audio.stopCount()
    }

    func capturedStartAdmissionLease() async -> CallAudioStartAdmissionLease? {
        await audio.capturedStartAdmissionLease()
    }

    func waitUntilAfterSourceTransitionIsBlocked() async {
        await transition.waitUntilBlocked()
    }

    func resumeAfterSourceTransition() async {
        await transition.resume()
    }

    func enableAutomation() async throws {
        try await database.pool.write { db in
            var config = try XCTUnwrap(CallAutomationConfigRow.fetchOne(db, key: 1))
            config.enabled = true
            config.endpointURL = "http://127.0.0.1:9876/call-event"
            config.endpointFingerprint = "fixture-receiver"
            config.updatedAtMs = 1
            try config.update(db)
        }
    }

    func cleanup() {
        try? database.pool.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private actor StoreAutomaticRejectionPreflight {
    private var blocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Bool, Never>?

    func run() async -> Bool {
        blocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        let result = await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        blocked = false
        return result
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func resume(result: Bool) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private actor StoreCallTransitionGate {
    private var suspended: Bool
    private var blocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    init(suspended: Bool) {
        self.suspended = suspended
    }

    func cross() async {
        guard suspended else { return }
        blocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        blocked = false
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func resume() {
        suspended = false
        continuation?.resume()
        continuation = nil
    }
}

private actor StoreCallAudio {
    private var sink: CallAudioFrameSink?
    private var frameAdmission = CallAudioFrameAdmissionLatch()
    private var lastStartAdmissionLease: CallAudioStartAdmissionLease?
    private let actual: CallSourceSelection?
    private var suspendStart: Bool
    private var startIsBlocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var suspendStop: Bool
    private var stopIsBlocked = false
    private var stopBlockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var stops = 0

    init(
        actual: CallSourceSelection? = nil,
        suspendStart: Bool = false,
        suspendStop: Bool = false
    ) {
        self.actual = actual
        self.suspendStart = suspendStart
        self.suspendStop = suspendStop
    }

    nonisolated func control() -> CallAudioControl {
        CallAudioControl(
            installSink: { [weak self] sink in await self?.setSink(sink) },
            start: { [weak self] requested, sinkLease, startAdmissionLease in
                guard let self else { return .none }
                return await self.start(
                    requested,
                    sinkLease: sinkLease,
                    startAdmissionLease: startAdmissionLease
                )
            },
            acceptedTargets: { AudioIngressTargets(me: nil, system: nil) },
            drainGaps: { [] },
            stop: { [weak self] in await self?.stop() }
        )
    }

    func waitUntilStartIsBlocked() async {
        guard !startIsBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func resumeStart() {
        suspendStart = false
        startContinuation?.resume()
        startContinuation = nil
    }

    func waitUntilStopIsBlocked() async {
        guard !stopIsBlocked else { return }
        await withCheckedContinuation { continuation in
            stopBlockedWaiters.append(continuation)
        }
    }

    func resumeStop() {
        suspendStop = false
        stopContinuation?.resume()
        stopContinuation = nil
    }

    func stopCount() -> Int {
        stops
    }

    func capturedStartAdmissionLease() -> CallAudioStartAdmissionLease? {
        lastStartAdmissionLease
    }

    private func setSink(_ sink: CallAudioFrameSink?) -> CallAudioFrameAdmissionLease? {
        self.sink = sink
        return frameAdmission.installSink(present: sink != nil)
    }

    private func start(
        _ requested: CallSourceSelection,
        sinkLease: CallAudioFrameAdmissionLease,
        startAdmissionLease: CallAudioStartAdmissionLease
    ) async -> CallSourceSelection {
        lastStartAdmissionLease = startAdmissionLease
        guard frameAdmission.admit(sinkLease) else { return .none }
        if suspendStart {
            startIsBlocked = true
            let waiters = blockedWaiters
            blockedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
            startIsBlocked = false
        }
        return actual ?? requested
    }

    private func stop() async {
        stops += 1
        guard suspendStop else { return }
        stopIsBlocked = true
        let waiters = stopBlockedWaiters
        stopBlockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
        stopIsBlocked = false
    }
}
