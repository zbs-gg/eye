import Foundation
import Observation

@MainActor
@Observable
final class CallRecordingStore {
    private(set) var snapshot = CallCoordinatorSnapshot.idle
    private(set) var errorMessage: String?
    @ObservationIgnored private var coordinator: CallCoordinator?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var startGeneration: UInt64 = 0
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var ending = false
    @ObservationIgnored var requestedSources: @MainActor () -> CallSourceSelection = { .none }
    @ObservationIgnored var admissionAllowed: @MainActor () -> Bool = { true }
    @ObservationIgnored var onManualStartWhileActive: @MainActor (Int64) -> Void = { _ in }

    var isActive: Bool {
        switch snapshot.phase {
        case .starting, .recording, .recoveryTail, .finalizing: true
        case .idle, .pendingTranscription, .ready, .readyDegraded, .failed: false
        }
    }

    func attach(_ coordinator: CallCoordinator) {
        self.coordinator = coordinator
    }

    func setExternalError(_ message: String?) {
        errorMessage = message
    }

    func start() {
        guard let coordinator else { return }
        if isActive, let callID = snapshot.callID {
            onManualStartWhileActive(callID)
            return
        }
        guard !starting, !ending else { return }
        guard admissionAllowed() else {
            errorMessage = "A storage move is in progress. No call was started."
            return
        }
        errorMessage = nil
        let requested = requestedSources()
        starting = true
        snapshot = CallCoordinatorSnapshot(
            phase: .starting,
            callID: nil,
            me: requested.me ? .unavailable : .disabled,
            system: requested.system ? .unavailable : .disabled,
            bookmarkCount: 0,
            stopReason: nil
        )
        startGeneration &+= 1
        let generation = startGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.startGeneration == generation {
                    self.starting = false
                    self.startTask = nil
                }
            }
            do {
                guard self.admissionAllowed() else {
                    self.snapshot = await coordinator.snapshot()
                    return
                }
                self.snapshot = try await coordinator.start(request: requested)
            } catch {
                self.errorMessage = error.localizedDescription
                self.snapshot = await coordinator.snapshot()
            }
        }
        startTask = task
    }

    func startAutomatic(idempotencyKey: String) async -> CallCoordinatorSnapshot? {
        guard let coordinator, !isActive, !starting, !ending, admissionAllowed() else { return nil }
        let requested = requestedSources()
        guard !requested.isEmpty else { return nil }
        starting = true
        defer { starting = false }
        errorMessage = nil
        do {
            snapshot = try await coordinator.start(
                request: requested,
                idempotencyKey: idempotencyKey
            )
            return snapshot
        } catch {
            errorMessage = error.localizedDescription
            snapshot = await coordinator.snapshot()
            return nil
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

    func undoAutomaticEnd() {
        guard let coordinator else { return }
        Task {
            do {
                snapshot = try await coordinator.undoSoftEnd()
            } catch {
                errorMessage = error.localizedDescription
                snapshot = await coordinator.snapshot()
            }
        }
    }

    func undoAutomaticEndAndWait() async -> CallCoordinatorSnapshot? {
        guard let coordinator else { return nil }
        do {
            snapshot = try await coordinator.undoSoftEnd()
            return snapshot
        } catch {
            errorMessage = error.localizedDescription
            snapshot = await coordinator.snapshot()
            return nil
        }
    }

    func softEndAutomaticAndWait() async -> CallCoordinatorSnapshot? {
        guard let coordinator, snapshot.phase == .recording else { return nil }
        do {
            snapshot = try await coordinator.softEnd()
            return snapshot
        } catch {
            errorMessage = error.localizedDescription
            snapshot = await coordinator.snapshot()
            return nil
        }
    }

    func commitAutomaticEndAndWait() async -> CallCoordinatorSnapshot? {
        guard let coordinator, snapshot.phase == .recoveryTail else { return nil }
        do {
            snapshot = try await coordinator.commitSoftEnd()
            return snapshot
        } catch {
            errorMessage = error.localizedDescription
            snapshot = await coordinator.snapshot()
            return nil
        }
    }

    func rejectAutomaticAndWait() async -> Int64? {
        guard let coordinator, let callID = snapshot.callID else { return nil }
        do {
            snapshot = try await coordinator.rejectAutomatic()
            return callID
        } catch {
            errorMessage = error.localizedDescription
            snapshot = await coordinator.snapshot()
            // The coordinator fails closed: it detaches the sink, stops audio,
            // and clears its active call before rethrowing. Keep the durable ID
            // so the caller can still erase every partial false-call artifact.
            return callID
        }
    }

    func endAndWait(reason: CallStopReason) async {
        guard let coordinator, (isActive || starting), !ending else { return }
        ending = true
        defer { ending = false }
        if let startTask { await startTask.value }
        guard isActive else { return }
        errorMessage = nil
        do {
            snapshot = try await coordinator.end(reason: reason)
        } catch {
            errorMessage = error.localizedDescription
            snapshot = await coordinator.snapshot()
        }
    }
}
