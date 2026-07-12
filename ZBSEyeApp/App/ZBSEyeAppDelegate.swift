import AppKit

/// Owns process-lifecycle hooks that must not depend on whether SwiftUI creates
/// or restores the main window.
@MainActor
final class ZBSEyeAppDelegate: NSObject, NSApplicationDelegate {
    static var onLaunch: (@MainActor () async -> Void)?
    static var onTerminate: (@MainActor () async -> Bool)?

    private var didStartLaunch = false
    private var isTerminating = false

    private static let terminationDecision = AppTerminationDecisionRelay()

    static func prepareForAcknowledgedTermination() {
        terminationDecision.prepare()
    }

    static func awaitAcknowledgedTerminationDecision() async -> Bool {
        await terminationDecision.wait()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !didStartLaunch, let handler = Self.onLaunch else { return }
        didStartLaunch = true
        Task { @MainActor in
            await handler()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }
        guard let handler = Self.onTerminate else {
            Self.terminationDecision.resolve(true)
            return .terminateNow
        }
        isTerminating = true
        Task { @MainActor in
            let shouldTerminate = await handler()
            Self.terminationDecision.resolve(shouldTerminate)
            for action in AppTerminationReplyPlan.actions(
                shouldTerminate: shouldTerminate
            ) {
                switch action {
                case .reply(let value):
                    NSApp.reply(toApplicationShouldTerminate: value)
                case .resetTerminationGuard:
                    isTerminating = false
                case .showRetryAlert:
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = String(localized: "ZBS Eye is still stopping")
                    alert.informativeText = String(localized: "ZBS Eye is staying open until macOS confirms that local capture and AI resources have stopped. Please try Quit again in a moment.")
                    alert.addButton(withTitle: String(localized: "OK"))
                    alert.runModal()
                }
            }
        }
        return .terminateLater
    }
}

@MainActor
private final class AppTerminationDecisionRelay {
    private var decision: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    func prepare() {
        precondition(waiter == nil, "overlapping acknowledged termination requests")
        decision = nil
    }

    func resolve(_ value: Bool) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: value)
        } else {
            decision = value
        }
    }

    func wait() async -> Bool {
        if let decision {
            self.decision = nil
            return decision
        }
        return await withCheckedContinuation { continuation in
            precondition(waiter == nil, "only one termination decision waiter is supported")
            waiter = continuation
        }
    }
}
