import Foundation

enum AutomaticCallBannerPhase: String, CaseIterable, Sendable, Equatable {
    case started
    case endingGrace = "ending_grace"
    case finalizing
    case saved
    case saveFailed = "save_failed"
}

/// Immutable identity captured when the user opens the per-app exclusion confirmation. Keeping
/// the Call envelope in the target prevents a late detector enrichment or successor Call from
/// applying the confirmation to a different app than the one the user actually saw.
struct AutomaticCallExclusionTarget: Sendable, Equatable {
    let callID: Int64
    let bundleID: String
    let displayName: String
}

struct AutomaticCallBannerState: Sendable, Equatable {
    let phase: AutomaticCallBannerPhase
    let callID: Int64
    let deadline: Date?
    let sourceAppName: String?
    let sourceAppBundleID: String?
    let errorMessage: String?

    init(
        phase: AutomaticCallBannerPhase,
        callID: Int64,
        deadline: Date?,
        sourceAppName: String? = nil,
        sourceAppBundleID: String? = nil,
        errorMessage: String? = nil
    ) {
        self.phase = phase
        self.callID = callID
        self.deadline = deadline
        self.sourceAppName = sourceAppName
        self.sourceAppBundleID = sourceAppBundleID
        self.errorMessage = errorMessage
    }

    var presentation: AutomaticCallBannerPresentation {
        switch phase {
        case .started:
            let source = sourceAppName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceLabel = (source?.isEmpty == false ? source : nil) ?? String(localized: "An app")
            return AutomaticCallBannerPresentation(
                title: String(localized: "Call recording started"),
                detail: String(localized: "\(sourceLabel) is using the microphone."),
                icon: "phone.badge.waveform",
                tone: .positive,
                showsEndAndSave: false,
                rejectActionTitle: String(localized: "This isn’t a call")
            )
        case .endingGrace:
            return AutomaticCallBannerPresentation(
                title: String(localized: "Call ended"),
                detail: String(localized: "Saving to Calls in 30 seconds. You can delete it there later."),
                icon: "timer",
                tone: .warning,
                showsEndAndSave: true,
                rejectActionTitle: String(localized: "This wasn’t a call")
            )
        case .finalizing:
            return AutomaticCallBannerPresentation(
                title: String(localized: "Saving call…"),
                detail: String(localized: "Finishing the recording and saving it to Calls."),
                icon: "arrow.trianglehead.2.clockwise.rotate.90",
                tone: .neutral,
                showsEndAndSave: false,
                rejectActionTitle: nil
            )
        case .saved:
            return AutomaticCallBannerPresentation(
                title: String(localized: "Call saved to Calls"),
                detail: String(localized: "You can open or delete it in ZBS Eye."),
                icon: "checkmark.circle",
                tone: .positive,
                showsEndAndSave: false,
                rejectActionTitle: nil
            )
        case .saveFailed:
            return AutomaticCallBannerPresentation(
                title: String(localized: "Call couldn't be saved"),
                detail: errorMessage
                    ?? String(localized: "The local recording was kept. Open Calls to retry or delete it."),
                icon: "exclamationmark.triangle",
                tone: .error,
                showsEndAndSave: false,
                rejectActionTitle: nil
            )
        }
    }

    /// Synthetic `process:*` identities keep unknown microphone owners recordable, but they are
    /// not bundle identifiers and therefore cannot become a durable user exclusion.
    var neverAutoRecordTarget: AutomaticCallExclusionTarget? {
        guard phase == .started || phase == .endingGrace,
              let bundleID = sourceAppBundleID,
              !bundleID.hasPrefix("process:"),
              !bundleID.hasPrefix("process-pid:")
        else { return nil }
        let trimmedName = sourceAppName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = (trimmedName?.isEmpty == false ? trimmedName : nil) ?? bundleID
        return AutomaticCallExclusionTarget(
            callID: callID,
            bundleID: bundleID,
            displayName: app
        )
    }

    var neverAutoRecordActionTitle: String? {
        neverAutoRecordTarget.map { target in
            String(localized: "Never auto-record \(target.displayName)")
        }
    }

    var visibleActionCount: Int {
        (presentation.showsEndAndSave ? 1 : 0)
            + (presentation.showsReject ? 1 : 0)
            + (neverAutoRecordTarget == nil ? 0 : 1)
    }
}

struct AutomaticCallBannerPresentation: Sendable, Equatable {
    enum Tone: Sendable, Equatable {
        case positive
        case warning
        case neutral
        case error
    }

