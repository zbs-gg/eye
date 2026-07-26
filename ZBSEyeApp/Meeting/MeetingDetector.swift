import AppKit
import CoreAudio
import Darwin
import Foundation

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
        let rootPID: Int32
        let bundleID: String
        let kind: CallAudioApplicationKind
        let fingerprint: String
        var surfaceKey: String
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
    /// Longer than the 30-second end grace plus the 15-second Undo window, so a transient
    /// CoreAudio reconfiguration can resume the same call without minting a new fingerprint.
    private static let activeSessionMissingRetention: TimeInterval = 60
    private var pollTask: Task<Void, Never>?
    private var continuation: AsyncStream<CallEvidenceSnapshot>.Continuation?
    private var activeSession: ActiveSession?
    private var suppressedSessions: [String: SuppressedSession] = [:]
    private var lastSurfaceProbeAt: [SurfaceProbeKey: TimeInterval] = [:]
    private var lifecycleGeneration: UInt64 = 0

    func start() -> AsyncStream<CallEvidenceSnapshot> {
        lifecycleGeneration &+= 1
        let (stream, cont) = AsyncStream<CallEvidenceSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation = cont
        pollTask?.cancel()
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
        continuation?.finish()
        continuation = nil
        activeSession = nil
        suppressedSessions.removeAll()
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
    func suppressSession(fingerprint: String) {
        guard let session = activeSession, session.fingerprint == fingerprint else { return }
        lifecycleGeneration &+= 1
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
    }

    func releaseSession(fingerprint: String? = nil) async {
        if let fingerprint {
            if activeSession?.fingerprint == fingerprint {
                lifecycleGeneration &+= 1
                let token = activeSession?.browserControlHandleToken
                let nativeToken = activeSession?.nativeSurfaceHandleToken
                activeSession = nil
                await BrowserCallSurfaceInspector.discardControl(token)
                await NativeCallSurfaceInspector.discardSurface(nativeToken)
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
        for token in tokens {
            await BrowserCallSurfaceInspector.discardControl(token)
        }
        for token in nativeTokens {
            await NativeCallSurfaceInspector.discardSurface(token)
        }
    }

    func tick(now: Date) async {
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

        let groups = CallAudioProcessGrouping.groups(from: collection.samples)
        pruneProbeCache(for: groups)
        await updateSuppressedSessions(
            groups: groups,
            runningBundleIDsByPID: bundleIDsByPID,
            now: monotonicNow
        )
        guard lifecycleGeneration == expectedGeneration, !Task.isCancelled else {
            return Self.idleEvidence(now: observedAt, monotonicNow: monotonicNow)
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
            return AudioProcessCollection(succeeded: false, samples: [])
        }

        let currentPID = Int32(ProcessInfo.processInfo.processIdentifier)
        var samples: [CallAudioProcessSample] = []
        for object in objects {
            let inputActive = isRunning(object, selector: kAudioProcessPropertyIsRunningInput)
            let outputActive = isRunning(object, selector: kAudioProcessPropertyIsRunningOutput)
            guard inputActive || outputActive else { continue }

            let pid = pidOf(object)
            guard pid > 0 else { continue }
            let ancestry = processAncestry(
                for: Int32(pid),
                bundleIDsByPID: bundleIDsByPID
            )
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
                    inputActive: inputActive,
                    outputActive: outputActive
                )
            )
        }
        return AudioProcessCollection(succeeded: true, samples: samples)
    }

    /// HAL and proc ancestry are synchronous C APIs. Keep them off the actor executor so the UI can
    /// always service "This isn't a call", release, and shutdown even if coreaudiod is unhealthy.
    private static func collectAudioProcessEvidenceOffActor(
        bundleIDsByPID: [Int32: String]
    ) async -> AudioProcessCollection {
        guard audioEvidencePollGate.begin() else {
            // A previous synchronous HAL call is still stuck. Do not queue unbounded work behind
            // it; keep emitting stale snapshots so the policy's bounded recovery can end capture.
            return AudioProcessCollection(succeeded: false, samples: [])
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
                    returning: AudioProcessCollection(succeeded: false, samples: [])
                )
            }
        }
    }

    private static func processAncestry(
        for pid: Int32,
        bundleIDsByPID: [Int32: String]
    ) -> [CallAudioProcessAncestor] {
        var result: [CallAudioProcessAncestor] = []
        var current = pid_t(pid)
        for _ in 0..<8 where current > 1 {
            let normalizedPID = Int32(current)
            result.append(
                CallAudioProcessAncestor(
                    pid: normalizedPID,
                    bundleID: bundleIDsByPID[normalizedPID],
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

    private static func isRunning(
        _ object: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(object, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr && value != 0
    }

    private static func pidOf(_ object: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &pid
        ) == noErr ? pid : -1
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
