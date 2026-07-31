import Foundation

enum CaptureLeg: String, Codable, Sendable, Hashable, CaseIterable {
    case screen
    case systemAudio
}

enum CaptureAggregateState: String, Codable, Sendable, Equatable {
    case healthy
    case recovering
    case repairRequired
    case permissionBlocked
    case suspended
    case paused
}

enum CaptureLegState: String, Codable, Sendable, Equatable {
    case healthy
    case recovering
    case repairRequired
    case permissionBlocked
    case suspended
    case paused
}

enum CapturePermissionState: String, Codable, Sendable, Equatable {
    case unknown
    case granted
    case denied
}

enum CaptureSuspensionReason: String, Codable, Sendable, Equatable {
    case locked
    case sleeping
    case maintenance
    case lowDisk
    case privacy
    case userPaused
}

enum CaptureHealthReason: String, Codable, Sendable, Equatable {
    case awaitingVerifiedProgress
    case staticDuplicate
    case userIdle
    case privacyExcluded
    case selfAppExcluded
    case systemAudioDisabled
    case permissionMissing
    case screenProgressUnverified
    case screenRequestFailed
    case screenRequestTimedOut
    case systemAudioStartFailed
    case systemAudioStartExhausted
    case verifiedProgress
}

struct CaptureIntent: Codable, Sendable, Equatable {
    var screenEnabled: Bool
    var systemAudioEnabled: Bool

    static let recordingScreenOnly = CaptureIntent(
        screenEnabled: true,
        systemAudioEnabled: false
    )
}

struct CaptureContext: Codable, Sendable, Equatable {
    var displayID: String?
    var frontmostBundleID: String?
    var focusedWindowID: String?
    var axRevision: Int64?
    var inputRevision: Int64?
}

enum CaptureObservationKind: Sendable, Equatable {
    case verifiedProgress
    case unchanged(CaptureHealthReason)
    case intentional(CaptureHealthReason)
    case failed(CaptureHealthReason)
}

struct CaptureObservation: Sendable, Equatable {
    var leg: CaptureLeg
    var generation: Int64
    var kind: CaptureObservationKind
    var fingerprint: String?
    var context: CaptureContext?
}

struct CaptureLegHealth: Codable, Sendable, Equatable {
    var state: CaptureLegState
    var reason: CaptureHealthReason
    var generation: Int64
    var attempt: Int
    var stateSinceMs: Int64
    var lastCycleAtMs: Int64?
    var lastVerifiedProgressAtMs: Int64?
}

extension CaptureLegHealth {
    var needsExplicitRepair: Bool {
        state == .repairRequired || (state == .recovering && attempt == 0)
    }
}

struct CaptureHealthSnapshot: Codable, Sendable, Equatable {
    var intent: CaptureIntent
    var permissions: [CaptureLeg: CapturePermissionState]
    var suspension: CaptureSuspensionReason?
    var legs: [CaptureLeg: CaptureLegHealth]
    var aggregate: CaptureAggregateState
}

extension CaptureHealthSnapshot {
    func isRequested(_ leg: CaptureLeg) -> Bool {
        switch leg {
        case .screen: intent.screenEnabled
        case .systemAudio: intent.systemAudioEnabled
        }
    }

    var requestedLegs: [CaptureLeg] {
        CaptureLeg.allCases.filter(isRequested)
    }

    var repairableLegs: [CaptureLeg] {
        requestedLegs.filter { legs[$0]?.needsExplicitRepair == true }
    }
}

struct CaptureCoverageOpen: Sendable, Equatable {
    var leg: CaptureLeg
    var reason: CaptureHealthReason
    var episodeID: String
    var generation: Int64
    var startMs: Int64
}

enum CaptureCoverageCloseCause: String, Codable, Sendable, Equatable {
    case verifiedProgress
    case manualStop
    case privacyPause
    case locked
    case sleeping
    case lowDisk
    case relocation
    case permissionDenied
    case appExit
    case historyDeleted
}

struct CaptureCoverageClose: Sendable, Equatable {
    var leg: CaptureLeg
    var episodeID: String
    var generation: Int64
    var endMs: Int64
    var cause: CaptureCoverageCloseCause
}

