import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Настройки").font(.largeTitle.bold())
                permissionsCard
                transcriptionCard
                serverCard
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .task {
            await env.permissions.refreshAll()
            await env.audioSettings.refreshHealth(env.audio)
        }
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

    private var transcriptionCard: some View {
        @Bindable var settings = env.audioSettings
        return GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Аудио и транскрипция").font(.headline)
                Toggle("Записывать и транскрибировать звук", isOn: $settings.transcriptionEnabled)
                    .onChange(of: settings.transcriptionEnabled) { _, _ in env.recording.syncAudio() }
                Text("Локально, on-device (Apple Speech). VAD отсекает тишину — пишутся только сегменты речи, "
                     + "затем они ищутся по словам. Звук не уходит в облако.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.transcriptionEnabled {
                    if env.permissions.snapshot.microphone != .granted {
                        Label("Нет доступа к микрофону — звук не записывается. Выдай доступ выше.",
                              systemImage: "mic.slash").font(.caption).foregroundStyle(.orange)
                    }
                    if env.permissions.snapshot.speech != .granted {
                        Label("Нет распознавания речи — звук не записывается (пишем только то, что можем расшифровать).",
                              systemImage: "exclamationmark.bubble").font(.caption).foregroundStyle(.orange)
                    }
                }
                if let h = settings.health, h.failed > 0, h.transcribed == 0,
                   h.lastErrorKind == "onDeviceUnavailable" {
                    Label("Распознавание не работает: нет on-device модели ru-RU. Включи диктовку в "
                          + "Системных настройках → Клавиатура → Диктовка. Звук пишется, но без текста.",
                          systemImage: "waveform.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private var serverCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Локальный API").font(.headline)
                HStack {
                    Text("Адрес")
                    Spacer()
                    Text(env.server.baseURL).foregroundStyle(.secondary).monospaced().textSelection(.enabled)
                }
                if let token = env.server.token {
                    HStack {
                        Text("Токен")
                        Spacer()
                        Text(token.prefix(14) + "…").monospaced().foregroundStyle(.secondary)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(token, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Скопировать токен")
                    }
                    Text("curl -H 'Authorization: Bearer <токен>' '\(env.server.baseURL)/v1/search?q=test'")
                        .font(.caption2).monospaced().foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(2)
                } else {
                    Text("Сервер запускается…").font(.caption).foregroundStyle(.secondary)
                }
                Text("Auth на всё кроме /health (токен в Keychain), bind 127.0.0.1. MCP — следующий шаг.")
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
