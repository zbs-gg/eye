import XCTest

@MainActor
final class CaptureRepairOrchestratorTests: XCTestCase {
    func testSharedRepairDrainsBothLegsBeforeReplacementWorkStarts() async {
        var events: [String] = []

        let repaired = await CaptureRepairOrchestrator.run(
            affected: [.screen, .systemAudio],
            drainScreen: {
                events.append("screen drained")
                return true
            },
            drainSystemAudio: {
                events.append("system audio drained")
                return true
            },
            restartScreen: { events.append("screen restarted") },
            requestRepair: { events.append("\($0.rawValue) repair requested") }
        )

        XCTAssertTrue(repaired)
        XCTAssertEqual(Set(events.prefix(2)), ["screen drained", "system audio drained"])
        XCTAssertEqual(
            Array(events.dropFirst(2)),
            ["screen restarted", "screen repair requested", "systemAudio repair requested"]
        )
    }

    func testScreenOnlyRepairNeverTouchesSystemAudio() async {
        var systemAudioDrainCount = 0

        let repaired = await CaptureRepairOrchestrator.run(
            affected: [.screen],
            drainScreen: { true },
            drainSystemAudio: {
                systemAudioDrainCount += 1
                return true
            },
            restartScreen: {},
            requestRepair: { _ in }
        )

        XCTAssertTrue(repaired)
        XCTAssertEqual(systemAudioDrainCount, 0)
    }

    func testFailedDrainDoesNotStartReplacementWork() async {
        var replacementCount = 0

        let repaired = await CaptureRepairOrchestrator.run(
            affected: [.screen, .systemAudio],
            drainScreen: { false },
            drainSystemAudio: { true },
            restartScreen: { replacementCount += 1 },
            requestRepair: { _ in replacementCount += 1 }
        )

        XCTAssertFalse(repaired)
        XCTAssertEqual(replacementCount, 0)
    }

    func testPersistenceOnlyRepairNeedsNoPhysicalDrain() async {
        var drainCount = 0
        let repaired = await CaptureRepairOrchestrator.run(
            affected: [],
            drainScreen: { drainCount += 1; return true },
            drainSystemAudio: { drainCount += 1; return true },
            restartScreen: {},
            requestRepair: { _ in }
        )

        XCTAssertTrue(repaired)
        XCTAssertEqual(drainCount, 0)
    }
}
