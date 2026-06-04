import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Настройки").font(.largeTitle.bold())
                permissionsCard
                serverCard
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .task { await env.permissions.refreshAll() }
    }

    private var permissionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Разрешения и диагностика").font(.headline)
                Text("Slishu читает экран через Accessibility (точно и легко для батареи), OCR — только где AX недоступен.")
                    .font(.caption).foregroundStyle(.secondary)

                PermissionRow(title: "Запись экрана",
                              status: env.permissions.snapshot.screenRecording,
                              request: { PermissionChecker.requestScreenRecording() },
                              openSettings: { PermissionChecker.openSettings("Privacy_ScreenCapture") })
                PermissionRow(title: "Универсальный доступ (Accessibility)",
                              status: env.permissions.snapshot.accessibility,
                              request: { PermissionChecker.requestAccessibility() },
                              openSettings: { PermissionChecker.openSettings("Privacy_Accessibility") })
                PermissionRow(title: "Микрофон",
                              status: env.permissions.snapshot.microphone,
                              request: { Task { await env.permissions.requestMicrophone() } },
                              openSettings: { PermissionChecker.openSettings("Privacy_Microphone") })
                PermissionRow(title: "Распознавание речи (для аудио-поиска)",
                              status: env.permissions.snapshot.speech,
                              request: { Task { await env.permissions.requestSpeech() } },
                              openSettings: { PermissionChecker.openSettings("Privacy_SpeechRecognition") })

                Button("Повторить проверку") {
                    Task { await env.permissions.refreshAll() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var serverCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Локальный сервер").font(.headline)
                HStack {
                    Text("Адрес")
                    Spacer()
                    Text(env.server.baseURL).foregroundStyle(.secondary).monospaced()
                }
                Text("REST API + MCP появятся в Фазе 2 (auth на всё кроме /health, токен в Keychain).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let status: PermissionStatus
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status == .granted ? Color.green : Color.orange)
            Text(title)
            Spacer()
            switch status {
            case .granted:
                StatusPill(text: "Выдано", color: .green)
            case .denied, .needsRestart:
                StatusPill(text: status == .needsRestart ? "Перезапуск" : "Нет доступа", color: .red)
                Button("Настройки", action: openSettings).buttonStyle(.borderless)
            case .notDetermined:
                Button("Запросить", action: request)
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
    }
}
