import Foundation
import Observation

/// Состояние записи. Делегирует старт/стоп в CaptureCoordinator (ставится из AppEnvironment.bootstrap).
@MainActor
@Observable
final class RecordingStore {
    private(set) var isCapturing = false
    private(set) var screenFrameCount = 0
    private(set) var audioChunkCount = 0

    @ObservationIgnored var coordinator: CaptureCoordinator?
    @ObservationIgnored var audio: AudioCoordinator?
    /// Гейты аудио (ставятся из AppEnvironment): микрофон (mic+speech) и системный звук (screen+speech).
    @ObservationIgnored var micEnabled: @MainActor () -> Bool = { false }
    @ObservationIgnored var systemEnabled: @MainActor () -> Bool = { false }

    func toggle() {
        guard let coordinator else { return }
        if isCapturing {
            coordinator.stop()
            audio?.stop()
            isCapturing = false
        } else {
            coordinator.start()
            audio?.start(mic: micEnabled(), system: systemEnabled())
            isCapturing = true
        }
    }

    /// Применить смену аудио-настроек на лету (вызывается из Settings, если запись активна).
    func syncAudio() {
        guard isCapturing, let audio else { return }
        audio.stop()
        let m = micEnabled(), s = systemEnabled()
        if m || s { audio.start(mic: m, system: s) }
    }

    func noteFrame() { screenFrameCount += 1 }
    func noteAudioChunk() { audioChunkCount += 1 }
}
