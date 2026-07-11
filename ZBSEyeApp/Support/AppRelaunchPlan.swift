import Darwin
import Foundation

enum AppRelaunchPlanError: Error, LocalizedError, Sendable, Equatable {
    case executableUnavailable
    case openFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            "The ZBS Eye executable could not be resolved for restart."
        case .openFailed(let status):
            "The replacement ZBS Eye process could not be opened (status \(status))."
        }
    }
}

/// Pure owner-side half of the handoff. The current app may terminate only
/// after the helper process has actually been spawned; otherwise relocation
/// must be able to roll back and resume the still-live service graph.
enum AppRelaunchHandoff {
    static func launch(
        plan: AppRelaunchPlan,
        executableURL: URL,
        launchHelper: (URL, [String]) throws -> Void,
        terminateOwner: () -> Void
    ) throws {
        try launchHelper(executableURL, plan.helperArguments)
        terminateOwner()
    }
}

/// A shell-free restart handoff. The helper is a second invocation of the app
/// executable, but it does not enter SwiftUI: it waits for the original PID to
/// disappear and only then asks LaunchServices to open the bundle again.
struct AppRelaunchPlan: Sendable, Equatable {
    static let helperFlag = "--relaunch-after-pid"

    let parentProcessID: pid_t
    let bundleURL: URL

    init(parentProcessID: pid_t, bundleURL: URL) {
        self.parentProcessID = parentProcessID
        self.bundleURL = URL(
            fileURLWithPath: bundleURL.path,
            isDirectory: true
        ).standardizedFileURL
    }

    init?(arguments: [String]) {
        guard let flagIndex = arguments.firstIndex(of: Self.helperFlag),
              arguments.indices.contains(flagIndex + 2),
              let processID = pid_t(arguments[flagIndex + 1]),
              processID > 1 else { return nil }
        let bundleURL = URL(
            fileURLWithPath: arguments[flagIndex + 2],
            isDirectory: true
        ).standardizedFileURL
        guard bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return nil
        }
        self.init(parentProcessID: processID, bundleURL: bundleURL)
    }

    var helperArguments: [String] {
        [Self.helperFlag, String(parentProcessID), bundleURL.path]
    }

    /// Kept injectable so the ordering contract has a deterministic unit test.
    func execute(
        waitForExit: (pid_t) -> Void,
        openBundle: (URL) throws -> Void
    ) rethrows {
        waitForExit(parentProcessID)
        try openBundle(bundleURL)
    }

    static func waitForProcessExit(_ processID: pid_t) {
        guard processID > 1, processID != getpid() else { return }
        while true {
            errno = 0
            if kill(processID, 0) == 0 || errno == EPERM {
                usleep(50_000)
                continue
            }
            if errno == EINTR { continue }
            return
        }
    }

    static func openReplacement(_ bundleURL: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundleURL.path]
        try task.run()
        task.waitUntilExit()
        guard task.terminationReason == .exit, task.terminationStatus == 0 else {
            throw AppRelaunchPlanError.openFailed(task.terminationStatus)
        }
    }
}
