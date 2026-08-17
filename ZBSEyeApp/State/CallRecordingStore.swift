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
    fileprivate let task: Task<CallTerminationOutcome, Never>
}

fileprivate struct CallTerminationOutcome: Sendable {
    let callID: Int64?
    let disposition: SealedCallEndDisposition?
    let snapshot: CallCoordinatorSnapshot
}

@MainActor
@Observable
final class CallRecordingStore {
    private struct TerminationRequest {
        let task: Task<CallTerminationOutcome, Never>
        let accepted: Bool
    }

    private(set) var snapshot = CallCoordinatorSnapshot.idle
    private(set) var errorMessage: String?
    @ObservationIgnored private var coordinator: CallCoordinator?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var startGeneration: UInt64 = 0
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var automaticStartAdmissionClosedGeneration: UInt64?
    @ObservationIgnored private var automaticStartAdmissionGeneration: UInt64 = 0
    @ObservationIgnored private var endJoinedStartGeneration: UInt64?
    @ObservationIgnored private var ending = false
    @ObservationIgnored private var endTask: Task<CallTerminationOutcome, Never>?
    @ObservationIgnored private var pendingEndDisposition: SealedCallEndDisposition?
    @ObservationIgnored private var endJoinOpen = false
    @ObservationIgnored private var terminationCallID: Int64?
    @ObservationIgnored private var endCompletionRequested = false
    @ObservationIgnored private var endIntentPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var endIntentPreparationGeneration: UInt64 = 0
    @ObservationIgnored private var nativeScreenshotGeneration: UInt64 = 0
    @ObservationIgnored private var nativeScreenshotTask: Task<Void, Never>?
    @ObservationIgnored private var desiredRecordingMode: CallRecordingMode?
    @ObservationIgnored private var recordingModeTask: Task<Void, Never>?
    @ObservationIgnored var requestedSources: @MainActor () -> CallSourceSelection = { .none }
    /// AppEnvironment uses the explicit one-Call mode here so manual Start can
    /// record while the persisted default remains Don't record.
    @ObservationIgnored var requestedSourcesForMode:
        (@MainActor (CallRecordingMode) -> CallSourceSelection)?
    @ObservationIgnored var requestedMode: @MainActor () -> CallRecordingMode = { .audio }
    @ObservationIgnored var admissionAllowed: @MainActor () -> Bool = { true }
    @ObservationIgnored var automaticStartAdmissionAllowed: @MainActor () -> Bool = { true }
    @ObservationIgnored var onManualStartWhileActive: @MainActor (Int64) -> Void = { _ in }
    @ObservationIgnored var onUserEndRequested: @MainActor () -> Void = {}
    @ObservationIgnored var onEndWillPrepare:
        @MainActor @Sendable (CallStopReason) async -> Void = { _ in }
    @ObservationIgnored var onEndCompleted: @MainActor (CallStopReason, Bool) -> Void = { _, _ in }
    @ObservationIgnored var waitForNativeScreenshotRelease:
        @MainActor @Sendable () async -> Void = {}

    var isActive: Bool {
        switch snapshot.phase {
        case .starting, .recording, .finalizing: true
        case .idle, .pendingTranscription, .ready, .readyDegraded, .failed: false
        }
    }

    private var hasDurablyFinishedCurrentCall: Bool {
        Self.isDurablyFinished(snapshot)
    }

    private static func isDurablyFinished(_ snapshot: CallCoordinatorSnapshot) -> Bool {
        switch snapshot.phase {
        case .pendingTranscription, .ready, .readyDegraded:
            true
        case .idle, .starting, .recording, .finalizing, .failed:
            false
        }
    }

    func attach(_ coordinator: CallCoordinator) {
        self.coordinator = coordinator
    }

    func publishAdoptedSnapshot(_ snapshot: CallCoordinatorSnapshot) {
        guard snapshot.phase == .recording, snapshot.callID != nil else { return }
        self.snapshot = snapshot
        starting = false
        ending = false
        terminationCallID = nil
    }

    func setExternalError(_ message: String?) {
        errorMessage = message
    }

