import Foundation
import Observation

@MainActor
@Observable
final class PermissionsStore {
    private(set) var snapshot = PermissionSnapshot()

    func refreshAll() async {
        snapshot = PermissionChecker.snapshot()
    }

    /// Критичные для записи права: экран + accessibility (микрофон/речь — для аудио, опциональны).
    var allCriticalGranted: Bool {
        snapshot.screenRecording == .granted && snapshot.accessibility == .granted
    }

    func requestMicrophone() async {
        await PermissionChecker.requestMicrophone()
        await refreshAll()
    }

    func requestSpeech() async {
        await PermissionChecker.requestSpeech()
        await refreshAll()
    }
}
