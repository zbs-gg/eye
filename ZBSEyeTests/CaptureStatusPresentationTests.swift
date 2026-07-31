import XCTest

final class CaptureStatusPresentationTests: XCTestCase {
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
