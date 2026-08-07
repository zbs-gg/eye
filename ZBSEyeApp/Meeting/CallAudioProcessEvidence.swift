import Foundation

enum CallAudioApplicationKind: String, Hashable, Sendable {
    case native
    case browser
    case generic
}

enum CallAudioAutomaticOwnerRole: String, Hashable, Sendable {
    /// A real microphone consumer. It may start, name, and keep an automatic Call alive.
    case initiator
    /// An audio relay that may coexist with a Call but must never own its lifecycle or identity.
    case relay
}

enum CallAudioAutomaticOwnerRolePolicy {
    static let krispRootBundleID = "ai.krisp.krispMac"

    static func role(forBundleID bundleID: String) -> CallAudioAutomaticOwnerRole {
        isKrispRelayBundleID(bundleID) ? .relay : .initiator
    }

    static func isKrispRelayBundleID(_ bundleID: String) -> Bool {
        bundleID == krispRootBundleID
            || bundleID.hasPrefix("\(krispRootBundleID).")
    }
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
    /// `bundleID` is a local process identity when CoreAudio cannot expose a real bundle id.
    /// Keep that distinction so exact user bundle exclusions never accidentally match a fallback.
    let bundleIDIsSynthetic: Bool
    /// Safe user-facing fallback only. `proc_name` returns a basename, never an executable path.
    let displayName: String?

    init(
        rootPID: Int32,
        bundleID: String,
        kind: CallAudioApplicationKind,
        bundleIDIsSynthetic: Bool = false,
        displayName: String? = nil
    ) {
        self.rootPID = rootPID
        self.bundleID = bundleID
        self.kind = kind
        self.bundleIDIsSynthetic = bundleIDIsSynthetic
        self.displayName = displayName
    }
}

enum CallAudioBrowserRootResolution {
    /// Resolve a detached Chromium audio helper to the visible supported browser root exposed by
    /// NSWorkspace. CoreAudio's process bundle id is the authority for the helper family; the
    /// returned root still has to be an exact running application bundle id.
    static func rootAncestor(
        audioProcessBundleID: String?,
        runningApplicationBundleIDs: [Int32: String]
    ) -> CallAudioProcessAncestor? {
        guard let canonical = CallSurfaceCatalog.canonicalBrowserBundleID(
            forAudioProcessBundleID: audioProcessBundleID
        ),
        let rootPID = runningApplicationBundleIDs
            .filter({ $0.value == canonical })
            .map(\.key)
            .sorted()
            .first
        else { return nil }
        return CallAudioProcessAncestor(
            pid: rootPID,
            bundleID: canonical,
            executableName: nil
        )
    }
}

enum CallAudioVisibleRootResolution {
    /// Detached app helpers are not always parented by their visible application. Resolve common
    /// helper namespaces only against an exact bundle id currently exposed by NSWorkspace.
    static func rootAncestor(
        audioProcessBundleID: String?,
        runningApplicationBundleIDs: [Int32: String]
    ) -> CallAudioProcessAncestor? {
        guard let audioProcessBundleID else { return nil }
        let matches = runningApplicationBundleIDs.compactMap { pid, rootBundleID in
            let isMatch = audioProcessBundleID == rootBundleID
                || audioProcessBundleID.hasPrefix("\(rootBundleID).helper")
                || audioProcessBundleID.hasPrefix("\(rootBundleID).Helper")
                || audioProcessBundleID.hasPrefix("\(rootBundleID).xpc")
            return isMatch ? (pid, rootBundleID) : nil
        }
        // Prefer the longest exact namespace, then a stable PID. `com.example.app.beta` must win
        // over a simultaneously running `com.example.app`.
        guard let match = matches.sorted(by: {
            if $0.1.count != $1.1.count { return $0.1.count > $1.1.count }
            return $0.0 < $1.0
        }).first else { return nil }
        return CallAudioProcessAncestor(
            pid: match.0,
            bundleID: match.1,
            executableName: nil
        )
    }
}

