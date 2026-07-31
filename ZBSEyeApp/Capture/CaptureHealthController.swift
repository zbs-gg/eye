import Foundation

enum CapturePipelineInvalidationReason: Sendable, Equatable {
    case displayChanged
    case wake
    case unlock
    case recovery
}

struct ScreenCaptureRequestToken: Sendable, Equatable {
    let id: UInt64
    let pipelineGeneration: Int64
    let healthGeneration: Int64
}

enum ScreenCaptureRequestResult: Sendable, Equatable {
    case success(fingerprint: String, context: CaptureContext, wasDuplicate: Bool)
    case failure(CaptureHealthReason)
}

enum ScreenCaptureCompletion: Sendable, Equatable {
    case accepted
    case rejectedOldGeneration
    case rejectedUnknownRequest
}

/// Sole owner of capture-health reduction and one-shot request admission.
/// ScreenCaptureKit remains in FramePipeline; this controller owns only
/// generations, single-flight, deadlines, and deterministic health effects.
@MainActor
final class CaptureHealthController {
    private var reducer: CaptureHealthReducer
    private var nextRequestID: UInt64 = 0
    private var inFlight: ScreenCaptureRequestToken?
    private var screenRecoveryAdmission: CaptureRecoveryAttempt?
    private var screenLocked = false
    private var timedOutOwnershipBlocked = false
    private var pendingCoverageOpens: [CaptureLeg: CaptureCoverageOpen] = [:]
    private var emit: @MainActor (CaptureHealthEffect) -> Void
    private var publish: @MainActor (CaptureHealthSnapshot) -> Void = { _ in }

    private(set) var pipelineGeneration: Int64 = 0

    var snapshot: CaptureHealthSnapshot { reducer.snapshot }

    init(
        nowMs: Int64,
        intent: CaptureIntent = .recordingScreenOnly,
        permissions: [CaptureLeg: CapturePermissionState] = [
            .screen: .granted,
            .systemAudio: .granted,
        ],
        openIntervals: [CaptureCoverageInterval] = [],
        emit: @escaping @MainActor (CaptureHealthEffect) -> Void = { _ in }
    ) {
        reducer = CaptureHealthReducer(
            nowMs: nowMs,
            intent: intent,
            permissions: permissions,
            openIntervals: openIntervals
        )
        self.emit = emit
    }

    func beginScreenRequest(nowMs: Int64) -> ScreenCaptureRequestToken? {
        let screenHealth = snapshot.legs[.screen]
        if screenHealth?.state == .recovering {
            guard let admission = screenRecoveryAdmission,
                  isCurrentRecoveryAttempt(admission) else { return nil }
        }
        guard !screenLocked,
              !timedOutOwnershipBlocked,
              pendingCoverageOpens[.screen] == nil,
              inFlight == nil,
              snapshot.intent.screenEnabled,
              snapshot.permissions[.screen] == .granted,
              snapshot.suspension == nil,
              snapshot.legs[.screen]?.state != .repairRequired else { return nil }
        nextRequestID &+= 1
        let token = ScreenCaptureRequestToken(
            id: nextRequestID,
            pipelineGeneration: pipelineGeneration,
            healthGeneration: snapshot.legs[.screen]?.generation ?? 0
        )
        inFlight = token
        return token
    }

    @discardableResult
    func completeScreenRequest(
        _ request: ScreenCaptureRequestToken,
        result: ScreenCaptureRequestResult,
        nowMs: Int64
    ) -> ScreenCaptureCompletion {
        guard inFlight?.id == request.id else { return .rejectedUnknownRequest }
        inFlight = nil
        guard request.pipelineGeneration == pipelineGeneration,
              !timedOutOwnershipBlocked else {
            return .rejectedOldGeneration
        }

        switch result {
        case .success(let fingerprint, let context, let wasDuplicate):
            let observation = CaptureObservation(
                leg: .screen,
                generation: request.healthGeneration,
                kind: wasDuplicate ? .unchanged(.staticDuplicate) : .verifiedProgress,
                fingerprint: fingerprint,
                context: context
            )
            apply(reducer.reduce(.observation(observation), at: nowMs))
        case .failure(let reason):
            reduceFailure(
                leg: .screen,
                generation: request.healthGeneration,
                reason: reason,
                nowMs: nowMs
            )
        }
        return .accepted
    }

