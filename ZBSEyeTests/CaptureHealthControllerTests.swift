import XCTest

@MainActor
final class CaptureHealthControllerTests: XCTestCase {
    func testSystemAudioRecoveryExhaustsOnceAndWaitsForExplicitRepair() {
        var effects: [CaptureHealthEffect] = []
        let controller = CaptureHealthController(nowMs: 0) { effects.append($0) }
        controller.setIntent(
            CaptureIntent(screenEnabled: true, systemAudioEnabled: true),
            nowMs: 1
        )

        controller.recordSystemAudioFailure(nowMs: 2)
        let open = try! XCTUnwrap(effects.lastOpen)
        controller.coverageDidOpen(open, nowMs: 3)

        for attempt in 1...3 {
            let scheduled = try! XCTUnwrap(effects.lastAttempt)
            XCTAssertEqual(scheduled.attempt, attempt)
            controller.recordSystemAudioFailure(nowMs: Int64(3 + attempt))
        }

        XCTAssertEqual(controller.snapshot.legs[.systemAudio]?.state, .repairRequired)
        let automaticAttemptCount = effects.attempts.count
        controller.recordSystemAudioFailure(nowMs: 20)
        XCTAssertEqual(effects.attempts.count, automaticAttemptCount)

        controller.repairRequested(.systemAudio, nowMs: 21)
        XCTAssertEqual(controller.snapshot.legs[.systemAudio]?.state, .recovering)
        XCTAssertEqual(effects.lastAttempt?.attempt, 1)
        XCTAssertEqual(effects.attempts.count, automaticAttemptCount + 1)
    }

    func testSnapshotSinkPublishesTheSameFiniteStateAsEffects() {
        var snapshots: [CaptureHealthSnapshot] = []
        let controller = CaptureHealthController(nowMs: 0)
        controller.setSnapshotSink { snapshots.append($0) }

        controller.setPermission(.denied, for: .screen, nowMs: 1)

        XCTAssertEqual(snapshots.last, controller.snapshot)
        XCTAssertEqual(snapshots.last?.aggregate, .permissionBlocked)
        XCTAssertEqual(snapshots.last?.legs[.screen]?.reason, .permissionMissing)
    }

    func testUnchangedInputsDoNotRepublishOrRewriteStateTimestamps() {
        var snapshots: [CaptureHealthSnapshot] = []
        let controller = CaptureHealthController(nowMs: 10)
        controller.setSnapshotSink { snapshots.append($0) }
        let original = controller.snapshot

        controller.setIntent(original.intent, nowMs: 20)
        controller.setPermission(.granted, for: .screen, nowMs: 30)
        controller.setSuspension(nil, nowMs: 40)

        XCTAssertEqual(snapshots, [original])
        XCTAssertEqual(controller.snapshot, original)
    }

    func testRecoveryIsNotPublishedBeforeCoverageOpenIsDurable() {
        var effects: [CaptureHealthEffect] = []
        var snapshots: [CaptureHealthSnapshot] = []
        let controller = CaptureHealthController(nowMs: 0) { effects.append($0) }
        controller.setSnapshotSink { snapshots.append($0) }
        controller.setIntent(
            CaptureIntent(screenEnabled: true, systemAudioEnabled: true),
            nowMs: 1
        )
        controller.recordSystemAudioFailure(nowMs: 2)
        let requestedOpen = try! XCTUnwrap(effects.lastOpen)
        XCTAssertNotEqual(controller.snapshot.legs[.systemAudio]?.state, .recovering)

        controller.coverageDidOpen(requestedOpen, nowMs: 3)
        XCTAssertEqual(controller.snapshot.legs[.systemAudio]?.state, .recovering)
        XCTAssertEqual(snapshots.last, controller.snapshot)
    }

    func testStaleRecoveryEffectCannotExecuteAfterAttemptAdvances() {
        var effects: [CaptureHealthEffect] = []
        let controller = CaptureHealthController(nowMs: 0) { effects.append($0) }
        controller.setIntent(
            CaptureIntent(screenEnabled: true, systemAudioEnabled: true),
            nowMs: 1
        )
        controller.recordSystemAudioFailure(nowMs: 2)
        controller.coverageDidOpen(try! XCTUnwrap(effects.lastOpen), nowMs: 3)
        let first = try! XCTUnwrap(effects.lastAttempt)

        controller.recordSystemAudioFailure(nowMs: 4)
        let second = try! XCTUnwrap(effects.lastAttempt)

        XCTAssertFalse(controller.isCurrentRecoveryAttempt(first))
        XCTAssertTrue(controller.isCurrentRecoveryAttempt(second))
    }

    func testSystemAudioFrameClosesTheDurableRecoveryInterval() {
        var effects: [CaptureHealthEffect] = []
        let controller = CaptureHealthController(nowMs: 0) { effects.append($0) }
        controller.setIntent(
            CaptureIntent(screenEnabled: true, systemAudioEnabled: true),
            nowMs: 1
        )
        controller.recordSystemAudioFailure(nowMs: 2)
        controller.coverageDidOpen(try! XCTUnwrap(effects.lastOpen), nowMs: 3)

        controller.recordSystemAudioProgress(nowMs: 4)

        let close = effects.reversed().compactMap {
            if case .closeCoverage(let close) = $0 { close } else { nil }
        }.first
        XCTAssertNotNil(close)
        controller.coverageDidClose(try! XCTUnwrap(close), nowMs: 5)
        XCTAssertEqual(controller.snapshot.legs[.systemAudio]?.state, .healthy)
    }
}

private extension Array where Element == CaptureHealthEffect {
    var lastOpen: CaptureCoverageOpen? {
        reversed().compactMap {
            if case .openCoverage(let open) = $0 { open } else { nil }
        }.first
    }

    var attempts: [CaptureRecoveryAttempt] {
        compactMap {
            if case .attemptRecovery(let attempt) = $0 { attempt } else { nil }
        }
    }

    var lastAttempt: CaptureRecoveryAttempt? { attempts.last }
}
