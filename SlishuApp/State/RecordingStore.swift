import Foundation
import Observation

/// Состояние записи. Делегирует старт/стоп в CaptureCoordinator (ставится из AppEnvironment.bootstrap).
/// Желание «запись включена» персистится — после ребута/краша bootstrap возобновляет запись сам
/// (вечная память не должна зависеть от ручного клика). isCapturing не врёт: без критичных прав
/// запись не стартует, вместо ложной зелёной точки — blockedReason.
@MainActor
@Observable
final class RecordingStore {
    private(set) var isCapturing = false
    private(set) var screenFrameCount = 0
    private(set) var audioChunkCount = 0

    // Health для индикаторов (menubar/sidebar): продукт обязан показывать, ЧТО реально пишется.
    private(set) var lastFrameAt: Date?
    /// Heartbeat capture-цикла: успешный проход (включая дедуп и осознанный idle-skip). Отдельно от
    /// lastFrameAt — статичный экран дедупится часами, это НЕ «захват умер» (анти-ложная тревога).
    private(set) var lastCycleOKAt: Date?
    private(set) var lastAudioAt: Date?
    private(set) var lowDiskPaused = false
    /// Запись не стартовала из-за прав — причина для UI (вместо ложного «Запись идёт»).
    private(set) var blockedReason: String?
    /// Запись идёт, но деградировала (права отозваны mid-run и т.п.) — показывается ПРИ isCapturing.
    private(set) var degradedReason: String?
    /// Временная privacy-пауза («не пиши 15 минут»): желание записи СОХРАНЯЕТСЯ, автостарт-watcher
    /// не возобновляет до истечения. nil = пауза не активна.
    private(set) var pausedUntil: Date?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private static let pausedKey = "slishu.recording.pausedUntil"

    init() {
        // Пауза переживает перезапуск/краш: иначе релонч молча возобновлял бы запись посреди
        // «не записывать 15 минут» — privacy-обещание сломано.
        if let saved = UserDefaults.standard.object(forKey: Self.pausedKey) as? Date {
            if saved > Date() {
                pausedUntil = saved
                let remain = saved.timeIntervalSinceNow
                resumeTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(remain))
                    guard !Task.isCancelled, let self else { return }
                    self.clearPause()
                    self.startIfWanted()
                }
            } else {
                UserDefaults.standard.removeObject(forKey: Self.pausedKey)
            }
        }
    }

    private func clearPause() {
        pausedUntil = nil
        UserDefaults.standard.removeObject(forKey: Self.pausedKey)
    }

    @ObservationIgnored var coordinator: CaptureCoordinator?
    @ObservationIgnored var audio: AudioCoordinator?
    /// Гейты (ставятся из AppEnvironment): критичные права записи; аудио mic/system.
    @ObservationIgnored var canCapture: @MainActor () -> Bool = { false }
    /// Почему запись недоступна (needsRestart vs denied — тексты разные; ставит AppEnvironment).
    @ObservationIgnored var blockedHint: @MainActor () -> String = {
        "Нет прав (Запись экрана + Универсальный доступ). Запись включится автоматически после выдачи; повторный клик — отмена"
    }
    @ObservationIgnored var micEnabled: @MainActor () -> Bool = { false }
    @ObservationIgnored var systemEnabled: @MainActor () -> Bool = { false }

    @ObservationIgnored private static let enabledKey = "slishu.recording.enabled"

    /// Желание пользователя (персист): были ли «Запись» включена при прошлом выходе.
    var wantsRecording: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func toggle() {
        guard let coordinator else {
            // bootstrap ещё идёт — кнопка не должна быть молчаливым no-op: запоминаем/снимаем намерение,
            // autostart-watcher дожмёт старт после инициализации.
            if wantsRecording {
                UserDefaults.standard.set(false, forKey: Self.enabledKey)
                blockedReason = nil
            } else {
                UserDefaults.standard.set(true, forKey: Self.enabledKey)
                blockedReason = "Slishu ещё запускается — запись включится автоматически"
            }
            return
        }
        if isCapturing {
            coordinator.stop()
            audio?.stop()
            isCapturing = false
            degradedReason = nil
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
        } else {
            // ручное включение снимает временную паузу (юзер передумал ждать)
            resumeTask?.cancel(); resumeTask = nil
            clearPause()
            guard canCapture() else {
                // Честный toggle НАМЕРЕНИЯ: первый клик взводит (запись стартанёт сама после выдачи
                // прав — говорим об этом), повторный клик СНИМАЕТ взвод (иначе отменить невозможно).
                if wantsRecording {
                    UserDefaults.standard.set(false, forKey: Self.enabledKey)
                    blockedReason = nil
                } else {
                    UserDefaults.standard.set(true, forKey: Self.enabledKey)
                    blockedReason = blockedHint()
                }
                return
            }
            blockedReason = nil
            coordinator.start()
            audio?.start(mic: micEnabled(), system: systemEnabled())
            isCapturing = true
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
        }
    }

    /// Явный отказ (онбординг «Позже» при взведённом намерении): остановить и снять взвод.
    func disarm() {
        if isCapturing { toggle() }
        else {
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            blockedReason = nil
        }
    }

    /// Остановка ради обслуживания (миграция хранилища): глушим захват, но НЕ трогаем намерение
    /// (enabledKey) и паузу — после рестарта autostart возобновит. Гарантирует, что во время копии
    /// данных в новый root никто не пишет в старый.
    func pauseForMaintenance() {
        guard isCapturing, let coordinator else { return }
        coordinator.stop()
        audio?.stop()
        isCapturing = false
        degradedReason = nil
    }

    /// Автостарт из bootstrap (и после выдачи прав): если юзер хотел запись и права есть — включаем.
    /// Временная пауза блокирует автостарт до истечения (resume-задача снимет pausedUntil).
    func startIfWanted() {
        guard pausedUntil == nil else { return }
        guard wantsRecording, !isCapturing, canCapture() else { return }
        toggle()
    }

    /// Privacy-пауза из menubar: остановить запись на N минут, потом возобновить самой.
    /// Желание записи (enabledKey) не трогаем — это пауза, не выключение.
    func pauseFor(minutes: Int) {
        guard isCapturing, let coordinator else { return }
        coordinator.stop()
        audio?.stop()
        isCapturing = false
        degradedReason = nil
        let until = Date().addingTimeInterval(Double(minutes) * 60)
        pausedUntil = until
        UserDefaults.standard.set(until, forKey: Self.pausedKey)
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled, let self else { return }
            self.clearPause()
            self.startIfWanted()
        }
    }

    /// Снять паузу досрочно (кнопка «Возобновить сейчас»).
    func resumeNow() {
        resumeTask?.cancel(); resumeTask = nil
        clearPause()
        startIfWanted()
    }

    /// Применить смену аудио-настроек на лету (вызывается из Settings, если запись активна).
    func syncAudio() {
        guard isCapturing, let audio else { return }
        audio.stop()
        let m = micEnabled(), s = systemEnabled()
        if m || s { audio.start(mic: m, system: s) }
    }

    func noteFrame() { screenFrameCount += 1; lastFrameAt = Date(); lastCycleOKAt = Date() }
    func noteCycleOK() { lastCycleOKAt = Date() }
    func noteAudioChunk() { audioChunkCount += 1; lastAudioAt = Date() }
    func setLowDisk(_ paused: Bool) { lowDiskPaused = paused }
    func setDegraded(_ reason: String?) { if degradedReason != reason { degradedReason = reason } }
}
