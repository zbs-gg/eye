import Foundation

enum CapturePipelineInvalidationReason: Sendable, Equatable {
    case displayChanged
    case contentTopologyChanged
    case wake
    case unlock
    case suspension
    case recovery
}

/// Sole owner of capture-health reduction. The persistent screen stream owns
/// physical generations; this controller accepts only callbacks from the exact
/// published generation and never infers failure from duplicate pixels.
@MainActor
final class CaptureHealthController {
    private var reducer: CaptureHealthReducer
    private var activeScreenStreamGeneration: Int64?
    private var screenRecoveryAdmission: CaptureRecoveryAttempt?
    private var screenLocked = false
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

    func screenStreamDidStart(generation: Int64, nowMs: Int64) {
        let screenHealth = snapshot.legs[.screen]
        if screenHealth?.state == .recovering {
            guard let admission = screenRecoveryAdmission,
                  isCurrentRecoveryAttempt(admission) else { return }
        }
        guard !screenLocked,
              pendingCoverageOpens[.screen] == nil,
              snapshot.intent.screenEnabled,
              snapshot.permissions[.screen] == .granted,
              snapshot.suspension == nil,
              snapshot.legs[.screen]?.state != .repairRequired else { return }
        activeScreenStreamGeneration = generation
        pipelineGeneration = generation
    }

    func recordScreenStreamFrame(
        _ stamp: ScreenStreamFrameStamp,
        nowMs: Int64
    ) {
        guard stamp.generation == activeScreenStreamGeneration,
              stamp.status.provesLiveness,
              !screenLocked,
              snapshot.suspension == nil else { return }
        let observation = CaptureObservation(
            leg: .screen,
            generation: snapshot.legs[.screen]?.generation ?? 0,
            kind: .verifiedProgress,
            fingerprint: "\(stamp.generation):\(stamp.displayTime)",
            context: nil
        )
        apply(reducer.reduce(.observation(observation), at: nowMs))
    }

    func recordScreenStreamFailure(
        generation: Int64,
        reason: CaptureHealthReason,
        nowMs: Int64
    ) {
        guard activeScreenStreamGeneration == generation else { return }
        activeScreenStreamGeneration = nil
        screenRecoveryAdmission = nil
        reduceFailure(
            leg: .screen,
            generation: snapshot.legs[.screen]?.generation ?? 0,
            reason: reason,
            nowMs: nowMs
        )
    }

    func recordScreenStartFailure(
        _ reason: CaptureHealthReason = .screenStreamStopped,
        nowMs: Int64
    ) {
        guard activeScreenStreamGeneration == nil else { return }
        reduceFailure(
            leg: .screen,
            generation: snapshot.legs[.screen]?.generation ?? 0,
            reason: reason,
            nowMs: nowMs
        )
    }

    /// A controller-owned start/update/stop operation failed after the
    /// pipeline had already revoked frame admission. Retire the previously
    /// published stream before opening the bounded recovery episode.
    func recordScreenPipelineFailure(
        _ reason: CaptureHealthReason = .screenStreamStopped,
        nowMs: Int64
    ) {
        activeScreenStreamGeneration = nil
        screenRecoveryAdmission = nil
        reduceFailure(
            leg: .screen,
            generation: snapshot.legs[.screen]?.generation ?? 0,
            reason: reason,
            nowMs: nowMs
        )
    }

    func invalidatePipeline(
        _ reason: CapturePipelineInvalidationReason,
        screenLocked: Bool,
        nowMs: Int64
    ) {
        _ = reason
        self.screenLocked = screenLocked
        screenRecoveryAdmission = nil
        activeScreenStreamGeneration = nil
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

    /// Opens admission for one controller-approved stream replacement. The
    /// coordinator must drain the prior physical stream before calling this.
    func markScreenRecoveryReady(_ attempt: CaptureRecoveryAttempt) -> Bool {
        guard attempt.leg == .screen,
              isCurrentRecoveryAttempt(attempt),
              activeScreenStreamGeneration == nil else { return false }
        screenRecoveryAdmission = attempt
        return true
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
        if leg == .screen { activeScreenStreamGeneration = nil }
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
