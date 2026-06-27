import Foundation
import Observation

/// Audio/transcription settings. Plan v1: ON by default ("record everything"), but the actual start
/// is still gated by permissions (microphone). Persisted in UserDefaults.
@MainActor
@Observable
final class AudioSettingsStore {
    var transcriptionEnabled: Bool {
        didSet { if transcriptionEnabled != oldValue { UserDefaults.standard.set(transcriptionEnabled, forKey: Self.key) } }
    }

    /// A separate toggle for system audio (calls/video = other people's voices) — so you can record
    /// your own microphone but not other people's audio. Default ON (the "record everything" plan), but it's a conscious choice.
    var recordSystemAudio: Bool {
        didSet { if recordSystemAudio != oldValue { UserDefaults.standard.set(recordSystemAudio, forKey: Self.sysKey) } }
    }

    /// Transcription health (refreshed when Settings opens) — to show "no on-device model".
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
