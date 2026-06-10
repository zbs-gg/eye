import SwiftUI

struct SlishuApp: App {
    @State private var env = AppEnvironment()

    /// Иконка честная: предупреждение, если запись «идёт», но фактически деградировала
    /// (мало места / SCK мёртв и нужен перезапуск) — а не вечная зелёная точка.
    private var menuBarIcon: String {
        if env.recording.isCapturing {
            let degraded = env.recording.lowDiskPaused || env.permissions.screenNeedsRestart
            return degraded ? "exclamationmark.triangle.fill" : "record.circle.fill"
        }
        return "waveform"
    }

    var body: some Scene {
        Window("Slishu", id: "main") {
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
