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
    /// Гейт аудио-записи: включена транскрипция И есть доступ к микрофону (ставится из AppEnvironment).
    @ObservationIgnored var audioEnabled: @MainActor () -> Bool = { false }

    func toggle() {
        guard let coordinator else { return }
        if isCapturing {
            coordinator.stop()
            audio?.stop()
            isCapturing = false
        } else {
            coordinator.start()
            if audioEnabled() { audio?.start() }
            isCapturing = true
        }
    }

    /// Применить смену настройки транскрипции на лету (вызывается из Settings, если запись активна).
    func syncAudio() {
        guard isCapturing, let audio else { return }
        if audioEnabled() { audio.start() } else { audio.stop() }
    }

    func noteFrame() { screenFrameCount += 1 }
    func noteAudioChunk() { audioChunkCount += 1 }
}