    /// Marks a request unsafe to replace. We advance the generation so a late
    /// callback cannot publish health, but keep admission closed even after it
    /// returns until an explicit repair starts a new bounded episode.
    @discardableResult
    func screenRequestDeadlineElapsed(
        _ request: ScreenCaptureRequestToken,
        nowMs: Int64
    ) -> Bool {
        guard inFlight?.id == request.id,
              request.pipelineGeneration == pipelineGeneration else { return false }
        timedOutOwnershipBlocked = true
        pipelineGeneration &+= 1
        reduceFailure(
            leg: .screen,
            generation: request.healthGeneration,
            reason: .screenRequestTimedOut,
            nowMs: nowMs
        )
        return true
    }

    func invalidatePipeline(
        _ reason: CapturePipelineInvalidationReason,
        screenLocked: Bool,
        nowMs: Int64
    ) {
        _ = reason
        self.screenLocked = screenLocked
        screenRecoveryAdmission = nil
        pipelineGeneration &+= 1
        if screenLocked {
            apply(reducer.reduce(.suspensionChanged(.locked), at: nowMs))
        } else if snapshot.suspension == .locked {
            apply(reducer.reduce(.suspensionChanged(nil), at: nowMs))
        }
    }

    func setSuspension(_ reason: CaptureSuspensionReason?, nowMs: Int64) {
        guard snapshot.suspension != reason else { return }
        screenLocked = reason == .locked
        apply(reducer.reduce(.suspensionChanged(reason), at: nowMs))
    }

    func setIntent(_ intent: CaptureIntent, nowMs: Int64) {
        guard snapshot.intent != intent else { return }
        apply(reducer.reduce(.intentChanged(intent), at: nowMs))
    }

    func setPermission(_ permission: CapturePermissionState, for leg: CaptureLeg, nowMs: Int64) {
        guard snapshot.permissions[leg] != permission else { return }
        apply(reducer.reduce(.permissionChanged(leg, permission), at: nowMs))
    }

    func setEffectSink(_ sink: @escaping @MainActor (CaptureHealthEffect) -> Void) {
        emit = sink
    }

    func setSnapshotSink(_ sink: @escaping @MainActor (CaptureHealthSnapshot) -> Void) {
        publish = sink
        publish(snapshot)
    }

    func recordScreenIntentional(_ reason: CaptureHealthReason, nowMs: Int64) {
        let observation = CaptureObservation(
            leg: .screen,
            generation: snapshot.legs[.screen]?.generation ?? 0,
            kind: .intentional(reason),
            fingerprint: nil,
            context: nil
        )
        apply(reducer.reduce(.observation(observation), at: nowMs))
    }

    func coverageDidOpen(_ open: CaptureCoverageOpen, nowMs: Int64) {
        if pendingCoverageOpens[open.leg] == open {
            pendingCoverageOpens[open.leg] = nil
        }
        apply(reducer.reduce(.coverageOpened(open), at: nowMs))
    }

    func coverageOpenPersistenceFailed(_ open: CaptureCoverageOpen, nowMs: Int64) {
        if pendingCoverageOpens[open.leg] == open {
            pendingCoverageOpens[open.leg] = nil
        }
        apply(reducer.reduce(.coverageOpenPersistenceFailed(open), at: nowMs))
    }

    func coverageDidClose(_ close: CaptureCoverageClose, nowMs: Int64) {
        if close.leg == .screen { screenRecoveryAdmission = nil }
        apply(reducer.reduce(.coverageClosed(close), at: nowMs))
    }

    func coverageClosePersistenceFailed(_ close: CaptureCoverageClose, nowMs: Int64) {
        if close.leg == .screen { screenRecoveryAdmission = nil }
        apply(reducer.reduce(.coverageClosePersistenceFailed(close), at: nowMs))
    }