struct CaptureCoverageInterval: Codable, Sendable, Equatable {
    var id: Int64
    var leg: CaptureLeg
    var reason: CaptureHealthReason
    var episodeID: String
    var generation: Int64
    var startMs: Int64
    var endMs: Int64?
    var closeCause: CaptureCoverageCloseCause?
}

enum CaptureCoverageRead: Sendable, Equatable {
    case metadataUnavailable
    case available([CaptureCoverageInterval])
}

struct CaptureRecoveryAttempt: Sendable, Equatable {
    var leg: CaptureLeg
    var generation: Int64
    var attempt: Int
    var delayMs: Int64
}

enum CaptureHealthEffect: Sendable, Equatable {
    case openCoverage(CaptureCoverageOpen)
    case attemptRecovery(CaptureRecoveryAttempt)
    case closeCoverage(CaptureCoverageClose)
}

enum CaptureHealthEvent: Sendable, Equatable {
    case intentChanged(CaptureIntent)
    case permissionChanged(CaptureLeg, CapturePermissionState)
    case suspensionChanged(CaptureSuspensionReason?)
    case observation(CaptureObservation)
    case coverageOpened(CaptureCoverageOpen)
    case coverageOpenPersistenceFailed(CaptureCoverageOpen)
    case recoveryAttemptFailed(leg: CaptureLeg, generation: Int64, reason: CaptureHealthReason)
    case recoveryOwnershipBlocked(leg: CaptureLeg, generation: Int64, reason: CaptureHealthReason)
    case coverageClosed(CaptureCoverageClose)
    case coverageClosePersistenceFailed(CaptureCoverageClose)
    case repairRequested(CaptureLeg)
}

/// Pure state machine for capture truth. Runtime owners execute returned effects;
/// the reducer itself performs no I/O, permission requests, or process control.
struct CaptureHealthReducer: Sendable, Equatable {
    struct Configuration: Sendable, Equatable {
        var staleObservationCount = 3
        var retryDelaysMs: [Int64] = [0, 1_000, 3_000]
    }

    private enum RecoveryOrigin: Sendable, Equatable {
        case failure
        case staleSuccess(contradictedFingerprint: String?)
    }

    private enum CoveragePersistenceFailure: Sendable, Equatable {
        case open
        case close
    }

    private struct Episode: Sendable, Equatable {
        var open: CaptureCoverageOpen
        var origin: RecoveryOrigin
        var persisted = false
        var pendingClose: CaptureCoverageClose?
        var persistenceFailure: CoveragePersistenceFailure?
    }

    private struct StaleSuspicion: Sendable, Equatable {
        var firstAtMs: Int64
        var count: Int
        var context: CaptureContext
        var fingerprint: String?
    }

    private(set) var snapshot: CaptureHealthSnapshot
    private let configuration: Configuration
    private var lastContext: [CaptureLeg: CaptureContext] = [:]
    private var staleSuspicions: [CaptureLeg: StaleSuspicion] = [:]
    private var episodes: [CaptureLeg: Episode] = [:]

