import SwiftUI

struct TimelineView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Таймлайн").font(.largeTitle.bold())

                if let err = env.dataError {
                    GlassCard {
                        Label("Ошибка БД: \(err)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                dashboard

                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Time-travel скруббер и семантический поиск — следующий шаг.")
                            .font(.headline)
                        Text("Сейчас работает захват: accessibility-текст + кадр экрана пишутся в БД при смене окна и каждые несколько секунд. Открой VS Code / Obsidian / браузер и нажми «Начать запись».")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private var dashboard: some View {
        HStack(spacing: 16) {
            statCard("Кадров за сессию", "\(env.recording.screenFrameCount)", "photo.stack")

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    env.recording.toggle()
                } label: {
                    Label(env.recording.isCapturing ? "Остановить запись" : "Начать запись",
                          systemImage: env.recording.isCapturing ? "stop.circle.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(env.recording.isCapturing ? .red : .accentColor)

                if !env.permissions.allCriticalGranted {
                    StatusPill(text: "Нужны разрешения — вкладка «Настройки»", color: .orange, system: "lock.shield")
                }
            }
        }
    }

    private func statCard(_ title: String, _ value: String, _ icon: String) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(size: 34, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
            }
        }
        .frame(width: 220)
    }
}
