import XCTest

final class LowDiskGuardTests: XCTestCase {
    func testColdLaunchBelowPauseThresholdPausesImmediately() {
        var guardState = LowDiskGuard(
            policy: DiskReservePolicy(pauseBytes: 100, recoveryBytes: 200)
        )

        XCTAssertEqual(guardState.evaluate(availableBytes: 99), .pauseCapture)
        XCTAssertEqual(guardState.state, .paused)
    }

    func testPausedGuardUsesRecoveryHysteresis() {
        var guardState = LowDiskGuard(
            policy: DiskReservePolicy(pauseBytes: 100, recoveryBytes: 200)
        )

        XCTAssertEqual(guardState.evaluate(availableBytes: 99), .pauseCapture)
        XCTAssertEqual(guardState.evaluate(availableBytes: 100), .none)
        XCTAssertEqual(guardState.evaluate(availableBytes: 150), .none)
        XCTAssertEqual(guardState.evaluate(availableBytes: 199), .none)
        XCTAssertEqual(guardState.evaluate(availableBytes: 200), .resumeCapture)
        XCTAssertEqual(guardState.state, .healthy)
    }

    func testHealthyGuardDoesNotFlapAbovePauseThreshold() {
        var guardState = LowDiskGuard(
            policy: DiskReservePolicy(pauseBytes: 100, recoveryBytes: 200)
        )

        XCTAssertEqual(guardState.evaluate(availableBytes: 250), .none)
        XCTAssertEqual(guardState.evaluate(availableBytes: 150), .none)
        XCTAssertEqual(guardState.state, .healthy)
        XCTAssertEqual(guardState.evaluate(availableBytes: 99), .pauseCapture)
    }

    func testCapacityReadFailureFailsClosedWithoutDeletionAction() {
        var guardState = LowDiskGuard(
            policy: DiskReservePolicy(pauseBytes: 100, recoveryBytes: 200)
        )

        XCTAssertEqual(guardState.evaluate(availableBytes: nil), .pauseCapture)
        XCTAssertEqual(Set(LowDiskGuard.Action.allCases), [.none, .pauseCapture, .resumeCapture])
    }

    func testBuiltInDownloadReserveSharesCapturePausePolicy() {
        let policy = DiskReservePolicy(pauseBytes: 100, recoveryBytes: 200, modelSafetyBytes: 25)

        XCTAssertEqual(policy.requiredCapacityForDownload(remainingBytes: 50), 175)
        XCTAssertFalse(policy.canDownload(remainingBytes: 50, availableBytes: 174))
        XCTAssertTrue(policy.canDownload(remainingBytes: 50, availableBytes: 175))
    }

    func testRecoveryStaysPausedWhenSystemAudioStopIsUnconfirmed() {
        var guardState = LowDiskGuard(
            policy: DiskReservePolicy(pauseBytes: 100, recoveryBytes: 200)
        )
        XCTAssertEqual(guardState.evaluate(availableBytes: 99), .pauseCapture)
        XCTAssertEqual(guardState.evaluate(availableBytes: 200), .resumeCapture)
        var admission = RecordingMaintenanceAdmission()
        let timedOutDrain = RecordingMaintenanceDrain(
            lease: admission.acquire(.lowDisk),
            capture: CaptureDrainAcknowledgement(
                hadActiveCapture: true,
                hadInFlightCycle: false,
                activeCycles: 0
            ),
            audio: AudioDrainAcknowledgement(
                hadActiveAudio: true,
                activeLegs: 0,
                transcriptionDrained: true,
                systemCaptureOutcome: .timedOut
            )
        )

        XCTAssertFalse(LowDiskDrainGate.isConfirmedStopped(timedOutDrain))
        guardState.holdPaused()
        XCTAssertEqual(guardState.state, .paused)
        XCTAssertEqual(guardState.evaluate(availableBytes: 200), .resumeCapture)
    }
}
