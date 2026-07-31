import Foundation
import Observation

@MainActor
@Observable
final class PermissionsStore {
    private(set) var snapshot = PermissionSnapshot()

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored var onSnapshotChanged: (@MainActor (PermissionSnapshot) -> Void)?

    func refreshAll() async {
        let snap = PermissionChecker.snapshot()
        guard snap != snapshot else { return }
        snapshot = snap
        onSnapshotChanged?(snap)
    }

    /// Background permission polling: the user grants permissions in System Settings — the UI picks it up without
    /// "Re-check". Cheap (TCC probes are local calls). Started once from bootstrap.
    func startPolling(interval: TimeInterval = 3) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                await self?.refreshAll()
            }
        }
    }

    /// Permissions critical for recording: screen + accessibility (microphone/speech — for audio, optional).
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
