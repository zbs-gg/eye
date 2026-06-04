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

    func toggle() {
        guard let coordinator else { return }
        if isCapturing {
            coordinator.stop()
            isCapturing = false
        } else {
            coordinator.start()
            isCapturing = true
        }
    }

    func noteFrame() { screenFrameCount += 1 }
}
