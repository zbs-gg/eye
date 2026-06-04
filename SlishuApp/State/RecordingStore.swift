import Foundation
import Observation

/// Заглушка состояния записи. В Фазе 2 (шаг 3+) обёрнёт CaptureCoordinator/FramePipelineActor.
@MainActor
@Observable
final class RecordingStore {
    private(set) var isCapturing = false
    private(set) var screenFrameCount = 0
    private(set) var audioChunkCount = 0

    func toggle() {
        isCapturing.toggle()
        // TODO(Фаза 2): start/stop CaptureCoordinator
    }
}
