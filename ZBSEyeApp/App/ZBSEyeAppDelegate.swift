import AppKit

/// Owns process-lifecycle hooks that must not depend on whether SwiftUI creates
/// or restores the main window.
@MainActor
final class ZBSEyeAppDelegate: NSObject, NSApplicationDelegate {
    static var onLaunch: (@MainActor () async -> Void)?
    static var onTerminate: (@MainActor () async -> Bool)?

    private var didStartLaunch = false
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !didStartLaunch, let handler = Self.onLaunch else { return }
        didStartLaunch = true
        Task { @MainActor in
            await handler()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }
        guard let handler = Self.onTerminate else { return .terminateNow }
        isTerminating = true
        Task { @MainActor in
            let shouldTerminate = await handler()
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