enum CallAudioOwnerResolution {
    /// Exact executable basenames owned by macOS audio/voice infrastructure. Prefix matching is
    /// deliberately forbidden: a third-party app with a similar name is still a valid mic owner.
    static let excludedExecutableNames: Set<String> = [
        "replayd",
        "coreaudiod",
        "audiomxd",
        "avconferenced",
        "assistantd",
        "siriactionsd",
        "speechsynthesisd",
        "voicetriggerd",
        "voiceover",
        "codex_chronicle",
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
              !isExcludedExecutableName(first.executableName)
        else { return nil }

        var nativeCandidate: CallAudioApplicationIdentity?
        var genericCandidate: CallAudioApplicationIdentity?
        for ancestor in ancestors {
            guard ancestor.pid != currentProcessID else { return nil }
            guard let bundleID = ancestor.bundleID else { continue }
            if isEyeBundleID(bundleID) {
                return nil
            }
            if CallSurfaceCatalog.browserBundleIDs.contains(bundleID) {
                return CallAudioApplicationIdentity(
                    rootPID: ancestor.pid,
                    bundleID: bundleID,
                    kind: .browser,
                    displayName: ancestor.executableName
                )
            }
            if CallSurfaceCatalog.nativeBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) {
                nativeCandidate = CallAudioApplicationIdentity(
                    rootPID: ancestor.pid,
                    bundleID: bundleID,
                    kind: .native,
                    displayName: ancestor.executableName
                )
            } else {
                // Walking child-first and retaining the last application identity folds ordinary
                // helper processes into their visible/root application when ancestry exposes it.
                genericCandidate = CallAudioApplicationIdentity(
                    rootPID: ancestor.pid,
                    bundleID: bundleID,
                    kind: .generic,
                    displayName: ancestor.executableName
                )
            }
        }
        if let nativeCandidate { return nativeCandidate }
        if let genericCandidate { return genericCandidate }

        // A nil CoreAudio bundle id is not a reason to lose a call. Use only a process basename
        // (never a path), falling back to one conservative anonymous identity if unavailable.
        let executableName = first.executableName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableProcessName = executableName.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let identifier = stableProcessName.map { "process:\($0)" } ?? "process:unknown"
        return CallAudioApplicationIdentity(
            rootPID: first.pid,
            bundleID: identifier,
            kind: .generic,
            bundleIDIsSynthetic: true,
            displayName: executableName
        )
    }

    static func isExcludedExecutableName(_ value: String?) -> Bool {
        guard let value else { return false }
        return excludedExecutableNames.contains(value.lowercased())
    }

    private static func isEyeBundleID(_ value: String) -> Bool {
        value == "gg.zbs.eye" || value.hasPrefix("gg.zbs.eye.")
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
    let ownerBundleIDIsSynthetic: Bool
    let ownerDisplayName: String?
    let inputActive: Bool
    let outputActive: Bool

    init(
        audioObjectID: UInt32,
        pid: Int32,
        rootPID: Int32,
        ownerBundleID: String,
        ownerKind: CallAudioApplicationKind,
        ownerBundleIDIsSynthetic: Bool = false,
        ownerDisplayName: String? = nil,
        inputActive: Bool,
        outputActive: Bool
    ) {
        self.audioObjectID = audioObjectID
        self.pid = pid
        self.rootPID = rootPID
        self.ownerBundleID = ownerBundleID
        self.ownerKind = ownerKind
        self.ownerBundleIDIsSynthetic = ownerBundleIDIsSynthetic
        self.ownerDisplayName = ownerDisplayName
        self.inputActive = inputActive
        self.outputActive = outputActive
    }
}

struct CallAudioApplicationGroup: Equatable, Sendable {
    let rootPID: Int32
    let ownerBundleID: String
    let ownerKind: CallAudioApplicationKind
    let ownerBundleIDIsSynthetic: Bool
    let ownerDisplayName: String?
    let inputActive: Bool
    let outputActive: Bool
    let memberCount: Int
    let inputAudioObjectIDs: Set<UInt32>
    let outputAudioObjectIDs: Set<UInt32>

    init(
        rootPID: Int32,
        ownerBundleID: String,
        ownerKind: CallAudioApplicationKind,
        ownerBundleIDIsSynthetic: Bool = false,
        ownerDisplayName: String? = nil,
        inputActive: Bool,
        outputActive: Bool,
        memberCount: Int,
        inputAudioObjectIDs: Set<UInt32>,
        outputAudioObjectIDs: Set<UInt32>
    ) {
        self.rootPID = rootPID
        self.ownerBundleID = ownerBundleID
        self.ownerKind = ownerKind
        self.ownerBundleIDIsSynthetic = ownerBundleIDIsSynthetic
        self.ownerDisplayName = ownerDisplayName
        self.inputActive = inputActive
        self.outputActive = outputActive
        self.memberCount = memberCount
        self.inputAudioObjectIDs = inputAudioObjectIDs
        self.outputAudioObjectIDs = outputAudioObjectIDs
    }

    var hasAnyAudioSession: Bool {
        inputActive || outputActive
    }

    var automaticCallOwnerRole: CallAudioAutomaticOwnerRole {
        CallAudioAutomaticOwnerRolePolicy.role(forBundleID: ownerBundleID)
    }
}