    /// Latches only closing automatic-admission edges across asynchronous audio startup. A gate
    /// that closes and reopens while physical audio startup is suspended must still release and
    /// re-probe the original detector owner. Opening or unrelated configuration changes must not
    /// fragment a healthy in-flight start.
    func automaticStartAdmissionChanged(isClosed: Bool) {
        guard isClosed else { return }
        automaticStartAdmissionGeneration &+= 1
    }

    /// Final synchronous validation used by AppEnvironment immediately before it admits the
    /// prepared Call sink. This closes the pre-install ABA window that the later post-start check
    /// can detect but cannot prevent from briefly opening physical audio.
    func permitsCallAudioStart(_ lease: CallAudioStartAdmissionLease) -> Bool {
        lease.isScoped
            && starting
            && !ending
            && lease.startGeneration == startGeneration
            && lease.lifecycleGeneration == automaticStartAdmissionGeneration
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
    }

    func start(mode explicitMode: CallRecordingMode? = nil) {
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
        let mode = explicitMode ?? requestedMode()
        guard mode != .off else {
            errorMessage = "Choose Audio only or Audio and video for this Call."
            return
        }
        let requested = requestedSourcesForMode?(mode) ?? requestedSources()
        starting = true
        snapshot = CallCoordinatorSnapshot(
            phase: .starting,
            callID: nil,
            me: requested.me ? .unavailable : .disabled,
            system: requested.system ? .unavailable : .disabled,
            bookmarkCount: 0,
            stopReason: nil,
            recordingMode: mode,
            video: mode.recordsVideo ? .starting : .disabled
        )
        startGeneration &+= 1
        let generation = startGeneration
        let startAdmissionLease = CallAudioStartAdmissionLease(
            startGeneration: generation,
            lifecycleGeneration: automaticStartAdmissionGeneration,
            isScoped: true
        )
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
                self.snapshot = try await coordinator.start(
                    request: requested,
                    recordingMode: mode,
                    startAdmissionLease: startAdmissionLease
                )
            } catch {
                await self.drainEndIntentPreparations()
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
        guard admissionAllowed(), automaticStartAdmissionAllowed() else {
            return .admissionClosed
        }
        let mode = requestedMode()
        guard mode != .off else { return .failed }
        let requested = requestedSourcesForMode?(mode) ?? requestedSources()
        guard !requested.isEmpty else {
            return automaticStartAdmissionAllowed() ? .failed : .admissionClosed
        }
        errorMessage = nil
        starting = true
        snapshot = CallCoordinatorSnapshot(
            phase: .starting,
            callID: nil,
            me: requested.me ? .unavailable : .disabled,
            system: requested.system ? .unavailable : .disabled,
            bookmarkCount: 0,
            stopReason: nil,
            recordingMode: mode,
            video: mode.recordsVideo ? .starting : .disabled
        )
        startGeneration &+= 1
        let generation = startGeneration
        let admissionGeneration = automaticStartAdmissionGeneration
        let startAdmissionLease = CallAudioStartAdmissionLease(
            startGeneration: generation,
            lifecycleGeneration: admissionGeneration,
            isScoped: true
        )
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
                guard self.automaticStartAdmissionGeneration == admissionGeneration,
                      self.admissionAllowed(),
                      self.automaticStartAdmissionAllowed() else {
                    self.automaticStartAdmissionClosedGeneration = generation
                    self.snapshot = await coordinator.snapshot()
                    return
                }
                self.snapshot = try await coordinator.start(
                    request: requested,
                    recordingMode: mode,
                    idempotencyKey: idempotencyKey,
                    startAdmissionLease: startAdmissionLease
                )
                if self.automaticStartAdmissionGeneration != admissionGeneration
                    || !self.automaticStartAdmissionAllowed() {
                    self.automaticStartAdmissionClosedGeneration = generation
                }
            } catch {
                await self.drainEndIntentPreparations()
                if self.automaticStartAdmissionGeneration != admissionGeneration
                    || !self.admissionAllowed()
                    || !self.automaticStartAdmissionAllowed() {
                    self.automaticStartAdmissionClosedGeneration = generation
                }
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
            if isActive {
                // Permission/audio admission closed after a physical source managed to start.
                // Finish that tiny local envelope before the detector releases this owner.
                await endAndWait(reason: .privacy)
            }
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

    /// Changes only the replaceable video leg. Audio remains owned by the
    /// existing Call. `off` is a terminal user save, not a silent discard.
    func setRecordingMode(_ mode: CallRecordingMode) {
        guard isActive || starting else { return }
        if mode == .off {
            desiredRecordingMode = nil
            recordingModeTask?.cancel()
            end()
            return
        }
        guard let coordinator else { return }
        desiredRecordingMode = mode
        guard recordingModeTask == nil else { return }
        recordingModeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.recordingModeTask = nil }
            while !Task.isCancelled,
                  self.isActive || self.starting,
                  let desired = self.desiredRecordingMode {
                if desired == .off { break }
                if self.starting, let startTask = self.startTask {
                    // Settings can change while physical audio is still
                    // starting even though the in-card picker is disabled.
                    // Join that exact start before queuing a replaceable-video
                    // command, then reconcile the still-latest selection.
                    await startTask.value
                    continue
                }
                do {
                    let applied = try await coordinator.setRecordingMode(desired)
                    if self.desiredRecordingMode == desired {
                        self.snapshot = applied
                        self.desiredRecordingMode = nil
                        break
                    }
                    // A newer selection arrived while the replaceable video
                    // leg was changing. Publish only authoritative coordinator
                    // state, then loop so the latest user choice is applied last.
                    self.snapshot = await coordinator.snapshot()
                } catch {
                    self.errorMessage = error.localizedDescription
                    self.snapshot = await coordinator.snapshot()
                    if !self.isActive, !self.starting {
                        self.desiredRecordingMode = nil
                        break
                    }
                    if self.desiredRecordingMode == desired {
                        self.desiredRecordingMode = nil
                        break
                    }
                }
            }
        }
    }

    /// Test/teardown joins only the replaceable video reconciliation. It never
    /// waits for or changes Call audio.
    func waitForRecordingModeReconciliation() async {
        while let task = recordingModeTask {
            await task.value
        }
    }

    func nativeScreenshotRequested() {
        guard let coordinator, snapshot.recordingMode.recordsVideo else { return }
        coordinator.requestImmediateVideoYieldForNativeScreenshot()
        nativeScreenshotGeneration &+= 1
        guard nativeScreenshotTask == nil else { return }
        nativeScreenshotTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let generation = self.nativeScreenshotGeneration
                let callID = self.snapshot.callID
                self.snapshot = await coordinator.yieldVideoForNativeScreenshot()
                await self.waitForNativeScreenshotRelease()
                guard !Task.isCancelled else { break }
                // A later hotkey/process edge extended the physical quiet
                // window. Join it before video is allowed to restart.
                guard generation == self.nativeScreenshotGeneration else { continue }
                if let callID {
                    self.snapshot = await coordinator.resumeVideoAfterNativeScreenshot(
                        callID: callID
                    )
                }
                guard generation == self.nativeScreenshotGeneration else { continue }
                break
            }
            self.nativeScreenshotTask = nil
        }
    }

    func videoStateChangedExternally(_ state: CallVideoState) {
        guard let coordinator else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await coordinator.videoStateChangedExternally(state)
            self.snapshot = await coordinator.snapshot()
        }
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

    /// Directly finishes an automatically-owned recording. The 30-second grace is managed by the
    /// lifecycle owner while this store and the coordinator remain in `.recording`, so no separate
    /// tail or undo transition exists.
    func finishAutomaticAndWait(reason: CallStopReason) async -> CallCoordinatorSnapshot? {
        guard reason == .automatic || reason == .user else { return nil }
        let expectedCallID = snapshot.callID ?? terminationCallID
        guard let request = requestTermination(
            .finish(reason),
            notifyCompletion: false
        ) else { return nil }
        if !request.accepted {
            // Physical audio teardown may already be sealed by Call Control, Audio Off, privacy,
            // or another lifecycle owner. The automatic banner must observe that same durable end
            // instead of falsely reporting a save failure, but it must never claim a later Call.
            guard let expectedCallID,
                  terminationCallID == expectedCallID
            else { return nil }
            let outcome = await request.task.value
            guard outcome.callID == expectedCallID,
                  Self.isDurablyFinished(outcome.snapshot)
            else { return nil }
            return outcome.snapshot
        }
        let outcome = await request.task.value
        return outcome.snapshot
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
        let outcome = await request.task.value
        return outcome.disposition == .rejectAutomatic ? request.callID : nil
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
        if let endTask {
            guard preflight == nil else {
                return TerminationRequest(task: endTask, accepted: false)
            }
            if endJoinOpen {
                pendingEndDisposition =
                    pendingEndDisposition?.merged(with: requested) ?? requested
                endCompletionRequested = endCompletionRequested || notifyCompletion
                enqueueEndIntentPreparation(for: requested)
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
        enqueueEndIntentPreparation(for: requested)
        let task = Task<CallTerminationOutcome, Never> { @MainActor [weak self] in
            guard let self else {
                return CallTerminationOutcome(
                    callID: nil,
                    disposition: nil,
                    snapshot: .idle
                )
            }
            var completedCallID = self.terminationCallID ?? self.snapshot.callID
            var sealedDisposition: SealedCallEndDisposition?
            defer {
                self.ending = false
                self.endJoinOpen = false
                self.endTask = nil
                self.pendingEndDisposition = nil
                self.terminationCallID = nil
                self.endIntentPreparationTask = nil
                let notifyCompletion = self.endCompletionRequested
                self.endCompletionRequested = false
                if notifyCompletion,
                   case let .finish(reason) = sealedDisposition {
                    self.onEndCompleted(reason, self.hasDurablyFinishedCurrentCall)
                }
            }
            if let startTask = self.startTask { await startTask.value }
            completedCallID = self.snapshot.callID ?? completedCallID
            if let preflight {
                let preflightSucceeded = await preflight()
                if preflightSucceeded {
                    self.pendingEndDisposition =
                        self.pendingEndDisposition?.merged(with: requested) ?? requested
                } else if self.pendingEndDisposition == nil {
                    self.endJoinOpen = false
                    return CallTerminationOutcome(
                        callID: completedCallID,
                        disposition: nil,
                        snapshot: self.snapshot
                    )
                }
            }
            guard self.isActive else {
                sealedDisposition = self.pendingEndDisposition ?? requested
                self.endJoinOpen = false
                return CallTerminationOutcome(
                    callID: completedCallID,
                    disposition: sealedDisposition,
                    snapshot: self.snapshot
                )
            }
            self.errorMessage = nil
            do {
                await self.drainEndIntentPreparations()
                let initialReason = self.pendingEndDisposition?.stopReason ?? requested.stopReason
                let prepared = try await coordinator.prepareEnd(initialReason: initialReason)
                // A stronger user/privacy intent can join while physical audio/spool teardown is
                // suspended. Its detector boundary must finish before this shared end seals.
                await self.drainEndIntentPreparations()

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
                // `prepareEnd` can fail after a stronger terminal intent joined while it was
                // suspended. Finish that intent's detector/privacy boundary before publishing the
                // shared failure outcome; otherwise its accepted hook would be silently dropped.
                await self.drainEndIntentPreparations()
                self.errorMessage = error.localizedDescription
                self.snapshot = await coordinator.snapshot()
                if sealedDisposition == nil {
                    sealedDisposition = self.pendingEndDisposition ?? requested
                    self.endJoinOpen = false
                }
            }
            return CallTerminationOutcome(
                callID: completedCallID,
                disposition: sealedDisposition,
                snapshot: self.snapshot
            )
        }
        endTask = task
        return TerminationRequest(task: task, accepted: true)
    }

    private func enqueueEndIntentPreparation(for disposition: SealedCallEndDisposition) {
        guard case let .finish(reason) = disposition else { return }
        let predecessor = endIntentPreparationTask
        let callback = onEndWillPrepare
        endIntentPreparationGeneration &+= 1
        endIntentPreparationTask = Task { @MainActor in
            if let predecessor { await predecessor.value }
            await callback(reason)
        }
    }

    private func drainEndIntentPreparations() async {
        while let task = endIntentPreparationTask {
            let generation = endIntentPreparationGeneration
            await task.value
            guard generation != endIntentPreparationGeneration else { return }
        }
    }

}
