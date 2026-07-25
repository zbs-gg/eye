import Foundation

enum CallAudioApplicationKind: String, Hashable, Sendable {
    case native
    case browser
}

struct CallAudioProcessAncestor: Equatable, Sendable {
    let pid: Int32
    let bundleID: String?
    let executableName: String?
}

struct CallAudioApplicationIdentity: Equatable, Sendable {
    let rootPID: Int32
    let bundleID: String
    let kind: CallAudioApplicationKind
}

enum CallAudioOwnerResolution {
    private static let excludedExecutableNames: Set<String> = [
        "replayd",
        "coreaudiod",
        "audiomxd",
        "avconferenced",
        "assistantd",
        "siriactionsd",
        "speechsynthesisd",
        "voicetriggerd",
        "voiceover",
    ]

    /// Resolve a helper-to-root ancestry captured child-first.
    ///
    /// Chromium helpers frequently expose their own bundle identifier, so stopping at the first
    /// bundle would misclassify Dia as Arc. Only an exact qualified browser root is accepted.
    static func resolve(
        ancestors: [CallAudioProcessAncestor],
        currentProcessID: Int32
    ) -> CallAudioApplicationIdentity? {
        guard let first = ancestors.first,
              first.pid != currentProcessID,
              !isExcludedExecutable(first.executableName)
        else { return nil }

        var nativeCandidate: CallAudioApplicationIdentity?
        for ancestor in ancestors {
            guard ancestor.pid != currentProcessID else { return nil }
            guard let bundleID = ancestor.bundleID else { continue }
            if bundleID == "gg.zbs.eye" || bundleID.hasPrefix("gg.zbs.eye.") {
                return nil
            }
            if CallSurfaceCatalog.browserBundleIDs.contains(bundleID) {
                return CallAudioApplicationIdentity(
                    rootPID: ancestor.pid,
                    bundleID: bundleID,
                    kind: .browser
                )
            }
            if CallSurfaceCatalog.nativeBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) {
                nativeCandidate = CallAudioApplicationIdentity(
                    rootPID: ancestor.pid,
                    bundleID: bundleID,
                    kind: .native
                )
            }
        }
        return nativeCandidate
    }

    private static func isExcludedExecutable(_ value: String?) -> Bool {
        guard let value else { return false }
        return excludedExecutableNames.contains(value.lowercased())
    }
}

struct CallAudioProcessSample: Equatable, Sendable {
    /// CoreAudio's process-object identity. Unlike a root browser PID this changes when CoreAudio
    /// tears down one browser audio process and later creates another.
    let audioObjectID: UInt32
    let pid: Int32
    let rootPID: Int32
    let ownerBundleID: String
    let ownerKind: CallAudioApplicationKind
    let inputActive: Bool
    let outputActive: Bool
}

struct CallAudioApplicationGroup: Equatable, Sendable {
    let rootPID: Int32
    let ownerBundleID: String
    let ownerKind: CallAudioApplicationKind
    let inputActive: Bool
    let outputActive: Bool
    let memberCount: Int
    let inputAudioObjectIDs: Set<UInt32>
    let outputAudioObjectIDs: Set<UInt32>

    var hasAnyAudioSession: Bool {
        inputActive || outputActive
    }
}

enum CallAudioSessionLivenessDecision: Equatable, Sendable {
    case continueActive
    case retainMissing(since: TimeInterval)
    case release
}

enum CallAudioSessionLiveness {
    static func decide(
        hasRequiredAudio: Bool,
        missingSince: TimeInterval?,
        now: TimeInterval,
        maximumMissingRetention: TimeInterval
    ) -> CallAudioSessionLivenessDecision {
        if hasRequiredAudio {
            return .continueActive
        }
        let started = missingSince ?? now
        guard now - started <= maximumMissingRetention else { return .release }
        return .retainMissing(since: started)
    }
}

enum CallSurfaceSuppressionPolicy {
    static func allows(
        candidateSurfaceKey: String,
        suppressedSurfaceKeys: Set<String>
    ) -> Bool {
        !suppressedSurfaceKeys.contains(candidateSurfaceKey)
    }

