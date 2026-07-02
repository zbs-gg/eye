import Foundation
import Observation

/// How audio capture is gated. Screen capture is unaffected by this — only audio.
///  - off:          never capture audio, even while recording.
///  - meetingsOnly: capture ONLY while a call/meeting is auto-detected (mic in use by any app +
///                  known meeting apps). The capture engine is fully STOPPED otherwise — no files,
///                  no mic/SCStream I/O, no CPU. This is the default: saves disk.
///  - always:       legacy continuous behavior (capture audio the whole time recording is on).
enum AudioMode: String, CaseIterable, Codable, Sendable {
    case off, meetingsOnly, always

    var label: String {
        switch self {
        case .off: return "Off"
        case .meetingsOnly: return "Meetings only"
        case .always: return "Always"
        }
    }
}

/// Audio/transcription settings. Audio capture is a tri-state `audioMode` (default `.meetingsOnly`):
/// the engine only runs during detected meetings, saving disk. Persisted in UserDefaults; the actual
/// start is still gated by permissions (microphone / screen recording).
@MainActor
@Observable
final class AudioSettingsStore {
    /// The capture mode (persisted). Source of truth for whether audio should be recorded.
    var audioMode: AudioMode {
        didSet {
            guard audioMode != oldValue else { return }
            UserDefaults.standard.set(audioMode.rawValue, forKey: Self.modeKey)
            // an explicit mode change wins over a stale session override — otherwise "force on" + switch
            // to Off would keep recording while the UI says Off (a privacy trap). Off = hard stop.
            manualAudioOverride = nil
        }
    }

    /// A separate toggle for system audio (calls/video = other people's voices) — so you can record
    /// your own microphone but not other people's audio. Default ON, but it's a conscious choice.
    var recordSystemAudio: Bool {
        didSet { if recordSystemAudio != oldValue { UserDefaults.standard.set(recordSystemAudio, forKey: Self.sysKey) } }
    }

    /// Runtime-only: a meeting/call is currently detected (fed by MeetingDetector). NOT persisted.
    var meetingActive: Bool = false

    /// Session-only manual override of audio capture. nil = auto (follow mode/detector), true = force ON,
    /// false = force OFF. Wins over `audioMode` entirely. Cleared at a real recording-session stop
    /// (NOT on every syncAudio, or a re-sync would wipe it). NOT persisted.
    var manualAudioOverride: Bool? = nil

    /// One-time nudge (post-migration): audio is now meetings-only by default. Persisted so we show it once.
    var migrationNudgeSeen: Bool {
        didSet { if migrationNudgeSeen != oldValue { UserDefaults.standard.set(migrationNudgeSeen, forKey: Self.nudgeKey) } }
    }

    /// Transcription health (refreshed when Settings opens) — to show "no on-device model".
    var health: TranscriptionHealth?
    var micEngineFailed = false
    var systemEngineFailed = false

    @ObservationIgnored private static let modeKey = "zbseye.audio.audioMode"
    @ObservationIgnored private static let legacyKey = "zbseye.audio.transcriptionEnabled"
    @ObservationIgnored private static let sysKey = "zbseye.audio.recordSystemAudio"
    @ObservationIgnored private static let nudgeKey = "zbseye.audio.migrationNudgeSeen"

    /// The single decision point: should audio be captured right now? Manual override wins; otherwise mode.
    func audioShouldCapture() -> Bool {
        if let ov = manualAudioOverride { return ov }
        switch audioMode {
        case .off: return false
        case .always: return true
        case .meetingsOnly: return meetingActive
        }
    }

    /// Menu-bar quick control — cycles the session override: auto → force-on → force-off → auto.
    func cycleManualOverride() {
        switch manualAudioOverride {
        case nil: manualAudioOverride = true
        case .some(true): manualAudioOverride = false
        case .some(false): manualAudioOverride = nil
        }
    }

    /// Clear the session override (called at a real recording-session stop). Idempotent.
    func clearManualOverride() { manualAudioOverride = nil }

    func refreshHealth(_ audio: AudioCoordinator?) async {
        health = await audio?.health()
        micEngineFailed = audio?.micStartFailed ?? false
        systemEngineFailed = audio?.systemStartFailed ?? false
    }

    init() {
        let d = UserDefaults.standard
        recordSystemAudio = (d.object(forKey: Self.sysKey) == nil) ? true : d.bool(forKey: Self.sysKey)
        migrationNudgeSeen = d.bool(forKey: Self.nudgeKey)

        // Migration → tri-state. New default is meetings-only for everyone; only an explicit prior
        // "audio off" (legacy transcriptionEnabled=false) is preserved as .off so we never start
        // recording audio someone deliberately disabled.
        if let raw = d.string(forKey: Self.modeKey), let mode = AudioMode(rawValue: raw) {
            audioMode = mode
        } else if d.object(forKey: Self.legacyKey) != nil && d.bool(forKey: Self.legacyKey) == false {
            audioMode = .off
            migrationNudgeSeen = true            // they had audio off; nothing to nudge about
            d.set(AudioMode.off.rawValue, forKey: Self.modeKey)
        } else {
            audioMode = .meetingsOnly
            d.set(AudioMode.meetingsOnly.rawValue, forKey: Self.modeKey)
        }
    }
}
