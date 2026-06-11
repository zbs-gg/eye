import SwiftUI
import AppKit

/// AppDelegate ради ОДНОГО хука: applicationShouldTerminate → terminateLater, чтобы успеть iCloud-
/// снапшот ДО смерти процесса (willTerminate уже не успевает — там процесс умирает синхронно).
/// onTerminate выставляет AppEnvironment.bootstrap (если бэкап включён). Без него — мгновенный выход.
final class SlishuAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var onTerminate: (@MainActor () async -> Void)?
    private var isTerminating = false   // повторный Cmd+Q / Force Quit пока бэкап идёт → НЕ плодим reply

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }   // уже завершаемся — ждём первый reply
        guard let handler = SlishuAppDelegate.onTerminate else { return .terminateNow }
        isTerminating = true
        Task { @MainActor in
            await handler()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct SlishuApp: App {
    @NSApplicationDelegateAdaptor(SlishuAppDelegate.self) private var appDelegate
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
