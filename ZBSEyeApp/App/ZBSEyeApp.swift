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
        .commands { CallCommands(env: env) }

        Window("Call", id: "call-detail") {
            Group {
                if let callID = env.presentedCallID {
                    CallDetailView(callID: callID)
                } else {
                    ContentUnavailableView(
                        "No call selected",
                        systemImage: "phone.badge.waveform"
                    )
                }
            }
            .frame(minWidth: 520, minHeight: 420)
            .environment(env)
        }
        .defaultSize(width: 680, height: 640)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarContent().environment(env)
        } label: {
            Image(systemName: menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
