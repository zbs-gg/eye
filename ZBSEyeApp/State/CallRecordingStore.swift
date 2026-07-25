import Foundation
import Observation

enum AutomaticCallStartResult: Sendable {
    case started(CallCoordinatorSnapshot)
    /// A temporary application-level admission barrier refused this attempt. The detector must
    /// release, not suppress, the same surface so it can qualify again after the barrier opens.
    case admissionClosed
    case failed
    /// A terminal privacy/maintenance/user end joined this exact start. The lifecycle owner must
    /// wait for `onEndCompleted` to release/suppress detector state after physical teardown.
    case interruptedByEnd

    var snapshot: CallCoordinatorSnapshot? {
        guard case let .started(snapshot) = self else { return nil }
        return snapshot
    }
}

struct AutomaticCallRejectionRequest: Sendable {
    let callID: Int64
    fileprivate let task: Task<SealedCallEndDisposition?, Never>
}

struct AutomaticCallUndoRequest: Sendable {
    let callID: Int64
    fileprivate let generation: UInt64
    fileprivate let task: Task<CallCoordinatorSnapshot?, Never>
}

@MainActor
@Observable
final class CallRecordingStore {
    private struct TerminationRequest {
        let task: Task<SealedCallEndDisposition?, Never>
        let accepted: Bool
    }

    private(set) var snapshot = CallCoordinatorSnapshot.idle
    private(set) var errorMessage: String?
    @ObservationIgnored private var coordinator: CallCoordinator?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var startGeneration: UInt64 = 0
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var automaticStartAdmissionClosedGeneration: UInt64?
    @ObservationIgnored private var endJoinedStartGeneration: UInt64?
    @ObservationIgnored private var ending = false
    @ObservationIgnored private var endTask: Task<SealedCallEndDisposition?, Never>?
    @ObservationIgnored private var pendingEndDisposition: SealedCallEndDisposition?
    @ObservationIgnored private var endJoinOpen = false
    @ObservationIgnored private var terminationCallID: Int64?
    @ObservationIgnored private var endCompletionRequested = false
    @ObservationIgnored private var automaticUndoGeneration: UInt64 = 0
    @ObservationIgnored private var automaticUndoTask: Task<CallCoordinatorSnapshot?, Never>?
    @ObservationIgnored private var automaticUndoCallID: Int64?
    @ObservationIgnored var requestedSources: @MainActor () -> CallSourceSelection = { .none }
    @ObservationIgnored var admissionAllowed: @MainActor () -> Bool = { true }
    @ObservationIgnored var onManualStartWhileActive: @MainActor (Int64) -> Void = { _ in }
    @ObservationIgnored var onUserEndRequested: @MainActor () -> Void = {}
    @ObservationIgnored var onEndCompleted: @MainActor (CallStopReason, Bool) -> Void = { _, _ in }

    var isActive: Bool {
        switch snapshot.phase {
        case .starting, .recording, .recoveryTail, .finalizing: true
        case .idle, .pendingTranscription, .ready, .readyDegraded, .failed: false
        }
    }

    var canScheduleAutomaticEnd: Bool {
        snapshot.phase == .recoveryTail
            && !ending
            && automaticUndoTask == nil
    }

    func attach(_ coordinator: CallCoordinator) {
        self.coordinator = coordinator
    }

    func setExternalError(_ message: String?) {
        errorMessage = message
    }

    /// The lifecycle owner must re-check this after every await before publishing an automatic
    /// recording as active. Privacy/maintenance can join and end the in-flight start while the
    /// caller is suspended on persistence.
    func canPublishAutomaticStart(callID: Int64) -> Bool {
        !ending
            && !starting
            && snapshot.phase == .recording
            && snapshot.callID == callID
    }