    static func shouldRelease(
        rootApplicationRunning: Bool
    ) -> Bool {
        !rootApplicationRunning
    }
}

enum MeetingDetectorLifecycleFence {
    /// Every result in one parallel browser probe batch belongs to one lifecycle generation.
    /// Any awaited reconciliation can race stop/release; an active session or generation change
    /// invalidates the remainder of that batch.
    static func permitsAdmission(
        probeGeneration: UInt64,
        currentGeneration: UInt64,
        hasActiveSession: Bool
    ) -> Bool {
        probeGeneration == currentGeneration && !hasActiveSession
    }
}

struct CallSurfaceContinuityDecision: Equatable, Sendable {
    let surfaceConfirmed: Bool
    let hasRequiredEvidence: Bool
}

enum CallSurfaceContinuity {
    /// A failed periodic surface check remains end evidence until a later check positively
    /// re-confirms that same surface. Audio alone cannot silently flip the state back to active
    /// between bounded AX probes.
    static func decide(
        hasRequiredAudio: Bool,
        previouslyConfirmed: Bool,
        latestSurfaceMatch: Bool?
    ) -> CallSurfaceContinuityDecision {
        let confirmed = latestSurfaceMatch ?? previouslyConfirmed
        return CallSurfaceContinuityDecision(
            surfaceConfirmed: confirmed,
            hasRequiredEvidence: hasRequiredAudio && confirmed
        )
    }
}

enum BrowserSurfaceRevalidation {
    /// AX cannot prove that an inactive/background Chromium tab disappeared merely because it is
    /// absent from the exposed tree. A complete no-match becomes contradictory only when CoreAudio
    /// also replaced the input/output process objects that originally carried the call.
    static func latestSurfaceMatch(
        trustedSurfaceFound: Bool,
        sameSurface: Bool,
        authoritativeNoMatch: Bool,
        audioSessionIdentityChanged: Bool
    ) -> Bool? {
        if trustedSurfaceFound {
            if sameSurface { return true }
            return audioSessionIdentityChanged ? false : nil
        }
        if authoritativeNoMatch && audioSessionIdentityChanged {
            return false
        }
        return nil
    }

    /// A hidden/background tab is never contradictory merely because its retained AX root was
    /// invalidated while the same CoreAudio carriers survive. A missing capability or a true AX
    /// read failure is not a background-tab signal: start the bounded trust-loss window even with
    /// unchanged carriers so revoked TCC or a wedged AX server cannot keep recording forever.
    static func startsBoundedTrustLoss(
        retainedControlState: BrowserCallControlState?,
        trustedSurfaceFound: Bool,
        authoritativeNoMatch: Bool,
        audioSessionIdentityChanged: Bool
    ) -> Bool {
        if retainedControlState == nil || retainedControlState == .unknown {
            return true
        }
        if !trustedSurfaceFound && !authoritativeNoMatch {
            // A timeout, AX error, or exhausted traversal budget is not the successful
            // background-tab ambiguity below. Bound the outage even when Chromium keeps the same
            // HAL objects alive for an assistant mic or unrelated playback.
            return true
        }
        guard audioSessionIdentityChanged,
              retainedControlState == .invalidated
        else { return false }
        return trustedSurfaceFound || authoritativeNoMatch
    }

    static func baselineAudioSessionWasReplaced(
        baselineInput: Set<UInt32>,
        baselineOutput: Set<UInt32>,
        currentInput: Set<UInt32>,
        currentOutput: Set<UInt32>
    ) -> Bool {
        // A positive call probe only proves that at least one object on each side carried the
        // call. Unrelated playback/notifications can be present in the same root. Replacement is
        // proven only when every candidate object from either required side disappeared.
        baselineInput.isDisjoint(with: currentInput)
            || baselineOutput.isDisjoint(with: currentOutput)
    }

    /// A control that was rebound inside the same retained web root still belongs to the current
    /// call across an ordinary mic/device switch. Only complete loss of both required carrier sets
    /// can corroborate that the replacement control belongs to a successor call.
    static func baselineAudioSessionWasFullyReplaced(
        baselineInput: Set<UInt32>,
        baselineOutput: Set<UInt32>,
        currentInput: Set<UInt32>,
        currentOutput: Set<UInt32>
    ) -> Bool {
        !baselineInput.isEmpty
            && !baselineOutput.isEmpty
            && baselineInput.isDisjoint(with: currentInput)
            && baselineOutput.isDisjoint(with: currentOutput)
    }
}

