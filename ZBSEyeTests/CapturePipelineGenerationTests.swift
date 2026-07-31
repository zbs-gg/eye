import XCTest

@MainActor
final class CapturePipelineGenerationTests: XCTestCase {
    private let baselineContext = CaptureContext(
        displayID: "display-1",
        frontmostBundleID: "com.example.editor",
        focusedWindowID: "window-1",
        axRevision: 1,
        inputRevision: 1
    )

    func testInvalidationRejectsLateCompletionBeforeAdmittingOneReplacement() {
        let controller = CaptureHealthController(nowMs: 0)
        let old = try! XCTUnwrap(controller.beginScreenRequest(nowMs: 1))

        controller.invalidatePipeline(.displayChanged, screenLocked: false, nowMs: 2)

        XCTAssertNil(controller.beginScreenRequest(nowMs: 3))
        XCTAssertEqual(
            controller.completeScreenRequest(
                old,
                result: .success(fingerprint: "old", context: baselineContext, wasDuplicate: false),
                nowMs: 4
            ),
            .rejectedOldGeneration
        )

        let replacement = try! XCTUnwrap(controller.beginScreenRequest(nowMs: 5))
        XCTAssertEqual(replacement.pipelineGeneration, old.pipelineGeneration + 1)
        XCTAssertNil(controller.beginScreenRequest(nowMs: 6))
        XCTAssertEqual(
            controller.completeScreenRequest(
                replacement,
                result: .success(fingerprint: "new", context: baselineContext, wasDuplicate: false),
                nowMs: 7
            ),
            .accepted
        )
    }

    func testDisplayWakeAndUnlockInvalidateButWakeWhileLockedAdmitsNothing() {
        let controller = CaptureHealthController(nowMs: 0)
        let initialGeneration = controller.pipelineGeneration

        controller.invalidatePipeline(.displayChanged, screenLocked: false, nowMs: 1)
        XCTAssertEqual(controller.pipelineGeneration, initialGeneration + 1)

        controller.invalidatePipeline(.wake, screenLocked: true, nowMs: 2)
        XCTAssertEqual(controller.pipelineGeneration, initialGeneration + 2)
        XCTAssertNil(controller.beginScreenRequest(nowMs: 3))

        controller.invalidatePipeline(.unlock, screenLocked: false, nowMs: 4)
        XCTAssertEqual(controller.pipelineGeneration, initialGeneration + 3)
        XCTAssertNotNil(controller.beginScreenRequest(nowMs: 5))
    }

    func testFailureOriginCanRecoverWithIdenticalValidPixels() {
        var effects: [CaptureHealthEffect] = []
        let controller = CaptureHealthController(nowMs: 0) { effects.append($0) }

        let failed = try! XCTUnwrap(controller.beginScreenRequest(nowMs: 1))
        XCTAssertEqual(
            controller.completeScreenRequest(
                failed,
                result: .failure(.screenRequestFailed),
                nowMs: 2
            ),
            .accepted
        )
        let open = try! XCTUnwrap(effects.openCoverage)
        controller.coverageDidOpen(open, nowMs: 3)
        let attempt = try! XCTUnwrap(effects.recoveryAttempt)
        controller.invalidatePipeline(.recovery, screenLocked: false, nowMs: 3)
        XCTAssertTrue(controller.markScreenRecoveryReady(attempt))

        let recovery = try! XCTUnwrap(controller.beginScreenRequest(nowMs: 4))
        XCTAssertEqual(
            controller.completeScreenRequest(
                recovery,
                result: .success(fingerprint: "same", context: baselineContext, wasDuplicate: false),
                nowMs: 5
            ),
            .accepted
        )
        XCTAssertNotNil(effects.closeCoverage)
    }

    func testStaleOriginMustAdvanceBeyondContradictedFingerprint() {
        var effects: [CaptureHealthEffect] = []
        let controller = CaptureHealthController(nowMs: 0) { effects.append($0) }

        completeSuccess(controller, fingerprint: "same", context: baselineContext, nowMs: 1)
        let changedContext = CaptureContext(
            displayID: baselineContext.displayID,
            frontmostBundleID: "com.example.browser",
            focusedWindowID: "window-2",
            axRevision: 2,
            inputRevision: 2
        )
        completeSuccess(controller, fingerprint: "same", context: changedContext, duplicate: true, nowMs: 2)
        completeSuccess(controller, fingerprint: "same", context: changedContext, duplicate: true, nowMs: 3)
        completeSuccess(controller, fingerprint: "same", context: changedContext, duplicate: true, nowMs: 4)

        let open = try! XCTUnwrap(effects.openCoverage)
        controller.coverageDidOpen(open, nowMs: 5)
        let attempt = try! XCTUnwrap(effects.recoveryAttempt)
        controller.invalidatePipeline(.recovery, screenLocked: false, nowMs: 6)
        XCTAssertTrue(controller.markScreenRecoveryReady(attempt))

        completeSuccess(controller, fingerprint: "same", context: changedContext, nowMs: 7)
        XCTAssertNil(effects.closeCoverage)
        let secondAttempt = try! XCTUnwrap(effects.recoveryAttempt)
        XCTAssertEqual(secondAttempt.attempt, 2)
        controller.invalidatePipeline(.recovery, screenLocked: false, nowMs: 8)
        XCTAssertTrue(controller.markScreenRecoveryReady(secondAttempt))

        completeSuccess(controller, fingerprint: "advanced", context: changedContext, nowMs: 9)
        XCTAssertNotNil(effects.closeCoverage)
    }

