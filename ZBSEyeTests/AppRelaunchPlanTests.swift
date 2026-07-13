import Foundation
import XCTest

final class AppRelaunchPlanTests: XCTestCase {
    func testReplacementOpenIsPlannedOnlyAfterOldProcessExit() throws {
        let bundle = URL(fileURLWithPath: "/Applications/ZBS Eye.app")
        let plan = AppRelaunchPlan(parentProcessID: 42, bundleURL: bundle)
        var events: [String] = []

        plan.execute(
            waitForExit: { processID in
                XCTAssertEqual(processID, 42)
                events.append("old-process-exited")
            },
            openBundle: { openedBundle in
                XCTAssertEqual(openedBundle, bundle)
                events.append("replacement-opened")
            }
        )

        XCTAssertEqual(events, ["old-process-exited", "replacement-opened"])
    }

    func testHelperArgumentsRoundTripWithoutShellInterpolation() throws {
        let bundle = URL(fileURLWithPath: "/tmp/ZBS Eye's Preview.app")
        let plan = AppRelaunchPlan(parentProcessID: 987, bundleURL: bundle)

        let restored = try XCTUnwrap(
            AppRelaunchPlan(arguments: ["ZBS Eye"] + plan.helperArguments)
        )

        XCTAssertEqual(restored, plan)
    }

    func testOwnerTerminationIsNotRequestedWhenHelperLaunchFails() {
        let plan = AppRelaunchPlan(
            parentProcessID: 42,
            bundleURL: URL(fileURLWithPath: "/Applications/ZBS Eye.app")
        )
        var terminationRequested = false

        XCTAssertThrowsError(
            try AppRelaunchHandoff.launch(
                plan: plan,
                executableURL: URL(fileURLWithPath: "/Applications/ZBS Eye.app/Contents/MacOS/ZBS Eye"),
                launchHelper: { _, _ in throw ExpectedRelaunchFailure.launchFailed },
                terminateOwner: { terminationRequested = true }
            )
        ) { error in
            XCTAssertEqual(error as? ExpectedRelaunchFailure, .launchFailed)
        }
        XCTAssertFalse(terminationRequested)
    }

    func testOwnerTerminationFollowsSuccessfulHelperLaunch() throws {
        let plan = AppRelaunchPlan(
            parentProcessID: 42,
            bundleURL: URL(fileURLWithPath: "/Applications/ZBS Eye.app")
        )
        var events: [String] = []

        try AppRelaunchHandoff.launch(
            plan: plan,
            executableURL: URL(fileURLWithPath: "/Applications/ZBS Eye.app/Contents/MacOS/ZBS Eye"),
            launchHelper: { executable, arguments in
                XCTAssertEqual(executable.lastPathComponent, "ZBS Eye")
                XCTAssertEqual(arguments, plan.helperArguments)
                events.append("helper-launched")
            },
            terminateOwner: { events.append("owner-termination-requested") }
        )

        XCTAssertEqual(events, ["helper-launched", "owner-termination-requested"])
    }

    @MainActor
    func testRejectedOwnerTerminationStopsHelperAndFailsHandoff() async {
        let plan = AppRelaunchPlan(
            parentProcessID: 42,
            bundleURL: URL(fileURLWithPath: "/Applications/ZBS Eye.app")
        )
        let helper = RelaunchHelperProbe()
        var events: [String] = []
        var activeRoot = "copied-root"
        var recordingSuspended = true
        var writersSuspended = true

        do {
            try await AppRelaunchHandoff.launchAcknowledged(
                plan: plan,
                executableURL: URL(fileURLWithPath: "/Applications/ZBS Eye.app/Contents/MacOS/ZBS Eye"),
                launchHelper: { _, _ in
                    events.append("helper-launched")
                    return { helper.stop(); events.append("helper-stopped") }
                },
                requestOwnerTermination: {
                    events.append("owner-termination-requested")
                },
                awaitOwnerDecision: { false }
            )
            XCTFail("Expected rejected termination handoff to throw")
        } catch {
            XCTAssertEqual(error as? AppRelaunchPlanError, .ownerTerminationRejected)
            await AppRelocationFailureRecovery.run(
                committedNewRoot: true,
                restorePreviousRoot: {
                    activeRoot = "old-root"
                    events.append("old-root-restored")
                },
                awaitRecordingDrain: {
                    events.append("recording-drain-completed")
                },
                awaitTerminationHandoffDrain: {
                    events.append("termination-handoff-drain-completed")
                },
                resumeOldGraphAdmissions: {
                    XCTAssertEqual(activeRoot, "old-root", "a copied-root writer must never be admitted")
                    writersSuspended = false
                    recordingSuspended = false
                    events.append("old-graph-resumed")
                }
            )
        }

        XCTAssertTrue(helper.wasStopped)
        XCTAssertEqual(activeRoot, "old-root")
        XCTAssertFalse(recordingSuspended)
        XCTAssertFalse(writersSuspended)
        XCTAssertEqual(
            events,
            [
                "helper-launched",
                "owner-termination-requested",
                "helper-stopped",
                "old-root-restored",
                "recording-drain-completed",
                "termination-handoff-drain-completed",
                "old-graph-resumed"
            ]
        )
    }
}

@MainActor
private final class RelaunchHelperProbe {
    private(set) var wasStopped = false
    func stop() { wasStopped = true }
}

private enum ExpectedRelaunchFailure: Error, Equatable {
    case launchFailed
}
