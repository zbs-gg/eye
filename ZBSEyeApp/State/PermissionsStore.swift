import Foundation
import Observation

@MainActor
@Observable
final class PermissionsStore {
    private(set) var snapshot = PermissionSnapshot()

    /// SCK returned an error while the permission was GRANTED (classic -3801 after granting Screen Recording: TCC
    /// requires a process restart). Set from the capture loop; cleared only by restarting the app.
    private(set) var screenNeedsRestart = false

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    func refreshAll() async {
        var snap = PermissionChecker.snapshot()
        // permission granted but capture is actually failing → honest "restart required" status
        if screenNeedsRestart && snap.screenRecording == .granted {
            snap.screenRecording = .needsRestart
        }
        snapshot = snap
    }

    /// Capture hit an SCK denial despite a granted permission — raise needsRestart (UI shows "Restart").
    func flagScreenNeedsRestart() {
        guard !screenNeedsRestart else { return }
        screenNeedsRestart = true
        Task { await refreshAll() }
    }

    /// Capture recovered (the failure was transient: wake, monitor change) — release the ratchet, otherwise
    /// "Restart required" and the re-start block would hang until relaunch even with capture alive.
    func clearScreenNeedsRestart() {
        guard screenNeedsRestart else { return }
        screenNeedsRestart = false
        Task { await refreshAll() }
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
