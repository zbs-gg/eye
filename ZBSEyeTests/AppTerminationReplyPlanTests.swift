import XCTest

final class AppTerminationReplyPlanTests: XCTestCase {
    func testPrivacyGateAtomicallyExcludesAutomaticRejectionAcrossTerminationAwaits() {
        var gate = AppTerminationPrivacyGate()

        XCTAssertTrue(gate.allowsAutomaticRejection)
        XCTAssertTrue(
            gate.acquireTerminationLease(
                automaticRejectionTaskActive: false,
                automaticRejectionCallID: nil
            )
        )
        XCTAssertFalse(gate.allowsAutomaticRejection)
        XCTAssertFalse(
            gate.acquireTerminationLease(
                automaticRejectionTaskActive: false,
                automaticRejectionCallID: nil
            )
        )

        gate.releaseTerminationLease()
        XCTAssertTrue(gate.allowsAutomaticRejection)
    }

    func testPrivacyGateRejectsQuitWhileAutomaticRejectionOwnsEitherStateMarker() {
        var gate = AppTerminationPrivacyGate()

        XCTAssertFalse(
            gate.acquireTerminationLease(
                automaticRejectionTaskActive: true,
                automaticRejectionCallID: nil
            )
        )
        XCTAssertTrue(gate.allowsAutomaticRejection)
        XCTAssertFalse(
            gate.acquireTerminationLease(
                automaticRejectionTaskActive: false,
                automaticRejectionCallID: 42
            )
        )
        XCTAssertTrue(gate.allowsAutomaticRejection)
    }

    func testRecordingDrainDeadlineCoversObservedScreenCaptureKitTeardown() {
        XCTAssertGreaterThanOrEqual(
            AppTerminationDeadlinePolicy.recordingDrain,
            .seconds(15)
        )
    }

    func testCancelledTerminationRepliesBeforeResettingGuardAndShowingAlert() {
        XCTAssertEqual(
            AppTerminationReplyPlan.actions(shouldTerminate: false),
            [.reply(false), .resetTerminationGuard, .showRetryAlert]
        )
    }

    func testSuccessfulTerminationRepliesDirectly() {
        XCTAssertEqual(
            AppTerminationReplyPlan.actions(shouldTerminate: true),
            [.reply(true)]
        )
    }

    func testRelocationHandoffDefersRecoveryToRootRollbackOwner() {
        XCTAssertTrue(AppTerminationRecoveryOwner.quit.recoversServiceGraphInline)
        XCTAssertFalse(
            AppTerminationRecoveryOwner.relocationHandoff.recoversServiceGraphInline
        )
    }

    @MainActor
    func testCriticalPhaseTimeoutIsCallerBoundedAndRecoveryWaitsForCompletion() async {
        let gate = AppTerminationPhaseGate()
        let recoveryProbe = AppTerminationRecoveryProbe()
        let started = ContinuousClock().now

        let phase = await AppTerminationCriticalPhase.run(
            timeout: .milliseconds(20)
        ) {
            await gate.hold()
            return true
        }

        XCTAssertEqual(phase.outcome, .timedOut)
        XCTAssertLessThan(
            started.duration(to: ContinuousClock().now),
            .milliseconds(500)
        )
        let recovery = phase.recoveryTask {
            await recoveryProbe.markRecovered()
        }
        for _ in 0..<20 { await Task.yield() }
        let recoveredBeforeRelease = await recoveryProbe.snapshot()
        XCTAssertFalse(recoveredBeforeRelease)

        await gate.release()
        await recovery.value
        let recoveredAfterRelease = await recoveryProbe.snapshot()
        XCTAssertTrue(recoveredAfterRelease)
    }

    @MainActor
    func testNonCooperativeRecordingDrainRejectsQuitBeforeDeadlineAndDoesNotResumeEarly() async {
        let gate = AppTerminationPhaseGate()
        let recoveryProbe = AppTerminationRecoveryProbe()
        let started = ContinuousClock().now

        let phase = await AppTerminationCriticalPhase.run(
            timeout: .milliseconds(20)
        ) {
            await gate.hold()
            return true
        }
        let shouldTerminate = AppTerminationCriticalPhase.acceptsTermination(phase)
        let recovery = phase.recoveryTask {
            await recoveryProbe.markRecovered()
        }

        XCTAssertFalse(shouldTerminate)
        XCTAssertEqual(
            AppTerminationReplyPlan.actions(shouldTerminate: shouldTerminate),
            [.reply(false), .resetTerminationGuard, .showRetryAlert]
        )
        XCTAssertLessThan(
            started.duration(to: ContinuousClock().now),
            .milliseconds(500)
        )
        for _ in 0..<20 { await Task.yield() }
        let recoveredBeforeRelease = await recoveryProbe.snapshot()
        XCTAssertFalse(recoveredBeforeRelease)

        await gate.release()
        await recovery.value
        let recoveredAfterRelease = await recoveryProbe.snapshot()
        XCTAssertTrue(recoveredAfterRelease)
    }

    @MainActor
    func testRejectedCriticalPhaseFailsClosedAndStillRunsRecovery() async {
        let recoveryProbe = AppTerminationRecoveryProbe()
        let phase = await AppTerminationCriticalPhase.run(
            timeout: .seconds(1)
        ) {
            false
        }

        XCTAssertEqual(phase.outcome, .completed(false))
        let recovery = phase.recoveryTask {
            await recoveryProbe.markRecovered()
        }
        await recovery.value
        let recovered = await recoveryProbe.snapshot()
        XCTAssertTrue(recovered)
    }
}

private actor AppTerminationPhaseGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor AppTerminationRecoveryProbe {
    private var recovered = false
    func markRecovered() { recovered = true }
    func snapshot() -> Bool { recovered }
}