enum BrowserControlLifecycle {
    static func establishesSuccessorBoundary(
        state _: BrowserCallControlState,
        audioCarriersFullyReplaced: Bool
    ) -> Bool {
        // Complete replacement of both required HAL carrier sets is already an authoritative
        // session boundary. Chromium SPAs may reuse the exact same AX control across calls, so
        // `.active` cannot override that audio identity change.
        return audioCarriersFullyReplaced
    }

    static func permitsCrossRootAdoption(
        identityMatches: Bool,
        audioCarriersFullyReplaced: Bool
    ) -> Bool {
        identityMatches && !audioCarriersFullyReplaced
    }

    static func activeMatch(
        state: BrowserCallControlState,
        audioCarriersFullyReplaced: Bool
    ) -> Bool? {
        switch state {
        case .active:
            return true
        case .rebound:
            return !audioCarriersFullyReplaced
        case .ended, .replaced:
            return false
        case .invalidated, .unknown:
            return nil
        }
    }

    static func shouldReleaseSuppression(
        state: BrowserCallControlState,
        audioCarriersFullyReplaced: Bool,
        allowsDocumentReplacementRelease: Bool
    ) -> Bool {
        (state == .replaced
            && (allowsDocumentReplacementRelease || audioCarriersFullyReplaced))
            || (
                audioCarriersFullyReplaced
                    && (state == .ended || state == .invalidated || state == .rebound)
            )
    }

    static func needsAudioIdentityFallback(
        state: BrowserCallControlState
    ) -> Bool {
        state == .invalidated || state == .unknown
    }

    /// Once the exact retained root no longer exposes the old control, the tombstone's opaque
    /// service/session identity is enough for collision-safe Meet/Zoom/qualified Teams matching.
    /// Releasing the AX capability keeps ended rejected calls from permanently filling the bounded
    /// registry. Unknown AX failures retain the capability and fail closed.
    static func shouldDetachSuppressedCapability(
        state: BrowserCallControlState
    ) -> Bool {
        state == .ended || state == .invalidated || state == .replaced
    }
}

enum BrowserSurfaceIdentity {
    static func matches(
        expectedService: BrowserCallService?,
        expectedDiscriminator: String?,
        expectedAllowsCrossRootReconciliation: Bool,
        observedService: BrowserCallService?,
        observedDiscriminator: String?,
        observedAllowsCrossRootReconciliation: Bool
    ) -> Bool {
        guard expectedAllowsCrossRootReconciliation,
              observedAllowsCrossRootReconciliation
        else { return false }
        guard let expectedService,
              let expectedDiscriminator,
              let observedService,
              let observedDiscriminator
        else { return false }
        return expectedService == observedService
            && expectedDiscriminator == observedDiscriminator
    }
}

enum NativeSuppressionBoundaryDecision: Equatable, Sendable {
    case retain(authoritativeEndSince: TimeInterval?)
    case release
}

enum DetachedSuppressionBoundary {
    /// A detached AX capability is intentionally fail-closed, but it must not tombstone an app
    /// forever after its complete required CoreAudio boundary disappears. Require two ordinary
    /// detector polls of the boundary; a partial return resets the proof.
    static func decide(
        freshTwoSidedReplacement: Bool = false,
        boundaryAbsent: Bool,
        boundarySince: TimeInterval?,
        now: TimeInterval,
        minimumStableBoundary: TimeInterval = 4
    ) -> NativeSuppressionBoundaryDecision {
        // A fresh input+output carrier pair is positive evidence for successor B, not merely
        // absence of A. Release immediately so a generic SPA tombstone cannot hide B behind the
        // disappearance debounce. The debounce remains only for a fully absent audio boundary.
        if freshTwoSidedReplacement {
            return .release
        }
        guard boundaryAbsent else {
            return .retain(authoritativeEndSince: nil)
        }
        let started = boundarySince ?? now
        guard now - started >= minimumStableBoundary else {
            return .retain(authoritativeEndSince: started)
        }
        return .release
    }
}

