import XCTest

@MainActor
final class CapturePipelineGenerationTests: XCTestCase {
    func testInvalidationRejectsLateFramesBeforePublishingReplacement() {
        let controller = CaptureHealthController(nowMs: 0)
        controller.screenStreamDidStart(generation: 1, nowMs: 1)
        controller.recordScreenStreamFrame(
            .init(generation: 1, status: .complete, displayTime: 10),
            nowMs: 2
        )
        let firstProgress = controller.snapshot.legs[.screen]?.lastVerifiedProgressAtMs

        controller.invalidatePipeline(.displayChanged, screenLocked: false, nowMs: 3)
        controller.recordScreenStreamFrame(
            .init(generation: 1, status: .complete, displayTime: 11),
            nowMs: 4
        )
        XCTAssertEqual(
            controller.snapshot.legs[.screen]?.lastVerifiedProgressAtMs,
            firstProgress
        )

        controller.screenStreamDidStart(generation: 2, nowMs: 5)
        controller.recordScreenStreamFrame(
            .init(generation: 2, status: .idle, displayTime: 1),
            nowMs: 6
        )
        XCTAssertEqual(controller.pipelineGeneration, 2)
        XCTAssertEqual(controller.snapshot.legs[.screen]?.lastVerifiedProgressAtMs, 6)
    }

    func testWakeWhileLockedCannotPublishAStreamGeneration() {
        let controller = CaptureHealthController(nowMs: 0)
        controller.invalidatePipeline(.wake, screenLocked: true, nowMs: 1)
        controller.screenStreamDidStart(generation: 1, nowMs: 2)
        controller.recordScreenStreamFrame(
            .init(generation: 1, status: .complete, displayTime: 1),
            nowMs: 3
        )
        XCTAssertNil(controller.snapshot.legs[.screen]?.lastVerifiedProgressAtMs)

        controller.invalidatePipeline(.unlock, screenLocked: false, nowMs: 4)
        controller.screenStreamDidStart(generation: 2, nowMs: 5)
        controller.recordScreenStreamFrame(
            .init(generation: 2, status: .complete, displayTime: 2),
            nowMs: 6
        )
        XCTAssertEqual(controller.snapshot.legs[.screen]?.lastVerifiedProgressAtMs, 6)
    }

    func testDelegateFailureRecoversWithFreshIdenticalPixels() {
        var effects: [CaptureHealthEffect] = []
        let controller = CaptureHealthController(nowMs: 0) { effects.append($0) }
        controller.screenStreamDidStart(generation: 1, nowMs: 1)
        controller.recordScreenStreamFrame(
            .init(generation: 1, status: .complete, displayTime: 1),
            nowMs: 2
        )
        controller.recordScreenStreamFailure(
            generation: 1,
            reason: .screenStreamStopped,
            nowMs: 3
        )
        let open = try! XCTUnwrap(effects.lastOpen)
        controller.coverageDidOpen(open, nowMs: 4)
        let attempt = try! XCTUnwrap(effects.lastAttempt)
        XCTAssertEqual(attempt.delayMs, 1_000)
        XCTAssertTrue(controller.markScreenRecoveryReady(attempt))

        controller.screenStreamDidStart(generation: 2, nowMs: 5)
        // No pixel hash is supplied. A fresh idle compositor event proves that
        // an unchanged/static screen recovered normally.
        controller.recordScreenStreamFrame(
            .init(generation: 2, status: .idle, displayTime: 1),
            nowMs: 6
        )
        XCTAssertNotNil(effects.lastClose)
    }

    func testControllerPipelineFailureRetiresActiveGenerationAndOpensRecovery() {
        var effects: [CaptureHealthEffect] = []
        let controller = CaptureHealthController(nowMs: 0) { effects.append($0) }
        controller.screenStreamDidStart(generation: 7, nowMs: 1)
        controller.recordScreenStreamFrame(
            .init(generation: 7, status: .complete, displayTime: 1),
            nowMs: 2
        )

        controller.recordScreenPipelineFailure(nowMs: 3)

        XCTAssertEqual(effects.lastOpen?.reason, .screenStreamStopped)
        controller.recordScreenStreamFrame(
            .init(generation: 7, status: .complete, displayTime: 2),
            nowMs: 4
        )
        XCTAssertEqual(controller.snapshot.legs[.screen]?.lastVerifiedProgressAtMs, 2)
    }

    func testRepeatedStaticFramesNeverOpenRecovery() {
        var effects: [CaptureHealthEffect] = []
        let controller = CaptureHealthController(nowMs: 0) { effects.append($0) }
        controller.screenStreamDidStart(generation: 8, nowMs: 1)

        for displayTime in 1...100 {
            controller.recordScreenStreamFrame(
                .init(generation: 8, status: .idle, displayTime: UInt64(displayTime)),
                nowMs: Int64(displayTime + 1)
            )
        }

        XCTAssertEqual(controller.snapshot.legs[.screen]?.state, .healthy)
        XCTAssertEqual(controller.snapshot.legs[.screen]?.reason, .verifiedProgress)
        XCTAssertNil(effects.lastOpen)
    }

