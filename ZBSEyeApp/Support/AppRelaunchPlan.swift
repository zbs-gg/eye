import Darwin
import Foundation

enum AppRelaunchPlanError: Error, LocalizedError, Sendable, Equatable {
    case executableUnavailable
    case ownerTerminationRejected
    case openFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            "The ZBS Eye executable could not be resolved for restart."
        case .ownerTerminationRejected:
            "ZBS Eye stayed open because its resources have not finished stopping."
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

    /// Relocation has already committed the new root before requesting Quit,
    /// so its helper must remain owned until AppDelegate confirms the process
    /// will actually exit. A rejected Quit stops the waiting helper and throws,
    /// allowing the caller to restore the old root and resume every admission
    /// gate before any writer can observe the copied root.
    @MainActor
    static func launchAcknowledged(
        plan: AppRelaunchPlan,
        executableURL: URL,
        launchHelper: (URL, [String]) throws -> () -> Void,
        requestOwnerTermination: () -> Void,
        awaitOwnerDecision: () async -> Bool
    ) async throws {
        let stopHelper = try launchHelper(executableURL, plan.helperArguments)
        requestOwnerTermination()
        guard await awaitOwnerDecision() else {
            stopHelper()
            throw AppRelaunchPlanError.ownerTerminationRejected
        }
    }
}

/// The rollback ordering shared by relocation's failure path and its
/// deterministic handoff test. Root resolution must be restored before any
/// old-graph admission gate reopens; recording drain ownership must complete
/// before those resumes run.
@MainActor
enum AppRelocationFailureRecovery {
    static func run(
        committedNewRoot: Bool,
        restorePreviousRoot: () -> Void,
        awaitRecordingDrain: () async -> Void,
        awaitTerminationHandoffDrain: () async -> Void,
        resumeOldGraphAdmissions: () async -> Void
    ) async {
        if committedNewRoot {
            restorePreviousRoot()
        }
        await awaitRecordingDrain()
        await awaitTerminationHandoffDrain()
        await resumeOldGraphAdmissions()
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
