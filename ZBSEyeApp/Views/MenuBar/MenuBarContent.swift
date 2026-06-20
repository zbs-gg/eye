import SwiftUI
import AppKit

struct MenuBarContent: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ZBS Eye").font(.headline)

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
            if env.recording.isCapturing {
                // privacy-микропауза: «сейчас будет чувствительное — не пиши 15 минут»
                Button("Не записывать 15 минут") { env.recording.pauseFor(minutes: 15) }
            }
            if let until = env.recording.pausedUntil {
                Text("Возобновится в \(until.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Возобновить сейчас") { env.recording.resumeNow() }
            }
            Button("Открыть ZBS Eye") { openWindow(id: "main") }

            Divider()

            Button("Выйти из ZBS Eye") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 260)
    }
}