    init(
        nowMs: Int64,
        intent: CaptureIntent = .recordingScreenOnly,
        permissions: [CaptureLeg: CapturePermissionState] = [
            .screen: .granted,
            .systemAudio: .granted,
        ],
        openIntervals: [CaptureCoverageInterval] = [],
        configuration: Configuration = .init()
    ) {
        self.configuration = configuration
        let screenPermission = permissions[.screen] ?? .unknown
        let audioPermission = permissions[.systemAudio] ?? .unknown
        let screen = CaptureLegHealth(
            state: !intent.screenEnabled ? .paused
                : (screenPermission == .granted ? .healthy : .permissionBlocked),
            reason: !intent.screenEnabled ? .userIdle
                : (screenPermission == .granted ? .awaitingVerifiedProgress : .permissionMissing),
            generation: 0,
            attempt: 0,
            stateSinceMs: nowMs,
            lastCycleAtMs: nil,
            lastVerifiedProgressAtMs: nil
        )
        let audio = CaptureLegHealth(
            state: !intent.systemAudioEnabled ? .paused
                : (audioPermission == .granted ? .healthy : .permissionBlocked),
            reason: !intent.systemAudioEnabled ? .systemAudioDisabled
                : (audioPermission == .granted ? .awaitingVerifiedProgress : .permissionMissing),
            generation: 0,
            attempt: 0,
            stateSinceMs: nowMs,
            lastCycleAtMs: nil,
            lastVerifiedProgressAtMs: nil
        )
        snapshot = CaptureHealthSnapshot(
            intent: intent,
            permissions: permissions,
            suspension: nil,
            legs: [.screen: screen, .systemAudio: audio],
            aggregate: .healthy
        )
        for interval in openIntervals where interval.endMs == nil {
            let open = CaptureCoverageOpen(
                leg: interval.leg,
                reason: interval.reason,
                episodeID: interval.episodeID,
                generation: interval.generation,
                startMs: interval.startMs
            )
            let origin: RecoveryOrigin = interval.reason == .screenProgressUnverified
                ? .staleSuccess(contradictedFingerprint: nil)
                : .failure
            episodes[interval.leg] = Episode(
                open: open,
                origin: origin,
                persisted: true
            )
            if var health = snapshot.legs[interval.leg] {
                health.generation = max(health.generation, interval.generation)
                if snapshot.isRequested(interval.leg),
                   snapshot.permissions[interval.leg] == .granted {
                    health.state = .recovering
                    health.reason = interval.reason
                    health.stateSinceMs = interval.startMs
                }
                snapshot.legs[interval.leg] = health
            }
        }
        recomputeAggregate()
    }

    mutating func reduce(_ event: CaptureHealthEvent, at nowMs: Int64) -> [CaptureHealthEffect] {
        let effects: [CaptureHealthEffect]
        switch event {
        case .intentChanged(let intent):
            snapshot.intent = intent
            effects = CaptureLeg.allCases.compactMap { leg in
                updateIntent(for: leg, at: nowMs)
            }
        case .permissionChanged(let leg, let permission):
            snapshot.permissions[leg] = permission
            effects = updatePermission(permission, for: leg, at: nowMs)
        case .suspensionChanged(let reason):
            snapshot.suspension = reason
            effects = updateSuspension(reason, at: nowMs)
        case .observation(let observation):
            effects = consume(observation, at: nowMs)
        case .coverageOpened(let open):
            effects = acknowledgeOpen(open, at: nowMs)
        case .coverageOpenPersistenceFailed(let open):
            effects = failCoverageOpenPersistence(open, at: nowMs)
        case .recoveryAttemptFailed(let leg, let generation, let reason):
            effects = failAttempt(leg: leg, generation: generation, reason: reason, at: nowMs)
        case .recoveryOwnershipBlocked(let leg, let generation, let reason):
            effects = blockRecovery(leg: leg, generation: generation, reason: reason, at: nowMs)
        case .coverageClosed(let close):
            effects = acknowledgeClose(close, at: nowMs)
        case .coverageClosePersistenceFailed(let close):
            effects = failCoverageClosePersistence(close, at: nowMs)
        case .repairRequested(let leg):
            effects = beginUserRetry(for: leg, at: nowMs)
        }
        recomputeAggregate()
        return effects
    }

