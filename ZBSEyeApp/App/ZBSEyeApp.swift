import SwiftUI

struct ZBSEyeApp: App {
    @NSApplicationDelegateAdaptor(ZBSEyeAppDelegate.self) private var appDelegate
    @State private var env: AppEnvironment

    init() {
        let env = AppEnvironment()
        _env = State(initialValue: env)
        ZBSEyeAppDelegate.onLaunch = { [weak env] in
            await env?.bootstrap()
        }
    }

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
