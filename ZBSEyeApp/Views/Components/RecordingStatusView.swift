import SwiftUI

/// Честный per-source статус записи (экран / микрофон / системный звук) — общий для menubar и sidebar.
/// Продукт-рекордер не имеет права показывать одну зелёную точку «всё ок», когда половина источников
/// мертва: ложная зелёная точка = дыры в «вечной памяти», обнаруженные через неделю.
/// Обёрнут в SwiftUI.TimelineView (1с) — возраст кадра и staleness живые, не замороженный Date() в body.
struct RecordingStatusView: View {
    @Environment(AppEnvironment.self) private var env
    var compact = false

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
            statusBody(now: context.date)
        }
    }

    @ViewBuilder
    private func statusBody(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if env.recording.isCapturing {
                screenRow(now: now)
                if env.recording.lowDiskPaused {
                    sourceRow(active: false, warn: true, icon: "externaldrive.badge.exclamationmark",
                              text: "Мало места — захват приостановлен")
                }
                if micWanted || micOn {
                    sourceRow(active: micOn, warn: micWanted && !micOn, icon: "mic",
                              text: micOn ? "Микрофон" : "Микрофон не запустился")
                }
                if systemWanted || systemOn {
                    sourceRow(active: systemOn, warn: systemWanted && !systemOn, icon: "speaker.wave.2",
                              text: systemOn ? "Системный звук" : "Системный звук не запустился")
                }
                if let degraded = env.recording.degradedReason {
                    Label(degraded, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
            } else if let until = env.recording.pausedUntil {
                HStack(spacing: 6) {
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                    Text("Пауза до \(until.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                HStack(spacing: 6) {
                    Circle().fill(Color.secondary).frame(width: 8, height: 8)
                    Text("На паузе").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let reason = env.recording.blockedReason, !env.recording.isCapturing {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
    }

    /// Строка «Экран»: warn по HEARTBEAT цикла (не по последнему кадру — статичный экран дедупится
    /// часами и это здоровье) и по needsRestart. Warn виден и в compact (цвет/иконка).
    private func screenRow(now: Date) -> some View {
        let needsRestart = env.permissions.screenNeedsRestart
        // nil = первый цикл ещё не прошёл (первые секунды после старта) — не пугаем зря
        let stale = staleSeconds(now: now).map { $0 > 90 } ?? false
        let warn = needsRestart || stale
        let text: String
        if needsRestart {
            text = "Экран: нужен перезапуск"
        } else if stale {
            text = "Экран: захват молчит"
        } else {
            text = "Экран" + frameAgeSuffix(now: now)
        }
        return sourceRow(active: !warn, warn: warn, icon: "display", text: text)
    }

    private var micOn: Bool { env.audio?.micRunning ?? false }
    private var systemOn: Bool { env.audio?.systemRunning ?? false }
    private var micWanted: Bool { env.recording.micEnabled() }
    private var systemWanted: Bool { env.recording.systemEnabled() }

    /// Сколько секунд heartbeat молчит (nil = ещё не было ни одного цикла).
    private func staleSeconds(now: Date) -> Int? {
        env.recording.lastCycleOKAt.map { Int(now.timeIntervalSince($0)) }
    }

    private func frameAgeSuffix(now: Date) -> String {
        guard !compact, let t = env.recording.lastFrameAt else { return "" }
        let s = Int(now.timeIntervalSince(t))
        return s < 120 ? " · кадр \(s)с назад" : ""   // давний кадр ≠ сбой (дедуп) — не пугаем
    }

    private func sourceRow(active: Bool, warn: Bool, icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(warn ? Color.orange : (active ? Color.green : Color.secondary))
                .frame(width: 14)
            Text(text).font(.caption)
                .foregroundStyle(warn ? Color.orange : Color.secondary)
        }
    }
}
