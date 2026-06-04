import SwiftUI

@main
struct SlishuApp: App {
    @State private var env = AppEnvironment()

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
            Image(systemName: env.recording.isCapturing ? "record.circle.fill" : "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}
