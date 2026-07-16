import Foundation
import Observation

@MainActor
@Observable
final class CallRecordingStore {
    private(set) var snapshot = CallCoordinatorSnapshot.idle
    private(set) var errorMessage: String?
    @ObservationIgnored private var coordinator: CallCoordinator?
    @ObservationIgnored private var ending = false
    @ObservationIgnored var requestedSources: @MainActor () -> CallSourceSelection = { .none }

    var isActive: Bool {
        switch snapshot.phase {
        case .starting, .recording, .finalizing: true
        case .idle, .pendingTranscription, .ready, .readyDegraded, .failed: false
        }
    }

    func attach(_ coordinator: CallCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        guard let coordinator else { return }
        errorMessage = nil
        Task {
            do {
                snapshot = try await coordinator.start(request: requestedSources())
            } catch {
                errorMessage = error.localizedDescription
                snapshot = await coordinator.snapshot()
            }
        }
    }

    func bookmark() {
        guard let coordinator else { return }
        errorMessage = nil
        Task {
            do {
                _ = try await coordinator.bookmark()
                snapshot = await coordinator.snapshot()
            } catch {
                errorMessage = error.localizedDescription
                snapshot = await coordinator.snapshot()
            }
        }
    }

    func end() {
        Task { await endAndWait(reason: .user) }
    }

    func endAndWait(reason: CallStopReason) async {
        guard let coordinator, isActive, !ending else { return }
        ending = true
        defer { ending = false }
        errorMessage = nil
        do {
            snapshot = try await coordinator.end(reason: reason)
        } catch {
            errorMessage = error.localizedDescription
            snapshot = await coordinator.snapshot()
        }
    }
}