    func canPublishAutomaticResume(callID: Int64) -> Bool {
        canPublishAutomaticStart(callID: callID)
            && automaticUndoTask == nil
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

    func startAutomatic(idempotencyKey: String) async -> AutomaticCallStartResult {
        guard let coordinator, !isActive, !starting, !ending else {
            return .failed
        }
        guard admissionAllowed() else { return .admissionClosed }
        let requested = requestedSources()
        guard !requested.isEmpty else { return .failed }
        errorMessage = nil
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
        automaticStartAdmissionClosedGeneration = nil
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
                    self.automaticStartAdmissionClosedGeneration = generation
                    self.snapshot = await coordinator.snapshot()
                    return
                }
                self.snapshot = try await coordinator.start(
                    request: requested,
                    idempotencyKey: idempotencyKey
                )
            } catch {
                self.errorMessage = error.localizedDescription
                self.snapshot = await coordinator.snapshot()
            }
        }
        startTask = task
        await task.value

        if endJoinedStartGeneration == generation || ending {
            return .interruptedByEnd
        }
        if automaticStartAdmissionClosedGeneration == generation {
            automaticStartAdmissionClosedGeneration = nil
            return .admissionClosed
        }
        guard startGeneration == generation,
              !ending,
              isActive,
              snapshot.phase == .recording,
              snapshot.callID != nil
        else {
            return .failed
        }
        return .started(snapshot)
    }

    func bookmark() {
        guard let coordinator, !ending else { return }
        errorMessage = nil
        Task {
            guard !ending else { return }
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
        guard isActive || starting else { return }
        guard let request = requestTermination(.finish(.user)),
              request.accepted
        else { return }
        onUserEndRequested()
    }

    /// Claims the recovery tail synchronously, before either the detector or the Undo button
    /// performs an await. An accepted claim closes admission for the 15-second automatic commit.
    /// Terminal user/privacy/maintenance/rejection requests may still invalidate this claim.
    func requestAutomaticUndo() -> AutomaticCallUndoRequest? {
        if let automaticUndoTask,
           let callID = automaticUndoCallID,
           !ending,
           snapshot.phase == .recoveryTail {
            return AutomaticCallUndoRequest(
                callID: callID,
                generation: automaticUndoGeneration,
                task: automaticUndoTask
            )
        }
        guard let coordinator,
              !ending,
              snapshot.phase == .recoveryTail,
              let callID = snapshot.callID
        else { return nil }

        automaticUndoGeneration &+= 1
        let generation = automaticUndoGeneration
        let task = Task<CallCoordinatorSnapshot?, Never> { @MainActor [weak self] in
            guard let self,
                  self.automaticUndoGeneration == generation,
                  !self.ending,
                  !Task.isCancelled
            else { return nil }
            defer {
                if self.automaticUndoGeneration == generation {
                    self.automaticUndoTask = nil
                    self.automaticUndoCallID = nil
                }
            }
            do {
                let undone = try await coordinator.undoSoftEnd()
                guard self.automaticUndoGeneration == generation,
                      !self.ending,
                      !Task.isCancelled,
                      undone.phase == .recording,
                      undone.callID == callID
                else { return nil }
                self.snapshot = undone
                return undone
            } catch {
                guard self.automaticUndoGeneration == generation,
                      !self.ending,
                      !Task.isCancelled
                else { return nil }
                self.errorMessage = error.localizedDescription
                let latest = await coordinator.snapshot()
                guard self.automaticUndoGeneration == generation,
                      !self.ending,
                      !Task.isCancelled
                else { return nil }
                self.snapshot = latest
                return nil
            }
        }
        automaticUndoTask = task
        automaticUndoCallID = callID
        return AutomaticCallUndoRequest(
            callID: callID,
            generation: generation,
            task: task
        )
    }

    func undoAutomaticEndAndWait(
        request suppliedRequest: AutomaticCallUndoRequest? = nil
    ) async -> CallCoordinatorSnapshot? {
        let request: AutomaticCallUndoRequest
        if let suppliedRequest {
            request = suppliedRequest
        } else {
            guard let created = requestAutomaticUndo() else { return nil }
            request = created
        }
        guard request.generation == automaticUndoGeneration else { return nil }
        return await request.task.value
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
        guard snapshot.phase == .recoveryTail,
              automaticUndoTask == nil
        else { return nil }
        guard let request = requestTermination(
            .finish(.automatic),
            notifyCompletion: false
        ) else { return nil }
        _ = await request.task.value
        return snapshot
    }

    /// A false-call rejection is accepted only before physical teardown starts. Its asynchronous
    /// preflight keeps the join window open while the durable privacy receipt is fsync'd off
    /// MainActor; later terminal requests become a fallback if that receipt cannot be persisted.
    func automaticRejectionCandidateCallID() -> Int64? {
        guard endTask == nil else { return nil }
        guard coordinator != nil, isActive || starting else { return nil }
        return snapshot.callID ?? terminationCallID
    }

    func requestAutomaticRejection(
        preflight: @escaping @MainActor @Sendable () async -> Bool
    ) -> AutomaticCallRejectionRequest? {
        guard let callID = snapshot.callID ?? terminationCallID else { return nil }
        guard let request = requestTermination(
            .rejectAutomatic,
            notifyCompletion: false,
            preflight: preflight
        ), request.accepted else { return nil }
        return AutomaticCallRejectionRequest(callID: callID, task: request.task)
    }

    func rejectAutomaticAndWait(
        request: AutomaticCallRejectionRequest
    ) async -> Int64? {
        let disposition = await request.task.value
        return disposition == .rejectAutomatic ? request.callID : nil
    }

    func endAndWait(reason: CallStopReason) async {
        guard let request = requestTermination(.finish(reason)) else { return }
        _ = await request.task.value
    }

    @discardableResult
    private func requestTermination(
        _ requested: SealedCallEndDisposition,
        notifyCompletion: Bool = true,
        preflight: (@MainActor @Sendable () async -> Bool)? = nil
    ) -> TerminationRequest? {
        switch requested {
        case .finish(.automatic):
            guard automaticUndoTask == nil else { return nil }
        case .finish, .rejectAutomatic:
            invalidateAutomaticUndo()
        }
        if let endTask {
            guard preflight == nil else {
                return TerminationRequest(task: endTask, accepted: false)
            }
            if endJoinOpen {
                pendingEndDisposition =
                    pendingEndDisposition?.merged(with: requested) ?? requested
                endCompletionRequested = endCompletionRequested || notifyCompletion
                return TerminationRequest(task: endTask, accepted: true)
            }
            return TerminationRequest(task: endTask, accepted: false)
        }
        guard let coordinator, (isActive || starting) else { return nil }
        ending = true
        endJoinOpen = true
        pendingEndDisposition = preflight == nil ? requested : nil
        endCompletionRequested = notifyCompletion
        terminationCallID = snapshot.callID
        endJoinedStartGeneration = startGeneration
        let task = Task<SealedCallEndDisposition?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            var sealedDisposition: SealedCallEndDisposition?
            defer {
                self.ending = false
                self.endJoinOpen = false
                self.endTask = nil
                self.pendingEndDisposition = nil
                self.terminationCallID = nil
                let notifyCompletion = self.endCompletionRequested
                self.endCompletionRequested = false
                if notifyCompletion,
                   case let .finish(reason) = sealedDisposition {
                    self.onEndCompleted(reason, !self.isActive && !self.starting)
                }
            }
            if let startTask = self.startTask { await startTask.value }
            if let preflight {
                let preflightSucceeded = await preflight()
                if preflightSucceeded {
                    self.pendingEndDisposition =
                        self.pendingEndDisposition?.merged(with: requested) ?? requested
                } else if self.pendingEndDisposition == nil {
                    self.endJoinOpen = false
                    return nil
                }
            }
            guard self.isActive else {
                sealedDisposition = self.pendingEndDisposition ?? requested
                self.endJoinOpen = false
                return sealedDisposition
            }
            self.errorMessage = nil
            do {
                let initialReason = self.pendingEndDisposition?.stopReason
                    ?? requested.stopReason
                let prepared = try await coordinator.prepareEnd(initialReason: initialReason)

                // This is the only seal. It happens synchronously on MainActor after every request
                // accepted during physical teardown, and before the DB/outbox transaction exists.
                sealedDisposition = self.pendingEndDisposition ?? requested
                self.endJoinOpen = false
                self.snapshot = prepared.finalizingSnapshot(
                    disposition: sealedDisposition ?? requested
                )
                self.snapshot = try await coordinator.commitPreparedEnd(
                    prepared,
                    disposition: sealedDisposition ?? requested
                )
            } catch {
                self.errorMessage = error.localizedDescription
                self.snapshot = await coordinator.snapshot()
                if sealedDisposition == nil {
                    sealedDisposition = self.pendingEndDisposition ?? requested
                    self.endJoinOpen = false
                }
            }
            return sealedDisposition
        }
        endTask = task
        return TerminationRequest(task: task, accepted: true)
    }

    private func invalidateAutomaticUndo() {
        guard automaticUndoTask != nil else { return }
        automaticUndoGeneration &+= 1
        automaticUndoTask?.cancel()
        automaticUndoTask = nil
        automaticUndoCallID = nil
    }
}
