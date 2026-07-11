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
}

private enum ExpectedRelaunchFailure: Error, Equatable {
    case launchFailed
}