    func testOldDelegateFailureCannotBreakReplacementGeneration() {
        var effects: [CaptureHealthEffect] = []
        let controller = CaptureHealthController(nowMs: 0) { effects.append($0) }
        controller.screenStreamDidStart(generation: 1, nowMs: 1)
        controller.invalidatePipeline(.displayChanged, screenLocked: false, nowMs: 2)
        controller.screenStreamDidStart(generation: 2, nowMs: 3)

        controller.recordScreenStreamFailure(
            generation: 1,
            reason: .screenStreamStopped,
            nowMs: 4
        )

        XCTAssertNil(effects.lastOpen)
        controller.recordScreenStreamFrame(
            .init(generation: 2, status: .complete, displayTime: 1),
            nowMs: 5
        )
        XCTAssertEqual(controller.snapshot.legs[.screen]?.state, .healthy)
    }

    func testAutomaticRecoveryUsesOneThreeTenSecondBackoff() {
        var effects: [CaptureHealthEffect] = []
        let controller = CaptureHealthController(nowMs: 0) { effects.append($0) }
        controller.screenStreamDidStart(generation: 1, nowMs: 1)
        controller.recordScreenStreamFailure(
            generation: 1,
            reason: .screenStreamStalled,
            nowMs: 2
        )
        controller.coverageDidOpen(try! XCTUnwrap(effects.lastOpen), nowMs: 3)

        XCTAssertEqual(effects.lastAttempt?.delayMs, 1_000)
        let generation = try! XCTUnwrap(effects.lastAttempt?.generation)
        controller.recoveryAttemptFailed(
            leg: .screen,
            generation: generation,
            reason: .screenStreamStalled,
            nowMs: 4
        )
        XCTAssertEqual(effects.lastAttempt?.delayMs, 3_000)
        controller.recoveryAttemptFailed(
            leg: .screen,
            generation: generation,
            reason: .screenStreamStalled,
            nowMs: 5
        )
        XCTAssertEqual(effects.lastAttempt?.delayMs, 10_000)
        controller.recoveryAttemptFailed(
            leg: .screen,
            generation: generation,
            reason: .screenStreamStalled,
            nowMs: 6
        )
        XCTAssertEqual(controller.snapshot.legs[.screen]?.state, .repairRequired)
    }

    func testHydratedRecoveryRequiresControllerApprovalBeforeNewStream() {
        let interval = CaptureCoverageInterval(
            id: 1,
            leg: .screen,
            reason: .screenStreamStopped,
            episodeID: "open-after-crash",
            generation: 7,
            startMs: 1,
            endMs: nil,
            closeCause: nil
        )
        var effects: [CaptureHealthEffect] = []
        let controller = CaptureHealthController(
            nowMs: 2,
            openIntervals: [interval],
            emit: { effects.append($0) }
        )

        controller.screenStreamDidStart(generation: 1, nowMs: 3)
        controller.recordScreenStreamFrame(
            .init(generation: 1, status: .complete, displayTime: 1),
            nowMs: 4
        )
        XCTAssertNil(effects.lastClose)

        controller.repairRequested(.screen, nowMs: 5)
        let attempt = try! XCTUnwrap(effects.lastAttempt)
        XCTAssertTrue(controller.markScreenRecoveryReady(attempt))
        controller.screenStreamDidStart(generation: 2, nowMs: 6)
        controller.recordScreenStreamFrame(
            .init(generation: 2, status: .complete, displayTime: 1),
            nowMs: 7
        )
        XCTAssertNotNil(effects.lastClose)
    }

    func testMissingUserIgnoredHelperFailsShareableContentAttestation() {
        let ignored = UserIgnoredCaptureApplicationIdentity(
            processIdentifier: 42,
            bundleIdentifier: "com.example.private"
        )

        XCTAssertFalse(CaptureSessionPolicy.contentCoversUserIgnoredApplications(
            expected: [ignored],
            represented: []
        ))
        XCTAssertTrue(CaptureSessionPolicy.contentCoversUserIgnoredApplications(
            expected: [ignored],
            represented: [ignored]
        ))
    }

    func testUserIgnoredAttestationRequiresExactPIDAndBundleIdentity() {
        let expected = UserIgnoredCaptureApplicationIdentity(
            processIdentifier: 42,
            bundleIdentifier: "com.example.private"
        )
        let reusedPID = UserIgnoredCaptureApplicationIdentity(
            processIdentifier: 42,
            bundleIdentifier: "com.example.other"
        )
        let siblingProcess = UserIgnoredCaptureApplicationIdentity(
            processIdentifier: 43,
            bundleIdentifier: "com.example.private"
        )

        XCTAssertFalse(CaptureSessionPolicy.contentCoversUserIgnoredApplications(
            expected: [expected],
            represented: [reusedPID, siblingProcess]
        ))
    }
}

private extension Array where Element == CaptureHealthEffect {
    var lastOpen: CaptureCoverageOpen? {
        reversed().compactMap {
            if case .openCoverage(let value) = $0 { value } else { nil }
        }.first
    }

    var lastClose: CaptureCoverageClose? {
        reversed().compactMap {
            if case .closeCoverage(let value) = $0 { value } else { nil }
        }.first
    }

    var lastAttempt: CaptureRecoveryAttempt? {
        reversed().compactMap {
            if case .attemptRecovery(let value) = $0 { value } else { nil }
        }.first
    }
}
