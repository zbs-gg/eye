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

    /// Здоровье транскрипции (обновляется при открытии Settings) — чтобы показать «нет on-device модели».
    var health: TranscriptionHealth?

    @ObservationIgnored private static let key = "slishu.audio.transcriptionEnabled"

    func refreshHealth(_ audio: AudioCoordinator?) async {
        health = await audio?.health()
    }

    init() {
        if UserDefaults.standard.object(forKey: Self.key) == nil {
            transcriptionEnabled = true   // дефолт ON
        } else {
            transcriptionEnabled = UserDefaults.standard.bool(forKey: Self.key)
        }
    }
}