    func testDeadlineClosesAdmissionAndLateResultCannotRestoreHealth() {
        var effects: [CaptureHealthEffect] = []
        let controller = CaptureHealthController(nowMs: 0) { effects.append($0) }
        let request = try! XCTUnwrap(controller.beginScreenRequest(nowMs: 1))

        XCTAssertTrue(controller.screenRequestDeadlineElapsed(request, nowMs: 2))
        XCTAssertNil(controller.beginScreenRequest(nowMs: 3))
        XCTAssertEqual(
            controller.snapshot.legs[.screen]?.state,
            .healthy,
            "recovery is not published before the uncertainty interval commits"
        )
        let open = try! XCTUnwrap(effects.openCoverage)
        controller.coverageDidOpen(open, nowMs: 3)
        XCTAssertEqual(controller.snapshot.legs[.screen]?.state, .recovering)

        XCTAssertEqual(
            controller.completeScreenRequest(
                request,
                result: .success(fingerprint: "late", context: baselineContext, wasDuplicate: false),
                nowMs: 4
            ),
            .rejectedOldGeneration
        )
        XCTAssertEqual(controller.snapshot.legs[.screen]?.state, .recovering)
        XCTAssertNil(effects.closeCoverage)

        let attempt = try! XCTUnwrap(effects.recoveryAttempt)
        controller.screenRecoveryOwnershipUnavailable(attempt, nowMs: 5)
        XCTAssertEqual(controller.snapshot.legs[.screen]?.state, .repairRequired)

        controller.repairRequested(.screen, nowMs: 6)
        let repair = try! XCTUnwrap(effects.reversed().compactMap {
            if case .attemptRecovery(let value) = $0 { value } else { nil }
        }.first)
        XCTAssertTrue(controller.markScreenRecoveryReady(repair))
        XCTAssertNotNil(controller.beginScreenRequest(nowMs: 7))
    }

    func testHydratedRecoveryAdmitsOnlyAControllerApprovedReplacementRequest() {
        let interval = CaptureCoverageInterval(
            id: 1,
            leg: .screen,
            reason: .screenRequestFailed,
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

        XCTAssertNil(controller.beginScreenRequest(nowMs: 3))
        controller.repairRequested(.screen, nowMs: 4)
        let attempt = try! XCTUnwrap(effects.compactMap {
            if case .attemptRecovery(let value) = $0 { value } else { nil }
        }.last)
        XCTAssertTrue(controller.markScreenRecoveryReady(attempt))
        XCTAssertNotNil(controller.beginScreenRequest(nowMs: 5))
        XCTAssertNil(controller.beginScreenRequest(nowMs: 6))
    }

    private func completeSuccess(
        _ controller: CaptureHealthController,
        fingerprint: String,
        context: CaptureContext,
        duplicate: Bool = false,
        nowMs: Int64
    ) {
        let request = try! XCTUnwrap(controller.beginScreenRequest(nowMs: nowMs))
        XCTAssertEqual(
            controller.completeScreenRequest(
                request,
                result: .success(fingerprint: fingerprint, context: context, wasDuplicate: duplicate),
                nowMs: nowMs
            ),
            .accepted
        )
    }
}

private extension Array where Element == CaptureHealthEffect {
    var openCoverage: CaptureCoverageOpen? {
        reversed().compactMap {
            if case .openCoverage(let value) = $0 { value } else { nil }
        }.first
    }

    var closeCoverage: CaptureCoverageClose? {
        reversed().compactMap {
            if case .closeCoverage(let value) = $0 { value } else { nil }
        }.first
    }

    var recoveryAttempt: CaptureRecoveryAttempt? {
        reversed().compactMap {
            if case .attemptRecovery(let value) = $0 { value } else { nil }
        }.first
    }
}