    let title: String
    let detail: String
    let icon: String
    let tone: Tone
    let showsEndAndSave: Bool
    let rejectActionTitle: String?

    var showsReject: Bool { rejectActionTitle != nil }
    var endAndSaveActionRole: AutomaticCallBannerActionRole? {
        showsEndAndSave ? .primary : nil
    }
    var rejectActionRole: AutomaticCallBannerActionRole? {
        showsReject ? .destructive : nil
    }
}

enum AutomaticCallBannerActionRole: Sendable, Equatable {
    case primary
    case destructive
}

struct AutomaticCallEndCompletionResolution: Sendable, Equatable {
    let effectiveReason: CallStopReason
    let fingerprint: String?

    static func resolve(
        reportedReason: CallStopReason,
        pendingUserFingerprint: String?,
        automaticFingerprint: String?,
        claimedFingerprint: String?
    ) -> AutomaticCallEndCompletionResolution {
        let effectiveReason: CallStopReason = pendingUserFingerprint == nil
            ? reportedReason
            : .user
        let fingerprint = effectiveReason == .user
            ? pendingUserFingerprint ?? automaticFingerprint ?? claimedFingerprint
            : automaticFingerprint ?? claimedFingerprint
        return AutomaticCallEndCompletionResolution(
            effectiveReason: effectiveReason,
            fingerprint: fingerprint
        )
    }
}

enum AutomaticCallTimeoutResumeGate {
    static func allowsResume(
        microphoneActivityResumed: Bool,
        callCanStillPublish: Bool
    ) -> Bool {
        microphoneActivityResumed && callCanStillPublish
    }
}

/// A reducer `.activity` result may mean either fresh microphone activity or a bounded stale HAL
/// read retained only to avoid splitting a live recording. Only the fresh positive edge may cancel
/// the 30-second end grace.
enum AutomaticCallActivityResumeGate {
    static func allowsResume(
        evidenceIsStale: Bool,
        microphoneAudioActive: Bool
    ) -> Bool {
        !evidenceIsStale && microphoneAudioActive
    }
}

/// Re-checks the current exact user exclusion at both sides of the asynchronous Call start. The
/// detector stream may already contain a positive edge collected before Settings changed, while
/// `startAutomatic` and local context persistence are both MainActor reentrancy points.
enum AutomaticCallExclusionBoundary {
    static func blocks(
        sourceBundleID: String?,
        excludedBundleIDs: Set<String>
    ) -> Bool {
        guard let sourceBundleID,
              !sourceBundleID.hasPrefix("process:"),
              !sourceBundleID.hasPrefix("process-pid:")
        else { return false }
        return excludedBundleIDs.contains(sourceBundleID)
    }
}

enum AutomaticCallRejectionGraceRecovery {
    /// A failed privacy-receipt preflight leaves the original grace lifecycle intact. It needs a
    /// replacement only when its timer already expired while rejection temporarily owned the end.
    static func shouldRestartGrace(
        bannerPhase: AutomaticCallBannerPhase?,
        originalTimerExists: Bool
    ) -> Bool {
        bannerPhase == .endingGrace && !originalTimerExists
    }
}

enum AutomaticCallTemporarySuspensionKind: Sendable, Equatable {
    case privacyPause
    case audioDisabled
    case sessionLock
}

struct AutomaticCallTemporarySuspension: Sendable, Equatable {
    let kind: AutomaticCallTemporarySuspensionKind
    let fingerprint: String
}

enum AutomaticCallTemporaryRearmPolicy {
    static func allowsRelease(
        kind: AutomaticCallTemporarySuspensionKind,
        audioIsDisabled: Bool,
        privacyPauseIsActive: Bool,
        sessionLockIsActive: Bool = false
    ) -> Bool {
        _ = kind
        return !audioIsDisabled && !privacyPauseIsActive && !sessionLockIsActive
    }
}

enum AutomaticCallAdmissionBarrierReason: Sendable, Equatable, Hashable {
    case privacyTransition
    case evidenceDeletion
}

enum AutomaticCallDiskAdmissionPolicy {
    static func isClosed(
        guardState: LowDiskGuard.State,
        recordingLowDiskPaused: Bool,
        availableBytes: Int64?,
        pauseBytes: Int64 = DiskReservePolicy.standard.pauseBytes
    ) -> Bool {
        guard guardState == .healthy,
              !recordingLowDiskPaused,
              let availableBytes
        else { return true }
        return availableBytes < pauseBytes
    }
}

