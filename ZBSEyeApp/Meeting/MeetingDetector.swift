import AppKit
import CoreAudio
import Darwin
import Foundation

enum MeetingSessionSuppressionResult: Sendable, Equatable {
    case suppressed
    case activityResumed
}

/// Collects bounded, on-device evidence that a call is happening now.
///
/// CoreAudio is the cheap first gate. Audio helper processes are resolved to one canonical native
/// application or qualified Chromium root, then input/output activity is aggregated across sibling
/// helpers. Browser candidates are confirmed by a bounded Accessibility scan; no AppleScript,
/// extension, stored browsing history, or new permission prompt is involved.
///
/// This actor owns the transient session identity. After one strong browser/native confirmation the
/// fingerprint remains stable while the same application audio session survives, so a background tab,
/// hidden toolbar, or microphone switch does not split a recording. Raw URL and Accessibility text never
/// leave the inspector and are never persisted or logged.
actor MeetingDetector {
    typealias ExcludedBundleIDsProvider = @Sendable () async -> Set<String>

    /// CoreAudio invokes these blocks on one private serial queue. A callback never decides call
    /// state or touches actor storage; it only wakes the detector's bounded poll path. Listener
    /// bookkeeping stays on that same queue and is rebuilt after a HAL service reset.
    private final class CoreAudioMicActivityListener: @unchecked Sendable {
        private let queue = DispatchQueue(
            label: "gg.zbs.eye.meeting-detector-core-audio-events",
            qos: .utility
        )
        private let wakePoll: @Sendable () -> Void
        private var listener: AudioObjectPropertyListenerBlock!
        private var registeredSystemSelectors: Set<AudioObjectPropertySelector> = []
        private var registeredProcessObjects: Set<AudioObjectID> = []
        private var stopped = false

        init(wakePoll: @escaping @Sendable () -> Void) {
            self.wakePoll = wakePoll
            listener = { [weak self] count, addresses in
                self?.propertiesChanged(count: count, addresses: addresses)
            }
        }

        func start() {
            queue.async { [self] in
                guard !stopped else { return }
                apply(CoreAudioMicListenerLifecyclePolicy.effects(for: .start))
            }
        }

        func stop() {
            queue.async { [self] in
                guard !stopped else { return }
                stopped = true
                apply(CoreAudioMicListenerLifecyclePolicy.effects(for: .stop))
            }
        }

        func refreshAfterWake() {
            queue.async { [self] in
                guard !stopped else { return }
                apply(CoreAudioMicListenerLifecyclePolicy.effects(for: .systemWake))
            }
        }

        private func propertiesChanged(
            count: UInt32,
            addresses: UnsafePointer<AudioObjectPropertyAddress>
        ) {
            guard !stopped else { return }
            var selectors: Set<UInt32> = []
            for index in 0..<Int(count) {
                selectors.insert(addresses[index].mSelector)
            }

            guard let event = CoreAudioMicListenerLifecyclePolicy.event(
                forPropertySelectors: selectors,
                runningInputSelector: kAudioProcessPropertyIsRunningInput,
                processListSelector: kAudioHardwarePropertyProcessObjectList,
                serviceRestartedSelector: kAudioHardwarePropertyServiceRestarted
            ) else { return }
            let effects = CoreAudioMicListenerLifecyclePolicy.effects(for: event)

            // The first effect for every registered property callback is the immediate read. HAL
            // listener mutation follows asynchronously after the callback returns; a final read
            // then closes the subscribe/read race for process-list and restart events.
            if effects.first == .wakePoll {
                wakePoll()
            }
            let deferredEffects = Array(effects.dropFirst())
            guard !deferredEffects.isEmpty else { return }
            queue.async { [self] in
                guard !stopped else { return }
                apply(deferredEffects)
            }
        }

        private func apply(_ effects: [CoreAudioMicListenerLifecyclePolicy.Effect]) {
            for effect in effects {
                switch effect {
                case .wakePoll:
                    wakePoll()
                case .forgetRegistrations:
                    registeredSystemSelectors.removeAll()
                    registeredProcessObjects.removeAll()
                case .installSystemListeners:
                    installSystemListeners()
                case .reconcileProcessListeners:
                    rebuildProcessListeners()
                case .removeAllListeners:
                    removeAllListeners()
                }
            }
        }

        private func installSystemListeners() {
            let system = AudioObjectID(kAudioObjectSystemObject)
            for selector in [
                kAudioHardwarePropertyProcessObjectList,
                kAudioHardwarePropertyServiceRestarted,
            ] where !registeredSystemSelectors.contains(selector) {
                var address = Self.address(selector)
                if AudioObjectAddPropertyListenerBlock(
                    system,
                    &address,
                    queue,
                    listener
                ) == noErr {
                    registeredSystemSelectors.insert(selector)
                }
            }
        }

        private func rebuildProcessListeners() {
            let currentObjects = Set(MeetingDetector.processObjects() ?? [])
            let plan = CoreAudioMicListenerLifecyclePolicy.processListenerPlan(
                current: currentObjects,
                registered: registeredProcessObjects
            )

            for object in plan.remove {
                var address = Self.address(kAudioProcessPropertyIsRunningInput)
                AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
            }
            registeredProcessObjects.subtract(plan.remove)

            for object in plan.add {
                var address = Self.address(kAudioProcessPropertyIsRunningInput)
                guard AudioObjectHasProperty(object, &address) else { continue }
                if AudioObjectAddPropertyListenerBlock(
                    object,
                    &address,
                    queue,
                    listener
                ) == noErr {
                    registeredProcessObjects.insert(object)
                }
            }
        }

        private func removeAllListeners() {
            let system = AudioObjectID(kAudioObjectSystemObject)
            for selector in registeredSystemSelectors {
                var address = Self.address(selector)
                AudioObjectRemovePropertyListenerBlock(system, &address, queue, listener)
            }
            registeredSystemSelectors.removeAll()
            for object in registeredProcessObjects {
                var address = Self.address(kAudioProcessPropertyIsRunningInput)
                AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
            }
            registeredProcessObjects.removeAll()
        }

        private static func address(
            _ selector: AudioObjectPropertySelector
        ) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        }
    }

    /// `inFlight` is exclusively protected by `lock`; no CoreAudio state crosses this bridge.
    private final class AudioEvidencePollGate: @unchecked Sendable {
        private let lock = NSLock()
        private var inFlight = false

        func begin() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !inFlight else { return false }
            inFlight = true
            return true
        }

        func finish() {
            lock.lock()
            inFlight = false
            lock.unlock()
        }
    }

    /// `completed` is exclusively protected by `lock`; the continuation is resumed exactly once
    /// after releasing the lock so re-entrant completion cannot deadlock.
    private final class AudioEvidenceCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func resume(
            _ continuation: CheckedContinuation<AudioProcessCollection, Never>,
            returning result: AudioProcessCollection
        ) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            lock.unlock()
            continuation.resume(returning: result)
        }
    }

    private struct ActiveSession: Sendable {
        var rootPID: Int32
        var bundleID: String
        var kind: CallAudioApplicationKind
        let fingerprint: String
        var surfaceKey: String
        var ownerKeys: Set<CallAudioOwnerKey>
        var missingSince: TimeInterval?
        var surfaceConfirmed: Bool
        var surfaceTrustUnknownSince: TimeInterval?
        var inputAudioObjectIDs: Set<UInt32>
        var outputAudioObjectIDs: Set<UInt32>
        var nativeSurfaceHandleToken: String?
        var browserControlHandleToken: String?
        var browserService: BrowserCallService?
        var browserSessionDiscriminator: String?
        var browserAllowsCrossRootReconciliation: Bool
    }

    private struct SuppressedSession: Sendable {
        let rootPID: Int32
        let bundleID: String
        let kind: CallAudioApplicationKind
        let fingerprint: String
        var surfaceKey: String
        var nativeSurfaceHandleToken: String?
        var browserControlHandleToken: String?
        var browserService: BrowserCallService?
        var browserSessionDiscriminator: String?
        var browserAllowsCrossRootReconciliation: Bool
        var inputAudioObjectIDs: Set<UInt32>
        var outputAudioObjectIDs: Set<UInt32>
        var controlEndedSince: TimeInterval?
        var fullAudioBoundarySince: TimeInterval?
    }

    private struct SurfaceProbeKey: Hashable, Sendable {
        let rootPID: Int32
        let bundleID: String
    }

    private struct BrowserProbeResult: Sendable {
        let group: CallAudioApplicationGroup
        let inspection: BrowserCallSurfaceInspection
    }

    private struct ActiveSurfaceRevalidation: Sendable {
        let match: Bool?
        let replacementControlHandleToken: String?
        let replacementNativeSurfaceHandleToken: String?
        let replacementSurfaceKey: String?
        let trustReadFailed: Bool
        let terminalBoundary: Bool

        init(
            match: Bool?,
            replacementControlHandleToken: String?,
            replacementNativeSurfaceHandleToken: String?,
            replacementSurfaceKey: String?,
            trustReadFailed: Bool = false,
            terminalBoundary: Bool = false
        ) {
            self.match = match
            self.replacementControlHandleToken = replacementControlHandleToken
            self.replacementNativeSurfaceHandleToken = replacementNativeSurfaceHandleToken
            self.replacementSurfaceKey = replacementSurfaceKey
            self.trustReadFailed = trustReadFailed
            self.terminalBoundary = terminalBoundary
        }
    }

    private struct AudioProcessCollection: Sendable {
        let succeeded: Bool
        /// True only when every current HAL process object produced an input-running answer. A
        /// partial object read may still contain trustworthy positive samples, but it cannot prove
        /// that a suppressed owner became idle.
        let inputStateAuthoritative: Bool
        /// True only when every current HAL process object supplied both input/output state and
        /// every active object supplied a PID. Native/browser suppression uses both audio sides,
        /// so its negative boundary needs stronger evidence than generic microphone admission.
        let fullAudioStateAuthoritative: Bool
        let samples: [CallAudioProcessSample]
    }

    private static let pollInterval = Duration.seconds(2)
    private static let negativeBrowserProbeInterval: TimeInterval = 4
    /// Three consecutive bounded AX probe intervals. A single timeout/reconfiguration is tolerated;
    /// persistent loss of the trusted surface becomes end evidence even if audio remains active.
    private static let maximumSurfaceTrustUnknown: TimeInterval = 12
    private static let audioEvidenceQueue = DispatchQueue(
        label: "gg.zbs.eye.meeting-detector-core-audio",
        qos: .utility
    )
    private static let audioEvidenceTimeoutQueue = DispatchQueue(
        label: "gg.zbs.eye.meeting-detector-core-audio-watchdog",
        qos: .utility
    )
    private static let audioEvidencePollGate = AudioEvidencePollGate()
    private static let maximumAudioEvidencePollSeconds: TimeInterval = 1
    /// Longer than the 30-second end grace, so a transient CoreAudio reconfiguration can resume
    /// the same call without minting a new fingerprint before final save owns teardown.
    private static let activeSessionMissingRetention: TimeInterval = 60
    private let excludedBundleIDsProvider: ExcludedBundleIDsProvider
    private var pollTask: Task<Void, Never>?
    private var coreAudioListener: CoreAudioMicActivityListener?
    private var eventPollScheduled = false
    private var pollInProgress = false
    private var pollAgainRequested = false
    private var continuation: AsyncStream<CallEvidenceSnapshot>.Continuation?
    private var activeSession: ActiveSession?
    private var suppressedSessions: [String: SuppressedSession] = [:]
    private var suppressedMicrophoneOwners: [
        CallAudioOwnerKey: CallAudioSuppressedOwnerState
    ] = [:]
    private var lastSurfaceProbeAt: [SurfaceProbeKey: TimeInterval] = [:]
    private var lifecycleGeneration: UInt64 = 0

    init(
        excludedBundleIDs: @escaping ExcludedBundleIDsProvider = { [] }
    ) {
        excludedBundleIDsProvider = excludedBundleIDs
    }

    func start() -> AsyncStream<CallEvidenceSnapshot> {
        lifecycleGeneration &+= 1
        let (stream, cont) = AsyncStream<CallEvidenceSnapshot>.makeStream(
            // Positive microphone edges are terminally important: if MainActor is briefly busy,
            // a later idle snapshot must not overwrite the start that arrived first.
            bufferingPolicy: .unbounded
        )
        continuation = cont
        pollTask?.cancel()
        coreAudioListener?.stop()
        let listener = CoreAudioMicActivityListener { [weak self] in
            Task { await self?.coreAudioStateDidChange() }
        }
        coreAudioListener = listener
        listener.start()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick(now: Date())
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
        return stream
    }

    func stop() async {
        lifecycleGeneration &+= 1
        let tokens = Set(
            ([activeSession?.browserControlHandleToken]
                + suppressedSessions.values.map(\.browserControlHandleToken))
                .compactMap { $0 }
        )
        let nativeTokens = Set(
            ([activeSession?.nativeSurfaceHandleToken]
                + suppressedSessions.values.map(\.nativeSurfaceHandleToken))
                .compactMap { $0 }
        )
        pollTask?.cancel()
        pollTask = nil
        coreAudioListener?.stop()
        coreAudioListener = nil
        eventPollScheduled = false
        pollAgainRequested = false
        continuation?.finish()
        continuation = nil
        activeSession = nil
        suppressedSessions.removeAll()
        suppressedMicrophoneOwners.removeAll()
        lastSurfaceProbeAt.removeAll()
        for token in tokens {
            await BrowserCallSurfaceInspector.discardControl(token)
        }
        for token in nativeTokens {
            await NativeCallSurfaceInspector.discardSurface(token)
        }
    }

    /// Move only this exact detector identity out of the active slot. Other browsers/surfaces can
    /// be admitted immediately, while the rejected surface remains suppressed across route gaps.
    @discardableResult
    func suppressSession(
        fingerprint: String,
        resumeIfMicrophoneActive: Bool = false
    ) async -> MeetingSessionSuppressionResult {
        guard var session = activeSession, session.fingerprint == fingerprint else {
            return .suppressed
        }
        // Freeze A's ownership before the first suspension point. A regular detector poll may
        // observe successor B while the bounded HAL refresh below is awaiting; B must never be
        // folded into the set tombstoned by End & save for A.
        let ownerKeysAtSuppressionStart = session.ownerKeys
        let now = Self.monotonicNow()
        let stableIdleWasPreviouslyObserved = session.missingSince.map {
            now - $0 >= CallAudioOwnerSuppressionBoundary.minimumStableIdle
        } ?? false
        var freshActiveOwners: Set<CallAudioOwnerKey>?
        var freshCollectionSucceeded = false
        var freshIdleIsAuthoritative = false
        if resumeIfMicrophoneActive || stableIdleWasPreviouslyObserved {
            let bundleIDsByPID = await MainActor.run { Self.runningApplicationBundleIDs() }
            var freshCollection = AudioProcessCollection(
                succeeded: false,
                inputStateAuthoritative: false,
                fullAudioStateAuthoritative: false,
                samples: []
            )
            // A regular detector read may be crossing the same boundary. Give that bounded poll a
            // chance to release the single HAL gate, then retry without ever queuing C calls.
            for attempt in 0..<3 {
                freshCollection = await Self.collectAudioProcessEvidenceOffActor(
                    bundleIDsByPID: bundleIDsByPID
                )
                if freshCollection.succeeded { break }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(50)) }
            }
            guard let current = activeSession, current.fingerprint == fingerprint else {
                return .suppressed
            }
            session = current
            if freshCollection.succeeded {
                freshCollectionSucceeded = true
                freshIdleIsAuthoritative = freshCollection.inputStateAuthoritative
                let excludedBundleIDs = await excludedBundleIDsProvider()
                guard let current = activeSession, current.fingerprint == fingerprint else {
                    return .suppressed
                }
                session = current
                let groupedInputs = CallAudioProcessGrouping.groups(
                    from: freshCollection.samples
                )
                let unsuppressedInputs = CallAudioAutomaticAdmission.unsuppressedInputGroups(
                    from: groupedInputs,
                    excludedBundleIDs: excludedBundleIDs,
                    suppressedOwners: Set(suppressedMicrophoneOwners.keys)
                )
                freshActiveOwners = Set(
                    unsuppressedInputs.lazy.map(CallAudioOwnerKey.init)
                )
            } else if resumeIfMicrophoneActive {
                // The 30-second grace has already elapsed. A failed HAL read is unknown, not
                // positive microphone activity, so it cannot cancel the required timeout save and
                // create an endless sequence of fresh grace windows during a coreaudiod outage.
                scheduleImmediatePoll()
            }
        }

        if resumeIfMicrophoneActive,
           CoreAudioMicTimeoutRecheckPolicy.confirmsMicrophoneResume(
                collectionSucceeded: freshCollectionSucceeded,
                activeOwnerCount: freshActiveOwners?.count ?? 0
           ),
           let freshActiveOwners {
            session.missingSince = nil
            session.ownerKeys.formUnion(freshActiveOwners)
            activeSession = session
            scheduleImmediatePoll()
            return .activityResumed
        }

        lifecycleGeneration &+= 1
        for owner in ownerKeysAtSuppressionStart {
            let authoritativeIdleSince: TimeInterval?
            if freshIdleIsAuthoritative, let freshActiveOwners {
                authoritativeIdleSince = freshActiveOwners.contains(owner)
                    ? nil
                    : session.missingSince
            } else if stableIdleWasPreviouslyObserved {
                // A failed refresh cannot prove that an old idle timestamp still describes now.
                authoritativeIdleSince = nil
            } else {
                authoritativeIdleSince = session.missingSince
            }
            if let state = CallAudioOwnerSuppressionBoundary.stateWhenSuppressing(
                fingerprint: fingerprint,
                alreadyIdleSince: authoritativeIdleSince,
                now: now
            ) {
                suppressedMicrophoneOwners[owner] = state
            }
        }
        if session.nativeSurfaceHandleToken == nil,
           session.browserControlHandleToken == nil {
            activeSession = nil
            scheduleImmediatePoll()
            return .suppressed
        }
        suppressedSessions[session.surfaceKey] = SuppressedSession(
            rootPID: session.rootPID,
            bundleID: session.bundleID,
            kind: session.kind,
            fingerprint: session.fingerprint,
            surfaceKey: session.surfaceKey,
            nativeSurfaceHandleToken: session.nativeSurfaceHandleToken,
            browserControlHandleToken: session.browserControlHandleToken,
            browserService: session.browserService,
            browserSessionDiscriminator: session.browserSessionDiscriminator,
            browserAllowsCrossRootReconciliation:
                session.browserAllowsCrossRootReconciliation,
            inputAudioObjectIDs: session.inputAudioObjectIDs,
            outputAudioObjectIDs: session.outputAudioObjectIDs,
            controlEndedSince: nil,
            fullAudioBoundarySince: nil
        )
        activeSession = nil
        return .suppressed
    }

    func releaseSession(fingerprint: String? = nil) async {
        if let fingerprint {
            lifecycleGeneration &+= 1
            var browserTokens: Set<String> = []
            var nativeTokens: Set<String> = []
            if activeSession?.fingerprint == fingerprint {
                if let token = activeSession?.browserControlHandleToken {
                    browserTokens.insert(token)
                }
                if let token = activeSession?.nativeSurfaceHandleToken {
                    nativeTokens.insert(token)
                }
                activeSession = nil
            }
            let matchingSurfaceKeys = suppressedSessions.compactMap { key, session in
                session.fingerprint == fingerprint ? key : nil
            }
            for key in matchingSurfaceKeys {
                if let session = suppressedSessions.removeValue(forKey: key) {
                    if let token = session.browserControlHandleToken {
                        browserTokens.insert(token)
                    }
                    if let token = session.nativeSurfaceHandleToken {
                        nativeTokens.insert(token)
                    }
                }
            }
            suppressedMicrophoneOwners = suppressedMicrophoneOwners.filter {
                $0.value.fingerprint != fingerprint
            }
            for token in browserTokens {
                await BrowserCallSurfaceInspector.discardControl(token)
            }
            for token in nativeTokens {
                await NativeCallSurfaceInspector.discardSurface(token)
            }
            return
        }
        lifecycleGeneration &+= 1
        let tokens = Set(
            ([activeSession?.browserControlHandleToken]
                + suppressedSessions.values.map(\.browserControlHandleToken))
                .compactMap { $0 }
        )
        let nativeTokens = Set(
            ([activeSession?.nativeSurfaceHandleToken]
                + suppressedSessions.values.map(\.nativeSurfaceHandleToken))
                .compactMap { $0 }
        )
        activeSession = nil
        suppressedSessions.removeAll()
        suppressedMicrophoneOwners.removeAll()
        for token in tokens {
            await BrowserCallSurfaceInspector.discardControl(token)
        }
        for token in nativeTokens {
            await NativeCallSurfaceInspector.discardSurface(token)
        }
    }

    func tick(now: Date) async {
        guard !pollInProgress else {
            pollAgainRequested = true
            return
        }
        pollInProgress = true
        var requestedNow = now
        // One event arriving during a HAL read gets one immediate follow-up. Further storms are
        // bounded and fall back to the next two-second reconciliation instead of creating a queue.
        for _ in 0..<2 {
            pollAgainRequested = false
            await performTick(now: requestedNow)
            guard pollAgainRequested else { break }
            requestedNow = Date()
        }
        pollAgainRequested = false
        pollInProgress = false
    }

    /// Runtime settings hook. AppEnvironment can call this from the exclusion-store callback;
    /// the provider is re-read on the resulting poll, so no detector restart is required.
    func autoCallExclusionsDidChange() {
        automaticCallAdmissionDidChange()
    }

    /// Re-probes current owners when an audio hard gate or capture permission changes. Sessions
    /// observed while admission was closed are released by AppEnvironment rather than tombstoned,
    /// so the same still-active microphone can qualify immediately when the gate opens.
    func automaticCallAdmissionDidChange() {
        // Invalidate any HAL result that captured the previous admission configuration. The queued
        // follow-up poll re-reads exact exclusions and current owners before yielding evidence.
        lifecycleGeneration &+= 1
        scheduleImmediatePoll()
    }

    /// Sleep/wake integration seam. The listener re-establishes HAL registrations before asking
    /// the normal bounded poll path to read current microphone ownership.
    func systemDidWake() {
        coreAudioListener?.refreshAfterWake()
    }

    private func coreAudioStateDidChange() {
        scheduleImmediatePoll()
    }

    private func scheduleImmediatePoll() {
        guard continuation != nil else { return }
        guard !eventPollScheduled else {
            pollAgainRequested = true
            return
        }
        eventPollScheduled = true
        Task { [weak self] in
            guard let self else { return }
            await self.runScheduledPoll()
        }
    }

    private func runScheduledPoll() async {
        guard eventPollScheduled else { return }
        eventPollScheduled = false
        await tick(now: Date())
    }

    private func performTick(now: Date) async {
        let tickGeneration = lifecycleGeneration
        let evidence = await collectEvidence(
            now: now,
            monotonicNow: Self.monotonicNow(),
            expectedGeneration: tickGeneration
        )
        guard lifecycleGeneration == tickGeneration else { return }
        continuation?.yield(evidence)
    }

    /// Testing/diagnostic seam: one raw strong-evidence pass with no lifecycle side effects.
    static func detectRaw() async -> Bool {
        let detector = MeetingDetector()
        let evidence = await detector.collectEvidence(
            now: Date(),
            monotonicNow: Self.monotonicNow(),
            expectedGeneration: 0
        )
        await detector.stop()
        return evidence.surface?.marker != nil
    }

    private func collectEvidence(
        now: Date,
        monotonicNow: TimeInterval,
        expectedGeneration: UInt64
    ) async -> CallEvidenceSnapshot {
        let observedAt = now.timeIntervalSince1970
        guard lifecycleGeneration == expectedGeneration, !Task.isCancelled else {
            return Self.idleEvidence(now: observedAt, monotonicNow: monotonicNow)
        }
        let bundleIDsByPID = await MainActor.run { Self.runningApplicationBundleIDs() }
        guard lifecycleGeneration == expectedGeneration, !Task.isCancelled else {
            return Self.idleEvidence(now: observedAt, monotonicNow: monotonicNow)
        }
        let collection = await Self.collectAudioProcessEvidenceOffActor(
            bundleIDsByPID: bundleIDsByPID
        )
        guard lifecycleGeneration == expectedGeneration, !Task.isCancelled else {
            return Self.idleEvidence(now: observedAt, monotonicNow: monotonicNow)
        }

        guard collection.succeeded else {
            return staleEvidence(now: observedAt, monotonicNow: monotonicNow)
        }

        let allGroups = CallAudioProcessGrouping.groups(from: collection.samples)
        let excludedBundleIDs = await excludedBundleIDsProvider()
        guard lifecycleGeneration == expectedGeneration, !Task.isCancelled else {
            return Self.idleEvidence(now: observedAt, monotonicNow: monotonicNow)
        }
        let groups = allGroups.filter {
            $0.ownerBundleIDIsSynthetic || !excludedBundleIDs.contains($0.ownerBundleID)
        }
        let activeOwnerKeys = Set(
            allGroups.lazy
                .filter { $0.inputActive && $0.automaticCallOwnerRole == .initiator }
                .map(CallAudioOwnerKey.init)
        )
        let negativeSuppressionMutationPermitted =
            CoreAudioMicEvidenceAuthorityPolicy.permitsNegativeSuppressionMutation(
                collectionSucceeded: collection.succeeded,
                inputStateAuthoritative: collection.inputStateAuthoritative
            )
        let fullAudioSuppressionMutationPermitted =
            CoreAudioMicEvidenceAuthorityPolicy.permitsFullAudioSuppressionMutation(
                collectionSucceeded: collection.succeeded,
                fullAudioStateAuthoritative: collection.fullAudioStateAuthoritative
            )
        if negativeSuppressionMutationPermitted, !suppressedMicrophoneOwners.isEmpty {
            suppressedMicrophoneOwners = CallAudioOwnerSuppressionBoundary.reconcile(
                suppressedMicrophoneOwners,
                activeOwners: activeOwnerKeys,
                now: monotonicNow
            )
        }
        let inputGroups = CallAudioAutomaticAdmission.eligibleInputGroups(
            from: groups,
            excludedBundleIDs: excludedBundleIDs
        )
        let unsuppressedInputGroups = CallAudioAutomaticAdmission.unsuppressedInputGroups(
            from: groups,
            excludedBundleIDs: excludedBundleIDs,
            suppressedOwners: Set(suppressedMicrophoneOwners.keys)
        )
        pruneProbeCache(for: groups)
        if fullAudioSuppressionMutationPermitted {
            await updateSuppressedSessions(
                groups: groups,
                runningBundleIDsByPID: bundleIDsByPID,
                now: monotonicNow
            )
            guard lifecycleGeneration == expectedGeneration, !Task.isCancelled else {
                return Self.idleEvidence(now: observedAt, monotonicNow: monotonicNow)
            }
        }

        // Trust available positive input samples, but never interpret a partial per-object HAL read
        // as global idle. The bounded stale policy keeps an active Call together while the two-second
        // fallback and service-restart listeners rebuild authoritative process objects.
        if CoreAudioMicEvidenceAuthorityPolicy.requiresStaleSnapshot(
            inputStateAuthoritative: collection.inputStateAuthoritative,
            unsuppressedPositiveOwnerCount: unsuppressedInputGroups.count
        ) {
            return staleEvidence(now: observedAt, monotonicNow: monotonicNow)
        }

        // Universal mic admission is deliberately first. AX/native/browser inspection below is
        // retained as optional enrichment and legacy suppression machinery, never as a start gate.
        if var session = activeSession {
            if let primary = CallAudioAutomaticAdmission.preferredGroup(
                from: unsuppressedInputGroups
            ) {
                session.rootPID = primary.rootPID
                session.bundleID = primary.ownerBundleID
                session.kind = primary.ownerKind
                session.ownerKeys.formUnion(
                    unsuppressedInputGroups.map(CallAudioOwnerKey.init)
                )
                session.missingSince = nil
                session.surfaceConfirmed = true
                session.surfaceTrustUnknownSince = nil
                session.inputAudioObjectIDs = primary.inputAudioObjectIDs
                session.outputAudioObjectIDs = primary.outputAudioObjectIDs
                activeSession = session
                return await enrichedMicrophoneActivityEvidence(
                    now: observedAt,
                    monotonicNow: monotonicNow,
                    group: primary,
                    fingerprint: session.fingerprint,
                    expectedGeneration: expectedGeneration
                )
            }

            switch CallAudioSessionLiveness.decide(
                hasRequiredAudio: false,
                missingSince: session.missingSince,
                now: monotonicNow,
                maximumMissingRetention: Self.activeSessionMissingRetention
            ) {
            case .continueActive:
                assertionFailure("Missing universal mic input cannot be active")
                return Self.retainedMissingEvidence(
                    now: observedAt,
                    monotonicNow: monotonicNow,
                    fingerprint: session.fingerprint
                )
            case let .retainMissing(since):
                session.missingSince = since
                activeSession = session
                return Self.retainedMissingEvidence(
                    now: observedAt,
                    monotonicNow: monotonicNow,
                    fingerprint: session.fingerprint
                )
            case .release:
                let browserToken = session.browserControlHandleToken
                let nativeToken = session.nativeSurfaceHandleToken
                activeSession = nil
                await BrowserCallSurfaceInspector.discardControl(browserToken)
                await NativeCallSurfaceInspector.discardSurface(nativeToken)
                return suppressedOrIdleEvidence(
                    now: observedAt,
                    monotonicNow: monotonicNow
                )
            }
        }

        if let primary = CallAudioAutomaticAdmission.preferredGroup(
            from: unsuppressedInputGroups
        ) {
            let fingerprint = Self.newSessionFingerprint(
                group: primary,
                surfaceDiscriminator: "microphone",
                originHost: nil
            )
            let surfaceKey = Self.surfaceKey(
                group: primary,
                surfaceDiscriminator: "microphone",
                originHost: nil
            )
            activeSession = ActiveSession(
                rootPID: primary.rootPID,
                bundleID: primary.ownerBundleID,
                kind: primary.ownerKind,
                fingerprint: fingerprint,
                surfaceKey: surfaceKey,
                ownerKeys: Set(unsuppressedInputGroups.map(CallAudioOwnerKey.init)),
                missingSince: nil,
                surfaceConfirmed: true,
                surfaceTrustUnknownSince: nil,
                inputAudioObjectIDs: primary.inputAudioObjectIDs,
                outputAudioObjectIDs: primary.outputAudioObjectIDs,
                nativeSurfaceHandleToken: nil,
                browserControlHandleToken: nil,
                browserService: nil,
                browserSessionDiscriminator: nil,
                browserAllowsCrossRootReconciliation: false
            )
            return Self.microphoneActivityEvidence(
                now: observedAt,
                monotonicNow: monotonicNow,
                group: primary,
                fingerprint: fingerprint
            )
        }

        if let suppressedGroup = CallAudioAutomaticAdmission.preferredGroup(
            from: inputGroups.filter {
                suppressedMicrophoneOwners[CallAudioOwnerKey(group: $0)] != nil
            }
        ),
           let fingerprint = suppressedMicrophoneOwners[
                CallAudioOwnerKey(group: suppressedGroup)
           ]?.fingerprint {
            var evidence = Self.microphoneActivityEvidence(
                now: observedAt,
                monotonicNow: monotonicNow,
                group: suppressedGroup,
                fingerprint: fingerprint
            )
            // This owner remains observable so the current suppression can prove its later idle,
            // but it is never a successor candidate while its per-owner tombstone is alive.
            evidence.isRetainedMissing = true
            return evidence
        }
        if !suppressedMicrophoneOwners.isEmpty,
           let fingerprint = suppressedMicrophoneOwners.values
                .map(\.fingerprint)
                .sorted()
                .first {
            return Self.retainedMissingEvidence(
                now: observedAt,
                monotonicNow: monotonicNow,
                fingerprint: fingerprint
            )
        }

        if var activeSession {
            let activeFingerprint = activeSession.fingerprint
            let activeGroup = groups.first(where: {
                $0.rootPID == activeSession.rootPID
                    && $0.ownerBundleID == activeSession.bundleID
                    && $0.ownerKind == activeSession.kind
            })
            let continuationAudio = CallAudioContinuationEvidence.evaluate(
                kind: activeSession.kind,
                group: activeGroup
            )

            let browserAudioCarriersFullyReplaced = CallAudioCarrierBaseline(
                inputAudioObjectIDs: activeSession.inputAudioObjectIDs,
                outputAudioObjectIDs: activeSession.outputAudioObjectIDs
            ).isFullyReplaced(
                by: activeGroup,
                kind: activeSession.kind
            )
            if BrowserControlLifecycle.establishesSuccessorBoundary(
                state: .active,
                audioCarriersFullyReplaced: browserAudioCarriersFullyReplaced
            ) {
                // Both required HAL carrier sets disappeared while fresh two-sided browser audio
                // is already active. That is an authoritative A -> B boundary even when a Chromium
                // SPA reuses the exact same AX Leave button. Retire A before publishing any evidence
                // from B and before the normal AX probe throttle can defer revalidation.
                let token = activeSession.browserControlHandleToken
                let nativeToken = activeSession.nativeSurfaceHandleToken
                self.activeSession = nil
                lastSurfaceProbeAt.removeValue(
                    forKey: SurfaceProbeKey(
                        rootPID: activeSession.rootPID,
                        bundleID: activeSession.bundleID
                    )
                )
                await BrowserCallSurfaceInspector.discardControl(token)
                await NativeCallSurfaceInspector.discardSurface(nativeToken)
                return suppressedOrIdleEvidence(
                    now: observedAt,
                    monotonicNow: monotonicNow
                )
            }

            var latestSurfaceMatch: Bool?
            var surfaceTrustReadFailed = false
            if continuationAudio.hasContinuationAudio,
               let activeGroup,
               shouldProbeSurface(activeGroup, now: monotonicNow) {
                // Audio is only the cheap gate. Re-confirm the exact surface periodically so a
                // browser assistant mic plus podcast cannot keep yesterday's call alive forever.
                let revalidation = await activeSurfaceStillMatches(
                    activeSession,
                    group: activeGroup
                )
                // Actor reentrancy: release/suppress may run while AX inspection is awaiting.
                // Never write the captured session back after its lifecycle owner removed it.
                guard self.activeSession?.fingerprint == activeFingerprint else {
                    if let replacement = revalidation.replacementControlHandleToken {
                        await discardControlHandleIfUnretained(replacement)
                    }
                    if let replacement = revalidation.replacementNativeSurfaceHandleToken {
                        await discardNativeSurfaceIfUnretained(replacement)
                    }
                    return suppressedOrIdleEvidence(
                        now: observedAt,
                        monotonicNow: monotonicNow
                    )
                }
                latestSurfaceMatch = revalidation.match
                surfaceTrustReadFailed = revalidation.trustReadFailed
                if revalidation.terminalBoundary {
                    let token = activeSession.browserControlHandleToken
                    let nativeToken = activeSession.nativeSurfaceHandleToken
                    self.activeSession = nil
                    lastSurfaceProbeAt.removeValue(
                        forKey: SurfaceProbeKey(
                            rootPID: activeSession.rootPID,
                            bundleID: activeSession.bundleID
                        )
                    )
                    await BrowserCallSurfaceInspector.discardControl(token)
                    await NativeCallSurfaceInspector.discardSurface(nativeToken)
                    return suppressedOrIdleEvidence(
                        now: observedAt,
                        monotonicNow: monotonicNow
                    )
                }
                if let replacement = revalidation.replacementControlHandleToken {
                    let previous = activeSession.browserControlHandleToken
                    activeSession.browserControlHandleToken = replacement
                    if let replacementSurfaceKey = revalidation.replacementSurfaceKey {
                        activeSession.surfaceKey = replacementSurfaceKey
                    }
                    // Publish the replacement capability before the first suspension. A concurrent
                    // suppress/release then owns the new token instead of capturing the stale one.
                    self.activeSession = activeSession
                    if previous != replacement {
                        await BrowserCallSurfaceInspector.discardControl(previous)
                        guard let current = self.activeSession,
                              current.fingerprint == activeFingerprint
                        else {
                            return suppressedOrIdleEvidence(
                                now: observedAt,
                                monotonicNow: monotonicNow
                            )
                        }
                        activeSession = current
                    }
                }
                if let replacement = revalidation.replacementNativeSurfaceHandleToken {
                    let previous = activeSession.nativeSurfaceHandleToken
                    activeSession.nativeSurfaceHandleToken = replacement
                    if let replacementSurfaceKey = revalidation.replacementSurfaceKey {
                        activeSession.surfaceKey = replacementSurfaceKey
                    }
                    self.activeSession = activeSession
                    if previous != replacement {
                        await NativeCallSurfaceInspector.discardSurface(previous)
                        guard let current = self.activeSession,
                              current.fingerprint == activeFingerprint
                        else {
                            return suppressedOrIdleEvidence(
                                now: observedAt,
                                monotonicNow: monotonicNow
                            )
                        }
                        activeSession = current
                    }
                }
                if latestSurfaceMatch == true {
                    let refreshedBaseline = CallAudioCarrierBaseline(
                        inputAudioObjectIDs: activeSession.inputAudioObjectIDs,
                        outputAudioObjectIDs: activeSession.outputAudioObjectIDs
                    ).refreshingConfirmedSide(from: activeGroup)
                    activeSession.inputAudioObjectIDs = refreshedBaseline.inputAudioObjectIDs
                    activeSession.outputAudioObjectIDs = refreshedBaseline.outputAudioObjectIDs
                }
            }
            let trust = CallSurfaceTrustWindow.decide(
                previouslyConfirmed: activeSession.surfaceConfirmed,
                latestSurfaceMatch: latestSurfaceMatch,
                trustReadFailed: surfaceTrustReadFailed,
                unknownSince: activeSession.surfaceTrustUnknownSince,
                now: monotonicNow,
                maximumUnknown: Self.maximumSurfaceTrustUnknown
            )
            activeSession.surfaceConfirmed = trust.surfaceConfirmed
            activeSession.surfaceTrustUnknownSince = trust.unknownSince

            switch CallAudioSessionLiveness.decide(
                hasRequiredAudio: continuationAudio.hasContinuationAudio && trust.surfaceConfirmed,
                missingSince: activeSession.missingSince,
                now: monotonicNow,
                maximumMissingRetention: Self.activeSessionMissingRetention
            ) {
            case .continueActive:
                guard let activeGroup else {
                    assertionFailure("Active liveness requires an audio group")
                    let token = activeSession.browserControlHandleToken
                    let nativeToken = activeSession.nativeSurfaceHandleToken
                    self.activeSession = nil
                    await BrowserCallSurfaceInspector.discardControl(token)
                    await NativeCallSurfaceInspector.discardSurface(nativeToken)
                    return Self.idleEvidence(now: observedAt, monotonicNow: monotonicNow)
                }
                activeSession.missingSince = nil
                self.activeSession = activeSession
                return Self.continuingEvidence(
                    now: observedAt,
                    monotonicNow: monotonicNow,
                    group: activeGroup,
                    fingerprint: activeSession.fingerprint
                )

            case let .retainMissing(since):
                activeSession.missingSince = since
                self.activeSession = activeSession
                return Self.retainedMissingEvidence(
                    now: observedAt,
                    monotonicNow: monotonicNow,
                    fingerprint: activeSession.fingerprint
                )

            case .release:
                let token = activeSession.browserControlHandleToken
                let nativeToken = activeSession.nativeSurfaceHandleToken
                self.activeSession = nil
                await BrowserCallSurfaceInspector.discardControl(token)
                await NativeCallSurfaceInspector.discardSurface(nativeToken)
                return suppressedOrIdleEvidence(
                    now: observedAt,
                    monotonicNow: monotonicNow
                )
            }
        }

        var nativeFallback: CallEvidenceSnapshot?
        for group in groups where group.ownerKind == .native && group.inputActive {
            let matchingSuppressed = suppressedSessions.filter { _, session in
                session.kind == .native
                    && session.rootPID == group.rootPID
                    && session.bundleID == group.ownerBundleID
            }
            guard NativeSurfaceLifecycle.allowsSuccessor(
                suppressedSessionCount: matchingSuppressed.count
            ) else {
                continue
            }
            let excludedSurfaceTokens = Set(
                matchingSuppressed.values.compactMap(\.nativeSurfaceHandleToken)
            )
            let inspectionGeneration = lifecycleGeneration
            let inspection = await NativeCallSurfaceInspector.inspect(
                pid: pid_t(group.rootPID),
                bundleID: group.ownerBundleID,
                excludingSurfaceTokens: excludedSurfaceTokens
            )
            guard lifecycleGeneration == inspectionGeneration,
                  activeSession == nil
            else {
                await NativeCallSurfaceInspector.discardSurface(
                    inspection.surfaceHandleToken
                )
                return suppressedOrIdleEvidence(
                    now: observedAt,
                    monotonicNow: monotonicNow
                )
            }
            let marker: CallStateMarker? = inspection.hasCallSignature
                ? .nativeCallControls
                : nil
            let candidate = Self.nativeEvidence(
                now: observedAt,
                monotonicNow: monotonicNow,
                group: group,
                marker: marker,
                fingerprint: Self.candidateFingerprint(for: group)
            )
            guard marker != nil else {
                if nativeFallback == nil { nativeFallback = candidate }
                continue
            }
            guard let nativeSurfaceToken = inspection.surfaceHandleToken else {
                continue
            }

            let pinGeneration = lifecycleGeneration
            guard await NativeCallSurfaceInspector.pinSurface(nativeSurfaceToken) else {
                await NativeCallSurfaceInspector.discardSurface(nativeSurfaceToken)
                continue
            }
            guard lifecycleGeneration == pinGeneration, activeSession == nil else {
                await discardNativeSurfaceIfUnretained(nativeSurfaceToken)
                return suppressedOrIdleEvidence(
                    now: observedAt,
                    monotonicNow: monotonicNow
                )
            }

            let fingerprint = Self.newSessionFingerprint(
                group: group,
                surfaceDiscriminator: nativeSurfaceToken,
                originHost: nil
            )
            let surfaceKey = Self.surfaceKey(
                group: group,
                surfaceDiscriminator: nativeSurfaceToken,
                originHost: nil
            )
            guard !isSuppressed(surfaceKey: surfaceKey) else {
                await NativeCallSurfaceInspector.discardSurface(nativeSurfaceToken)
                continue
            }
            activeSession = ActiveSession(
                rootPID: group.rootPID,
                bundleID: group.ownerBundleID,
                kind: .native,
                fingerprint: fingerprint,
                surfaceKey: surfaceKey,
                ownerKeys: [CallAudioOwnerKey(group: group)],
                missingSince: nil,
                surfaceConfirmed: true,
                surfaceTrustUnknownSince: nil,
                inputAudioObjectIDs: group.inputAudioObjectIDs,
                outputAudioObjectIDs: group.outputAudioObjectIDs,
                nativeSurfaceHandleToken: nativeSurfaceToken,
                browserControlHandleToken: nil,
                browserService: nil,
                browserSessionDiscriminator: nil,
                browserAllowsCrossRootReconciliation: false
            )
            return Self.nativeEvidence(
                now: observedAt,
                monotonicNow: monotonicNow,
                group: group,
                marker: marker,
                fingerprint: fingerprint
            )
        }

        let browserGroups = groups.filter {
            $0.ownerKind == .browser && $0.inputActive && $0.outputActive
        }
        let groupsToProbe = browserGroups.filter {
            shouldProbeSurface($0, now: monotonicNow)
        }
        var excludedTokensByIdentity: [SurfaceProbeKey: Set<String>] = [:]
        for session in suppressedSessions.values {
            guard session.kind == .browser,
                  let token = session.browserControlHandleToken
            else { continue }
            let key = SurfaceProbeKey(
                rootPID: session.rootPID,
                bundleID: session.bundleID
            )
            excludedTokensByIdentity[key, default: []].insert(token)
        }
        let probeGeneration = lifecycleGeneration
        let probeResults = await Self.inspectBrowserGroups(
            groupsToProbe,
            excludingControlTokensByIdentity: excludedTokensByIdentity
        )
        guard MeetingDetectorLifecycleFence.permitsAdmission(
            probeGeneration: probeGeneration,
            currentGeneration: lifecycleGeneration,
            hasActiveSession: activeSession != nil
        ) else {
            await discardUnretainedControlHandles(in: probeResults)
            return suppressedOrIdleEvidence(
                now: observedAt,
                monotonicNow: monotonicNow
            )
        }

        for result in probeResults {
            Self.logBrowserProbe(result)
            let reconciledSuppressedRoot = await reconcileSuppressedRootReplacement(result)
            // Reconciliation may suspend while pinning/discarding an AX capability. A concurrent
            // stop/release invalidates the *whole* probe batch; never capture a fresh generation
            // after that suspension and admit a later result from this stale batch.
            guard MeetingDetectorLifecycleFence.permitsAdmission(
                probeGeneration: probeGeneration,
                currentGeneration: lifecycleGeneration,
                hasActiveSession: activeSession != nil
            ) else {
                await discardUnretainedControlHandles(in: probeResults)
                return suppressedOrIdleEvidence(
                    now: observedAt,
                    monotonicNow: monotonicNow
                )
            }
            if reconciledSuppressedRoot {
                continue
            }
            let inspection = result.inspection
            guard inspection.isTrustedCall,
                  let origin = inspection.trustedOrigin,
                  let controlHandleToken = inspection.controlHandleToken
            else { continue }

            let fingerprint = Self.newSessionFingerprint(
                group: result.group,
                surfaceDiscriminator: controlHandleToken,
                originHost: origin.host
            )
            guard let admittedEvidence = BrowserCallAdmission.evidence(
                group: result.group,
                inspection: inspection,
                observedAt: observedAt,
                monotonicNow: monotonicNow,
                fingerprint: fingerprint
            ) else {
                continue
            }
            let surfaceKey = Self.surfaceKey(
                group: result.group,
                surfaceDiscriminator: controlHandleToken,
                originHost: origin.host
            )
            guard !isSuppressed(surfaceKey: surfaceKey) else { continue }
            let pinGeneration = lifecycleGeneration
            guard await BrowserCallSurfaceInspector.pinControl(controlHandleToken) else {
                await BrowserCallSurfaceInspector.discardControl(controlHandleToken)
                continue
            }
            guard lifecycleGeneration == pinGeneration, activeSession == nil else {
                await discardControlHandleIfUnretained(controlHandleToken)
                await discardUnretainedControlHandles(in: probeResults)
                return suppressedOrIdleEvidence(
                    now: observedAt,
                    monotonicNow: monotonicNow
                )
            }
            activeSession = ActiveSession(
                rootPID: result.group.rootPID,
                bundleID: result.group.ownerBundleID,
                kind: .browser,
                fingerprint: fingerprint,
                surfaceKey: surfaceKey,
                ownerKeys: [CallAudioOwnerKey(group: result.group)],
                missingSince: nil,
                surfaceConfirmed: true,
                surfaceTrustUnknownSince: nil,
                inputAudioObjectIDs: result.group.inputAudioObjectIDs,
                outputAudioObjectIDs: result.group.outputAudioObjectIDs,
                nativeSurfaceHandleToken: nil,
                browserControlHandleToken: controlHandleToken,
                browserService: inspection.service,
                browserSessionDiscriminator: inspection.sessionDiscriminator,
                browserAllowsCrossRootReconciliation:
                    inspection.allowsCrossRootReconciliation
            )
            let browser = Self.browserClass(for: result.group.ownerBundleID)
            let service = inspection.service?.rawValue ?? "unknown"
            let fingerprintPrefix = String(fingerprint.prefix(12))
            Log.meetingDetection.debug(
                "browser_call_confirmed browser=\(browser, privacy: .public) service=\(service, privacy: .public) fingerprint=\(fingerprintPrefix, privacy: .public)"
            )
            await discardUnretainedControlHandles(in: probeResults)
            guard activeSession?.fingerprint == fingerprint else {
                return suppressedOrIdleEvidence(
                    now: observedAt,
                    monotonicNow: monotonicNow
                )
            }
            return admittedEvidence
        }

        await discardUnretainedControlHandles(in: probeResults)
        if let nativeFallback {
            return nativeFallback
        }
        if let browserFallback = groups.first(where: {
            $0.ownerKind == .browser && $0.inputActive
        }) {
            return Self.browserCandidateEvidence(
                now: observedAt,
                monotonicNow: monotonicNow,
                group: browserFallback
            )
        }
        return suppressedOrIdleEvidence(now: observedAt, monotonicNow: monotonicNow)
    }

    private func staleEvidence(
        now: TimeInterval,
        monotonicNow: TimeInterval
    ) -> CallEvidenceSnapshot {
        CallEvidenceSnapshot(
            now: now,
            monotonicNow: monotonicNow,
            microphoneOwnerBundleID: nil,
            surface: nil,
            microphoneAudioActive: false,
            systemAudioActive: false,
            calendarHint: false,
            isStale: true,
            fingerprint: activeSession?.fingerprint ?? "stale"
        )
    }

    private func shouldProbeSurface(
        _ group: CallAudioApplicationGroup,
        now: TimeInterval
    ) -> Bool {
        let key = SurfaceProbeKey(rootPID: group.rootPID, bundleID: group.ownerBundleID)
        if let previous = lastSurfaceProbeAt[key],
           now - previous < Self.negativeBrowserProbeInterval {
            return false
        }
        lastSurfaceProbeAt[key] = now
        return true
    }

    private func pruneProbeCache(for groups: [CallAudioApplicationGroup]) {
        let liveKeys = Set(groups.lazy.filter {
            $0.hasAnyAudioSession
        }.map {
            SurfaceProbeKey(rootPID: $0.rootPID, bundleID: $0.ownerBundleID)
        })
        lastSurfaceProbeAt = lastSurfaceProbeAt.filter { liveKeys.contains($0.key) }
    }

    private func activeSurfaceStillMatches(
        _ session: ActiveSession,
        group: CallAudioApplicationGroup
    ) async -> ActiveSurfaceRevalidation {
        switch session.kind {
        case .generic:
            return ActiveSurfaceRevalidation(
                match: true,
                replacementControlHandleToken: nil,
                replacementNativeSurfaceHandleToken: nil,
                replacementSurfaceKey: nil
            )

        case .native:
            guard let token = session.nativeSurfaceHandleToken else {
                return ActiveSurfaceRevalidation(
                    match: nil,
                    replacementControlHandleToken: nil,
                    replacementNativeSurfaceHandleToken: nil,
                    replacementSurfaceKey: nil,
                    trustReadFailed: true
                )
            }
            let state = await NativeCallSurfaceInspector.revalidateSurface(token)
            guard self.activeSession?.fingerprint == session.fingerprint else {
                return ActiveSurfaceRevalidation(
                    match: nil,
                    replacementControlHandleToken: nil,
                    replacementNativeSurfaceHandleToken: nil,
                    replacementSurfaceKey: nil
                )
            }
            switch state {
            case .active, .obscured, .ended:
                return ActiveSurfaceRevalidation(
                    // `.obscured` is positive continuity for the exact retained root and clears
                    // any earlier transient AX-failure timer.
                    match: state.directSurfaceMatch,
                    replacementControlHandleToken: nil,
                    replacementNativeSurfaceHandleToken: nil,
                    replacementSurfaceKey: nil
                )
            case .unknown:
                return ActiveSurfaceRevalidation(
                    match: nil,
                    replacementControlHandleToken: nil,
                    replacementNativeSurfaceHandleToken: nil,
                    replacementSurfaceKey: nil,
                    trustReadFailed: true
                )
            case .invalidated:
                let inspection = await NativeCallSurfaceInspector.inspect(
                    pid: pid_t(group.rootPID),
                    bundleID: group.ownerBundleID,
                    excludingSurfaceTokens: [token]
                )
                guard self.activeSession?.fingerprint == session.fingerprint else {
                    await NativeCallSurfaceInspector.discardSurface(
                        inspection.surfaceHandleToken
                    )
                    return ActiveSurfaceRevalidation(
                        match: nil,
                        replacementControlHandleToken: nil,
                        replacementNativeSurfaceHandleToken: nil,
                        replacementSurfaceKey: nil
                    )
                }
                // A different native window in the same PID may be the next call, not a toolbar
                // rebuild. Never pin/rebind it under the old fingerprint. Close A first; a later
                // fresh probe may admit B with its own opaque token and fingerprint.
                await NativeCallSurfaceInspector.discardSurface(
                    inspection.surfaceHandleToken
                )
                let match = NativeSurfaceLifecycle.invalidatedSurfaceMatch(
                    replacementHasCallSignature: inspection.hasCallSignature,
                    authoritativeNoMatch: inspection.authoritativeNoMatch
                )
                return ActiveSurfaceRevalidation(
                    match: match,
                    replacementControlHandleToken: nil,
                    replacementNativeSurfaceHandleToken: nil,
                    replacementSurfaceKey: nil,
                    trustReadFailed: match == nil
                )
            }

        case .browser:
            var retainedControlState: BrowserCallControlState?
            let audioCarriersFullyReplaced = CallAudioCarrierBaseline(
                inputAudioObjectIDs: session.inputAudioObjectIDs,
                outputAudioObjectIDs: session.outputAudioObjectIDs
            ).isFullyReplaced(
                by: group,
                kind: session.kind
            )
            if let token = session.browserControlHandleToken {
                let controlState = await BrowserCallSurfaceInspector.revalidateControl(
                    token,
                    allowRootRebind: !audioCarriersFullyReplaced
                )
                retainedControlState = controlState
                guard self.activeSession?.fingerprint == session.fingerprint else {
                    return ActiveSurfaceRevalidation(
                        match: nil,
                        replacementControlHandleToken: nil,
                        replacementNativeSurfaceHandleToken: nil,
                        replacementSurfaceKey: nil
                    )
                }
                if BrowserControlLifecycle.establishesSuccessorBoundary(
                    state: controlState,
                    audioCarriersFullyReplaced: audioCarriersFullyReplaced
                ) {
                    return ActiveSurfaceRevalidation(
                        match: false,
                        replacementControlHandleToken: nil,
                        replacementNativeSurfaceHandleToken: nil,
                        replacementSurfaceKey: nil,
                        terminalBoundary: true
                    )
                }
                if let match = BrowserControlLifecycle.activeMatch(
                    state: controlState,
                    audioCarriersFullyReplaced: audioCarriersFullyReplaced
                ), match || !audioCarriersFullyReplaced {
                    return ActiveSurfaceRevalidation(
                        match: match,
                        replacementControlHandleToken: nil,
                        replacementNativeSurfaceHandleToken: nil,
                        replacementSurfaceKey: nil
                    )
                }
            }

            let inspection = await BrowserCallSurfaceInspector.inspect(pid: pid_t(group.rootPID))
            guard self.activeSession?.fingerprint == session.fingerprint else {
                if let provisional = inspection.controlHandleToken {
                    await discardControlHandleIfUnretained(provisional)
                }
                return ActiveSurfaceRevalidation(
                    match: nil,
                    replacementControlHandleToken: nil,
                    replacementNativeSurfaceHandleToken: nil,
                    replacementSurfaceKey: nil
                )
            }
            Self.logBrowserProbe(BrowserProbeResult(group: group, inspection: inspection))
            let sameSurface: Bool
            let terminalBoundary: Bool
            if inspection.isTrustedCall,
               let controlHandleToken = inspection.controlHandleToken {
                let identityMatches = BrowserSurfaceIdentity.matches(
                    expectedService: session.browserService,
                    expectedDiscriminator: session.browserSessionDiscriminator,
                    expectedAllowsCrossRootReconciliation:
                        session.browserAllowsCrossRootReconciliation,
                    observedService: inspection.service,
                    observedDiscriminator: inspection.sessionDiscriminator,
                    observedAllowsCrossRootReconciliation:
                        inspection.allowsCrossRootReconciliation
                )
                sameSurface = BrowserControlLifecycle.permitsCrossRootAdoption(
                    identityMatches: identityMatches,
                    audioCarriersFullyReplaced: audioCarriersFullyReplaced
                )
                terminalBoundary = identityMatches && audioCarriersFullyReplaced
                if sameSurface,
                   controlHandleToken != session.browserControlHandleToken {
                    let pinned = await BrowserCallSurfaceInspector.pinControl(
                        controlHandleToken
                    )
                    guard self.activeSession?.fingerprint == session.fingerprint else {
                        await discardControlHandleIfUnretained(controlHandleToken)
                        return ActiveSurfaceRevalidation(
                            match: nil,
                            replacementControlHandleToken: nil,
                            replacementNativeSurfaceHandleToken: nil,
                            replacementSurfaceKey: nil
                        )
                    }
                    if !pinned {
                        await BrowserCallSurfaceInspector.discardControl(controlHandleToken)
                        return ActiveSurfaceRevalidation(
                            match: nil,
                            replacementControlHandleToken: nil,
                            replacementNativeSurfaceHandleToken: nil,
                            replacementSurfaceKey: nil,
                            trustReadFailed: true
                        )
                    }
                }
            } else {
                sameSurface = false
                terminalBoundary = false
            }
            if let provisional = inspection.controlHandleToken,
               provisional != session.browserControlHandleToken,
               !sameSurface {
                await discardControlHandleIfUnretained(provisional)
            }
            let boundedTrustLoss =
                BrowserSurfaceRevalidation.startsBoundedTrustLoss(
                    retainedControlState: retainedControlState,
                    trustedSurfaceFound: inspection.isTrustedCall,
                    authoritativeNoMatch: inspection.authoritativeNoMatch,
                    audioSessionIdentityChanged: audioCarriersFullyReplaced
                )
            return ActiveSurfaceRevalidation(
                // An invalidated root can be an ordinary background-tab rebuild while the same
                // CoreAudio carriers survive. A true AX read failure (`.unknown`) is different:
                // bound it even without an audio carrier change so revoked TCC or a wedged AX
                // server cannot keep recording forever.
                match: BrowserSurfaceRevalidation.latestSurfaceMatch(
                    trustedSurfaceFound: inspection.isTrustedCall,
                    sameSurface: sameSurface,
                    authoritativeNoMatch: inspection.authoritativeNoMatch,
                    audioSessionIdentityChanged: audioCarriersFullyReplaced
                ),
                replacementControlHandleToken: sameSurface
                    ? inspection.controlHandleToken
                    : nil,
                replacementNativeSurfaceHandleToken: nil,
                replacementSurfaceKey: sameSurface
                    ? inspection.controlHandleToken.map {
                        Self.surfaceKey(
                            group: group,
                            surfaceDiscriminator: $0,
                            originHost: inspection.trustedOrigin?.host
                        )
                    }
                    : nil,
                trustReadFailed: !sameSurface && boundedTrustLoss,
                terminalBoundary: terminalBoundary
            )
        }
    }

    private func isSuppressed(surfaceKey: String) -> Bool {
        !CallSurfaceSuppressionPolicy.allows(
            candidateSurfaceKey: surfaceKey,
            suppressedSurfaceKeys: Set(suppressedSessions.keys)
        )
    }

    private func updateSuppressedSessions(
        groups: [CallAudioApplicationGroup],
        runningBundleIDsByPID: [Int32: String],
        now: TimeInterval
    ) async {
        let groupsByIdentity = Dictionary(
            uniqueKeysWithValues: groups.map {
                (
                    SurfaceProbeKey(rootPID: $0.rootPID, bundleID: $0.ownerBundleID),
                    $0
                )
            }
        )

        for surfaceKey in Array(suppressedSessions.keys) {
            guard var session = suppressedSessions[surfaceKey] else { continue }

            let rootApplicationRunning = runningBundleIDsByPID[session.rootPID] == session.bundleID

            let identity = SurfaceProbeKey(
                rootPID: session.rootPID,
                bundleID: session.bundleID
            )
            let group = groupsByIdentity[identity]
            let hasRequiredAudio: Bool
            switch session.kind {
            case .browser:
                hasRequiredAudio = group?.inputActive == true && group?.outputActive == true
            case .native:
                hasRequiredAudio = group?.inputActive == true
            case .generic:
                hasRequiredAudio = group?.inputActive == true
            }

            if session.kind == .native,
               rootApplicationRunning,
               let token = session.nativeSurfaceHandleToken {
                let state = await NativeCallSurfaceInspector.revalidateSurface(token)
                guard suppressedSessions[surfaceKey]?.fingerprint == session.fingerprint else {
                    continue
                }
                switch NativeSurfaceLifecycle.suppressionBoundary(
                    state: state,
                    inputActive: hasRequiredAudio,
                    authoritativeEndSince: session.controlEndedSince,
                    now: now
                ) {
                case .release:
                    suppressedSessions.removeValue(forKey: surfaceKey)
                    await NativeCallSurfaceInspector.discardSurface(token)
                    continue

                case let .retain(authoritativeEndSince):
                    session.controlEndedSince = authoritativeEndSince
                }

                if state == .invalidated {
                    // The old root cannot prove an end or identify a successor. Drop the dead AX
                    // capability to protect the bounded registry, but retain a detached,
                    // group-fail-closed tombstone until the existing audio/app boundary.
                    session.nativeSurfaceHandleToken = nil
                    session.controlEndedSince = nil
                    suppressedSessions[surfaceKey] = session
                    await NativeCallSurfaceInspector.discardSurface(token)
                    guard let current = suppressedSessions[surfaceKey],
                          current.fingerprint == session.fingerprint
                    else { continue }
                    session = current
                }
            }

            if session.kind == .browser,
               rootApplicationRunning,
               let token = session.browserControlHandleToken {
                let controlState = await BrowserCallSurfaceInspector.revalidateControl(
                    token,
                    allowRootRebind: true
                )
                // suppress/release can re-enter while the direct AX query awaits.
                guard suppressedSessions[surfaceKey]?.fingerprint == session.fingerprint else {
                    continue
                }
                let audioCarriersFullyReplaced = CallAudioCarrierBaseline(
                    inputAudioObjectIDs: session.inputAudioObjectIDs,
                    outputAudioObjectIDs: session.outputAudioObjectIDs
                ).isFullyReplaced(
                    by: group,
                    kind: session.kind
                )
                let carrierCorroboratedRelease =
                    BrowserControlLifecycle.shouldReleaseSuppression(
                    state: controlState,
                    audioCarriersFullyReplaced: audioCarriersFullyReplaced,
                    allowsDocumentReplacementRelease:
                        session.browserAllowsCrossRootReconciliation
                    )
                if carrierCorroboratedRelease {
                    suppressedSessions.removeValue(forKey: surfaceKey)
                    await BrowserCallSurfaceInspector.discardControl(token)
                    continue
                }

                var capabilityToDetach: String?
                switch controlState {
                case .active, .rebound:
                    // Exact/root continuity proves that route changes still belong to A. Future
                    // replacement checks compare against this latest proof, not admission-time IDs.
                    if group?.inputActive == true, let group {
                        let refreshedBaseline = CallAudioCarrierBaseline(
                            inputAudioObjectIDs: session.inputAudioObjectIDs,
                            outputAudioObjectIDs: session.outputAudioObjectIDs
                        ).refreshingConfirmedSide(from: group)
                        session.inputAudioObjectIDs = refreshedBaseline.inputAudioObjectIDs
                        session.outputAudioObjectIDs = refreshedBaseline.outputAudioObjectIDs
                    }
                    session.controlEndedSince = nil
                    session.fullAudioBoundarySince = nil

                case .ended:
                    let endedSince = session.controlEndedSince ?? now
                    session.controlEndedSince = endedSince
                    if BrowserControlLifecycle.shouldDetachSuppressedCapability(
                        state: controlState
                    ) {
                        capabilityToDetach = session.browserControlHandleToken
                        session.browserControlHandleToken = nil
                    }

                case .invalidated:
                    // Chromium can replace the entire AXWebArea during a responsive rebuild.
                    // Mark the exact root unavailable so another root can be considered, but keep
                    // this tombstone until a collision-safe match or corroborating audio boundary.
                    let endedSince = session.controlEndedSince ?? now
                    session.controlEndedSince = endedSince
                    if BrowserControlLifecycle.shouldDetachSuppressedCapability(
                        state: controlState
                    ) {
                        capabilityToDetach = session.browserControlHandleToken
                        session.browserControlHandleToken = nil
                    }

                case .replaced:
                    // Collision-safe service/session identities are released above. Generic Teams
                    // routes cannot prove that a changed SPA document is B, so retain a detached
                    // group-fail-closed tombstone without consuming the AX registry.
                    let endedSince = session.controlEndedSince ?? now
                    session.controlEndedSince = endedSince
                    if BrowserControlLifecycle.shouldDetachSuppressedCapability(
                        state: controlState
                    ) {
                        capabilityToDetach = session.browserControlHandleToken
                        session.browserControlHandleToken = nil
                    }

                case .unknown:
                    session.controlEndedSince = nil
                }

                if let capabilityToDetach {
                    // Publish the detached tombstone before awaiting the serial AX teardown.
                    // A concurrent lifecycle operation then cannot resurrect the old capability.
                    suppressedSessions[surfaceKey] = session
                    await BrowserCallSurfaceInspector.discardControl(capabilityToDetach)
                    guard let current = suppressedSessions[surfaceKey],
                          current.fingerprint == session.fingerprint
                    else { continue }
                    session = current
                }
            }

            if session.kind == .browser,
               rootApplicationRunning,
               session.browserControlHandleToken == nil,
               session.controlEndedSince != nil {
                let audioCarriersFullyReplaced = CallAudioCarrierBaseline(
                    inputAudioObjectIDs: session.inputAudioObjectIDs,
                    outputAudioObjectIDs: session.outputAudioObjectIDs
                ).isFullyReplaced(
                    by: group,
                    kind: session.kind
                )
                switch DetachedSuppressionBoundary.decide(
                    freshTwoSidedReplacement:
                        hasRequiredAudio && audioCarriersFullyReplaced,
                    boundaryAbsent:
                        group?.inputActive != true && group?.outputActive != true,
                    boundarySince: session.fullAudioBoundarySince,
                    now: now
                ) {
                case .release:
                    suppressedSessions.removeValue(forKey: surfaceKey)
                    continue
                case let .retain(authoritativeEndSince):
                    session.fullAudioBoundarySince = authoritativeEndSince
                }
            }

            if session.kind == .native,
               rootApplicationRunning,
               session.nativeSurfaceHandleToken == nil {
                switch DetachedSuppressionBoundary.decide(
                    freshTwoSidedReplacement: false,
                    boundaryAbsent: NativeSuppressionAudioBoundary.isAbsent(
                        inputActive: group?.inputActive == true,
                        outputActive: group?.outputActive == true
                    ),
                    boundarySince: session.fullAudioBoundarySince,
                    now: now
                ) {
                case .release:
                    suppressedSessions.removeValue(forKey: surfaceKey)
                    continue
                case let .retain(authoritativeEndSince):
                    session.fullAudioBoundarySince = authoritativeEndSince
                }
            }

            if CallSurfaceSuppressionPolicy.shouldRelease(
                rootApplicationRunning: rootApplicationRunning
            ) {
                suppressedSessions.removeValue(forKey: surfaceKey)
                await BrowserCallSurfaceInspector.discardControl(
                    session.browserControlHandleToken
                )
                await NativeCallSurfaceInspector.discardSurface(
                    session.nativeSurfaceHandleToken
                )
                continue
            }

            suppressedSessions[surfaceKey] = session
        }
    }

    /// When an exact rejected AX root disappears, inspect the remaining roots without blocking B.
    /// A collision-safe replacement with the same service + opaque URL discriminator is rebound
    /// into the suppression entry. A different trusted surface may proceed as B, but it never
    /// deletes A's tombstone: an exposed-tree no-match cannot prove a background tab is gone.
    private func reconcileSuppressedRootReplacement(
        _ result: BrowserProbeResult
    ) async -> Bool {
        let replacementKeys = suppressedSessions.compactMap { surfaceKey, session -> String? in
            guard session.kind == .browser,
                  session.rootPID == result.group.rootPID,
                  session.bundleID == result.group.ownerBundleID,
                  session.controlEndedSince != nil
            else { return nil }
            return surfaceKey
        }
        guard !replacementKeys.isEmpty else { return false }
        let requiresGroupFailClosed = replacementKeys.contains { key in
            suppressedSessions[key]?.browserAllowsCrossRootReconciliation == false
        }

        let inspection = result.inspection
        if inspection.isTrustedCall,
           let matchingKey = replacementKeys.first(where: { key in
               guard let session = suppressedSessions[key] else { return false }
               return BrowserSurfaceIdentity.matches(
                   expectedService: session.browserService,
                   expectedDiscriminator: session.browserSessionDiscriminator,
                   expectedAllowsCrossRootReconciliation:
                       session.browserAllowsCrossRootReconciliation,
                   observedService: inspection.service,
                   observedDiscriminator: inspection.sessionDiscriminator,
                   observedAllowsCrossRootReconciliation:
                       inspection.allowsCrossRootReconciliation
               )
           }) {
            guard var session = suppressedSessions[matchingKey],
                  let token = inspection.controlHandleToken,
                  let origin = inspection.trustedOrigin
            else {
                // A matching page without a retainable capability is ambiguous. Keep the
                // suppression rather than risk automatically recording the rejected call.
                return true
            }
            let pinGeneration = lifecycleGeneration
            guard await BrowserCallSurfaceInspector.pinControl(token) else {
                await BrowserCallSurfaceInspector.discardControl(token)
                return true
            }
            guard lifecycleGeneration == pinGeneration,
                  suppressedSessions[matchingKey]?.fingerprint == session.fingerprint
            else {
                await discardControlHandleIfUnretained(token)
                return true
            }

            let previousToken = session.browserControlHandleToken
            let replacementKey = Self.surfaceKey(
                group: result.group,
                surfaceDiscriminator: token,
                originHost: origin.host
            )
            session.surfaceKey = replacementKey
            session.browserControlHandleToken = token
            session.browserService = inspection.service
            session.browserSessionDiscriminator = inspection.sessionDiscriminator
            session.browserAllowsCrossRootReconciliation =
                inspection.allowsCrossRootReconciliation
            session.inputAudioObjectIDs = result.group.inputAudioObjectIDs
            session.outputAudioObjectIDs = result.group.outputAudioObjectIDs
            session.controlEndedSince = nil
            session.fullAudioBoundarySince = nil
            suppressedSessions.removeValue(forKey: matchingKey)
            suppressedSessions[replacementKey] = session
            if previousToken != token {
                await BrowserCallSurfaceInspector.discardControl(previousToken)
            }
            return true
        }

        // Generic SPA routes (currently Teams `/v2`) have no collision-safe page discriminator.
        // Once their exact root disappears, fail closed for this browser group until an audio/app
        // boundary rather than risk recording the same rejected call from a rebuilt root.
        if requiresGroupFailClosed {
            if let provisional = result.inspection.controlHandleToken {
                await discardControlHandleIfUnretained(provisional)
            }
            return true
        }

        // Keep unmatched tombstones until CoreAudio disappears stably, all carrier identities are
        // replaced, or the browser exits. A different collision-safe trusted surface may proceed
        // as B, but it never deletes A's tombstone.
        return false
    }

    private func suppressedOrIdleEvidence(
        now: TimeInterval,
        monotonicNow: TimeInterval
    ) -> CallEvidenceSnapshot {
        guard let suppressed = suppressedSessions.values.sorted(by: {
            $0.fingerprint < $1.fingerprint
        }).first else {
            return Self.idleEvidence(now: now, monotonicNow: monotonicNow)
        }
        return Self.retainedMissingEvidence(
            now: now,
            monotonicNow: monotonicNow,
            fingerprint: suppressed.fingerprint
        )
    }

    private static func inspectBrowserGroups(
        _ groups: [CallAudioApplicationGroup],
        excludingControlTokensByIdentity: [SurfaceProbeKey: Set<String>]
    ) async -> [BrowserProbeResult] {
        await withTaskGroup(of: BrowserProbeResult.self, returning: [BrowserProbeResult].self) { taskGroup in
            for group in groups {
                let excluded = excludingControlTokensByIdentity[
                    SurfaceProbeKey(rootPID: group.rootPID, bundleID: group.ownerBundleID)
                ] ?? []
                taskGroup.addTask {
                    let inspection = await BrowserCallSurfaceInspector.inspect(
                        pid: pid_t(group.rootPID),
                        excludingControlTokens: excluded
                    )
                    return BrowserProbeResult(group: group, inspection: inspection)
                }
            }
            var results: [BrowserProbeResult] = []
            for await result in taskGroup {
                results.append(result)
            }
            return results.sorted {
                if $0.group.ownerBundleID != $1.group.ownerBundleID {
                    return $0.group.ownerBundleID < $1.group.ownerBundleID
                }
                return $0.group.rootPID < $1.group.rootPID
            }
        }
    }

    private func discardUnretainedControlHandles(
        in results: [BrowserProbeResult]
    ) async {
        let retained = Set(
            ([activeSession?.browserControlHandleToken]
                + suppressedSessions.values.map(\.browserControlHandleToken))
                .compactMap { $0 }
        )
        let provisional = Set(results.compactMap(\.inspection.controlHandleToken))
        for token in provisional where !retained.contains(token) {
            await BrowserCallSurfaceInspector.discardControl(token)
        }
    }

    private func discardControlHandleIfUnretained(_ token: String) async {
        let retained = Set(
            ([activeSession?.browserControlHandleToken]
                + suppressedSessions.values.map(\.browserControlHandleToken))
                .compactMap { $0 }
        )
        guard !retained.contains(token) else { return }
        await BrowserCallSurfaceInspector.discardControl(token)
    }

    private func discardNativeSurfaceIfUnretained(_ token: String) async {
        let retained = Set(
            ([activeSession?.nativeSurfaceHandleToken]
                + suppressedSessions.values.map(\.nativeSurfaceHandleToken))
                .compactMap { $0 }
        )
        guard !retained.contains(token) else { return }
        await NativeCallSurfaceInspector.discardSurface(token)
    }

    private static func logBrowserProbe(_ result: BrowserProbeResult) {
        let diagnostics = result.inspection.diagnostics
        let browser = browserClass(for: result.group.ownerBundleID)
        let service = result.inspection.service?.rawValue ?? "none"
        Log.meetingDetection.debug(
            "browser_probe browser=\(browser, privacy: .public) service=\(service, privacy: .public) input=\(result.group.inputActive, privacy: .public) output=\(result.group.outputActive, privacy: .public) trusted=\(result.inspection.isTrustedCall, privacy: .public) authoritative_no_match=\(result.inspection.authoritativeNoMatch, privacy: .public) ax_trusted=\(diagnostics.accessibilityTrusted, privacy: .public) windows=\(diagnostics.windowsVisited, privacy: .public) nodes=\(diagnostics.nodesVisited, privacy: .public) window_limited=\(diagnostics.hitWindowLimit, privacy: .public) node_limited=\(diagnostics.hitNodeLimit, privacy: .public) latency_ms=\(diagnostics.elapsedMilliseconds, privacy: .public) timed_out=\(diagnostics.timedOut, privacy: .public)"
        )
    }

    private static func browserClass(for bundleID: String) -> String {
        switch bundleID {
        case "com.google.Chrome": "chrome"
        case "company.thebrowser.dia": "dia"
        case "com.microsoft.edgemac": "edge"
        default: "unsupported"
        }
    }

    private static func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func newSessionFingerprint(
        group: CallAudioApplicationGroup,
        surfaceDiscriminator: String,
        originHost: String?
    ) -> String {
        CallDetectorFingerprint.make(
            bundleID: group.ownerBundleID,
            sessionMarker: [
                "root:\(group.rootPID)",
                "surface:\(surfaceDiscriminator)",
                "activation:\(UUID().uuidString.lowercased())",
            ].joined(separator: "|"),
            originHost: originHost
        )
    }

    private static func surfaceKey(
        group: CallAudioApplicationGroup,
        surfaceDiscriminator: String,
        originHost: String?
    ) -> String {
        CallDetectorFingerprint.makeSurfaceKey(
            bundleID: group.ownerBundleID,
            rootPID: group.rootPID,
            surfaceDiscriminator: surfaceDiscriminator,
            originHost: originHost
        )
    }

    private static func candidateFingerprint(for group: CallAudioApplicationGroup) -> String {
        CallDetectorFingerprint.make(
            bundleID: group.ownerBundleID,
            sessionMarker: "candidate-root:\(group.rootPID)",
            originHost: nil
        )
    }

    private func enrichedMicrophoneActivityEvidence(
        now: TimeInterval,
        monotonicNow: TimeInterval,
        group: CallAudioApplicationGroup,
        fingerprint: String,
        expectedGeneration: UInt64
    ) async -> CallEvidenceSnapshot {
        var evidence = Self.microphoneActivityEvidence(
            now: now,
            monotonicNow: monotonicNow,
            group: group,
            fingerprint: fingerprint
        )
        guard shouldProbeSurface(group, now: monotonicNow) else { return evidence }

        switch group.ownerKind {
        case .generic:
            return evidence

        case .native:
            let inspection = await NativeCallSurfaceInspector.inspect(
                pid: pid_t(group.rootPID),
                bundleID: group.ownerBundleID,
                excludingSurfaceTokens: []
            )
            guard lifecycleGeneration == expectedGeneration,
                  activeSession?.fingerprint == fingerprint,
                  inspection.hasCallSignature
            else {
                await NativeCallSurfaceInspector.discardSurface(inspection.surfaceHandleToken)
                return evidence
            }
            if let token = inspection.surfaceHandleToken,
               var session = activeSession,
               session.fingerprint == fingerprint {
                let previous = session.nativeSurfaceHandleToken
                session.nativeSurfaceHandleToken = token
                activeSession = session
                if previous != token {
                    await NativeCallSurfaceInspector.discardSurface(previous)
                }
            }
            evidence.surface = CallSurfaceEvidence(
                kind: .native,
                ownerBundleID: group.ownerBundleID,
                trustedOrigin: nil,
                marker: .nativeCallControls,
                observedAt: now
            )
            return evidence

        case .browser:
            guard group.outputActive else { return evidence }
            let inspection = await BrowserCallSurfaceInspector.inspect(pid: pid_t(group.rootPID))
            guard lifecycleGeneration == expectedGeneration,
                  activeSession?.fingerprint == fingerprint,
                  inspection.isTrustedCall
            else {
                await BrowserCallSurfaceInspector.discardControl(inspection.controlHandleToken)
                return evidence
            }
            if let token = inspection.controlHandleToken,
               var session = activeSession,
               session.fingerprint == fingerprint {
                let previous = session.browserControlHandleToken
                session.browserControlHandleToken = token
                session.browserService = inspection.service
                session.browserSessionDiscriminator = inspection.sessionDiscriminator
                session.browserAllowsCrossRootReconciliation =
                    inspection.allowsCrossRootReconciliation
                activeSession = session
                if previous != token {
                    await BrowserCallSurfaceInspector.discardControl(previous)
                }
            }
            evidence.surface = CallSurfaceEvidence(
                kind: .browser,
                ownerBundleID: group.ownerBundleID,
                trustedOrigin: inspection.trustedOrigin,
                marker: .trustedBrowserCallState,
                observedAt: now
            )
            return evidence
        }
    }

    private static func microphoneActivityEvidence(
        now: TimeInterval,
        monotonicNow: TimeInterval,
        group: CallAudioApplicationGroup,
        fingerprint: String
    ) -> CallEvidenceSnapshot {
        let surfaceKind: CallSurfaceKind
        switch group.ownerKind {
        case .native:
            surfaceKind = .native
        case .browser:
            surfaceKind = .browser
        case .generic:
            surfaceKind = .generic
        }
        return CallEvidenceSnapshot(
            now: now,
            monotonicNow: monotonicNow,
            microphoneOwnerBundleID: group.ownerBundleID,
            microphoneOwnerDisplayName: group.ownerDisplayName,
            surface: CallSurfaceEvidence(
                kind: surfaceKind,
                ownerBundleID: group.ownerBundleID,
                trustedOrigin: nil,
                marker: .microphoneActivity,
                observedAt: now
            ),
            microphoneAudioActive: group.inputActive,
            systemAudioActive: group.outputActive,
            calendarHint: false,
            isStale: false,
            fingerprint: fingerprint
        )
    }

    private static func continuingEvidence(
        now: TimeInterval,
        monotonicNow: TimeInterval,
        group: CallAudioApplicationGroup,
        fingerprint: String
    ) -> CallEvidenceSnapshot {
        CallEvidenceSnapshot(
            now: now,
            monotonicNow: monotonicNow,
            microphoneOwnerBundleID: group.ownerBundleID,
            surface: nil,
            microphoneAudioActive: group.inputActive,
            systemAudioActive: group.outputActive,
            calendarHint: false,
            isStale: false,
            fingerprint: fingerprint
        )
    }

    private static func nativeEvidence(
        now: TimeInterval,
        monotonicNow: TimeInterval,
        group: CallAudioApplicationGroup,
        marker: CallStateMarker?,
        fingerprint: String
    ) -> CallEvidenceSnapshot {
        CallEvidenceSnapshot(
            now: now,
            monotonicNow: monotonicNow,
            microphoneOwnerBundleID: group.ownerBundleID,
            surface: CallSurfaceEvidence(
                kind: .native,
                ownerBundleID: group.ownerBundleID,
                trustedOrigin: nil,
                marker: marker,
                observedAt: now
            ),
            microphoneAudioActive: group.inputActive,
            systemAudioActive: group.outputActive,
            calendarHint: false,
            isStale: false,
            fingerprint: fingerprint
        )
    }

    private static func browserCandidateEvidence(
        now: TimeInterval,
        monotonicNow: TimeInterval,
        group: CallAudioApplicationGroup
    ) -> CallEvidenceSnapshot {
        CallEvidenceSnapshot(
            now: now,
            monotonicNow: monotonicNow,
            microphoneOwnerBundleID: group.ownerBundleID,
            surface: nil,
            microphoneAudioActive: group.inputActive,
            systemAudioActive: group.outputActive,
            calendarHint: false,
            isStale: false,
            fingerprint: candidateFingerprint(for: group)
        )
    }

    private static func idleEvidence(
        now: TimeInterval,
        monotonicNow: TimeInterval
    ) -> CallEvidenceSnapshot {
        CallEvidenceSnapshot(
            now: now,
            monotonicNow: monotonicNow,
            microphoneOwnerBundleID: nil,
            surface: nil,
            microphoneAudioActive: false,
            systemAudioActive: false,
            calendarHint: false,
            isStale: false,
            fingerprint: "idle"
        )
    }

    private static func retainedMissingEvidence(
        now: TimeInterval,
        monotonicNow: TimeInterval,
        fingerprint: String
    ) -> CallEvidenceSnapshot {
        CallEvidenceSnapshot(
            now: now,
            monotonicNow: monotonicNow,
            microphoneOwnerBundleID: nil,
            surface: nil,
            microphoneAudioActive: false,
            systemAudioActive: false,
            calendarHint: false,
            isStale: false,
            fingerprint: fingerprint,
            isRetainedMissing: true
        )
    }

    // MARK: CoreAudio and process ownership

    @MainActor
    private static func runningApplicationBundleIDs() -> [Int32: String] {
        var result: [Int32: String] = [:]
        for application in NSWorkspace.shared.runningApplications {
            guard let bundleID = application.bundleIdentifier else { continue }
            result[Int32(application.processIdentifier)] = bundleID
        }
        return result
    }

    private static func collectAudioProcessEvidence(
        bundleIDsByPID: [Int32: String]
    ) -> AudioProcessCollection {
        guard let objects = processObjects() else {
            return AudioProcessCollection(
                succeeded: false,
                inputStateAuthoritative: false,
                fullAudioStateAuthoritative: false,
                samples: []
            )
        }

        let currentPID = Int32(ProcessInfo.processInfo.processIdentifier)
        var samples: [CallAudioProcessSample] = []
        var inputStateAuthoritative = true
        var fullAudioStateAuthoritative = true
        for object in objects {
            guard let inputActive = runningState(
                object,
                selector: kAudioProcessPropertyIsRunningInput
            ) else {
                inputStateAuthoritative = false
                fullAudioStateAuthoritative = false
                continue
            }
            let outputState = runningState(
                object,
                selector: kAudioProcessPropertyIsRunningOutput
            )
            if outputState == nil { fullAudioStateAuthoritative = false }
            let outputActive = outputState ?? false
            guard inputActive || outputActive else { continue }

            guard let pid = pidOf(object), pid > 0 else {
                if inputActive { inputStateAuthoritative = false }
                fullAudioStateAuthoritative = false
                continue
            }
            let audioProcessBundleID = bundleIDOf(object)
            var ancestry = processAncestry(
                for: Int32(pid),
                bundleIDsByPID: bundleIDsByPID,
                audioProcessBundleID: audioProcessBundleID
            )
            // This check intentionally precedes detached helper -> visible root folding. Otherwise
            // a short `codex_chronicle` pulse could inherit ChatGPT's root identity and open a Call.
            guard !CallAudioOwnerResolution.isExcludedExecutableName(
                ancestry.first?.executableName
            ) else { continue }
            if let browserRoot = CallAudioBrowserRootResolution.rootAncestor(
                audioProcessBundleID: audioProcessBundleID,
                runningApplicationBundleIDs: bundleIDsByPID
            ),
            !ancestry.contains(where: { $0.pid == browserRoot.pid }) {
                ancestry.append(browserRoot)
            }
            if let visibleRoot = CallAudioVisibleRootResolution.rootAncestor(
                audioProcessBundleID: audioProcessBundleID,
                runningApplicationBundleIDs: bundleIDsByPID
            ),
            !ancestry.contains(where: { $0.pid == visibleRoot.pid }) {
                ancestry.append(visibleRoot)
            }
            guard let owner = CallAudioOwnerResolution.resolve(
                ancestors: ancestry,
                currentProcessID: currentPID
            ) else { continue }

            samples.append(
                CallAudioProcessSample(
                    audioObjectID: object,
                    pid: Int32(pid),
                    rootPID: owner.rootPID,
                    ownerBundleID: owner.bundleID,
                    ownerKind: owner.kind,
                    ownerBundleIDIsSynthetic: owner.bundleIDIsSynthetic,
                    ownerDisplayName: owner.displayName,
                    inputActive: inputActive,
                    outputActive: outputActive
                )
            )
        }
        return AudioProcessCollection(
            succeeded: true,
            inputStateAuthoritative: inputStateAuthoritative,
            fullAudioStateAuthoritative: fullAudioStateAuthoritative,
            samples: samples
        )
    }

    /// HAL and proc ancestry are synchronous C APIs. Keep them off the actor executor so the UI can
    /// always service "This isn't a call", release, and shutdown even if coreaudiod is unhealthy.
    private static func collectAudioProcessEvidenceOffActor(
        bundleIDsByPID: [Int32: String]
    ) async -> AudioProcessCollection {
        guard audioEvidencePollGate.begin() else {
            // A previous synchronous HAL call is still stuck. Do not queue unbounded work behind
            // it; keep emitting stale snapshots so the policy's bounded recovery can end capture.
            return AudioProcessCollection(
                succeeded: false,
                inputStateAuthoritative: false,
                fullAudioStateAuthoritative: false,
                samples: []
            )
        }

        return await withCheckedContinuation { continuation in
            let completion = AudioEvidenceCompletion()
            audioEvidenceQueue.async {
                let result = collectAudioProcessEvidence(bundleIDsByPID: bundleIDsByPID)
                audioEvidencePollGate.finish()
                completion.resume(
                    continuation,
                    returning: result
                )
            }
            audioEvidenceTimeoutQueue.asyncAfter(
                deadline: .now() + maximumAudioEvidencePollSeconds
            ) {
                // The C call cannot be cancelled safely. Resume the detector as stale and leave
                // the gate closed until that exact poll eventually returns.
                completion.resume(
                    continuation,
                    returning: AudioProcessCollection(
                        succeeded: false,
                        inputStateAuthoritative: false,
                        fullAudioStateAuthoritative: false,
                        samples: []
                    )
                )
            }
        }
    }

    private static func processAncestry(
        for pid: Int32,
        bundleIDsByPID: [Int32: String],
        audioProcessBundleID: String?
    ) -> [CallAudioProcessAncestor] {
        var result: [CallAudioProcessAncestor] = []
        var current = pid_t(pid)
        for _ in 0..<8 where current > 1 {
            let normalizedPID = Int32(current)
            result.append(
                CallAudioProcessAncestor(
                    pid: normalizedPID,
                    bundleID: normalizedPID == pid
                        ? (audioProcessBundleID ?? bundleIDsByPID[normalizedPID])
                        : bundleIDsByPID[normalizedPID],
                    executableName: processName(of: current)
                )
            )
            let parent = parentPid(of: current)
            if parent <= 1 || parent == current { break }
            current = parent
        }
        return result
    }

    private static func processObjects() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            return nil
        }
        guard size > 0 else { return [] }

        var objects = [AudioObjectID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            system,
            &address,
            0,
            nil,
            &size,
            &objects
        ) == noErr else {
            return nil
        }
        return objects
    }

    private static func runningState(
        _ object: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value != 0
    }

    private static func pidOf(_ object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &pid
        ) == noErr else { return nil }
        return pid
    }

    private static func bundleIDOf(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &unmanaged
        ) == noErr,
        let value = unmanaged?.takeRetainedValue() else { return nil }
        return value as String
    }

    private static func parentPid(of pid: pid_t) -> pid_t {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size)
        return result == size ? pid_t(info.pbsi_ppid) : -1
    }

    private static func processName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 1_024)
        let count = buffer.withUnsafeMutableBufferPointer {
            proc_name(pid, $0.baseAddress, UInt32($0.count))
        }
        guard count > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(count)).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}