    private mutating func consume(_ observation: CaptureObservation, at nowMs: Int64) -> [CaptureHealthEffect] {
        guard var leg = snapshot.legs[observation.leg] else { return [] }
        leg.lastCycleAtMs = nowMs
        snapshot.legs[observation.leg] = leg

        switch observation.kind {
        case .intentional(let reason):
            staleSuspicions[observation.leg] = nil
            setReason(reason, for: observation.leg)
            return []

        case .failed(let reason):
            guard observation.generation == leg.generation,
                  episodes[observation.leg] == nil,
                  isRequested(observation.leg),
                  snapshot.suspension == nil,
                  snapshot.permissions[observation.leg] == .granted else { return [] }
            return openEpisode(
                leg: observation.leg,
                reason: reason,
                origin: .failure,
                startMs: nowMs
            )

        case .unchanged(let reason):
            setReason(reason, for: observation.leg)
            guard observation.leg == .screen,
                  observation.generation == leg.generation,
                  episodes[.screen] == nil,
                  let context = observation.context,
                  contextContradictsBaseline(context, for: .screen) else {
                staleSuspicions[observation.leg] = nil
                return []
            }

            let suspicion: StaleSuspicion
            if var existing = staleSuspicions[.screen], existing.context == context {
                existing.count += 1
                suspicion = existing
            } else {
                suspicion = StaleSuspicion(
                    firstAtMs: nowMs,
                    count: 1,
                    context: context,
                    fingerprint: observation.fingerprint
                )
            }
            staleSuspicions[.screen] = suspicion
            guard suspicion.count >= configuration.staleObservationCount else { return [] }
            staleSuspicions[.screen] = nil
            return openEpisode(
                leg: .screen,
                reason: .screenProgressUnverified,
                origin: .staleSuccess(contradictedFingerprint: suspicion.fingerprint),
                startMs: suspicion.firstAtMs
            )

        case .verifiedProgress:
            if var episode = episodes[observation.leg] {
                guard observation.generation == episode.open.generation,
                      episode.persisted,
                      episode.pendingClose == nil else { return [] }
                let proved: Bool
                switch episode.origin {
                case .failure:
                    proved = observation.leg == .systemAudio
                        || observation.fingerprint != nil
                case .staleSuccess(let contradictedFingerprint):
                    proved = observation.fingerprint != nil
                        && observation.fingerprint != contradictedFingerprint
                }
                guard proved else {
                    return failAttempt(
                        leg: observation.leg,
                        generation: observation.generation,
                        reason: episode.open.reason,
                        at: nowMs
                    )
                }
                if let context = observation.context {
                    lastContext[observation.leg] = context
                }
                let close = CaptureCoverageClose(
                    leg: observation.leg,
                    episodeID: episode.open.episodeID,
                    generation: episode.open.generation,
                    endMs: nowMs,
                    cause: .verifiedProgress
                )
                episode.pendingClose = close
                episodes[observation.leg] = episode
                return [.closeCoverage(close)]
            }

            guard observation.generation == leg.generation else { return [] }
            if let context = observation.context {
                lastContext[observation.leg] = context
            }
            staleSuspicions[observation.leg] = nil
            leg.state = .healthy
            leg.reason = .verifiedProgress
            leg.stateSinceMs = nowMs
            leg.lastVerifiedProgressAtMs = nowMs
            leg.attempt = 0
            snapshot.legs[observation.leg] = leg
            return []
        }
    }

    private mutating func openEpisode(
        leg: CaptureLeg,
        reason: CaptureHealthReason,
        origin: RecoveryOrigin,
        startMs: Int64
    ) -> [CaptureHealthEffect] {
        guard var health = snapshot.legs[leg], episodes[leg] == nil else { return [] }
        health.generation += 1
        health.attempt = 0
        snapshot.legs[leg] = health
        let open = CaptureCoverageOpen(
            leg: leg,
            reason: reason,
            episodeID: "\(leg.rawValue)-\(health.generation)-\(startMs)",
            generation: health.generation,
            startMs: startMs
        )
        episodes[leg] = Episode(open: open, origin: origin)
        return [.openCoverage(open)]
    }

    private mutating func acknowledgeOpen(_ open: CaptureCoverageOpen, at nowMs: Int64) -> [CaptureHealthEffect] {
        guard var episode = episodes[open.leg], episode.open == open,
              !episode.persisted, var health = snapshot.legs[open.leg] else { return [] }
        episode.persisted = true
        episode.persistenceFailure = nil
        episodes[open.leg] = episode

        if !isRequested(open.leg) {
            health.state = .paused
            health.reason = pausedReason(for: open.leg)
            health.stateSinceMs = nowMs
            snapshot.legs[open.leg] = health
            return intentionalCloseEffect(
                for: open.leg,
                at: nowMs,
                cause: .manualStop
            ).map { [$0] } ?? []
        }
        if snapshot.permissions[open.leg] != .granted {
            health.state = .permissionBlocked
            health.reason = .permissionMissing
            health.stateSinceMs = nowMs
            snapshot.legs[open.leg] = health
            return intentionalCloseEffect(
                for: open.leg,
                at: nowMs,
                cause: .permissionDenied
            ).map { [$0] } ?? []
        }
        if let suspension = snapshot.suspension {
            health.state = .suspended
            health.reason = suspensionHealthReason(suspension)
            health.stateSinceMs = nowMs
            snapshot.legs[open.leg] = health
            return suspensionCloseCause(suspension).flatMap {
                intentionalCloseEffect(for: open.leg, at: nowMs, cause: $0)
            }.map { [$0] } ?? []
        }

        health.attempt = 1
        health.state = .recovering
        health.reason = open.reason
        health.stateSinceMs = nowMs
        snapshot.legs[open.leg] = health
        return [.attemptRecovery(.init(
            leg: open.leg,
            generation: open.generation,
            attempt: 1,
            delayMs: configuration.retryDelaysMs.first ?? 0
        ))]
    }