struct AutomaticCallAdmissionBarrierLease: Sendable, Equatable, Hashable {
    let reason: AutomaticCallAdmissionBarrierReason
    fileprivate let admissionID: UUID
    fileprivate let token: UInt64
}

/// MainActor-owned counted gate for privacy operations that suspend before their durable boundary
/// is complete. A lease is acquired synchronously before the first `await`, so queued microphone
/// evidence cannot open a new Call inside the operation.
struct AutomaticCallAdmissionBarrier: Sendable, Equatable {
    private let admissionID = UUID()
    private var nextToken: UInt64 = 0
    private var leases: [UInt64: AutomaticCallAdmissionBarrierReason] = [:]

    var isClosed: Bool { !leases.isEmpty }
    var activeLeaseCount: Int { leases.count }

    mutating func acquire(
        _ reason: AutomaticCallAdmissionBarrierReason
    ) -> AutomaticCallAdmissionBarrierLease {
        nextToken &+= 1
        leases[nextToken] = reason
        return AutomaticCallAdmissionBarrierLease(
            reason: reason,
            admissionID: admissionID,
            token: nextToken
        )
    }

    @discardableResult
    mutating func release(_ lease: AutomaticCallAdmissionBarrierLease) -> Bool {
        guard lease.admissionID == admissionID,
              leases[lease.token] == lease.reason
        else { return false }
        leases[lease.token] = nil
        return true
    }
}

enum AutomaticCallRearmAdmissionGate {
    static func isClosed(releaseInProgressFingerprint: String?) -> Bool {
        releaseInProgressFingerprint != nil
    }
}

/// Pure floating-panel geometry, kept outside AppKit so narrow and offset displays can be tested
/// without launching the app. A compact panel reserves height for vertically wrapped actions.
struct AutomaticCallPopupGeometry: Sendable, Equatable {
    static let targetWidth: Double = 980
    static let horizontalMargin: Double = 12
    static let topMargin: Double = 18
    static let wideHeight: Double = 108
    static let expandedWideHeight: Double = 154
    static let compactHeight: Double = 220
    static let compactWidthThreshold: Double = 900

    let x: Double
    let y: Double
    let width: Double
    let height: Double

    static func fit(
        visibleX: Double,
        visibleY: Double,
        visibleWidth: Double,
        visibleHeight: Double,
        actionCount: Int = 0
    ) -> AutomaticCallPopupGeometry {
        let availableWidth = max(1, visibleWidth - horizontalMargin * 2)
        let width = min(targetWidth, availableWidth)
        let desiredHeight: Double
        if width < compactWidthThreshold {
            desiredHeight = compactHeight
        } else {
            // Three actions can force the localized button row under the message even at the
            // target width. Reserve a second row without turning the banner into a 220pt overlay.
            desiredHeight = actionCount >= 3 ? expandedWideHeight : wideHeight
        }
        let availableHeight = max(1, visibleHeight - topMargin * 2)
        let height = min(desiredHeight, availableHeight)
        return AutomaticCallPopupGeometry(
            x: visibleX + max(0, (visibleWidth - width) / 2),
            y: visibleY + max(0, visibleHeight - height - topMargin),
            width: width,
            height: height
        )
    }
}

/// Serializes a successor microphone owner behind the Call Envelope that is still finalizing.
/// The detector candidate is released and re-probed once after the old owner has actually cleared;
/// otherwise policy would remain `.active(successor)` while AppEnvironment still owns the old Call.
struct AutomaticCallSuccessorProbeGate: Sendable, Equatable {
    private(set) var hasDeferredSuccessor = false

    mutating func deferIfDifferentOwnerStillActive(
        activeFingerprint: String?,
        candidateFingerprint: String
    ) -> Bool {
        guard let activeFingerprint,
              activeFingerprint != candidateFingerprint
        else { return false }
        hasDeferredSuccessor = true
        return true
    }

    mutating func consumeReprobeIfOwnerCleared(activeFingerprint: String?) -> Bool {
        guard activeFingerprint == nil, hasDeferredSuccessor else { return false }
        hasDeferredSuccessor = false
        return true
    }
}

/// Synchronous owner of the automatic Call end transition. AppEnvironment still owns the clock
/// task and persistence; this value prevents a timeout, button click, and returning microphone
/// event from becoming competing terminal owners.
struct AutomaticCallEndLifecycle: Sendable, Equatable {
    struct Identity: Sendable, Equatable {
        let callID: Int64
        let fingerprint: String
    }

    enum FinishIntent: Sendable, Equatable {
        case automaticTimeout
        case userSave
        case externalUserEnd
    }