struct CallAudioOwnerKey: Hashable, Sendable {
    let ownerBundleID: String
    let syntheticRootPID: Int32?

    init(group: CallAudioApplicationGroup) {
        ownerBundleID = group.ownerBundleID
        syntheticRootPID = group.ownerBundleIDIsSynthetic ? group.rootPID : nil
    }
}

struct CallAudioSuppressedOwnerState: Equatable, Sendable {
    let fingerprint: String
    var idleSince: TimeInterval?
}

enum CallAudioOwnerSuppressionBoundary {
    static let minimumStableIdle: TimeInterval = 4

    /// A Call that already spent a stable interval without this owner needs no tombstone when it
    /// is finally saved. This is what lets the same app begin a genuinely new back-to-back Call.
    static func stateWhenSuppressing(
        fingerprint: String,
        alreadyIdleSince: TimeInterval?,
        now: TimeInterval,
        minimumStableIdle: TimeInterval = CallAudioOwnerSuppressionBoundary.minimumStableIdle
    ) -> CallAudioSuppressedOwnerState? {
        if let alreadyIdleSince,
           now - alreadyIdleSince >= minimumStableIdle {
            return nil
        }
        return CallAudioSuppressedOwnerState(
            fingerprint: fingerprint,
            idleSince: alreadyIdleSince
        )
    }

    /// Each initiating microphone owner proves its own idle boundary. Relay-only processes never
    /// enter this map, so they cannot keep a real app tombstoned after its microphone becomes idle.
    static func reconcile(
        _ states: [CallAudioOwnerKey: CallAudioSuppressedOwnerState],
        activeOwners: Set<CallAudioOwnerKey>,
        now: TimeInterval,
        minimumStableIdle: TimeInterval = CallAudioOwnerSuppressionBoundary.minimumStableIdle
    ) -> [CallAudioOwnerKey: CallAudioSuppressedOwnerState] {
        var retained: [CallAudioOwnerKey: CallAudioSuppressedOwnerState] = [:]
        retained.reserveCapacity(states.count)
        for (owner, original) in states {
            var state = original
            if activeOwners.contains(owner) {
                state.idleSince = nil
                retained[owner] = state
                continue
            }
            let idleSince = state.idleSince ?? now
            guard now - idleSince < minimumStableIdle else { continue }
            state.idleSince = idleSince
            retained[owner] = state
        }
        return retained
    }
}

enum CallAudioAutomaticAdmission {
    /// Every permitted input process remains observable, including relay-only helpers. This is the
    /// participant set; callers must use `eligibleInputGroups` for lifecycle ownership.
    static func participatingInputGroups(
        from groups: [CallAudioApplicationGroup],
        excludedBundleIDs: Set<String>
    ) -> [CallAudioApplicationGroup] {
        groups.filter { group in
            group.inputActive
                && (group.ownerBundleIDIsSynthetic
                    || !excludedBundleIDs.contains(group.ownerBundleID))
        }
    }

    /// User exclusions are exact, case-sensitive bundle ids. Synthetic identities intentionally
    /// remain eligible because they are not bundle ids and cannot be configured safely by prefix.
    /// Relay-only owners stay observable through `participatingInputGroups`, but cannot initiate,
    /// name, or hold an automatic Call.
    static func eligibleInputGroups(
        from groups: [CallAudioApplicationGroup],
        excludedBundleIDs: Set<String>
    ) -> [CallAudioApplicationGroup] {
        participatingInputGroups(
            from: groups,
            excludedBundleIDs: excludedBundleIDs
        ).filter { $0.automaticCallOwnerRole == .initiator }
    }

    static func unsuppressedInputGroups(
        from groups: [CallAudioApplicationGroup],
        excludedBundleIDs: Set<String>,
        suppressedOwners: Set<CallAudioOwnerKey>
    ) -> [CallAudioApplicationGroup] {
        eligibleInputGroups(
            from: groups,
            excludedBundleIDs: excludedBundleIDs
        ).filter { !suppressedOwners.contains(CallAudioOwnerKey(group: $0)) }
    }

    /// Stable deterministic enrichment choice. The detector's activation fingerprint is retained
    /// independently, so another owner becoming preferable never splits the Call.
    static func preferredGroup(
        from groups: [CallAudioApplicationGroup],
        retaining owner: CallAudioOwnerKey? = nil
    ) -> CallAudioApplicationGroup? {
        let initiators = groups.filter { $0.automaticCallOwnerRole == .initiator }
        if let owner,
           let retained = initiators.first(where: { CallAudioOwnerKey(group: $0) == owner }) {
            return retained
        }
        return initiators.sorted(by: { lhs, rhs in
            if lhs.outputActive != rhs.outputActive { return lhs.outputActive && !rhs.outputActive }
            if lhs.ownerKind != rhs.ownerKind {
                let rank: [CallAudioApplicationKind: Int] = [.native: 0, .browser: 1, .generic: 2]
                return rank[lhs.ownerKind, default: 9] < rank[rhs.ownerKind, default: 9]
            }
            if lhs.ownerBundleID != rhs.ownerBundleID {
                return lhs.ownerBundleID < rhs.ownerBundleID
            }
            return lhs.rootPID < rhs.rootPID
        }).first
    }
}

