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
}