    func recoveryAttemptFailed(
        leg: CaptureLeg,
        generation: Int64,
        reason: CaptureHealthReason,
        nowMs: Int64
    ) {
        if leg == .screen { screenRecoveryAdmission = nil }
        apply(reducer.reduce(
            .recoveryAttemptFailed(leg: leg, generation: generation, reason: reason),
            at: nowMs
        ))
    }

    func isCurrentRecoveryAttempt(_ attempt: CaptureRecoveryAttempt) -> Bool {
        guard let health = snapshot.legs[attempt.leg] else { return false }
        return health.state == .recovering
            && health.generation == attempt.generation
            && health.attempt == attempt.attempt
    }

    /// Opens admission for exactly one request after the adapter has reset its
    /// disposable screenshot state for this controller-approved attempt.
    func markScreenRecoveryReady(_ attempt: CaptureRecoveryAttempt) -> Bool {
        guard attempt.leg == .screen,
              isCurrentRecoveryAttempt(attempt),
              inFlight == nil,
              !timedOutOwnershipBlocked else { return false }
        screenRecoveryAdmission = attempt
        return true
    }

    func screenRecoveryOwnershipUnavailable(
        _ attempt: CaptureRecoveryAttempt,
        nowMs: Int64
    ) {
        guard attempt.leg == .screen,
              timedOutOwnershipBlocked,
              isCurrentRecoveryAttempt(attempt) else { return }
        apply(reducer.reduce(
            .recoveryOwnershipBlocked(
                leg: .screen,
                generation: attempt.generation,
                reason: .screenRequestTimedOut
            ),
            at: nowMs
        ))
    }

    func recordSystemAudioFailure(
        _ reason: CaptureHealthReason = .systemAudioStartFailed,
        nowMs: Int64
    ) {
        let generation = snapshot.legs[.systemAudio]?.generation ?? 0
        reduceFailure(
            leg: .systemAudio,
            generation: generation,
            reason: reason,
            nowMs: nowMs
        )
    }

    func recordSystemAudioProgress(nowMs: Int64) {
        let observation = CaptureObservation(
            leg: .systemAudio,
            generation: snapshot.legs[.systemAudio]?.generation ?? 0,
            kind: .verifiedProgress,
            fingerprint: nil,
            context: nil
        )
        apply(reducer.reduce(.observation(observation), at: nowMs))
    }

    func repairRequested(_ leg: CaptureLeg, nowMs: Int64) {
        if leg == .screen {
            guard inFlight == nil else { return }
            timedOutOwnershipBlocked = false
        }
        apply(reducer.reduce(.repairRequested(leg), at: nowMs))
    }

    func repairRequiresPhysicalDrain(for leg: CaptureLeg) -> Bool {
        reducer.repairRequiresPhysicalDrain(for: leg)
    }

    private func reduceFailure(
        leg: CaptureLeg,
        generation: Int64,
        reason: CaptureHealthReason,
        nowMs: Int64
    ) {
        if let health = snapshot.legs[leg],
           health.state == .recovering,
           health.attempt > 0 {
            apply(reducer.reduce(
                .recoveryAttemptFailed(
                    leg: leg,
                    generation: generation,
                    reason: reason
                ),
                at: nowMs
            ))
            return
        }
        let observation = CaptureObservation(
            leg: leg,
            generation: generation,
            kind: .failed(reason),
            fingerprint: nil,
            context: nil
        )
        apply(reducer.reduce(.observation(observation), at: nowMs))
    }

    private func apply(_ effects: [CaptureHealthEffect]) {
        for effect in effects {
            if case .openCoverage(let open) = effect {
                pendingCoverageOpens[open.leg] = open
            }
        }
        // The reducer does not enter recovering until coverageDidOpen, so
        // permission and intent changes stay publishable while persistence is
        // in flight without exposing an unrecorded uncertainty episode.
        publish(snapshot)
        effects.forEach(emit)
    }

    func permitsSystemAudioStart() -> Bool {
        guard pendingCoverageOpens[.systemAudio] == nil,
              let state = snapshot.legs[.systemAudio]?.state else { return false }
        return state != .recovering && state != .repairRequired
    }
}