struct CallAudioContinuationEvidence: Equatable, Sendable {
    let hasContinuationAudio: Bool
    let hasFreshTwoSidedBrowserAudio: Bool

    static func evaluate(
        kind: CallAudioApplicationKind,
        group: CallAudioApplicationGroup?
    ) -> CallAudioContinuationEvidence {
        guard let group else {
            return CallAudioContinuationEvidence(
                hasContinuationAudio: false,
                hasFreshTwoSidedBrowserAudio: false
            )
        }
        return CallAudioContinuationEvidence(
            // Output-only playback never keeps a call alive. Once a browser call was admitted,
            // however, its mic plus retained trusted control survives a quiet output interval.
            hasContinuationAudio: group.inputActive,
            // Carrier replacement remains a two-sided boundary proof. An empty output set during
            // silence must not make an ordinary microphone switch look like successor call B.
            hasFreshTwoSidedBrowserAudio: kind == .browser
                && group.inputActive
                && group.outputActive
        )
    }
}

struct CallAudioCarrierBaseline: Equatable, Sendable {
    let inputAudioObjectIDs: Set<UInt32>
    let outputAudioObjectIDs: Set<UInt32>

    init(
        inputAudioObjectIDs: Set<UInt32>,
        outputAudioObjectIDs: Set<UInt32>
    ) {
        self.inputAudioObjectIDs = inputAudioObjectIDs
        self.outputAudioObjectIDs = outputAudioObjectIDs
    }

    /// A quiet browser interval can omit one side from the current HAL sample. Keep the last
    /// positively observed carrier set for that side instead of erasing the session boundary.
    func refreshingConfirmedSide(from group: CallAudioApplicationGroup) -> Self {
        Self(
            inputAudioObjectIDs: group.inputAudioObjectIDs.isEmpty
                ? inputAudioObjectIDs
                : group.inputAudioObjectIDs,
            outputAudioObjectIDs: group.outputAudioObjectIDs.isEmpty
                ? outputAudioObjectIDs
                : group.outputAudioObjectIDs
        )
    }

    /// Only a fresh two-sided browser sample can prove A -> B. A mic switch observed while the
    /// output carrier is quiet must never be promoted into a successor-call boundary.
    func isFullyReplaced(
        by group: CallAudioApplicationGroup?,
        kind: CallAudioApplicationKind
    ) -> Bool {
        guard let group,
              CallAudioContinuationEvidence.evaluate(
                  kind: kind,
                  group: group
              ).hasFreshTwoSidedBrowserAudio
        else { return false }
        return BrowserSurfaceRevalidation.baselineAudioSessionWasFullyReplaced(
            baselineInput: inputAudioObjectIDs,
            baselineOutput: outputAudioObjectIDs,
            currentInput: group.inputAudioObjectIDs,
            currentOutput: group.outputAudioObjectIDs
        )
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
        let ownerBundleIDIsSynthetic: Bool
    }

    static func groups(from samples: [CallAudioProcessSample]) -> [CallAudioApplicationGroup] {
        var grouped: [
            Key: (
                input: Bool,
                output: Bool,
                pids: Set<Int32>,
                inputObjects: Set<UInt32>,
                outputObjects: Set<UInt32>,
                displayName: String?
            )
        ] = [:]

        for sample in samples where sample.inputActive || sample.outputActive {
            let key = Key(
                rootPID: sample.rootPID,
                ownerBundleID: sample.ownerBundleID,
                ownerKind: sample.ownerKind,
                ownerBundleIDIsSynthetic: sample.ownerBundleIDIsSynthetic
            )
            var aggregate = grouped[key] ?? (false, false, [], [], [], nil)
            aggregate.input = aggregate.input || sample.inputActive
            aggregate.output = aggregate.output || sample.outputActive
            aggregate.pids.insert(sample.pid)
            if aggregate.displayName == nil {
                aggregate.displayName = sample.ownerDisplayName
            }
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
                ownerBundleIDIsSynthetic: key.ownerBundleIDIsSynthetic,
                ownerDisplayName: aggregate.displayName,
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
