import SwiftUI
import AppKit

struct MenuBarContent: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Slishu").font(.headline)

            RecordingStatusView()

            if !env.permissions.allCriticalGranted {
                // Кликабельный пилл: из menubar сразу в настройку прав, не тупик.
                Button {
                    env.selectedSection = .settings
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    StatusPill(text: "Нужны разрешения — настроить", color: .orange, system: "lock.shield")
                }
                .buttonStyle(.plain)
            }

            Divider()

            Button(env.recording.isCapturing ? "Поставить на паузу" : "Начать запись") {
                env.recording.toggle()
            }
            Button("Открыть Slishu") { openWindow(id: "main") }

            Divider()

            Button("Выйти из Slishu") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 260)
    }
}