    enum Phase: Sendable, Equatable {
        case idle
        case recording(Identity)
        case grace(Identity, deadline: Date)
        case finalizing(Identity, intent: FinishIntent)
        case saved(callID: Int64)
        case failed(Identity)
    }

    private(set) var phase: Phase = .idle

    @discardableResult
    mutating func didStart(callID: Int64, fingerprint: String) -> Bool {
        let identity = Identity(callID: callID, fingerprint: fingerprint)
        switch phase {
        case .idle, .saved, .failed:
            phase = .recording(identity)
            return true
        case .recording(let current) where current == identity:
            return true
        case .recording, .grace, .finalizing:
            return false
        }
    }

    /// Duplicate end evidence returns the original deadline and never extends the grace window.
    mutating func beginGrace(
        callID: Int64,
        fingerprint: String,
        now: Date,
        duration: TimeInterval = 30
    ) -> Date? {
        let identity = Identity(callID: callID, fingerprint: fingerprint)
        switch phase {
        case .recording(identity):
            let deadline = now.addingTimeInterval(duration)
            phase = .grace(identity, deadline: deadline)
            return deadline
        case .grace(identity, let deadline):
            return deadline
        case .idle, .recording, .grace, .finalizing, .saved, .failed:
            return nil
        }
    }

    /// Returning microphone activity resumes the same envelope only before finalization is owned.
    @discardableResult
    mutating func resume(callID: Int64, fingerprint: String) -> Bool {
        let identity = Identity(callID: callID, fingerprint: fingerprint)
        switch phase {
        case .recording(identity):
            return true
        case .grace(identity, _):
            phase = .recording(identity)
            return true
        case .idle, .recording, .grace, .finalizing, .saved, .failed:
            return false
        }
    }

    func isRecording(callID: Int64, fingerprint: String) -> Bool {
        let identity = Identity(callID: callID, fingerprint: fingerprint)
        guard case .recording(identity) = phase else { return false }
        return true
    }

    /// Exactly one caller can claim finalization. `allowWhileRecording` is used only for explicit
    /// user actions such as Call Control or a confirmed per-app exclusion.
    mutating func claimFinish(
        callID: Int64,
        fingerprint: String,
        intent: FinishIntent,
        allowWhileRecording: Bool
    ) -> Bool {
        let identity = Identity(callID: callID, fingerprint: fingerprint)
        switch phase {
        case .grace(identity, _):
            phase = .finalizing(identity, intent: intent)
            return true
        case .recording(identity) where allowWhileRecording:
            phase = .finalizing(identity, intent: intent)
            return true
        case .idle, .recording, .grace, .finalizing, .saved, .failed:
            return false
        }
    }

    /// A timeout may race a CoreAudio edge that proves the microphone resumed before teardown.
    /// Only the automatic timeout is reversible; an explicit user save remains terminal.
    @discardableResult
    mutating func cancelAutomaticTimeoutForActivity(
        callID: Int64,
        fingerprint: String
    ) -> Bool {
        let identity = Identity(callID: callID, fingerprint: fingerprint)
        guard case .finalizing(identity, .automaticTimeout) = phase else { return false }
        phase = .recording(identity)
        return true
    }

    @discardableResult
    mutating func complete(
        callID: Int64,
        fingerprint: String,
        succeeded: Bool
    ) -> Bool {
        let identity = Identity(callID: callID, fingerprint: fingerprint)
        guard case .finalizing(identity, _) = phase else { return false }
        phase = succeeded ? .saved(callID: callID) : .failed(identity)
        return true
    }

    @discardableResult
    mutating func dismissSaved(callID: Int64) -> Bool {
        guard case .saved(callID) = phase else { return false }
        phase = .idle
        return true
    }

    mutating func reset() {
        phase = .idle
    }
}

/// A durable false-call receipt permits the stopped Call envelope to release immediately while
/// physical erasure retries in the background. Pending erasure blocks data-root mutation/quit, but
/// deliberately never blocks admission of the next microphone-owned Call.
struct AutomaticCallRejectedEraseGate: Sendable, Equatable {
    private(set) var pendingCallIDs: Set<Int64> = []

    var allowsAutomaticCallAdmission: Bool { true }
    var allowsDataRootMutation: Bool { pendingCallIDs.isEmpty }

    mutating func enqueue(callID: Int64) {
        pendingCallIDs.insert(callID)
    }

    mutating func finish(callID: Int64) {
        pendingCallIDs.remove(callID)
    }
}