    private mutating func failAttempt(
        leg: CaptureLeg,
        generation: Int64,
        reason: CaptureHealthReason,
        at nowMs: Int64
    ) -> [CaptureHealthEffect] {
        guard let episode = episodes[leg], episode.persisted,
              episode.open.generation == generation,
              var health = snapshot.legs[leg],
              health.state == .recovering else { return [] }
        health.reason = reason
        let nextAttempt = health.attempt + 1
        if nextAttempt <= configuration.retryDelaysMs.count {
            health.attempt = nextAttempt
            health.stateSinceMs = nowMs
            snapshot.legs[leg] = health
            return [.attemptRecovery(.init(
                leg: leg,
                generation: generation,
                attempt: nextAttempt,
                delayMs: configuration.retryDelaysMs[nextAttempt - 1]
            ))]
        }
        health.state = .repairRequired
        health.stateSinceMs = nowMs
        snapshot.legs[leg] = health
        return []
    }

    private mutating func blockRecovery(
        leg: CaptureLeg,
        generation: Int64,
        reason: CaptureHealthReason,
        at nowMs: Int64
    ) -> [CaptureHealthEffect] {
        guard let episode = episodes[leg], episode.persisted,
              episode.open.generation == generation,
              var health = snapshot.legs[leg],
              health.state == .recovering else { return [] }
        health.state = .repairRequired
        health.reason = reason
        health.attempt = 0
        health.stateSinceMs = nowMs
        snapshot.legs[leg] = health
        return []
    }

    private mutating func failCoverageOpenPersistence(
        _ open: CaptureCoverageOpen,
        at nowMs: Int64
    ) -> [CaptureHealthEffect] {
        guard var episode = episodes[open.leg], episode.open == open,
              !episode.persisted, var health = snapshot.legs[open.leg] else { return [] }
        episode.persistenceFailure = .open
        episodes[open.leg] = episode
        projectPersistenceFailure(
            for: open.leg,
            episode: episode,
            health: &health,
            at: nowMs
        )
        snapshot.legs[open.leg] = health
        return []
    }

    private mutating func failCoverageClosePersistence(
        _ close: CaptureCoverageClose,
        at nowMs: Int64
    ) -> [CaptureHealthEffect] {
        guard var episode = episodes[close.leg], episode.persisted,
              episode.pendingClose == close,
              var health = snapshot.legs[close.leg] else { return [] }
        episode.persistenceFailure = .close
        episodes[close.leg] = episode
        projectPersistenceFailure(
            for: close.leg,
            episode: episode,
            health: &health,
            at: nowMs
        )
        snapshot.legs[close.leg] = health
        return []
    }

    private func projectPersistenceFailure(
        for leg: CaptureLeg,
        episode: Episode,
        health: inout CaptureLegHealth,
        at nowMs: Int64
    ) {
        if !isRequested(leg) {
            health.state = .paused
            health.reason = pausedReason(for: leg)
        } else if snapshot.permissions[leg] != .granted {
            health.state = .permissionBlocked
            health.reason = .permissionMissing
        } else if let suspension = snapshot.suspension {
            health.state = .suspended
            health.reason = suspensionHealthReason(suspension)
        } else {
            health.state = .repairRequired
            health.reason = episode.open.reason
        }
        health.attempt = 0
        health.stateSinceMs = nowMs
    }

    private func persistenceRetryEffect(for episode: Episode) -> CaptureHealthEffect? {
        switch episode.persistenceFailure {
        case .open:
            .openCoverage(episode.open)
        case .close:
            episode.pendingClose.map(CaptureHealthEffect.closeCoverage)
        case nil:
            nil
        }
    }

