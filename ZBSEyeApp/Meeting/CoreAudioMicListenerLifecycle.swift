import Foundation

/// Pure lifecycle plan for the Core Audio microphone-activity listener.
///
/// Core Audio registration itself stays in `MeetingDetector`, but the ordering is deliberately
/// expressed here so the subscribe-then-read boundary can be verified without touching HAL or TCC.
struct CoreAudioMicListenerLifecyclePolicy {
    enum Event: Equatable, Sendable {
        case start
        case inputActivity
        case processListChanged
        case serviceRestarted
        case systemWake
        case stop
    }

    enum Effect: Equatable, Sendable {
        case wakePoll
        case forgetRegistrations
        case installSystemListeners
        case reconcileProcessListeners
        case removeAllListeners
    }

    struct ProcessListenerPlan: Equatable, Sendable {
        let remove: [UInt32]
        let add: [UInt32]
    }

    static func effects(for event: Event) -> [Effect] {
        switch event {
        case .start:
            // Read only after the system and current per-process listeners are installed. This
            // closes the window where input could become active between discovery and subscribe.
            return [
                .installSystemListeners,
                .reconcileProcessListeners,
                .wakePoll,
            ]
        case .inputActivity:
            return [.wakePoll]
        case .processListChanged:
            // The first wake observes the process-list edge promptly. The second happens after
            // listeners for newly discovered processes are installed.
            return [
                .wakePoll,
                .reconcileProcessListeners,
                .wakePoll,
            ]
        case .serviceRestarted:
            // HAL discarded the old registrations, so cached registration state is no longer
            // authoritative. Do not remove stale handles; forget and rebuild them instead.
            return [
                .wakePoll,
                .forgetRegistrations,
                .installSystemListeners,
                .reconcileProcessListeners,
                .wakePoll,
            ]
        case .systemWake:
            // Wake notifications do not guarantee a service-restarted edge. Replace the known
            // registrations and then re-read, making sleep/wake self-healing in either case.
            return [
                .removeAllListeners,
                .installSystemListeners,
                .reconcileProcessListeners,
                .wakePoll,
            ]
        case .stop:
            return [.removeAllListeners]
        }
    }

    static func event(
        forPropertySelectors selectors: Set<UInt32>,
        runningInputSelector: UInt32,
        processListSelector: UInt32,
        serviceRestartedSelector: UInt32
    ) -> Event? {
        if selectors.contains(serviceRestartedSelector) {
            return .serviceRestarted
        }
        if selectors.contains(processListSelector) {
            return .processListChanged
        }
        if selectors.contains(runningInputSelector) {
            return .inputActivity
        }
        return nil
    }

    static func processListenerPlan(
        current: Set<UInt32>,
        registered: Set<UInt32>
    ) -> ProcessListenerPlan {
        ProcessListenerPlan(
            remove: registered.subtracting(current).sorted(),
            add: current.subtracting(registered).sorted()
        )
    }
}

enum CoreAudioMicTimeoutRecheckPolicy {
    /// The 30-second save timer is cancelled only by a fresh positive HAL result. A timeout,
    /// coreaudiod restart, or other unknown read cannot claim that microphone activity resumed.
    static func confirmsMicrophoneResume(
        collectionSucceeded: Bool,
        activeOwnerCount: Int
    ) -> Bool {
        collectionSucceeded && activeOwnerCount > 0
    }
}

enum CoreAudioMicEvidenceAuthorityPolicy {
    /// A partial process-object read may contain trustworthy positive microphone owners, but it
    /// cannot advance any negative/idle suppression boundary for objects that failed to answer.
    static func permitsNegativeSuppressionMutation(
        collectionSucceeded: Bool,
        inputStateAuthoritative: Bool
    ) -> Bool {
        collectionSucceeded && inputStateAuthoritative
    }

    /// Native/browser tombstones use a two-sided input+output boundary. They may advance only
    /// when every active HAL object supplied both running states and an identity; otherwise an
    /// output-only route during a service restart could be mistaken for proven full silence.
    static func permitsFullAudioSuppressionMutation(
        collectionSucceeded: Bool,
        fullAudioStateAuthoritative: Bool
    ) -> Bool {
        collectionSucceeded && fullAudioStateAuthoritative
    }

    /// Positive samples remain actionable; only a partial snapshot with no visible positive owner
    /// must be published as stale instead of global idle.
    static func requiresStaleSnapshot(
        inputStateAuthoritative: Bool,
        unsuppressedPositiveOwnerCount: Int
    ) -> Bool {
        !inputStateAuthoritative && unsuppressedPositiveOwnerCount == 0
    }
}
