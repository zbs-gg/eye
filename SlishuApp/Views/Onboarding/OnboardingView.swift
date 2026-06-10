import SwiftUI

/// Первый запуск: consent («Slishu записывает всё — локально») + выдача прав с live-статусом.
/// Без онбординга юзер падал в пустой Timeline, жал «Запись», получал ложную зелёную точку и ноль
/// кадров — первый опыт был тихим провалом. Права обновляются фоновым поллингом PermissionsStore.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 480)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: welcome
        default: permissions
        }
    }

    // MARK: шаг 1 — что это и согласие

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 40)).foregroundStyle(.tint)
                Text("Slishu — вечная память твоего Mac").font(.title2.bold())
            }
            Text("Slishu непрерывно записывает работу за компьютером, чтобы любой момент можно было найти и пересмотреть:")
                .font(.callout)
            VStack(alignment: .leading, spacing: 10) {
                bullet("display", "Экран и текст с него — каждое приложение, окно, вкладка")
                bullet("mic", "Микрофон — твой голос (если включишь)")
                bullet("speaker.wave.2", "Системный звук — звонки, встречи, видео (если включишь)")
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("Всё остаётся на этом Mac: без облака, аккаунтов и подписок.",
                      systemImage: "lock.shield.fill").font(.callout).bold()
                Text("История хранится 7 дней или до 20 ГБ (настраивается). Запись собеседников в звонках — "
                     + "под твою ответственность: macOS не показывает им индикатор.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.tint)
            Text(text).font(.callout)
        }
    }

    // MARK: шаг 2 — права с live-статусом

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Разрешения").font(.title2.bold())
            Text("Статусы обновляются сами — выдай право и возвращайся.")
                .font(.callout).foregroundStyle(.secondary)

            permissionStep(
                title: "Запись экрана", required: true,
                status: env.permissions.snapshot.screenRecording,
                request: { PermissionChecker.requestScreenRecording() },
                settingsPane: "Privacy_ScreenCapture")
            if env.permissions.snapshot.screenRecording == .needsRestart {
                Label("Право выдано — нужен перезапуск Slishu (так устроен macOS).",
                      systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.orange)
                Button("Перезапустить Slishu") { AppRelauncher.relaunch() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            permissionStep(
                title: "Универсальный доступ (текст с экрана)", required: true,
                status: env.permissions.snapshot.accessibility,
                request: { PermissionChecker.requestAccessibility() },
                settingsPane: "Privacy_Accessibility")
            permissionStep(
                title: "Микрофон (запись голоса)", required: false,
                status: env.permissions.snapshot.microphone,
                request: { Task { await env.permissions.requestMicrophone() } },
                settingsPane: "Privacy_Microphone")
            permissionStep(
                title: "Распознавание речи (поиск по звонкам)", required: false,
                status: env.permissions.snapshot.speech,
                request: { Task { await env.permissions.requestSpeech() } },
                settingsPane: "Privacy_SpeechRecognition")

            Spacer()
            if env.permissions.allCriticalGranted {
                Label("Готово — можно записывать.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout.bold())
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionStep(title: String, required: Bool, status: PermissionStatus,
                                request: @escaping () -> Void, settingsPane: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(status == .granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                if !required { Text("необязательно").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            switch status {
            case .granted:
                EmptyView()
            case .notDetermined:
                Button("Запросить", action: request).controlSize(.small).buttonStyle(.borderedProminent)
            case .denied, .needsRestart:
                Button("Открыть настройки") { PermissionChecker.openSettings(settingsPane) }
                    .controlSize(.small)
            }
        }
    }

    // MARK: футер

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Назад") { step -= 1 }
            }
            Spacer()
            if step == 0 {
                Button("Продолжить") { step = 1 }.buttonStyle(.borderedProminent)
            } else {
                // Закрыть можно и без прав (онбординг не клетка), но запись включаем только при правах.
                Button(env.permissions.allCriticalGranted ? "Включить запись" : "Позже") {
                    env.completeOnboarding(startRecording: env.permissions.allCriticalGranted)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}