    private mutating func acknowledgeClose(_ close: CaptureCoverageClose, at nowMs: Int64) -> [CaptureHealthEffect] {
        guard let episode = episodes[close.leg],
              episode.persisted,
              episode.pendingClose == close,
              episode.open.episodeID == close.episodeID,
              episode.open.generation == close.generation,
              var health = snapshot.legs[close.leg] else { return [] }
        episodes[close.leg] = nil
        if !isRequested(close.leg) {
            health.state = .paused
            health.reason = pausedReason(for: close.leg)
        } else if snapshot.permissions[close.leg] != .granted {
            health.state = .permissionBlocked
            health.reason = .permissionMissing
        } else if let suspension = snapshot.suspension {
            health.state = .suspended
            health.reason = suspensionHealthReason(suspension)
        } else if close.cause == .verifiedProgress {
            health.state = .healthy
            health.reason = .verifiedProgress
        } else {
            health.state = .healthy
            health.reason = .awaitingVerifiedProgress
        }
        health.stateSinceMs = nowMs
        if close.cause == .verifiedProgress {
            health.lastVerifiedProgressAtMs = close.endMs
        }
        health.attempt = 0
        snapshot.legs[close.leg] = health
        return []
    }

    private mutating func beginUserRetry(for leg: CaptureLeg, at nowMs: Int64) -> [CaptureHealthEffect] {
        guard let episode = episodes[leg],
              var health = snapshot.legs[leg],
              health.state == .repairRequired || (health.state == .recovering && health.attempt == 0)
        else { return [] }
        if !episode.persisted {
            return [.openCoverage(episode.open)]
        }
        if let pendingClose = episode.pendingClose {
            return [.closeCoverage(pendingClose)]
        }
        health.state = .recovering
        health.attempt = 1
        health.stateSinceMs = nowMs
        snapshot.legs[leg] = health
        return [.attemptRecovery(.init(
            leg: leg,
            generation: episode.open.generation,
            attempt: 1,
            delayMs: 0
        ))]
    }

    private mutating func updateIntent(for leg: CaptureLeg, at nowMs: Int64) -> CaptureHealthEffect? {
        guard var health = snapshot.legs[leg] else { return nil }
        if !isRequested(leg) {
            health.state = .paused
            health.reason = pausedReason(for: leg)
            health.stateSinceMs = nowMs
            staleSuspicions[leg] = nil
            snapshot.legs[leg] = health
            return intentionalCloseEffect(for: leg, at: nowMs, cause: .manualStop)
        }
        if snapshot.permissions[leg] != .granted {
            health.state = .permissionBlocked
            health.reason = .permissionMissing
        } else if snapshot.suspension != nil {
            health.state = .suspended
        } else if let episode = episodes[leg] {
            if episode.persistenceFailure != nil {
                health.state = .recovering
                health.attempt = 0
            } else {
                health.state = .recovering
            }
            health.reason = episode.open.reason
        } else {
            health.state = .healthy
            health.reason = .awaitingVerifiedProgress
        }
        health.stateSinceMs = nowMs
        snapshot.legs[leg] = health
        guard snapshot.permissions[leg] == .granted,
              snapshot.suspension == nil else { return nil }
        return episodes[leg].flatMap(persistenceRetryEffect)
    }

    private mutating func updatePermission(
        _ permission: CapturePermissionState,
        for leg: CaptureLeg,
        at nowMs: Int64
    ) -> [CaptureHealthEffect] {
        guard var health = snapshot.legs[leg] else { return [] }
        if permission != .granted, isRequested(leg) {
            health.state = .permissionBlocked
            health.reason = .permissionMissing
            health.stateSinceMs = nowMs
            snapshot.legs[leg] = health
            return intentionalCloseEffect(for: leg, at: nowMs, cause: .permissionDenied).map { [$0] } ?? []
        }
        return updateIntent(for: leg, at: nowMs).map { [$0] } ?? []
    }

