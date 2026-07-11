import SwiftUI
import AppKit

/// AppDelegate exists for ONE hook: applicationShouldTerminate → terminateLater, so AppEnvironment can
/// bound process-provider teardown and, when enabled, take the iCloud snapshot before the process dies
/// (willTerminate no longer has time — the process dies synchronously there).
/// Without it — an immediate exit.
final class ZBSEyeAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var onTerminate: (@MainActor () async -> Bool)?
    private var isTerminating = false   // a repeated Cmd+Q / Force Quit while the backup is running → do NOT spawn another reply

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }   // already terminating — waiting for the first reply
        guard let handler = ZBSEyeAppDelegate.onTerminate else { return .terminateNow }
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

struct ZBSEyeApp: App {
    @NSApplicationDelegateAdaptor(ZBSEyeAppDelegate.self) private var appDelegate
    @State private var env = AppEnvironment()

    /// An honest icon: a warning if recording is "ongoing" but has actually degraded
    /// (low disk space / SCK is dead and a restart is needed) — rather than a perpetual green dot.
    private var menuBarIcon: String {
        if env.recording.isCapturing {
            let degraded = env.recording.lowDiskPaused || env.permissions.screenNeedsRestart
            return degraded ? "exclamationmark.triangle.fill" : "record.circle.fill"
        }
        return env.rewards.menuBarIcon   // the chosen reward icon (when idle)
    }

    var body: some Scene {
        Window("ZBS Eye", id: "main") {
            RootWindow()
                .environment(env)
                .task { await env.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 720)

        MenuBarExtra {
            MenuBarContent().environment(env)
        } label: {
            Image(systemName: menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
