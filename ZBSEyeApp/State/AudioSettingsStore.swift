import Foundation
import Observation

/// Настройки аудио/транскрипции. План v1: ON по умолчанию («записывать всё»), но фактический старт
/// всё равно гейтится правами (микрофон). Persist в UserDefaults.
@MainActor
@Observable
final class AudioSettingsStore {
    var transcriptionEnabled: Bool {
        didSet { if transcriptionEnabled != oldValue { UserDefaults.standard.set(transcriptionEnabled, forKey: Self.key) } }
    }

    /// Отдельный тумблер системного звука (звонки/видео = голоса собеседников) — чтобы можно было писать
    /// свой микрофон, но не чужой звук. Дефолт ON (план «записывать всё»), но это осознанный выбор.
    var recordSystemAudio: Bool {
        didSet { if recordSystemAudio != oldValue { UserDefaults.standard.set(recordSystemAudio, forKey: Self.sysKey) } }
    }

    /// Здоровье транскрипции (обновляется при открытии Settings) — чтобы показать «нет on-device модели».
    var health: TranscriptionHealth?
    var micEngineFailed = false
    var systemEngineFailed = false

    @ObservationIgnored private static let key = "zbseye.audio.transcriptionEnabled"
    @ObservationIgnored private static let sysKey = "zbseye.audio.recordSystemAudio"

    func refreshHealth(_ audio: AudioCoordinator?) async {
        health = await audio?.health()
        micEngineFailed = audio?.micStartFailed ?? false
        systemEngineFailed = audio?.systemStartFailed ?? false
    }

    init() {
        let d = UserDefaults.standard
        transcriptionEnabled = (d.object(forKey: Self.key) == nil) ? true : d.bool(forKey: Self.key)
        recordSystemAudio = (d.object(forKey: Self.sysKey) == nil) ? true : d.bool(forKey: Self.sysKey)
    }
}
