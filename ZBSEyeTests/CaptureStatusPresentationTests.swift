import XCTest

final class CaptureStatusPresentationTests: XCTestCase {
    func testLivePulseRequiresRecentVerifiedProgressAndStopsOnFailure() {
        var health = CaptureLegHealth(
            state: .healthy, reason: .awaitingVerifiedProgress, generation: 0,
            attempt: 0, stateSinceMs: 0, lastCycleAtMs: nil, lastVerifiedProgressAtMs: nil
        )
        XCTAssertFalse(health.hasRecentVerifiedProgress(at: 1_000))
        health.reason = .verifiedProgress
        health.lastVerifiedProgressAtMs = 1_000
        XCTAssertTrue(health.hasRecentVerifiedProgress(at: 2_000))
        XCTAssertFalse(health.hasRecentVerifiedProgress(at: 9_001))
        XCTAssertFalse(health.hasRecentVerifiedProgress(at: 999))
        health.reason = .staticDuplicate
        XCTAssertTrue(health.hasRecentVerifiedProgress(at: 2_000), "Static pixels remain live")
        for state in [CaptureLegState.paused, .suspended, .recovering, .repairRequired, .permissionBlocked] {
            health.state = state
            XCTAssertFalse(health.hasRecentVerifiedProgress(at: 2_000))
        }
        health.state = .healthy
        health.reason = .awaitingVerifiedProgress
        XCTAssertFalse(health.hasRecentVerifiedProgress(at: 2_000), "Resume must not reuse an old heartbeat")
    }

    func testActualCaptureErrorsEnterRecoveryWhileSupersededWorkDoesNot() {
        XCTAssertNil(CaptureError.staleGeneration.healthFailureReason)
        XCTAssertNil(CaptureError.privacyInventoryIncomplete.healthFailureReason)
        for error in [CaptureError.noDisplay, .noShareableApplications, .encodeFailed] {
            XCTAssertEqual(error.healthFailureReason, .screenRequestFailed)
        }
        for error in [CaptureError.streamStartFailed, .streamUpdateFailed, .streamStopUnconfirmed] {
            XCTAssertEqual(error.healthFailureReason, .screenStreamStopped)
        }
    }

    func testCoverageWarningNamesAffectedLegAndForbidsInactivityInference() {
        let disclosure = CaptureCoverageDisclosure(
            availability: .available,
            intervals: [CaptureCoverageInterval(
                id: 1,
                leg: .systemAudio,
                reason: .systemAudioStartExhausted,
                episodeID: "synthetic",
                generation: 1,
                startMs: 10,
                endMs: nil,
                closeCause: nil
            )]
        )

        XCTAssertTrue(disclosure.userFacingWarning?.contains("System Audio") == true)
        XCTAssertTrue(disclosure.userFacingWarning?.contains("do not prove inactivity") == true)
        XCTAssertTrue(disclosure.modelInstruction(russian: false)?.contains("confirmed capture gap") == true)
    }

    func testMetadataUnavailableIsNeverPresentedAsCleanCoverage() {
        XCTAssertTrue(CaptureCoverageDisclosure.metadataUnavailable.hasWarning)
        XCTAssertNotNil(CaptureCoverageDisclosure.metadataUnavailable.userFacingWarning)
        XCTAssertFalse(CaptureCoverageDisclosure.clean.hasWarning)
        XCTAssertNil(CaptureCoverageDisclosure.clean.userFacingWarning)
    }

    func testRepairPresentationAndStatusDTOReadTheSameSnapshot() {
        let health = CaptureLegHealth(
            state: .repairRequired,
            reason: .screenRequestTimedOut,
            generation: 7,
            attempt: 3,
            stateSinceMs: 100,
            lastCycleAtMs: 90,
            lastVerifiedProgressAtMs: 50
        )
        let snapshot = CaptureHealthSnapshot(
            intent: .init(screenEnabled: true, systemAudioEnabled: false),
            permissions: [.screen: .granted, .systemAudio: .granted],
            suspension: nil,
            legs: [.screen: health],
            aggregate: .repairRequired
        )

        let presentation = CaptureRepairPresentation(snapshot: snapshot)
        let dto = CaptureStatusDTO(snapshot: snapshot, coverage: .clean)

        XCTAssertEqual(presentation.state, .repairRequired)
        XCTAssertEqual(presentation.affectedLegs, [.screen])
        XCTAssertEqual(dto.state, .repairRequired)
        XCTAssertEqual(dto.legs.first?.reason, .screenRequestTimedOut)
        XCTAssertEqual(dto.legs.first?.attempt, 3)
    }
}
