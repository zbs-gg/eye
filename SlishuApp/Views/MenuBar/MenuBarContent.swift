import SwiftUI
import AppKit

struct MenuBarContent: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Slishu").font(.headline)

            HStack(spacing: 6) {
                Circle()
                    .fill(env.recording.isCapturing ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(env.recording.isCapturing ? "Запись идёт" : "На паузе")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !env.permissions.allCriticalGranted {
                StatusPill(text: "Нужны разрешения", color: .orange, system: "lock.shield")
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
        .frame(width: 240)
    }
}