enum NativeSuppressionAudioBoundary {
    static func isAbsent(inputActive: Bool, outputActive: Bool) -> Bool {
        !inputActive && !outputActive
    }
}

enum NativeSurfaceLifecycle {
    /// A native app PID is not a call identity. A successor becomes eligible only after the exact
    /// retained window was authoritatively free of call controls for two ordinary detector polls.
    /// Input may already belong to the successor; AX uncertainty and invalidation remain fail-closed.
    static func suppressionBoundary(
        state: NativeCallSurfaceState,
        inputActive: Bool,
        authoritativeEndSince: TimeInterval?,
        now: TimeInterval,
        minimumAuthoritativeEnd: TimeInterval = 4
    ) -> NativeSuppressionBoundaryDecision {
        switch state {
        case .active, .obscured:
            return .retain(authoritativeEndSince: nil)
        case .unknown, .invalidated:
            // The end boundary must be consecutive authoritative evidence. Any AX uncertainty
            // breaks the streak instead of letting wall time silently complete it.
            return .retain(authoritativeEndSince: nil)
        case .ended:
            let started = authoritativeEndSince ?? now
            guard now - started >= minimumAuthoritativeEnd else {
                return .retain(authoritativeEndSince: started)
            }
            return .release
        }
    }

    /// A second native window in the same app PID can be a mirror/rebuild of the rejected call.
    /// Admission therefore waits until `updateSuppressedSessions` has consumed an authoritative
    /// end boundary and removed every tombstone for that native process.
    static func allowsSuccessor(suppressedSessionCount: Int) -> Bool {
        suppressedSessionCount == 0
    }

    /// An invalidated retained native window is an identity boundary. A hard-control window found
    /// elsewhere in the same PID may already be a successor call; it can never inherit the old
    /// fingerprint. Admission of its token waits until the old envelope has closed.
    static func invalidatedSurfaceMatch(
        replacementHasCallSignature: Bool,
        authoritativeNoMatch: Bool
    ) -> Bool? {
        if replacementHasCallSignature || authoritativeNoMatch {
            return false
        }
        return nil
    }
}

enum CallAudioProcessGrouping {
    private struct Key: Hashable {
        let rootPID: Int32
        let ownerBundleID: String
        let ownerKind: CallAudioApplicationKind
    }

    static func groups(from samples: [CallAudioProcessSample]) -> [CallAudioApplicationGroup] {
        var grouped: [
            Key: (
                input: Bool,
                output: Bool,
                pids: Set<Int32>,
                inputObjects: Set<UInt32>,
                outputObjects: Set<UInt32>
            )
        ] = [:]

        for sample in samples where sample.inputActive || sample.outputActive {
            let key = Key(
                rootPID: sample.rootPID,
                ownerBundleID: sample.ownerBundleID,
                ownerKind: sample.ownerKind
            )
            var aggregate = grouped[key] ?? (false, false, [], [], [])
            aggregate.input = aggregate.input || sample.inputActive
            aggregate.output = aggregate.output || sample.outputActive
            aggregate.pids.insert(sample.pid)
            if sample.inputActive {
                aggregate.inputObjects.insert(sample.audioObjectID)
            }
            if sample.outputActive {
                aggregate.outputObjects.insert(sample.audioObjectID)
            }
            grouped[key] = aggregate
        }

        return grouped.map { key, aggregate in
            CallAudioApplicationGroup(
                rootPID: key.rootPID,
                ownerBundleID: key.ownerBundleID,
                ownerKind: key.ownerKind,
                inputActive: aggregate.input,
                outputActive: aggregate.output,
                memberCount: aggregate.pids.count,
                inputAudioObjectIDs: aggregate.inputObjects,
                outputAudioObjectIDs: aggregate.outputObjects
            )
        }
        .sorted {
            if $0.ownerBundleID != $1.ownerBundleID {
                return $0.ownerBundleID < $1.ownerBundleID
            }
            return $0.rootPID < $1.rootPID
        }
    }
}
