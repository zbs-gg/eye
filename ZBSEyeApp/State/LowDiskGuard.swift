import Foundation

/// Hysteretic capture admission. It has no deletion action by design: low disk can only pause or resume capture.
struct LowDiskGuard: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case unknown
        case healthy
        case paused
    }

    enum Action: Sendable, Equatable, Hashable, CaseIterable {
        case none
        case pauseCapture
        case resumeCapture
    }

    let policy: DiskReservePolicy
    private(set) var state: State = .unknown

    init(policy: DiskReservePolicy = .standard) {
        self.policy = policy
    }

    mutating func evaluate(availableBytes: Int64?) -> Action {
        let available = max(0, availableBytes ?? 0)
        switch state {
        case .unknown:
            if available < policy.pauseBytes {
                state = .paused
                return .pauseCapture
            }
            state = .healthy
            return .none
        case .healthy:
            guard available < policy.pauseBytes else { return .none }
            state = .paused
            return .pauseCapture
        case .paused:
            guard available >= policy.recoveryBytes else { return .none }
            state = .healthy
            return .resumeCapture
        }
    }

    /// A physical stop that was not confirmed must stay fail-closed. The next
    /// healthy sample will retry the resume transition and its final drain.
    mutating func holdPaused() {
        state = .paused
    }
}

enum LowDiskDrainGate {
    nonisolated static func isConfirmedStopped(
        _ drain: RecordingMaintenanceDrain
    ) -> Bool {
        drain.capture.activeCycles == 0
            && drain.audio.activeLegs == 0
            && drain.audio.systemCaptureOutcome.isConfirmedStopped
    }
}