    private mutating func updateSuspension(
        _ reason: CaptureSuspensionReason?,
        at nowMs: Int64
    ) -> [CaptureHealthEffect] {
        guard let reason else {
            var effects: [CaptureHealthEffect] = []
            for leg in CaptureLeg.allCases where isRequested(leg) {
                if let effect = updateIntent(for: leg, at: nowMs) {
                    effects.append(effect)
                }
            }
            return effects
        }
        var effects: [CaptureHealthEffect] = []
        for leg in CaptureLeg.allCases where isRequested(leg) {
            guard var health = snapshot.legs[leg] else { continue }
            health.state = .suspended
            health.reason = suspensionHealthReason(reason)
            health.stateSinceMs = nowMs
            snapshot.legs[leg] = health
            staleSuspicions[leg] = nil
            if let cause = suspensionCloseCause(reason),
               let effect = intentionalCloseEffect(for: leg, at: nowMs, cause: cause) {
                effects.append(effect)
            }
        }
        return effects
    }

    private mutating func intentionalCloseEffect(
        for leg: CaptureLeg,
        at nowMs: Int64,
        cause: CaptureCoverageCloseCause
    ) -> CaptureHealthEffect? {
        guard var episode = episodes[leg], episode.persisted,
              episode.pendingClose == nil else { return nil }
        let close = CaptureCoverageClose(
            leg: leg,
            episodeID: episode.open.episodeID,
            generation: episode.open.generation,
            endMs: nowMs,
            cause: cause
        )
        episode.pendingClose = close
        episodes[leg] = episode
        return .closeCoverage(close)
    }

    private func contextContradictsBaseline(_ context: CaptureContext, for leg: CaptureLeg) -> Bool {
        guard let baseline = lastContext[leg] else { return false }
        let strong = differs(context.displayID, baseline.displayID)
            || differs(context.frontmostBundleID, baseline.frontmostBundleID)
            || differs(context.focusedWindowID, baseline.focusedWindowID)
        let pairedWeak = differs(context.axRevision, baseline.axRevision)
            && differs(context.inputRevision, baseline.inputRevision)
        return strong || pairedWeak
    }

    private func differs<T: Equatable>(_ lhs: T?, _ rhs: T?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs != rhs
    }

    private func isRequested(_ leg: CaptureLeg) -> Bool {
        snapshot.isRequested(leg)
    }

    func repairRequiresPhysicalDrain(for leg: CaptureLeg) -> Bool {
        episodes[leg]?.pendingClose == nil
    }

    private func pausedReason(for leg: CaptureLeg) -> CaptureHealthReason {
        leg == .systemAudio ? .systemAudioDisabled : .userIdle
    }

    private func suspensionHealthReason(_ reason: CaptureSuspensionReason) -> CaptureHealthReason {
        switch reason {
        case .privacy: .privacyExcluded
        default: .awaitingVerifiedProgress
        }
    }

    private func suspensionCloseCause(_ reason: CaptureSuspensionReason) -> CaptureCoverageCloseCause? {
        switch reason {
        case .locked: .locked
        case .sleeping: .sleeping
        case .lowDisk: .lowDisk
        case .privacy: .privacyPause
        case .maintenance: .relocation
        case .userPaused: .manualStop
        }
    }

    private mutating func setReason(_ reason: CaptureHealthReason, for leg: CaptureLeg) {
        guard var health = snapshot.legs[leg] else { return }
        health.reason = reason
        snapshot.legs[leg] = health
    }

    private mutating func recomputeAggregate() {
        let requested = snapshot.requestedLegs
        if let suspension = snapshot.suspension, !requested.isEmpty {
            _ = suspension
            snapshot.aggregate = .suspended
            return
        }
        let states = requested.compactMap { snapshot.legs[$0]?.state }
        if states.contains(.repairRequired) {
            snapshot.aggregate = .repairRequired
        } else if states.contains(.recovering) {
            snapshot.aggregate = .recovering
        } else if states.contains(.permissionBlocked) {
            snapshot.aggregate = .permissionBlocked
        } else if states.isEmpty || states.allSatisfy({ $0 == .paused }) {
            snapshot.aggregate = .paused
        } else if states.contains(.suspended) {
            snapshot.aggregate = .suspended
        } else {
            snapshot.aggregate = .healthy
        }
    }
}
