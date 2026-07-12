import AppKit

/// Restart the app — needed after Screen Recording is granted (TCC applies the permission only to a new
/// process; without a relaunch SCK returns -3801 even though the permission is "granted").
@MainActor
enum AppRelauncher {
    static func relaunch() throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw AppRelaunchPlanError.executableUnavailable
        }
        let plan = AppRelaunchPlan(
            parentProcessID: ProcessInfo.processInfo.processIdentifier,
            bundleURL: Bundle.main.bundleURL
        )
        try AppRelaunchHandoff.launch(
            plan: plan,
            executableURL: executableURL,
            launchHelper: { executableURL, arguments in
                let helper = Process()
                helper.executableURL = executableURL
                helper.arguments = arguments
                try helper.run()
            },
            terminateOwner: {
                NSApplication.shared.terminate(nil)
            }
        )
    }

    /// Relocation needs proof that AppDelegate accepted Quit. If teardown is
    /// rejected, stop the helper and throw so the old-root service graph can be
    /// restored instead of leaving a helper waiting forever for this PID.
    static func relaunchAcknowledged() async throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw AppRelaunchPlanError.executableUnavailable
        }
        let plan = AppRelaunchPlan(
            parentProcessID: ProcessInfo.processInfo.processIdentifier,
            bundleURL: Bundle.main.bundleURL
        )
        ZBSEyeAppDelegate.prepareForAcknowledgedTermination()
        try await AppRelaunchHandoff.launchAcknowledged(
            plan: plan,
            executableURL: executableURL,
            launchHelper: { executableURL, arguments in
                let helper = Process()
                helper.executableURL = executableURL
                helper.arguments = arguments
                try helper.run()
                return {
                    guard helper.isRunning else { return }
                    helper.terminate()
                }
            },
            requestOwnerTermination: {
                NSApplication.shared.terminate(nil)
            },
            awaitOwnerDecision: {
                await ZBSEyeAppDelegate.awaitAcknowledgedTerminationDecision()
            }
        )
    }
}
