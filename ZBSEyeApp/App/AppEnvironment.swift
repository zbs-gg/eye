import Foundation
import AppKit
import Observation
import UserNotifications

private struct AutomaticCallRejectionSuspensionOwnership {
    var automation = false
    var workerBarrier = false
}

private struct AutomaticCallPermissionAvailability: Equatable {
    let microphone: Bool
    let systemAudio: Bool

    init(_ snapshot: PermissionSnapshot) {
        microphone = snapshot.microphone == .granted
        systemAudio = snapshot.screenRecording == .granted
    }
}

private struct AutomaticCallContextEvidence: Equatable {
    let callID: Int64
    let detectorFingerprint: String
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var trustedOriginHost: String?
    var sourceIsKnownCallSurface: Bool

    func merging(
        sourceAppBundleID incomingBundleID: String?,
        sourceAppName incomingName: String?,
        trustedOriginHost incomingOrigin: String?,
        sourceIsKnownCallSurface incomingIsKnownCallSurface: Bool
    ) -> AutomaticCallContextEvidence {
        var merged = self
        let currentIsSynthetic = Self.isSynthetic(sourceAppBundleID)
        if incomingIsKnownCallSurface && !sourceIsKnownCallSurface {
            if let incomingBundleID {
                merged.sourceAppBundleID = incomingBundleID
                merged.sourceAppName = incomingName ?? merged.sourceAppName
            }
            merged.sourceIsKnownCallSurface = true
        } else if sourceAppBundleID == nil || currentIsSynthetic {
            if let incomingBundleID,
               sourceAppBundleID == nil || !Self.isSynthetic(incomingBundleID) {
                merged.sourceAppBundleID = incomingBundleID
                if let incomingName { merged.sourceAppName = incomingName }
            }
        }
        if merged.sourceAppName == nil { merged.sourceAppName = incomingName }
        if merged.trustedOriginHost == nil { merged.trustedOriginHost = incomingOrigin }
        return merged
    }

    static func isKnownCallSurface(_ surface: CallSurfaceEvidence?) -> Bool {
        switch surface?.marker {
        case .nativeCallControls, .accessibilityParticipantRoster, .trustedBrowserCallState:
            true
        case .microphoneActivity, nil:
            false
        }
    }

    private static func isSynthetic(_ bundleID: String?) -> Bool {
        bundleID?.hasPrefix("process:") == true
            || bundleID?.hasPrefix("process-pid:") == true
    }
}

/// Root application state. The single @Observable, injected via .environment.
/// Owns all the stores (per the v2 plan — instead of scattered @State and the 14-binding antipattern).
@MainActor
@Observable
final class AppEnvironment {
    typealias KeepMediaConfirmation = KeepMediaPolicyConfirmation
    typealias KeepMediaChangeResult = KeepMediaPolicyChangeResult
    let permissions = PermissionsStore()
    let recording = RecordingStore()
    let server = ServerStore()
    let connections = ConnectionStore()   // destination-folder config persists itself, no db needed
    let ai = AIProviderStore()            // Optional AI: one active provider/model pair or Off.
    let aiSetup = AISetupPresentation()
    let mcpReadiness = MCPReadinessService()
    let audioSettings = AudioSettingsStore()
    let calls = CallRecordingStore()
    let speechModel = WhisperModelSettingsStore()
    let speakerModel = SpeakerDiarizationModelSettingsStore()
    let storageSettings: StorageSettingsStore
    let storageOperations = StorageOperationsStore()
    let resourceUsage: ResourceUsageStore
    let backupSettings = BackupSettingsStore()
    let builtInModels = BuiltInModelStore()
    let privacy = PrivacyStore()
    let rewards = RewardsStore()   // cosmetic rewards (theme/icon/menu-bar) — independent of the DB
    let workspace = WorkspaceStore()
    private(set) var captureHealth = CaptureHealthReducer(nowMs: 0).snapshot
    private(set) var automaticCallBanner: AutomaticCallBannerState? {
        didSet { publishAutomaticCallPopup() }
    }
    private(set) var automaticCallRejectionCallID: Int64? {
        didSet { publishAutomaticCallPopup() }
    }
    var automaticCallRejectionInProgress: Bool {
        automaticCallRejectionCallID == automaticCallBanner?.callID
    }
    @ObservationIgnored private let keepMediaPolicyCoordinator = KeepMediaPolicyCoordinator()
    @ObservationIgnored private var captureHealthController: CaptureHealthController?
    @ObservationIgnored private var captureRecoveryTasks: [CaptureLeg: Task<Void, Never>] = [:]
    @ObservationIgnored private var captureCoveragePersistenceTasks: [CaptureLeg: Task<Void, Never>] = [:]
    @ObservationIgnored private var captureRepairInProgress = false
    @ObservationIgnored private var automaticCallPopupPresenter: AutomaticCallPopupPresenter?
    @ObservationIgnored private var lastAutomaticCallAudioDisabled: Bool?
    @ObservationIgnored private var lastAutomaticCallPermissionAvailability:
        AutomaticCallPermissionAvailability?

    init() {
        let storageSettings = StorageSettingsStore()
        self.storageSettings = storageSettings
        resourceUsage = ResourceUsageStore(dataBytes: { [weak storageSettings] in
            storageSettings?.totalBytes ?? 0
        })
        audioSettings.onCaptureConfigurationChanged = { [weak self] in
            self?.syncAudioConfiguration()
        }
        lastAutomaticCallAudioDisabled = CallAudioSourcePolicy.requestedSources(
            audioMode: audioSettings.audioMode,
            manualOverride: audioSettings.manualAudioOverride
        ).isEmpty
        lastAutomaticCallPermissionAvailability = AutomaticCallPermissionAvailability(
            permissions.snapshot
        )
        recording.onPrivacyPauseEnded = { [weak self] in
            self?.calls.automaticStartAdmissionChanged(isClosed: false)
            self?.resumeTemporarilySuspendedAutomaticCall(kind: .privacyPause)
            Task { [weak detector = self?.meetingDetector] in
                await detector?.automaticCallAdmissionDidChange()
            }
        }
        recording.onMaintenanceAdmissionClosed = { [weak self] in
            self?.calls.automaticStartAdmissionChanged(isClosed: true)
        }
    }

    func syncAudioConfiguration() {
        let audioIsDisabled = CallAudioSourcePolicy.requestedSources(
            audioMode: audioSettings.audioMode,
            manualOverride: audioSettings.manualAudioOverride
        ).isEmpty
        if lastAutomaticCallAudioDisabled != audioIsDisabled {
            lastAutomaticCallAudioDisabled = audioIsDisabled
            calls.automaticStartAdmissionChanged(isClosed: audioIsDisabled)
        }
        recording.syncAudio()
        if !audioIsDisabled {
            resumeTemporarilySuspendedAutomaticCall(kind: .audioDisabled)
        }
        Task { [weak meetingDetector] in
            await meetingDetector?.automaticCallAdmissionDidChange()
        }
        guard CallAudioSourcePolicy.mustEndActiveCall(
            audioMode: audioSettings.audioMode,
            manualOverride: audioSettings.manualAudioOverride,
            callIsActive: calls.isActive
        ) else { return }
        // Off is a privacy hard gate, including explicit Call ownership. Finish and preserve the
        // local Call exactly once; changing an audio setting never means destructive rejection.
        audio?.closeCallFrameAdmission()
        if let fingerprint = automaticCallFingerprint ?? claimedCallDetectorFingerprint {
            pendingAutomaticCallTemporarySuspension = AutomaticCallTemporarySuspension(
                kind: .audioDisabled,
                fingerprint: fingerprint
            )
        }
        Task { @MainActor [weak self] in
            await self?.calls.endAndWait(reason: .privacy)
        }
    }

    /// The banner state is authoritative. The popup is only a lazily-created mirror and never
    /// requests notification permission or activates Eye.
    private func publishAutomaticCallPopup() {
        guard let state = automaticCallBanner else {
            automaticCallPopupPresenter?.update(
                state: nil,
                rejectionInProgress: false
            )
            return
        }
        if automaticCallPopupPresenter == nil {
            automaticCallPopupPresenter = AutomaticCallPopupPresenter(
                onEndAndSave: { [weak self] in self?.endDetectedCallAndSave() },
                onReject: { [weak self] in self?.rejectDetectedCall() },
                onNeverAutoRecord: { [weak self] target in
                    self?.neverAutoRecordDetectedApp(target)
                }
            )
        }
        automaticCallPopupPresenter?.update(
            state: state,
            rejectionInProgress: automaticCallRejectionInProgress
        )
    }
    var presentedCallID: Int64?
    /// First launch → onboarding (consent "everything gets recorded" + permissions). Persist: shown until completed.
    var showOnboarding = !UserDefaults.standard.bool(forKey: "zbseye.onboarding.done")
    /// Self-repair sheet trigger — shared by the main-window toolbar button and the menu-bar item.
    var showSelfRepair = false

    func completeOnboarding(startRecording: Bool) {
        UserDefaults.standard.set(true, forKey: "zbseye.onboarding.done")
        showOnboarding = false
        if startRecording {
            if !recording.isCapturing { recording.toggle() }
        } else {
            // "Later" — an explicit refusal at the consent point: stop a possible autostart from under the shade
            // and clear the armed intent (otherwise recording would start on its own against the refusal).
            recording.disarm()
        }
    }

    // Data layer (created in bootstrap; nil until initialized / on error).
    private(set) var database: ZBSEyeDatabase?
    private(set) var ingest: IngestService?
    private(set) var callRepository: CallRepository?
    private(set) var callEvidenceQueryService: CallEvidenceQueryService?
    private(set) var callsLibrary: CallsStore?
    private(set) var callEvidenceDeletionService: CallEvidenceDeletionService?
    private(set) var callRecovery: CallRecoveryService?
    private(set) var retention: RetentionManager?
    @ObservationIgnored private var automaticRetentionAdmission: AutomaticRetentionAdmission?
    /// One process-wide decoded-image cache shared by Timeline and Activities.
    /// It is created against the active relocatable media directory during bootstrap.
    @ObservationIgnored private(set) var visualFrameImageLoader: VisualFrameImageLoader?
    private(set) var timelineStore: TimelineStore?
    private(set) var ask: AskStore?
    private(set) var cartographer: CartographerStore?
    private(set) var httpServer: ZBSEyeHTTPServer?
    private(set) var automations: DaySummaryStore?
    private(set) var callAutomation: CallAutomationStore?
    private(set) var sceneStore: SceneStore?
    private(set) var audio: AudioCoordinator?
    private(set) var storage: StorageManager?   // for the Settings storage card (used/delete/Finder)
    private(set) var db: ZBSEyeDatabase?         // for the Settings size breakdown / backup
    private(set) var export: ExportService?
    private(set) var historyImporter: HistoryImporter?
    private(set) var dataError: String?
    private(set) var progress: ProgressStore?
    @ObservationIgnored private(set) var usageStats: UsageStatsService?
    @ObservationIgnored private var automationAuditWriter: AutomationAuditWriter?
    @ObservationIgnored private var callAutomationDispatcher: CallAutomationDispatcher?
    @ObservationIgnored private(set) var llmRouter: LLMRouter?
    @ObservationIgnored private(set) var aiComputeCoordinator: AIComputeCoordinator?
    @ObservationIgnored private(set) var whisperModelStore: WhisperModelStore?
    @ObservationIgnored private(set) var handySpeechModelStore: HandySpeechModelStore?
    @ObservationIgnored private(set) var speakerDiarizationModelStore: SpeakerDiarizationModelStore?
    @ObservationIgnored private(set) var callTranscriptWorker: CallTranscriptWorker?
    @ObservationIgnored private var callTranscriptWorkerTask: Task<Void, Never>?
    @ObservationIgnored private(set) var speakerDiarizationWorker: SpeakerDiarizationWorker?
    @ObservationIgnored private var callEvidenceWorkerBarrier: CallEvidenceWorkerBarrier?
    @ObservationIgnored private var speakerDiarizationWorkerTask: Task<Void, Never>?
    @ObservationIgnored private(set) var builtInModelManager: BuiltInModelManager?
    @ObservationIgnored private var builtInModelProviderBridge: BuiltInModelProviderBridge?
    @ObservationIgnored private var builtInModelReconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var builtInModelRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var recordingTerminationRecoveryTask: Task<Void, Never>?
    /// Relocation owns rollback while a relaunch handoff is awaiting the
    /// AppDelegate decision. A rejected Quit must not reopen the copied-root
    /// service graph before relocation restores the previous root.
    @ObservationIgnored private var relocationTerminationHandoffInProgress = false
    /// A relocation-owned Quit may time out while shutdown still owns model
    /// state. Rollback awaits this exact retained task before reopening the old
    /// graph, preventing a late shutdown from closing admission again.
    @ObservationIgnored private var relocationTerminationDrainTask: Task<Bool, Never>?
    @ObservationIgnored private var builtInModelReconciliationGeneration: UInt64 = 0
    @ObservationIgnored private var builtInModelRecoveryGeneration: UInt64 = 0
    @ObservationIgnored private var localAIMemoryPressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var processProviderRuntimeOwner: ProcessProviderRuntimeOwner?
    /// Prevents a headless `--relocate` process from snapshotting this root
    /// while the GUI has live writers. Kernel ownership survives stale files
    /// and is released automatically if the app crashes.
    @ObservationIgnored private var dataRootProcessLock: StorageRelocationProcessLock?
    private let bootstrapGate = AppBootstrapGate()
    private(set) var achievements: AchievementStore?

    @ObservationIgnored private var retentionTask: Task<Void, Never>?
    @ObservationIgnored private var backupTask: Task<Void, Never>?
    @ObservationIgnored private(set) var backupManager: BackupManager?
    @ObservationIgnored private var autostartTask: Task<Void, Never>?
    @ObservationIgnored private var meetingDetector: MeetingDetector?
    @ObservationIgnored private var meetingTask: Task<Void, Never>?
    @ObservationIgnored private var meetingWakeObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var meetingSessionObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var callDetectionPolicy = CallDetectionPolicy()
    @ObservationIgnored private var automaticCallAdmissionBarrier =
        AutomaticCallAdmissionBarrier()
    @ObservationIgnored private var automaticCallSessionGate =
        CaptureSessionGateState(reasons: .session)
    @ObservationIgnored private var automaticCallFingerprint: String?
    @ObservationIgnored private var automaticCallContextEvidence:
        AutomaticCallContextEvidence?
    @ObservationIgnored private var claimedCallDetectorFingerprint: String?
    @ObservationIgnored private var pendingUserEndDetectorFingerprint: String?
    @ObservationIgnored private var lowDiskSuspendedDetectorFingerprint: String?
    @ObservationIgnored private var maintenanceSuspendedDetectorFingerprint: String?
    @ObservationIgnored private var pendingAutomaticCallTemporarySuspension:
        AutomaticCallTemporarySuspension?
    @ObservationIgnored private var suspendedAutomaticCall:
        AutomaticCallTemporarySuspension?
    @ObservationIgnored private var automaticCallRearmInProgressFingerprint: String?
    @ObservationIgnored private var automaticCallEndGraceTask: Task<Void, Never>?
    @ObservationIgnored private var automaticCallFinalizationCallID: Int64?
    @ObservationIgnored private var automaticCallSavedBannerTask: Task<Void, Never>?
    @ObservationIgnored private var automaticCallSavedBannerGeneration: UInt64 = 0
    @ObservationIgnored private var automaticCallSuccessorProbeGate =
        AutomaticCallSuccessorProbeGate()
    @ObservationIgnored private var automaticCallEndLifecycle =
        AutomaticCallEndLifecycle()
    @ObservationIgnored private var automaticCallRejectionTask: Task<Void, Never>?
    @ObservationIgnored private var automaticCallEraseTasks: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var automaticCallRejectedEraseGate =
        AutomaticCallRejectedEraseGate()
    @ObservationIgnored private var automaticCallRejectionReceipt: CallPrivacyIntentReceipt?
    @ObservationIgnored private var automaticCallRejectionSuspensions:
        [Int64: AutomaticCallRejectionSuspensionOwnership] = [:]
    @ObservationIgnored private var terminationPrivacyGate = AppTerminationPrivacyGate()
    @ObservationIgnored private(set) var browserHistoryImporter: BrowserHistoryImporter?
    @ObservationIgnored private var browserHistoryTask: Task<Void, Never>?
    @ObservationIgnored private var lowDiskTask: Task<Void, Never>?
    @ObservationIgnored private var lowDiskGuard = LowDiskGuard()
    @ObservationIgnored private var lowDiskDrainConfirmed = true

    /// Race an operation against a timeout — so a backup on exit doesn't hang quit forever.
    nonisolated static func withTimeout(seconds: Double, _ op: @escaping @Sendable () async -> Void) async {
        let operation = Task { await op() }
        let outcome = await LocalRuntimeTaskDeadline.wait(
            for: operation,
            timeout: .seconds(seconds)
        )
        if outcome != .completed {
            // Structured task groups wait for a non-cooperative loser when
            // leaving scope. Keep Quit caller-bounded; the process owns the
            // cancelled backup task only until termination completes.
            operation.cancel()
        }
    }

    private func installLocalAIMemoryPressureHandler(
        for localInference: LocalInferenceService
    ) {
        localAIMemoryPressureSource?.cancel()
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler(
            handler: LocalAIMemoryPressureDispatchHandler.make(for: localInference)
        )
        source.activate()
        localAIMemoryPressureSource = source
    }

    private func cancelBuiltInModelReconciliation() -> Task<Void, Never>? {
        builtInModelReconciliationGeneration &+= 1
        let task = builtInModelReconciliationTask
        builtInModelReconciliationTask = nil
        task?.cancel()
        return task
    }

    private func restartBuiltInModelReconciliation(
        manager: BuiltInModelManager,
        providerBridge: BuiltInModelProviderBridge
    ) {
        _ = cancelBuiltInModelReconciliation()
        builtInModelReconciliationGeneration &+= 1
        let generation = builtInModelReconciliationGeneration
        let selectionRevision = ai.currentSelectionRevision
        builtInModelReconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.builtInModelReconciliationGeneration == generation {
                    self.builtInModelReconciliationTask = nil
                }
            }
            do {
                let reconciled = try await manager.reconcileAfterRestart(
                    currentSelectionRevision: selectionRevision
                )
                guard !Task.isCancelled,
                      self.builtInModelReconciliationGeneration == generation else { return }
                _ = providerBridge.reconcile(reconciled.snapshot)
                await self.builtInModels.refresh()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.builtInModelReconciliationGeneration == generation else { return }
                await self.builtInModels.refresh()
                self.builtInModels.setHardwareSupport(
                    .unavailable(
                        reason: String(localized: "ZBS Eye Local could not open its model storage safely.")
                    )
                )
                let message = BuiltInModelFailureMessage.userFacing(
                    error,
                    context: .operation
                )
                Log.app.error(
                    "built-in model reconciliation failed closed: \(message, privacy: .public)"
                )
            }
        }
    }

    private func cancelBuiltInModelRecovery() {
        builtInModelRecoveryGeneration &+= 1
        builtInModelRecoveryTask?.cancel()
        builtInModelRecoveryTask = nil
    }

    private func recoverBuiltInModelsAfterCancelledTermination(
        after phase: AppTerminationCriticalPhaseResult,
        manager: BuiltInModelManager?,
        providerBridge: BuiltInModelProviderBridge?,
        resumeCompute: Bool
    ) {
        cancelBuiltInModelRecovery()
        builtInModelRecoveryGeneration &+= 1
        let generation = builtInModelRecoveryGeneration
        builtInModelRecoveryTask = phase.recoveryTask { @MainActor [weak self] in
            guard !Task.isCancelled,
                  let self,
                  self.builtInModelRecoveryGeneration == generation else { return }
            if let manager {
                await manager.recoverAfterCancelledShutdown()
            }
            guard !Task.isCancelled,
                  self.builtInModelRecoveryGeneration == generation else { return }
            if resumeCompute {
                await self.aiComputeCoordinator?.resume()
            }
            guard !Task.isCancelled,
                  self.builtInModelRecoveryGeneration == generation else { return }
            self.builtInModelRecoveryTask = nil
            if let manager, let providerBridge {
                self.restartBuiltInModelReconciliation(
                    manager: manager,
                    providerBridge: providerBridge
                )
            }
        }
    }

    private func recoverRecordingAfterCancelledTermination(
        after phase: AppTerminationCriticalPhaseResult,
        lease: RecordingMaintenanceLease
    ) {
        recordingTerminationRecoveryTask?.cancel()
        recordingTerminationRecoveryTask = phase.recoveryTask { @MainActor [weak self] in
            guard let self else { return }
            await self.resumeRecordingAfterCancelledTermination(lease)
            self.recordingTerminationRecoveryTask = nil
        }
    }

    /// Reopens capture after macOS cancels Quit. A maintenance call end has already closed the
    /// Call Envelope, so its detector identity must be released at the same boundary as recording
    /// admission. Otherwise the browser can stay pinned forever after a later shutdown phase fails.
    private func resumeRecordingAfterCancelledTermination(
        _ lease: RecordingMaintenanceLease?
    ) async {
        if let fingerprint = maintenanceSuspendedDetectorFingerprint {
            callDetectionPolicy.reject(fingerprint: fingerprint)
            await meetingDetector?.releaseSession(fingerprint: fingerprint)
            maintenanceSuspendedDetectorFingerprint = nil
        }
        captureHealthController?.setSuspension(nil, nowMs: Self.epochMs())
        if let lease { recording.resumeAfterMaintenance(lease) }
        await meetingDetector?.automaticCallAdmissionDidChange()
    }

    private func handleCaptureHealthEffect(
        _ effect: CaptureHealthEffect,
        controller: CaptureHealthController,
        coordinator: CaptureCoordinator,
        audio: AudioCoordinator,
        ingest: IngestService,
        database: ZBSEyeDatabase
    ) {
        switch effect {
        case .openCoverage(let open):
            enqueueCaptureCoveragePersistence(for: open.leg) { @MainActor [weak self] in
                var durable = false
                var lastFailure = "durability verification failed"
                for delayMs: Int64 in [0, 250, 1_000] {
                    if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) }
                    do {
                        let inserted = try await ingest.openCaptureCoverage(open)
                        durable = inserted
                        if !inserted,
                           case .available(let intervals) = try await CaptureCoverageQuery(
                            database: database
                           ).openIntervals() {
                            durable = intervals.contains {
                                $0.leg == open.leg
                                    && $0.episodeID == open.episodeID
                                    && $0.generation == open.generation
                                    && $0.startMs == open.startMs
                            }
                        }
                        if durable { break }
                    } catch {
                        lastFailure = String(describing: error)
                    }
                }
                guard durable else {
                    Log.capture.error(
                        "capture coverage open failed after bounded retry: \(lastFailure, privacy: .public)"
                    )
                    controller.coverageOpenPersistenceFailed(open, nowMs: Self.epochMs())
                    self?.captureHealth = controller.snapshot
                    return
                }
                controller.coverageDidOpen(open, nowMs: Self.epochMs())
            }

        case .closeCoverage(let close):
            enqueueCaptureCoveragePersistence(for: close.leg) { @MainActor in
                var durable = false
                var lastFailure = "compare-and-set close was not acknowledged"
                for delayMs: Int64 in [0, 250, 1_000] {
                    if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) }
                    do {
                        durable = try await ingest.closeCaptureCoverage(close)
                        if durable { break }
                    } catch {
                        lastFailure = String(describing: error)
                    }
                }
                guard durable else {
                    Log.capture.error(
                        "capture coverage close failed after bounded retry: \(lastFailure, privacy: .public)"
                    )
                    controller.coverageClosePersistenceFailed(close, nowMs: Self.epochMs())
                    return
                }
                controller.coverageDidClose(close, nowMs: Self.epochMs())
            }

        case .attemptRecovery(let attempt):
            captureRecoveryTasks[attempt.leg]?.cancel()
            captureRecoveryTasks[attempt.leg] = Task { @MainActor in
                if attempt.delayMs > 0 {
                    try? await Task.sleep(for: .milliseconds(attempt.delayMs))
                }
                guard !Task.isCancelled,
                      controller.isCurrentRecoveryAttempt(attempt) else { return }
                switch attempt.leg {
                case .screen:
                    await coordinator.performScreenRecovery(attempt)
                case .systemAudio:
                    await audio.performSystemAudioRecovery(attempt)
                }
            }
        }
    }

    private func enqueueCaptureCoveragePersistence(
        for leg: CaptureLeg,
        operation: @escaping @MainActor () async -> Void
    ) {
        let previous = captureCoveragePersistenceTasks[leg]
        captureCoveragePersistenceTasks[leg] = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    private func drainCaptureCoveragePersistence() async {
        for task in Array(captureCoveragePersistenceTasks.values) {
            await task.value
        }
    }

    func repairCapture() async {
        guard !captureRepairInProgress else { return }
        captureRepairInProgress = true
        defer { captureRepairInProgress = false }

        guard let controller = captureHealthController,
              let coordinator = recording.coordinator,
              let audio else { return }
        let affected = Set(controller.snapshot.repairableLegs)
        guard !affected.isEmpty, recording.wantsRecording else { return }
        let physicalAffected = Set(affected.filter {
            controller.repairRequiresPhysicalDrain(for: $0)
        })
        let lease = physicalAffected.isEmpty
            ? nil
            : recording.acquireMaintenanceLease(.repair)
        let drained = await CaptureRepairOrchestrator.run(
            affected: physicalAffected,
            drainScreen: { await coordinator.stopAndDrain().activeCycles == 0 },
            drainSystemAudio: {
                await audio.stopSystemAndDrain(timeout: .seconds(5)).isConfirmedStopped
            },
            restartScreen: {},
            requestRepair: { _ in }
        )
        if let lease {
            recording.completeCaptureRepair(
                lease,
                screenWasDrained: physicalAffected.contains(.screen),
                drainSucceeded: drained
            )
        }
        guard drained else { return }
        for leg in CaptureLeg.allCases where affected.contains(leg) {
            controller.repairRequested(leg, nowMs: Self.epochMs())
        }
    }

    nonisolated private static func epochMs(_ date: Date = Date()) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }

    nonisolated private static func capturePermission(
        from status: PermissionStatus
    ) -> CapturePermissionState {
        switch status {
        case .granted: .granted
        case .denied: .denied
        case .notDetermined, .needsRestart: .unknown
        }
    }

    /// 👁 Delighter: once per crossed "round" memory milestone — a friendly local notification
    /// + a visual-celebration trigger in ProgressStore.
    /// Marks all crossed ones at once (doesn't backfill old ones one by one), celebrates only the top new one.
    func celebrateMilestoneIfNeeded(frames: Int) {
        let milestones = MemoryMilestones.frames
        let key = "zbseye.milestones.celebrated"
        let done = Set(UserDefaults.standard.array(forKey: key) as? [Int] ?? [])
        let crossed = milestones.filter { $0 <= frames }
        guard let top = crossed.filter({ !done.contains($0) }).max() else { return }
        UserDefaults.standard.set(crossed, forKey: key)   // mark ALL crossed — no spam with old ones
        let pretty = NumberFormatter.localizedString(from: NSNumber(value: top), number: .decimal)
        let content = UNMutableNotificationContent()
        content.title = "👁 ZBS Eye"
        content.body = "\(pretty) moments in your memory. All of it — on this Mac, for you only."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "zbseye.milestone.\(top)", content: content, trigger: nil))
        // Visual delighter: overlay in the UI
        progress?.celebrateMilestone(top)
    }

    // Keep nonisolated static version for legacy callsites (unused internally now, safe to leave)
    nonisolated static func celebrateMilestoneIfNeeded(frames: Int) {
        let milestones = MemoryMilestones.frames
        let key = "zbseye.milestones.celebrated"
        let done = Set(UserDefaults.standard.array(forKey: key) as? [Int] ?? [])
        let crossed = milestones.filter { $0 <= frames }
        guard let top = crossed.filter({ !done.contains($0) }).max() else { return }
        UserDefaults.standard.set(crossed, forKey: key)
        let pretty = NumberFormatter.localizedString(from: NSNumber(value: top), number: .decimal)
        let content = UNMutableNotificationContent()
        content.title = "👁 ZBS Eye"
        content.body = "\(pretty) moments in your memory. All of it — on this Mac, for you only."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "zbseye.milestone.\(top)", content: content, trigger: nil))
    }

    /// Startup order of background services. For now — permission probes + the Data layer; capture/server/automations
    /// will be added as the modules appear (Phase 2, steps 3+).
    func bootstrap() async {
        await bootstrapGate.run { [weak self] in
            await self?.bootstrapOnce()
        }
    }

    private func bootstrapOnce() async {
        ZBSEyeHTTPServer.log("bootstrap: begin")
        automaticCallSessionGate = CaptureSessionPolicy.startupGate(
            sessionLockedNow: CaptureSessionPolicy.currentSessionLocked()
        )
        calls.admissionAllowed = { [weak self] in
            guard let self else { return false }
            return !self.isCallLifecycleAdmissionClosed
                && CaptureSessionPolicy.currentSessionLocked() == false
        }
        rewards.applyAppIcon()   // the chosen alternate app icon (dock) — apply on startup
        // Crash marker: if the clean-exit flag wasn't set on the previous launch → the session died
        // incorrectly (kill/crash/kernel panic). Visible in Console.app for remote diagnostics.
        let cleanKey = "zbseye.cleanShutdown"
        if UserDefaults.standard.object(forKey: cleanKey) != nil,
           !UserDefaults.standard.bool(forKey: cleanKey) {
            Log.app.error("previous session ended INCORRECTLY (crash/kill) — check for gaps in history")
            ZBSEyeHTTPServer.log("CRASH-MARKER: previous session ended incorrectly (crash/kill)")
        }
        UserDefaults.standard.set(false, forKey: cleanKey)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            UserDefaults.standard.set(true, forKey: cleanKey)
        }
        await permissions.refreshAll()
        // ANTI-SPLIT-BRAIN: if the data was moved to a volume that's currently unavailable — DON'T start
        // on legacy "from scratch" (otherwise empty history + a split of new frames). Ask to connect and restart.
        if let missing = StorageLocation.unavailableConfiguredPath() {
            self.dataError = "Data folder unavailable: \(missing). Connect the disk/volume and restart ZBS Eye — "
                + "recording is off so the \"eternal memory\" isn't split in two."
            ZBSEyeHTTPServer.log("data_root_unavailable: bootstrap aborted (anti-split-brain)")
            return
        }
        do {
            let resolvedDataRoot = try StorageLocation.requireAvailableDataRoot()
                .resolvingSymlinksInPath()
                .standardizedFileURL
            self.dataRootProcessLock = try StorageRelocationProcessLock(
                dataRoot: resolvedDataRoot
            )
            let storage = try StorageManager()
            self.storage = storage
            let db = try ZBSEyeDatabase(path: ZBSEyeDatabase.defaultURL().path)
            self.db = db
            // Keep Media migration is resolved only after the canonical root,
            // database, and captured-media tree are available. This one-time
            // reconciliation never calls RetentionManager; an uncertain result
            // keeps automatic deletion closed.
            let keepMediaInventory: KeepMediaInventoryEvidence
            if storageSettings.automaticRetentionRecord.phase == .pendingFinite {
                // Persisted finite admission never crosses a process boundary.
                // Perform the one expensive exact DB/filesystem proof before
                // reopening it; the scheduler reuses the resulting permit.
                keepMediaInventory = await CapturedMediaReconciler.reconcile(
                    db: db,
                    storage: storage
                )
            } else {
                keepMediaInventory = await Self.classifyFreshKeepMediaProfile(
                    db: db,
                    storage: storage
                )
            }
            let keepMediaResolution = storageSettings.initializeKeepMediaPolicy(
                inventory: keepMediaInventory
            )
            let automaticRetentionAdmission = AutomaticRetentionAdmission(
                record: storageSettings.automaticRetentionRecord
            )
            self.automaticRetentionAdmission = automaticRetentionAdmission
            Log.retention.info(
                "Keep Media initialized: \(keepMediaResolution.policy.rawValue, privacy: .public), deletion admitted=\(keepMediaResolution.automaticDeletionAdmitted)"
            )
            // Gamification: progress and milestones
            self.progress = ProgressStore(db: db)
            let backupManager = BackupManager(db: db, storage: storage)
            self.backupManager = backupManager
            backupSettings.manager = backupManager
            backupSettings.refresh()
            // Backup on exit (applicationShouldTerminate → terminateLater): snapshot in time before the process
            // dies (willTerminate would be too late — the process dies synchronously there). With a 30s timeout.
            ZBSEyeAppDelegate.onTerminate = { [weak self] in
                guard let self else { return true }
                guard self.terminationPrivacyGate.acquireTerminationLease(
                    automaticRejectionTaskActive:
                        self.automaticCallRejectionTask != nil
                            || !self.automaticCallEraseTasks.isEmpty,
                    automaticRejectionCallID:
                        self.automaticCallRejectionCallID
                            ?? self.automaticCallRejectedEraseGate.pendingCallIDs.first
                ) else {
                    Log.audio.error(
                        "termination cancelled: false-call privacy deletion is still completing"
                    )
                    return false
                }
                var keepTerminationLeaseUntilProcessExit = false
                defer {
                    if !keepTerminationLeaseUntilProcessExit {
                        self.terminationPrivacyGate.releaseTerminationLease()
                    }
                }
                let recoveryOwner: AppTerminationRecoveryOwner =
                    self.relocationTerminationHandoffInProgress
                        ? .relocationHandoff
                        : .quit
                // A previous Quit timed out while capture still owned hardware.
                // Its retained recovery reopens admission only after the real
                // drain finishes; another Quit must not race that ownership.
                guard self.recordingTerminationRecoveryTask == nil else {
                    Log.audio.error("termination cancelled: recording drain is still completing")
                    return false
                }
                // terminateLater keeps the process alive until ScreenCaptureKit
                // has acknowledged its CoreAudio teardown and both capture
                // legs have flushed their final DB row. Speech recognition can
                // resume from backfill after launch, so it must not hold Quit.
                var recordingMaintenanceLease: RecordingMaintenanceLease?
                if recoveryOwner == .quit {
                    let lease = self.recording.acquireMaintenanceLease(.termination)
                    recordingMaintenanceLease = lease
                    self.audio?.closeCallFrameAdmission()
                    self.calls.automaticStartAdmissionChanged(isClosed: true)
                    self.captureHealthController?.setSuspension(
                        .maintenance,
                        nowMs: Self.epochMs()
                    )
                    await self.drainCaptureCoveragePersistence()
                    let recordingPhase = await AppTerminationCriticalPhase.run(
                        timeout: AppTerminationDeadlinePolicy.recordingDrain
                    ) {
                        // The outer critical phase owns the only caller
                        // deadline. The underlying hardware teardown remains
                        // retained to real completion before recovery resumes.
                        await self.calls.endAndWait(reason: .maintenance)
                        let recordingDrain = await self.recording.pauseForMaintenanceAndDrain(
                            lease: lease,
                            waitForTranscription: false
                        )
                        return recordingDrain.capture.activeCycles == 0
                            && recordingDrain.audio.activeLegs == 0
                            && recordingDrain.audio.systemCaptureOutcome.isConfirmedStopped
                    }
                    guard AppTerminationCriticalPhase.acceptsTermination(recordingPhase) else {
                        Log.audio.error("termination cancelled: recording drain was not confirmed before deadline")
                        self.recoverRecordingAfterCancelledTermination(
                            after: recordingPhase,
                            lease: lease
                        )
                        return false
                    }
                }
                self.cancelBuiltInModelRecovery()
                let reconciliation = self.cancelBuiltInModelReconciliation()
                await self.callTranscriptWorker?.suspendAndDrain()
                await self.speakerDiarizationWorker?.suspendAndDrain()
                await self.whisperModelStore?.suspendAndDrain()
                await self.speakerDiarizationModelStore?.suspendAndDrain()
                await self.callAutomationDispatcher?.suspendAndDrainForRelocation()
                await self.callAutomation?.suspendAndDrain()

                // These two ownership barriers share the fail-closed Quit path:
                // each is caller-bounded, but its task remains retained until it
                // really finishes before recovery can reopen model admission.
                let localRuntimePhase = await AppTerminationCriticalPhase.run(
                    timeout: .seconds(5)
                ) {
                    await self.builtInModelManager?.shutdown() ?? true
                }
                guard localRuntimePhase.outcome == .completed(true) else {
                    Log.app.error("termination cancelled: local AI runtime release was not confirmed")
                    if recoveryOwner.recoversServiceGraphInline {
                        self.recoverBuiltInModelsAfterCancelledTermination(
                            after: localRuntimePhase,
                            manager: self.builtInModelManager,
                            providerBridge: self.builtInModelProviderBridge,
                            resumeCompute: false
                        )
                        if case .completed = localRuntimePhase.outcome {
                            await self.builtInModels.refresh()
                        }
                        await self.resumeRecordingAfterCancelledTermination(recordingMaintenanceLease)
                        await self.whisperModelStore?.resumeAfterDrain()
                        await self.speakerDiarizationModelStore?.resumeAfterDrain()
                        await self.callTranscriptWorker?.resume()
                        await self.speakerDiarizationWorker?.resume()
                        await self.callAutomationDispatcher?.resumeAfterRelocation()
                        await self.callAutomation?.resumeAfterSuspension()
                    } else {
                        self.relocationTerminationDrainTask = localRuntimePhase.operation
                    }
                    return false
                }

                let computePhase = await AppTerminationCriticalPhase.run(
                    timeout: .seconds(5)
                ) {
                    guard let coordinator = self.aiComputeCoordinator else { return true }
                    do {
                        try await coordinator.suspendAndDrain()
                        return true
                    } catch {
                        return false
                    }
                }
                guard computePhase.outcome == .completed(true) else {
                    Log.app.error("termination cancelled: AI compute drain was not confirmed")
                    if recoveryOwner.recoversServiceGraphInline {
                        self.recoverBuiltInModelsAfterCancelledTermination(
                            after: computePhase,
                            manager: self.builtInModelManager,
                            providerBridge: self.builtInModelProviderBridge,
                            resumeCompute: true
                        )
                        await self.builtInModels.refresh()
                        await self.resumeRecordingAfterCancelledTermination(recordingMaintenanceLease)
                        await self.whisperModelStore?.resumeAfterDrain()
                        await self.speakerDiarizationModelStore?.resumeAfterDrain()
                        await self.callTranscriptWorker?.resume()
                        await self.speakerDiarizationWorker?.resume()
                        await self.callAutomationDispatcher?.resumeAfterRelocation()
                        await self.callAutomation?.resumeAfterSuspension()
                    } else {
                        self.relocationTerminationDrainTask = computePhase.operation
                    }
                    return false
                }
                await reconciliation?.value
                await self.callAutomationDispatcher?.shutdown()
                await self.builtInModels.shutdown()
                self.localAIMemoryPressureSource?.cancel()
                self.localAIMemoryPressureSource = nil
                if let router = self.llmRouter {
                    _ = await router.shutdown(timeout: .seconds(5))
                }
                if let owner = self.processProviderRuntimeOwner {
                    _ = await owner.shutdown(timeout: .seconds(5))
                }
                if self.backupSettings.enabled, BackupManager.iCloudAvailable() {
                    let keep = self.backupSettings.keepN
                    await Self.withTimeout(seconds: 30) {
                        _ = try? await backupManager.makeBackup(keepN: keep)
                    }
                }
                keepTerminationLeaseUntilProcessExit = true
                return true
            }
            ZBSEyeHTTPServer.log("bootstrap: db ok")
            self.database = db
            // Ingest does NOT embed anymore (that kept the e5 model resident 24/7 and burned CPU per capture).
            let ingestService = IngestService(db: db, storage: storage)
            self.ingest = ingestService
            let callRepository = CallRepository(database: db)
            self.callRepository = callRepository
            let callEvidenceQueryService = CallEvidenceQueryService(database: db)
            self.callEvidenceQueryService = callEvidenceQueryService
            self.callsLibrary = CallsStore(service: callEvidenceQueryService)
            let callEvidenceDeletionService = CallEvidenceDeletionService(
                repository: callRepository,
                mediaRoot: storage.mediaDirectory
            )
            self.callEvidenceDeletionService = callEvidenceDeletionService
            let callRecovery = CallRecoveryService(
                repository: callRepository,
                mediaRoot: storage.mediaDirectory
            )
            self.callRecovery = callRecovery
            let callRecoveryReport = try await callRecovery.recover()
            if callRecoveryReport.callsInterrupted > 0
                || callRecoveryReport.jobsReset > 0
                || callRecoveryReport.chunksFinalized > 0
                || callRecoveryReport.chunksDiscarded > 0 {
                Log.audio.notice(
                    "call recovery reconciled interrupted evidence and queued retryable work"
                )
            }

            let callAutomationRepository = CallAutomationRepository(database: db)
            let callAutomationTransport = LoopbackWebhookTransport()
            let callAutomationDispatcher = CallAutomationDispatcher(
                repository: callAutomationRepository,
                transport: callAutomationTransport
            )
            let callAutomationStore = CallAutomationStore(
                repository: callAutomationRepository,
                transport: callAutomationTransport,
                dispatcher: callAutomationDispatcher
            )
            self.callAutomationDispatcher = callAutomationDispatcher
            self.callAutomation = callAutomationStore
            await callEvidenceDeletionService.attachCallAutomation(
                suspend: { await callAutomationDispatcher.suspendAndDrainForRelocation() },
                resume: { await callAutomationDispatcher.resumeAfterRelocation() }
            )
            await callAutomationStore.load()
            await callAutomationDispatcher.setStatusDidChange { [weak callAutomationStore] in
                await callAutomationStore?.refresh()
            }
            await callAutomationDispatcher.start()

            // The continuous semantic indexer owns ALL embedding: it fills vectors for frames/transcripts off the
            // hot path and UNLOADS the model when the backlog is drained. Its own EmbeddingService (search keeps a
            // separate one so an index batch never blocks a search-query embed). Started delayed @ .utility so the
            // 449MB model load stays off the launch path.
            let indexerEmbedder = EmbeddingService()
            let backfill = VectorBackfill(db: db, embedder: indexerEmbedder)
            let computeCoordinator = AIComputeCoordinator(
                vectorBackfill: AIComputeVectorBackfillHooks(
                    suspendAndDrain: { await backfill.suspendAndDrain() },
                    resume: { await backfill.resume() }
                )
            )
            await backfill.attachComputeCoordinator(computeCoordinator)
            self.aiComputeCoordinator = computeCoordinator

            let speechRoot = StorageLocation.speechModelRoot(under: resolvedDataRoot)
            do {
                try FileManager.default.createDirectory(
                    at: speechRoot,
                    withIntermediateDirectories: true
                )
                let whisperModelStore = WhisperModelStore(root: speechRoot)
                self.whisperModelStore = whisperModelStore
                let handySpeechModelStore = HandySpeechModelStore()
                self.handySpeechModelStore = handySpeechModelStore
                let speakerDiarizationModelStore = SpeakerDiarizationModelStore(
                    root: StorageLocation.speakerDiarizationModelRoot(under: resolvedDataRoot)
                )
                self.speakerDiarizationModelStore = speakerDiarizationModelStore
                let callTranscriptWorker = CallTranscriptWorker(
                    repository: callRepository,
                    computeCoordinator: computeCoordinator,
                    dataRoot: resolvedDataRoot,
                    modelStore: whisperModelStore,
                    handyModelStore: handySpeechModelStore,
                    afterSourceTransition: { [weak callAutomationDispatcher] in
                        await callAutomationDispatcher?.kick()
                    }
                )
                self.callTranscriptWorker = callTranscriptWorker
                let speakerDiarizationWorker = SpeakerDiarizationWorker(
                    repository: callRepository,
                    computeCoordinator: computeCoordinator,
                    dataRoot: resolvedDataRoot,
                    afterTransition: { [weak callAutomationDispatcher] in
                        await callAutomationDispatcher?.kick()
                    }
                )
                self.speakerDiarizationWorker = speakerDiarizationWorker
                let callEvidenceWorkerBarrier = CallEvidenceWorkerBarrier(
                    workers: [
                        .init(
                            suspend: {
                                await callTranscriptWorker
                                    .suspendAndDrainForPrivacyBarrier()
                                return true
                            },
                            resume: { await callTranscriptWorker.resumeFromPrivacyBarrier() }
                        ),
                        .init(
                            suspend: {
                                await speakerDiarizationWorker
                                    .suspendAndDrainForPrivacyBarrier()
                                return true
                            },
                            resume: { await speakerDiarizationWorker.resumeFromPrivacyBarrier() }
                        ),
                    ]
                )
                self.callEvidenceWorkerBarrier = callEvidenceWorkerBarrier
                await callEvidenceDeletionService.attachTranscriptWorker(
                    suspend: { await callEvidenceWorkerBarrier.suspend() },
                    resume: { await callEvidenceWorkerBarrier.resume() }
                )
                speechModel.attach(
                    whisperModelStore,
                    handyModelStore: handySpeechModelStore,
                    suspendWorker: { await callTranscriptWorker.suspendAndDrain() },
                    resumeWorker: { [weak self] in
                        let allowed = await MainActor.run {
                            self?.recording.lowDiskPaused == false
                                && self?.storageSettings.relocationInProgress == false
                        }
                        if allowed { await callTranscriptWorker.resume() }
                    }
                )
                speakerModel.attach(
                    speakerDiarizationModelStore,
                    suspendWorker: { await speakerDiarizationWorker.suspendAndDrain() },
                    resumeWorker: { [weak self] in
                        let allowed = await MainActor.run {
                            self?.recording.lowDiskPaused == false
                                && self?.storageSettings.relocationInProgress == false
                        }
                        if allowed { await speakerDiarizationWorker.resume() }
                    }
                )
                if storage.freeBytes() < DiskReservePolicy.standard.pauseBytes {
                    await callTranscriptWorker.suspendAndDrain()
                    await speakerDiarizationWorker.suspendAndDrain()
                }
                callTranscriptWorkerTask = Task.detached(priority: .utility) {
                    await callTranscriptWorker.runLoop()
                }
                speakerDiarizationWorkerTask = Task.detached(priority: .utility) {
                    await speakerDiarizationWorker.runLoop()
                }
                Task { @MainActor [speechModel] in
                    await speechModel.refresh()
                }
                Task { @MainActor [speakerModel] in
                    await speakerModel.refresh()
                }
            } catch {
                Log.audio.error("optional Whisper model storage unavailable")
            }

            let localDriver = MLXLocalRuntimeDriver()
            let localInference = LocalInferenceService(
                driver: localDriver,
                computeCoordinator: computeCoordinator
            )
            installLocalAIMemoryPressureHandler(for: localInference)

            // The data-root anti-split-brain guard has already passed. Pin the
            // manager below that exact resolved root for its entire lifetime.
            let modelRoot = StorageLocation.builtInModelRoot(under: resolvedDataRoot)
            do {
                try FileManager.default.createDirectory(
                    at: modelRoot,
                    withIntermediateDirectories: true
                )
                let hardware = await Task.detached(priority: .utility) {
                    BuiltInModelHardwareSnapshot.current()
                }.value
                let hardwareSupported = hardware.supports(.regular)
                builtInModels.setHardwareSupport(
                    hardwareSupported
                        ? .supported
                        : .unsupported(
                            reason: String(localized: "ZBS Eye Local currently requires an Apple silicon Mac16,5 with exactly 64 GB unified memory and macOS 15 or later.")
                        )
                )
                let providerBridge = BuiltInModelProviderBridge(providers: ai)
                let manager = try BuiltInModelManager(
                    dataRoot: modelRoot,
                    manifests: BuiltInModelManifest.all,
                    downloadClient: BuiltInDownloadClient(
                        allowedAssetHosts: BuiltInModelRuntimeSupport.allowedAssetHosts,
                        capacityCheck: { progress in
                            let available = (try? BuiltInModelRuntimeSupport.availableCapacity(
                                at: modelRoot
                            )) ?? 0
                            return BuiltInModelRuntimeSupport.downloadCapacityDecision(
                                progress,
                                availableBytes: available
                            )
                        }
                    ),
                    hardwareEligibility: { hardware.supports($0) },
                    capacityReader: {
                        try BuiltInModelRuntimeSupport.availableCapacity(at: $0)
                    },
                    candidateLoader: localInference.candidateLoader(),
                    runtimeDrainer: localInference.runtimeDrainer(),
                    effectHandler: { [weak self] effect in
                        let outcome: (BuiltInModelProviderEffectResult, LLMRouter?) = await MainActor.run {
                            guard let self else {
                                return (.retryablePersistenceFailure, nil)
                            }
                            let committed = providerBridge.handle(effect)
                            return (committed, self.llmRouter)
                        }
                        if outcome.0 == .applied {
                            await outcome.1?.selectionOrAuthorizationDidChange()
                        }
                        return outcome.0
                    }
                )
                self.builtInModelManager = manager
                self.builtInModelProviderBridge = providerBridge
                await builtInModels.attach(manager: manager, providers: ai)
                if hardwareSupported {
                    restartBuiltInModelReconciliation(
                        manager: manager,
                        providerBridge: providerBridge
                    )
                }
            } catch {
                builtInModels.setHardwareSupport(
                    .unavailable(reason: String(localized: "ZBS Eye Local could not open its model storage safely."))
                )
                let message = BuiltInModelFailureMessage.userFacing(error, context: .operation)
                Log.app.error(
                    "built-in model bootstrap failed closed: \(message, privacy: .public)"
                )
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(30))
                await backfill.run()
            }
            let retention = RetentionManager(
                db: db,
                storage: storage,
                callDeletion: callEvidenceDeletionService
            )
            self.retention = retention

            // The extension writes only fresh rendered DOM into this in-memory
            // store; the capture loop consumes it before AX/OCR.
            let browserContent = BrowserContentStore()

            let openCoverage: [CaptureCoverageInterval]
            switch try await CaptureCoverageQuery(database: db).openIntervals() {
            case .available(let intervals):
                openCoverage = intervals
            case .metadataUnavailable:
                openCoverage = []
            }
            let screenPermission = Self.capturePermission(
                from: permissions.snapshot.screenRecording
            )
            let captureHealthController = CaptureHealthController(
                nowMs: Self.epochMs(),
                intent: CaptureIntent(
                    screenEnabled: recording.wantsRecording,
                    systemAudioEnabled: recording.wantsRecording
                        && audioSettings.audioShouldCapture()
                        && audioSettings.recordSystemAudio
                ),
                permissions: [
                    .screen: screenPermission,
                    .systemAudio: screenPermission,
                ],
                openIntervals: openCoverage
            )
            self.captureHealthController = captureHealthController
            // ScreenCaptureKit start/update/stop calls from the persistent
            // screen stream and the system-audio stream share one FIFO owner.
            let sckResourceCoordinator = SCKResourceCoordinator()
            captureHealthController.setSnapshotSink { [weak self] snapshot in
                self?.captureHealth = snapshot
            }
            lastAutomaticCallPermissionAvailability = AutomaticCallPermissionAvailability(
                permissions.snapshot
            )
            permissions.onSnapshotChanged = { [weak self, weak captureHealthController] snapshot in
                let availability = AutomaticCallPermissionAvailability(snapshot)
                if let self,
                   self.lastAutomaticCallPermissionAvailability != availability {
                    self.lastAutomaticCallPermissionAvailability = availability
                    let isClosed = !CallAudioSourcePolicy.allowsAutomaticCallStart(
                        audioMode: self.audioSettings.audioMode,
                        manualOverride: self.audioSettings.manualAudioOverride,
                        microphoneAvailable: availability.microphone,
                        systemAudioAvailable: availability.systemAudio
                    )
                    self.calls.automaticStartAdmissionChanged(isClosed: isClosed)
                }
                let permission = Self.capturePermission(from: snapshot.screenRecording)
                captureHealthController?.setPermission(
                    permission,
                    for: .screen,
                    nowMs: Self.epochMs()
                )
                captureHealthController?.setPermission(
                    permission,
                    for: .systemAudio,
                    nowMs: Self.epochMs()
                )
                Task { [weak detector = self?.meetingDetector] in
                    await detector?.automaticCallAdmissionDidChange()
                }
            }

            // Capture loop (the heart). Starts on toggle in RecordingStore.
            let coordinator = CaptureCoordinator(
                ingest: ingestService,
                browserContent: browserContent,
                healthController: captureHealthController,
                resourceCoordinator: sckResourceCoordinator
            )
            coordinator.onFrame = { [weak self, weak rec = recording] capturedAt in
                rec?.noteFrame()
                Task { @MainActor [weak self] in
                    await self?.timelineStore?.noteFrameAvailable(at: capturedAt)
                }
            }
            // The independent disk monitor owns transitions. This cycle gate is
            // only a final admission check while an asynchronous drain settles.
            coordinator.diskOK = { [weak self] in
                guard let self else { return false }
                return !self.recording.lowDiskPaused
            }
            coordinator.isIgnoredApp = { [weak self] in self?.privacy.isIgnored($0) ?? false }
            coordinator.ignoredBundleIds = { [weak self] in Set(self?.privacy.ignoredBundleIds ?? []) }
            privacy.onIgnoredBundleIdsChanged = { [weak coordinator] in
                coordinator?.privacyExclusionsDidChange()
            }
            recording.coordinator = coordinator
            // Honest recording: won't start without the critical permissions (instead of a false green dot).
            recording.canCapture = { [weak self] in self?.permissions.allCriticalGranted ?? false }
            recording.blockedHint = {
                return "No permissions (Screen Recording + Accessibility). Recording turns on automatically once granted; click again to cancel"
            }

            // Audio recording + on-device transcription (step 10). Gate — transcription on + mic granted.
            let audioCoordinator = AudioCoordinator(
                storage: storage,
                ingest: ingestService,
                healthController: captureHealthController,
                resourceCoordinator: sckResourceCoordinator
            )
            audioCoordinator.onSegment = { [weak rec = recording] in rec?.noteAudioChunk() }
            recording.audio = audioCoordinator
            // Gates for RECORDING audio (without the speech permission: raw audio is valuable on its own — you'll
            // find it by time and play it back in the timeline; transcription is separate, when speech is available).
            // The microphone requires mic access; system audio — Screen Recording (already granted for screen) + its own toggle.
            recording.micEnabled = { [weak self] in
                guard let self else { return false }
                return self.audioSettings.audioShouldCapture()   // mode/meeting/override gate
                    && !self.recording.lowDiskPaused             // disk-guard gates audio too (not just screen)
                    && self.permissions.snapshot.microphone == .granted
            }
            recording.systemEnabled = { [weak self] in
                guard let self else { return false }
                return self.audioSettings.audioShouldCapture()
                    && self.audioSettings.recordSystemAudio
                    && !self.recording.lowDiskPaused
                    && self.permissions.snapshot.screenRecording == .granted
            }
            self.audio = audioCoordinator
            captureHealthController.setEffectSink { [weak self] effect in
                self?.handleCaptureHealthEffect(
                    effect,
                    controller: captureHealthController,
                    coordinator: coordinator,
                    audio: audioCoordinator,
                    ingest: ingestService,
                    database: db
                )
            }
            // Assign only after persistence effects are wired: a restored
            // privacy pause may immediately close a hydrated open interval.
            recording.healthController = captureHealthController
            let callAudio = CallAudioControl(
                installSink: { [weak audioCoordinator] sink in
                    await MainActor.run {
                        audioCoordinator?.installCallFrameSink(sink)
                    }
                },
                start: { [weak self, weak audioCoordinator]
                    requested, sinkLease, startAdmissionLease in
                    guard let audioCoordinator else { return .none }
                    let permitted = await MainActor.run { [weak self] in
                        guard let self else { return CallSourceSelection.none }
                        let sessionLockState = CaptureSessionPolicy.currentSessionLocked()
                        if sessionLockState != false {
                            self.latchAutomaticCallSessionBoundary(reason: .session)
                        }
                        guard self.calls.permitsCallAudioStart(startAdmissionLease),
                              !self.isCallLifecycleAdmissionClosed,
                              sessionLockState == false
                        else {
                            // This is the last check before physical audio startup. Latch the exact
                            // closing edge so a disk/session/maintenance gate that later reopens is
                            // still classified as temporary rather than a capture failure.
                            self.calls.automaticStartAdmissionChanged(isClosed: true)
                            return CallSourceSelection.none
                        }
                        let permitted = CallSourceSelection(
                            me: requested.me && self.permissions.snapshot.microphone == .granted,
                            system: requested.system
                                && self.permissions.snapshot.screenRecording == .granted
                        )
                        guard !permitted.isEmpty,
                              audioCoordinator.admitCallFrameSink(sinkLease)
                        else { return .none }
                        return permitted
                    }
                    return await audioCoordinator.beginExplicitCall(
                        permitted,
                        sinkLease: sinkLease
                    )
                },
                acceptedTargets: { [weak audioCoordinator] in
                    await audioCoordinator?.acceptedIngressTargets()
                        ?? AudioIngressTargets(me: nil, system: nil)
                },
                drainGaps: { [weak audioCoordinator] in
                    await audioCoordinator?.drainIngressGaps() ?? []
                },
                stop: { [weak audioCoordinator] in
                    await audioCoordinator?.endExplicitCall()
                }
            )
            let callCoordinator = CallCoordinator(
                repository: callRepository,
                mediaRoot: storage.mediaDirectory,
                audio: callAudio,
                afterSourceTransition: { [weak callAutomationDispatcher] in
                    await callAutomationDispatcher?.kick()
                }
            )
            calls.requestedSources = { [weak self] in
                guard let self else { return .none }
                // The background system-audio toggle protects the lightweight Timeline path.
                // A confirmed/explicit call always requests both attributable legs; otherwise a user
                // can unknowingly save only their own voice and the call recorder lies by omission.
                return CallAudioSourcePolicy.requestedSources(
                    audioMode: self.audioSettings.audioMode,
                    manualOverride: self.audioSettings.manualAudioOverride
                )
            }
            calls.automaticStartAdmissionAllowed = { [weak self] in
                guard let self else { return false }
                return CallAudioSourcePolicy.allowsAutomaticCallStart(
                    audioMode: self.audioSettings.audioMode,
                    manualOverride: self.audioSettings.manualAudioOverride,
                    microphoneAvailable: self.permissions.snapshot.microphone == .granted,
                    systemAudioAvailable: self.permissions.snapshot.screenRecording == .granted
                )
            }
            calls.attach(callCoordinator)
            calls.onManualStartWhileActive = { [weak self] callID in
                self?.claimAutomaticCall(callID: callID)
            }
            calls.onUserEndRequested = { [weak self] in
                self?.handleUserRequestedCallEnd()
            }
            calls.onEndCompleted = { [weak self] reason, didFinish in
                self?.handleCallEndCompleted(reason: reason, didFinish: didFinish)
            }
            // Clear the session-scoped manual audio override when recording truly stops (NOT on every
            // syncAudio re-sync — that fires each meeting edge and would wipe the override).
            recording.onSessionStop = { [weak self] in self?.audioSettings.clearManualOverride() }

            // Every external CoreAudio input owner can start a local Call. Known surfaces add
            // context, while the separate audio exclusion list is the only user-configured filter.
            let detector = MeetingDetector(excludedBundleIDs: { @MainActor [weak self] in
                Set(self?.audioSettings.autoCallExcludedBundleIDs ?? [])
            })
            self.meetingDetector = detector
            calls.onEndWillPrepare = { [weak self, weak detector] _ in
                guard let self,
                      let fingerprint = self.automaticCallFingerprint
                        ?? self.claimedCallDetectorFingerprint
                else { return }
                // Freeze the old owner set before audio/spool teardown can overlap a successor
                // microphone owner. Otherwise a late B could be folded into A and tombstoned when
                // Call Control, Audio Off, or privacy finishes A.
                self.callDetectionPolicy.reject(fingerprint: fingerprint)
                _ = await detector?.suppressSession(fingerprint: fingerprint)
            }
            installMeetingDetectorWakeForwarding(detector)
            audioSettings.onAutoCallExclusionsChanged = { [weak detector] _ in
                Task { await detector?.autoCallExclusionsDidChange() }
            }
            self.meetingTask = Task { [weak self] in
                for await evidence in await detector.start() {
                    guard let self else { return }
                    let decision = self.callDetectionPolicy.reduce(evidence)
                    await self.handleCallDetection(decision, evidence: evidence)
                    if self.recording.isCapturing { self.recording.syncAudio() }
                }
            }
            // Transcribe the segments left without text (crash/fail) — a minute after start.
            Task { [weak audioCoordinator] in
                try? await Task.sleep(for: .seconds(60))
                await audioCoordinator?.backfillUntranscribed(db: db, storage: storage)
            }

            // Search (hybrid FTS+vector) + timeline.
            let searchSvc = SearchService(
                db: db,
                embedder: EmbeddingService(),
                semanticPolicy: .coordinated(computeCoordinator)
            )
            let timelineSvc = TimelineService(db: db)
            let coverageQuery = CaptureCoverageQuery(database: db)
            let visualFrameImageLoader = VisualFrameImageLoader(
                mediaDirectory: storage.mediaDirectory
            )
            self.visualFrameImageLoader = visualFrameImageLoader
            self.timelineStore = TimelineStore(
                search: searchSvc,
                timeline: timelineSvc,
                coverage: coverageQuery,
                mediaDirectory: storage.mediaDirectory,
                imageLoader: visualFrameImageLoader
            )

            // Shared aggregation layer for the day's activity (one scan + segmentation + active time + batch text).
            // Reused by scenes, the cartographer, and the summary — deduping logic (Pro review #9).
            let activityRepo = DayActivityRepository(db: db)
            self.usageStats = UsageStatsService(db: db, repo: activityRepo)

            // Achievements: stats from the DB + counters → the achievement catalog (unlocks persist).
            self.achievements = AchievementStore(service: AchievementStatsService(db: db, repo: activityRepo))
            rewards.achievements = self.achievements   // the rewards know what's unlocked

            // One process-wide router boundary. Ask is the first migrated
            // consumer; later consumer slices reuse this exact actor instead of
            // creating private clients or fallback selection paths.
            let adapterOverlay = LLMAdapterRegistry()
            do {
                let processProviders = try ProcessProviderRuntimeFactory.make(
                    snapshotProvider: ai,
                    dataRoot: resolvedDataRoot
                )
                self.processProviderRuntimeOwner = processProviders.owner
                ai.configureProcessProviders(
                    codex: processProviders.codex,
                    claudeCode: processProviders.claudeCode,
                    overlay: adapterOverlay
                )
            } catch {
                // Process setup errors may contain executable or account paths.
                // Fail closed without copying those details into unified logs.
                Log.app.error("process AI providers failed closed")
            }
            await adapterOverlay.register(
                LLMAdapterRegistration(
                    providerID: AIProvider.zbsEyeLocal.rawValue,
                    executedLocally: true,
                    adapter: localInference
                )
            )
            let adapterRegistry = ApplicationLLMAdapterRegistry(
                providers: ai,
                overlay: adapterOverlay
            )
            let llmRouter = LLMRouter(
                snapshotProvider: ai,
                adapterRegistry: adapterRegistry
            )
            self.llmRouter = llmRouter
            ai.configureRouterChangeNotification { [weak llmRouter] in
                guard let llmRouter else { return }
                await llmRouter.selectionOrAuthorizationDidChange()
            }

            let consumerGenerator = RoutedAIConsumerGenerator(router: llmRouter)
            let automationAuditWriter = AutomationAuditWriter()
            self.automationAuditWriter = automationAuditWriter

            // "The day in activities": scenes on top of screen_captures (without a new table),
            // grouped into blocks; generated labels share the same process-wide router.
            let sceneSvc = SceneService(repo: activityRepo)
            self.sceneStore = SceneStore(
                service: sceneSvc,
                timeline: timelineSvc,
                labeler: BlockLabelService(generator: consumerGenerator),
                readiness: ai
            )

            // "Ask your memory": hybrid retrieval completes first, then the
            // exact authorized snapshot crosses the process-wide router.
            let askRetrieval = AskDatabaseRetrieval(search: searchSvc, db: db)
            let askService = AskService(
                retrieval: askRetrieval,
                router: llmRouter,
                coverage: coverageQuery
            )
            self.ask = AskStore(
                service: askService,
                readiness: ai,
                workspace: workspace,
                onQuestionSent: { AchievementCounters.bump(.questions) }
            )

            // Cartographer: AI insights for the day through the shared process-wide router.
            let cartographerSvc = CartographerService(
                repo: activityRepo,
                generator: consumerGenerator,
                auditWriter: automationAuditWriter
            )
            self.cartographer = CartographerStore(
                service: cartographerSvc,
                readiness: ai
            )

            // Automation v1 "day summary": collect→shared router→write.
            let summarySvc = DailySummaryService(
                repo: activityRepo,
                generator: consumerGenerator,
                auditWriter: automationAuditWriter
            )
            let automationsStore = DaySummaryStore(
                service: summarySvc,
                connections: connections,
                readiness: ai
            )
            automationsStore.startScheduler()   // "a recap by itself at the end of the day" (5-min tick, gates inside)
            self.automations = automationsStore

            // Export (anti-lock-in): markdown by day ± media.
            self.export = ExportService(
                db: db,
                mediaDirectory: storage.mediaDirectory,
                collectDay: { day in
                    try await summarySvc.collect(day: day, safety: .default)
                }
            )
            self.historyImporter = HistoryImporter(db: db)

            // Local REST /v1 (auth on everything except /health).
            let token = KeychainStore.apiToken()
            let browserToken = KeychainStore.browserIngestToken()
            let rec = recording
            let deps = ZBSEyeHTTPServer.Deps(
                search: searchSvc, timeline: timelineSvc, calls: callEvidenceQueryService,
                db: db, mediaDir: storage.mediaDirectory,
                token: token,
                browserToken: browserToken,
                browserContent: browserContent,
                version: AppVersion.current,
                isCapturing: { await MainActor.run { rec.isCapturing } },
                captureStatus: {
                    await MainActor.run { captureHealthController.snapshot }
                },
                toggleCapture: { enable in
                    await MainActor.run {
                        if let enable, enable == rec.isCapturing { return rec.isCapturing }
                        rec.toggle()
                        return rec.isCapturing
                    }
                },
                repairCapture: { [weak self] in
                    await self?.repairCapture()
                    return await MainActor.run { captureHealthController.snapshot }
                },
                mediaBytes: { storage.totalBytes() },
                browserDidIngestAt: { [weak self] date in
                    await MainActor.run { self?.server.noteBrowserSnapshot(at: date) }
                }
            )
            let server = ZBSEyeHTTPServer(deps: deps)
            self.httpServer = server
            Task { [weak self] in
                let port = await server.start()
                ZBSEyeHTTPServer.log("bootstrap: start -> \(String(describing: port))")
                if let port {
                    await MainActor.run {
                        self?.server.setActive(
                            port: port,
                            token: token,
                            browserToken: browserToken
                        )
                    }
                }
            }

            // Retention runs CONTINUOUSLY (not only at startup): immediately + every 30 min. A 24/7 uptime over weeks
            // must not let the disk drift past the limit between restarts.
            retentionTask = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    let report: PruneReport?
                    if let permit = automaticRetentionAdmission.currentPermit() {
                        do {
                            let automatic = try await retention.pruneAutomatically(
                                permit: permit,
                                admission: automaticRetentionAdmission
                            )
                            report = PruneReport(
                                framesDeleted: automatic.framesDeleted,
                                audioDeleted: automatic.audioDeleted,
                                callsDeleted: automatic.callsDeleted,
                                callBytesDeleted: automatic.callBytesDeleted,
                                orphansDeleted: 0
                            )
                        } catch AutomaticRetentionError.postCommitFileDeletionFailed {
                            Log.retention.error(
                                "automatic retention paused after post-commit media deletion failure"
                            )
                            report = nil
                        } catch {
                            Log.retention.error("automatic retention failed closed")
                            report = nil
                        }
                    } else {
                        report = nil
                    }
                    if let r = report,
                       r.framesDeleted + r.audioDeleted + r.callsDeleted + r.orphansDeleted > 0 {
                        Log.retention.info(
                            "prune: frames \(r.framesDeleted) audio \(r.audioDeleted) calls \(r.callsDeleted) orphans \(r.orphansDeleted)"
                        )
                    }
                    // 👁 delighter: warmly mark a crossed "round" memory milestone (once each)
                    if let frames = try? await db.pool.read({
                        try SystemAppFilter.visibleScreenCaptureStats(in: $0).frames
                    }) {
                        await MainActor.run { self?.celebrateMilestoneIfNeeded(frames: frames) }
                        if let progressStore = await MainActor.run(body: { self?.progress }) {
                            await progressStore.refresh()
                        }
                        if let achStore = await MainActor.run(body: { self?.achievements }) {
                            await achStore.refresh()
                        }
                    }
                    try? await Task.sleep(for: .seconds(1800))
                }
            }

            // Browser history: pull each browser's real URLs + visit times (Dia/Arc hide the URL from AX).
            // On-device only. Immediately + every 15 min, gated by a Settings toggle (default on) + pause.
            let browserHistoryImporter = BrowserHistoryImporter(db: db)
            self.browserHistoryImporter = browserHistoryImporter
            browserHistoryTask = Task.detached(priority: .background) { [weak self] in
                while !Task.isCancelled {
                    let on = UserDefaults.standard.object(forKey: "zbseye.browserHistory.enabled") as? Bool ?? true
                    let paused = await MainActor.run { self?.recording.pausedUntil != nil }
                    if on && !paused { _ = try? await browserHistoryImporter.run() }
                    try? await Task.sleep(for: .seconds(900))
                }
            }

            // iCloud backup: every 6h (+ manual in Settings + on exit). Gates inside (enabled && iCloud).
            backupTask = Task.detached(priority: .background) { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(6 * 3600))
                    guard !Task.isCancelled else { break }
                    let cfg = await MainActor.run { () -> (Bool, Int) in
                        (self?.backupSettings.enabled ?? false, self?.backupSettings.keepN ?? 7)
                    }
                    guard cfg.0, BackupManager.iCloudAvailable() else { continue }
                    if let r = try? await backupManager.makeBackup(keepN: cfg.1) {
                        await MainActor.run { self?.backupSettings.noteScheduledBackup(r) }
                        Log.app.info("iCloud backup: \(StorageSettingsStore.format(r.compressedBytes)) (\(r.frames) frames)")
                    }
                }
            }
        } catch {
            self.dataError = String(describing: error)
            Log.app.error("bootstrap_failed")
            ZBSEyeHTTPServer.log("bootstrap_failed")
        }

        // Permission polling (the user grants them in System Settings — the UI and autostart pick it up themselves).
        permissions.startPolling()
        // Cold-launch admission is evaluated before autostart. Disk monitoring
        // then continues independently of screen cycles, so audio-only capture
        // cannot outlive a low-disk transition.
        if storage != nil {
            await evaluateDiskPressure()
            lowDiskTask?.cancel()
            lowDiskTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, let self else { return }
                    await self.evaluateDiskPressure()
                }
            }
        }
        // Autostart: "eternal memory" resumes after a reboot/crash, if the user had it on.
        recording.startIfWanted()
        // Watcher (4s): (1) autostart on late permission grant; (2) audio-gate drift — mic/speech granted
        // AFTER recording started / lowDisk changed → re-sync the legs (previously required restarting recording).
        autostartTask = Task { [weak self] in
            var prevGates: (mic: Bool, system: Bool)? = nil
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self else { return }
                self.recording.startIfWanted()
                if self.recording.isCapturing {
                    // audio-gate drift (new permissions/settings/lowDisk) → re-sync the legs
                    let gates = (self.recording.micEnabled(), self.recording.systemEnabled())
                    if let prev = prevGates, prev != gates { self.recording.syncAudio() }
                    prevGates = gates
                } else {
                    prevGates = nil
                }
            }
        }
    }

    /// The migration only needs to distinguish a positively empty install from
    /// every kind of existing profile. Authoritative byte reconciliation stays
    /// at U2's finite-deletion boundary, so launch never walks the full history.
    nonisolated private static func classifyFreshKeepMediaProfile(
        db: ZBSEyeDatabase,
        storage: StorageManager
    ) async -> KeepMediaInventoryEvidence {
        let databaseIsEmpty = (try? await db.pool.read { database in
            let frames = try ScreenCaptureRow.fetchCount(database)
            let audio = try AudioCaptureRow.fetchCount(database)
            return frames == 0 && audio == 0
        })
        guard databaseIsEmpty == true else {
            return .uncertain(databaseIsEmpty == nil ? .databaseReadFailed : .existingProfileNeedsReconciliation)
        }
        let mediaIsEmpty = await Task.detached(priority: .utility) {
            try? FileManager.default.contentsOfDirectory(
                at: storage.mediaDirectory,
                includingPropertiesForKeys: nil
            ).isEmpty
        }.value
        guard mediaIsEmpty == true else {
            return .uncertain(mediaIsEmpty == nil ? .filesystemReadFailed : .existingProfileNeedsReconciliation)
        }
        return .positivelyEmpty
    }

    func pauseForPrivacy(minutes: Int) {
        // Close admission in the click's synchronous MainActor turn. Deferring this acquisition
        // into the task below would leave one run-loop window where queued microphone evidence
        // could start a Call after the person already asked for privacy.
        let admissionLease = acquireAutomaticCallAdmissionBarrier(.privacyTransition)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.releaseAutomaticCallAdmissionBarrier(admissionLease) }
            if let fingerprint = self.automaticCallFingerprint
                ?? self.claimedCallDetectorFingerprint {
                self.pendingAutomaticCallTemporarySuspension =
                    AutomaticCallTemporarySuspension(
                        kind: .privacyPause,
                        fingerprint: fingerprint
                    )
            }
            await self.calls.endAndWait(reason: .privacy)
            self.recording.pauseFor(minutes: minutes)
        }
    }

    /// History deletion (privacy): lastSeconds=nil → everything. Returns a report for the UI.
    func deleteHistory(lastSeconds: TimeInterval?) async -> PruneReport? {
        guard !storageSettings.relocationInProgress, let retention else { return nil }
        let admissionLease = acquireAutomaticCallAdmissionBarrier(.evidenceDeletion)
        defer { releaseAutomaticCallAdmissionBarrier(admissionLease) }
        // The upper bound is fixed AT THE MOMENT of the click: with recording running, "delete 15 minutes" must not
        // catch frames recorded during the deletion itself (batches take seconds).
        let now = Date()
        let toMs: Int64 = lastSeconds == nil ? Int64.max : msFromDate(now)
        let fromMs: Int64 = lastSeconds.map { msFromDate(now.addingTimeInterval(-$0)) } ?? 0
        var ownsWorkerResume = false
        var ownsSpeakerWorkerResume = false
        if let callTranscriptWorker {
            ownsWorkerResume = await callTranscriptWorker
                .suspendAndDrainForEvidenceMutation()
        }
        if let speakerDiarizationWorker {
            ownsSpeakerWorkerResume = await speakerDiarizationWorker
                .suspendAndDrainForEvidenceMutation()
        }
        // A privacy cut is terminal for an intersecting active Call Envelope. Flush/close it first;
        // live mutation would let the spool re-persist bytes after the accepted deletion boundary.
        await calls.endAndWait(reason: .privacy)
        // Release decoded screenshots immediately. Repeat after the storage
        // mutation so a decode admitted during the delete cannot republish
        // pixels that crossed this privacy boundary.
        timelineStore?.discardVisualStateForPrivacyErase()
        visualFrameImageLoader?.invalidateAllForPrivacyErase()
        // CRITICAL (privacy): an open VAD segment lives in memory — deleteRange doesn't see it.
        // We flush in-flight audio BEFORE the delete, otherwise "said a password → wipe" would survive
        // up to 28s of speech captured before the click (it would close and land in the DB AFTER the delete).
        await audio?.discardInFlight(from: dateFromMs(fromMs), to: lastSeconds == nil ? now : dateFromMs(toMs))
        let report = try? await retention.deleteRange(fromMs: fromMs, toMs: toMs)
        timelineStore?.discardVisualStateForPrivacyErase()
        visualFrameImageLoader?.invalidateAllForPrivacyErase()
        if ownsWorkerResume,
           !recording.lowDiskPaused,
           !storageSettings.relocationInProgress {
            await callTranscriptWorker?.resume()
        }
        if ownsSpeakerWorkerResume,
           !recording.lowDiskPaused,
           !storageSettings.relocationInProgress {
            await speakerDiarizationWorker?.resume()
        }
        if let r = report {
            Log.retention.info(
                "manual delete: frames \(r.framesDeleted) audio \(r.audioDeleted) calls \(r.callsDeleted)"
            )
        }
        await storageSettings.refresh(storage: storage)
        // the timeline cursor may have pointed into what was wiped — refresh it
        await timelineStore?.load()
        // PRIVACY (Pro NO-GO): derived private states are built on the deleted history —
        // we invalidate them, otherwise scenes/progress/Cartographer insights keep showing the wiped data.
        // currentScene in TimelineView recomputes itself (cursor onChange after load + the gate "the scene
        // contains the current moment").
        await sceneStore?.load()
        await progress?.refresh()
        cartographer?.reset()
        automations?.reset()   // DaySummaryStore.preview = LLM markdown over the wiped day (same class)
        AchievementCounters.set(.deletedPeriod)   // "Cleaner" achievement
        await achievements?.refresh()
        return report
    }

    /// One safe Settings facade for Keep Media. Finite admission is based on a
    /// fresh, quiet DB/filesystem reconciliation; shrinking below current use
    /// requires an exact confirmation and is rechecked before commit.
    func changeKeepMediaPolicy(
        _ policy: KeepMediaPolicy,
        confirmedRemovalBytes: Int64? = nil
    ) async -> KeepMediaChangeResult {
        await keepMediaPolicyCoordinator.change(
            policy,
            confirmedRemovalBytes: confirmedRemovalBytes,
            storageSettings: storageSettings,
            recording: recording,
            storage: storage,
            database: db,
            admission: automaticRetentionAdmission
        )
    }

    /// Move all of memory to a chosen folder (T1): pause and drain every DB writer → online DB backup + copy media →
    /// verify (integrity + COUNT parity) → flip StorageLocation → relaunch. We don't touch the source (copy);
    /// on error we resume recording, the data at the old location is intact.
    func relocate(to chosen: URL) async {
        guard let db, let storage, let ingest,
              !storageSettings.relocationInProgress else { return }
        guard automaticCallRejectionTask == nil,
              automaticCallRejectionCallID == nil,
              automaticCallRejectedEraseGate.allowsDataRootMutation else {
            storageSettings.relocationError =
                "Wait for the false call to finish permanent deletion before moving storage."
            return
        }
        guard !calls.isActive else {
            storageSettings.relocationError = "End the active call before moving storage. The recording was not interrupted."
            return
        }
        let previousRoot = StorageLocation.dataRoot()
        let previousRootWasRelocated = StorageLocation.isRelocated()
        var committedNewRoot = false
        storageSettings.relocationInProgress = true
        storageSettings.relocationError = nil
        storageSettings.relocationProgress = 0
        storageSettings.relocationStatus = "Stopping recording…"
        captureHealthController?.setSuspension(.maintenance, nowMs: Self.epochMs())
        await drainCaptureCoveragePersistence()
        let recordingDrainTask = Task { @MainActor [recording] in
            await recording.pauseForMaintenanceAndDrain(owner: .relocation)
        }

        let relocator = StorageRelocator()
        do {
            // Ordered barrier: stop transcript jobs before draining the model
            // store they read, then stop the remaining compute users. Capture
            // and audio stay independently paused for data consistency.
            if let builtInModelManager {
                _ = try await builtInModelManager.suspendAndDrainForRelocation()
            }
            await callAutomationDispatcher?.suspendAndDrainForRelocation()
            await callAutomation?.suspendAndDrain()
            await callTranscriptWorker?.suspendAndDrain()
            await speakerDiarizationWorker?.suspendAndDrain()
            await whisperModelStore?.suspendAndDrain()
            await speakerDiarizationModelStore?.suspendAndDrain()
            if let aiComputeCoordinator {
                try await aiComputeCoordinator.suspendAndDrain()
            }

            // These actors write directly through GRDB instead of IngestService.
            // Suspending their admission and draining the complete async operation
            // prevents a reentrant writer from changing COUNTs after the backup.
            let historyDrain = await historyImporter?.suspendAndDrainForRelocation()
            let browserHistoryDrain = await browserHistoryImporter?.suspendAndDrainForRelocation()
            let retentionDrain = await retention?.suspendAndDrainForRelocation()
            let automationAuditDrain = await automationAuditWriter?.suspendAndDrainForRelocation()

            let recordingDrain = await recordingDrainTask.value
            let ingestDrain = await ingest.suspendAndDrainForRelocation()
            guard recordingDrain.capture.activeCycles == 0,
                  recordingDrain.audio.activeLegs == 0,
                  recordingDrain.audio.systemCaptureOutcome.isConfirmedStopped,
                  recordingDrain.audio.transcriptionDrained,
                  ingestDrain.activeWrites == 0,
                  (historyDrain?.activeOperations ?? 0) == 0,
                  (browserHistoryDrain?.activeOperations ?? 0) == 0,
                  (retentionDrain?.activeOperations ?? 0) == 0,
                  (automationAuditDrain?.activeOperations ?? 0) == 0 else {
                throw RelocationError.verifyFailed(
                    "database writer maintenance drain was not acknowledged"
                )
            }
            let report = try await relocator.migrate(
                sourcePool: db.pool,
                sourceDBURL: try ZBSEyeDatabase.defaultURL(),
                sourceMedia: storage.mediaDirectory,
                chosen: chosen,
                progress: { p, msg in
                    Task { @MainActor in
                        self.storageSettings.relocationProgress = p
                        self.storageSettings.relocationStatus = msg
                    }
                })
            StorageLocation.setRoot(report.newDataRoot)
            committedNewRoot = true
            AchievementCounters.set(.relocated)   // "To Your Own Disk" achievement
            storageSettings.relocationStatus = "Moved (\(report.mediaFilesCopied) media). Restarting…"
            try? await Task.sleep(for: .milliseconds(600))   // let the UI show the status
            relocationTerminationHandoffInProgress = true
            relocationTerminationDrainTask = nil
            do {
                try await AppRelauncher.relaunchAcknowledged()
            } catch {
                relocationTerminationHandoffInProgress = false
                throw error
            }
        } catch {
            // A failed helper launch leaves this process and its old DB graph
            // alive. Restore path resolution before resuming any service, or
            // helpers/settings would point at the copied root while writers
            // still own the original one.
            let terminationDrain = relocationTerminationDrainTask
            relocationTerminationDrainTask = nil
            await AppRelocationFailureRecovery.run(
                committedNewRoot: committedNewRoot,
                restorePreviousRoot: {
                    if previousRootWasRelocated {
                        StorageLocation.setRoot(previousRoot)
                    } else {
                        StorageLocation.resetToLegacy()
                    }
                },
                awaitRecordingDrain: {
                    _ = await recordingDrainTask.value
                },
                awaitTerminationHandoffDrain: {
                    _ = await terminationDrain?.value
                },
                resumeOldGraphAdmissions: {
                    await self.ingest?.resumeAfterRelocation()
                    await self.callAutomationDispatcher?.resumeAfterRelocation()
                    await self.callAutomation?.resumeAfterSuspension()
                    await self.automationAuditWriter?.resumeAfterRelocation()
                    await self.retention?.resumeAfterRelocation()
                    await self.browserHistoryImporter?.resumeAfterRelocation()
                    await self.historyImporter?.resumeAfterRelocation()
                    // Resume compute admission before reloading the old LKG:
                    // the candidate loader itself takes the MLX lease and
                    // suspends backfill again while warming the old-root LKG.
                    await self.aiComputeCoordinator?.resume()
                    try? await self.builtInModelManager?.resumeAfterRelocation()
                    await self.whisperModelStore?.resumeAfterDrain()
                    await self.speakerDiarizationModelStore?.resumeAfterDrain()
                    await self.callTranscriptWorker?.resume()
                    await self.speakerDiarizationWorker?.resume()
                    await self.builtInModels.refresh()
                    self.captureHealthController?.setSuspension(nil, nowMs: Self.epochMs())
                    let recordingDrain = await recordingDrainTask.value
                    self.recording.resumeAfterMaintenance(recordingDrain.lease)
                }
            )
            storageSettings.relocationInProgress = false
            storageSettings.relocationError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    private func evaluateDiskPressure() async {
        guard let storage else { return }
        let available = await Task.detached(priority: .utility) {
            storage.availableCapacityForImportantUsage()
        }.value
        switch lowDiskGuard.evaluate(availableBytes: available) {
        case .none:
            return
        case .pauseCapture:
            audio?.closeCallFrameAdmission()
            calls.automaticStartAdmissionChanged(isClosed: true)
            captureHealthController?.setSuspension(.lowDisk, nowMs: Self.epochMs())
            await drainCaptureCoveragePersistence()
            // Stop speech scratch work first, then close the explicit Call
            // Envelope before draining the shared physical capture legs.
            await callTranscriptWorker?.suspendAndDrain()
            await speakerDiarizationWorker?.suspendAndDrain()
            await calls.endAndWait(reason: .lowDisk)
            let drain = await recording.pauseForLowDiskAndDrain(
                systemCaptureTimeout: .seconds(5)
            )
            lowDiskDrainConfirmed = LowDiskDrainGate.isConfirmedStopped(drain)
            if !lowDiskDrainConfirmed {
                Log.audio.error("low-disk pause remains closed: capture teardown was not confirmed")
            }
        case .resumeCapture:
            calls.automaticStartAdmissionChanged(isClosed: false)
            if !lowDiskDrainConfirmed {
                let retry = await recording.pauseForLowDiskAndDrain(
                    systemCaptureTimeout: .seconds(5)
                )
                lowDiskDrainConfirmed = LowDiskDrainGate.isConfirmedStopped(retry)
            }
            guard lowDiskDrainConfirmed else {
                lowDiskGuard.holdPaused()
                Log.audio.error("low-disk recovery withheld: capture teardown is still unconfirmed")
                return
            }
            // Low disk is a temporary admission barrier, not a user rejection. Keep the reducer
            // suppressing the old fingerprint while the detector releases it; the fresh detector
            // activation gets a new identity and can then qualify the same still-running mic.
            if let fingerprint = lowDiskSuspendedDetectorFingerprint {
                callDetectionPolicy.reject(fingerprint: fingerprint)
                await meetingDetector?.releaseSession(fingerprint: fingerprint)
                lowDiskSuspendedDetectorFingerprint = nil
            }
            captureHealthController?.setSuspension(nil, nowMs: Self.epochMs())
            recording.resumeAfterLowDisk()
            await callTranscriptWorker?.resume()
            await speakerDiarizationWorker?.resume()
            await meetingDetector?.automaticCallAdmissionDidChange()
        }
    }

    private func installMeetingDetectorWakeForwarding(_ detector: MeetingDetector) {
        let center = NSWorkspace.shared.notificationCenter
        for observer in meetingWakeObservers {
            center.removeObserver(observer)
        }
        let sleepingNotifications: [(Notification.Name, CaptureSuspensionReasons)] = [
            (NSWorkspace.willSleepNotification, .systemSleep),
            (NSWorkspace.screensDidSleepNotification, .displaySleep),
        ]
        let wakingNotifications: [(Notification.Name, CaptureSuspensionReasons)] = [
            (NSWorkspace.didWakeNotification, .systemSleep),
            (NSWorkspace.screensDidWakeNotification, .displaySleep),
        ]
        meetingWakeObservers = sleepingNotifications.map { name, reason in
            center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.latchAutomaticCallSessionBoundary(reason: reason)
                    Task { @MainActor [weak self] in
                        await self?.finishAutomaticCallSessionBoundary()
                    }
                }
            }
        } + wakingNotifications.map { name, reason in
            center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self, weak detector] _ in
                Task { @MainActor in
                    await detector?.systemDidWake()
                    await self?.reconcileAutomaticCallSessionAdmission(clearing: reason)
                }
            }
        }

        let distributed = DistributedNotificationCenter.default()
        for observer in meetingSessionObservers {
            distributed.removeObserver(observer)
        }
        let closedNotifications: [(Notification.Name, CaptureSuspensionReasons)] = [
            (Notification.Name("com.apple.screenIsLocked"), .session),
            (Notification.Name("com.apple.screensaver.didstart"), .screenSaver),
        ]
        let openHints: [(Notification.Name, CaptureSuspensionReasons)] = [
            (Notification.Name("com.apple.screenIsUnlocked"), .session),
            (Notification.Name("com.apple.screensaver.didstop"), .screenSaver),
        ]
        meetingSessionObservers = closedNotifications.map { name, reason in
            distributed.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.latchAutomaticCallSessionBoundary(reason: reason)
                    Task { @MainActor [weak self] in
                        await self?.finishAutomaticCallSessionBoundary()
                    }
                }
            }
        } + openHints.map { name, reason in
            distributed.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.reconcileAutomaticCallSessionAdmission(clearing: reason)
                }
            }
        }
    }

    private func closeAutomaticCallForSessionBoundary(
        reason: CaptureSuspensionReasons = .session
    ) async {
        latchAutomaticCallSessionBoundary(reason: reason)
        await finishAutomaticCallSessionBoundary()
    }

    /// Notification callbacks are delivered on the main queue, but their closure type is not
    /// actor-isolated. They call this through `MainActor.assumeIsolated` before returning so no
    /// queued microphone edge can cross a lock/sleep boundary.
    private func latchAutomaticCallSessionBoundary(reason: CaptureSuspensionReasons) {
        // Close the active spool in this exact MainActor turn. The end path deliberately performs
        // detector/persistence work before detaching its sink, so start admission alone is not a
        // sufficient privacy boundary for already queued audio frames.
        audio?.closeCallFrameAdmission()
        let wasClosed = isCallLifecycleAdmissionClosed
        automaticCallSessionGate = CaptureSessionPolicy.suspendedGate(
            previous: automaticCallSessionGate,
            adding: reason
        )
        if !wasClosed {
            calls.automaticStartAdmissionChanged(isClosed: true)
        }
        if let fingerprint = automaticCallFingerprint ?? claimedCallDetectorFingerprint {
            pendingAutomaticCallTemporarySuspension = AutomaticCallTemporarySuspension(
                kind: .sessionLock,
                fingerprint: fingerprint
            )
        }
    }

    private func finishAutomaticCallSessionBoundary() async {
        await calls.endAndWait(reason: .privacy)
    }

    @discardableResult
    private func reconcileAutomaticCallSessionAdmission(
        clearing reason: CaptureSuspensionReasons? = nil
    ) async -> Bool {
        let previous = automaticCallSessionGate
        let sessionLockedNow = CaptureSessionPolicy.currentSessionLocked()
        let next: CaptureSessionGateState
        if let reason {
            next = CaptureSessionPolicy.resumeSignalGate(
                previous: previous,
                clearing: reason,
                sessionLockedNow: sessionLockedNow
            )
        } else if let periodic = CaptureSessionPolicy.periodicGate(
            previous: previous,
            sessionLockedNow: sessionLockedNow
        ) {
            next = periodic
        } else {
            next = CaptureSessionPolicy.suspendedGate(
                previous: previous,
                adding: .session
            )
        }
        automaticCallSessionGate = next

        guard next.isOpen else {
            audio?.closeCallFrameAdmission()
            if previous.isOpen {
                calls.automaticStartAdmissionChanged(isClosed: true)
            }
            if let fingerprint = automaticCallFingerprint ?? claimedCallDetectorFingerprint {
                pendingAutomaticCallTemporarySuspension = AutomaticCallTemporarySuspension(
                    kind: .sessionLock,
                    fingerprint: fingerprint
                )
            }
            await finishAutomaticCallSessionBoundary()
            return false
        }

        if !previous.isOpen {
            resumeTemporarilySuspendedAutomaticCall(kind: .sessionLock)
            await meetingDetector?.automaticCallAdmissionDidChange()
        }
        return true
    }

    private func handleCallDetection(
        _ decision: CallDetectionDecision,
        evidence: CallEvidenceSnapshot
    ) async {
        guard await reconcileAutomaticCallSessionAdmission() else {
            audioSettings.meetingActive = false
            if case let .start(fingerprint) = decision {
                callDetectionPolicy.reject(fingerprint: fingerprint)
                await meetingDetector?.releaseSession(fingerprint: fingerprint)
            }
            return
        }
        switch decision {
        case .none:
            audioSettings.meetingActive = false

        case let .start(fingerprint):
            audioSettings.meetingActive = true
            // The detector stream is intentionally unbounded so a brief MainActor stall cannot
            // overwrite a positive microphone edge with a later idle sample. That also means an
            // edge collected just before the user changes this privacy setting can still be queued.
            // This is the first live guard; it is repeated after every start-side await below.
            let detectedBundleID = evidence.microphoneOwnerBundleID
                ?? evidence.surface?.ownerBundleID
            if AutomaticCallExclusionBoundary.blocks(
                sourceBundleID: detectedBundleID,
                excludedBundleIDs: Set(audioSettings.autoCallExcludedBundleIDs)
            ) {
                audioSettings.meetingActive = false
                callDetectionPolicy.reject(fingerprint: fingerprint)
                await meetingDetector?.releaseSession(fingerprint: fingerprint)
                return
            }
            if isAutomaticCallAdmissionTemporarilyClosed {
                // A call first appearing while a temporary admission barrier is closed is not a
                // failed/rejected call. Release only this detector identity so the same still-
                // running surface can qualify again after privacy pause/relocation/low disk ends.
                audioSettings.meetingActive = false
                callDetectionPolicy.reject(fingerprint: fingerprint)
                await meetingDetector?.releaseSession(fingerprint: fingerprint)
                return
            }
            if automaticCallSuccessorProbeGate.deferIfDifferentOwnerStillActive(
                activeFingerprint: automaticCallFingerprint,
                candidateFingerprint: fingerprint
            ) {
                // Policy has already promoted the successor to active, but its Call cannot start
                // until the previous envelope confirms teardown. Release that transient identity
                // and re-probe it exactly once after the old owner clears.
                audioSettings.meetingActive = false
                if let ownedFingerprint = automaticCallFingerprint {
                    callDetectionPolicy.reject(fingerprint: ownedFingerprint)
                }
                await meetingDetector?.releaseSession(fingerprint: fingerprint)
                return
            }
            guard automaticCallFingerprint == nil else { return }
            // Publish detector ownership before the first await. If privacy/maintenance joins this
            // start, `onEndCompleted` now owns suppression and releases it only after audio teardown.
            automaticCallFingerprint = fingerprint
            let startResult = await calls.startAutomatic(
                idempotencyKey: "automatic:\(fingerprint)"
            )
            switch startResult {
            case .interruptedByEnd:
                return
            case .admissionClosed:
                audioSettings.meetingActive = false
                // The Store latches the exact failed admission check. Do not re-read the current
                // barrier after the await: it may already have reopened.
                callDetectionPolicy.reject(fingerprint: fingerprint)
                await meetingDetector?.releaseSession(fingerprint: fingerprint)
                if automaticCallFingerprint == fingerprint {
                    automaticCallFingerprint = nil
                }
                if !isAutomaticCallAdmissionTemporarilyClosed {
                    await meetingDetector?.automaticCallAdmissionDidChange()
                }
                Log.meetingDetection.info(
                    "automatic_call_start_deferred transient_admission_barrier=true"
                )
                return
            case .failed:
                audioSettings.meetingActive = false
                // A real capture failure (sources off or coordinator failure) is suppressed until
                // disappearance so the detector does not spin on the same surface.
                callDetectionPolicy.reject(fingerprint: fingerprint)
                await meetingDetector?.suppressSession(fingerprint: fingerprint)
                if automaticCallFingerprint == fingerprint {
                    automaticCallFingerprint = nil
                }
                Log.meetingDetection.error(
                    "automatic_call_start_failed suppressed_until_idle=true"
                )
                return
            case let .started(snapshot):
                guard let callID = snapshot.callID,
                      automaticCallFingerprint == fingerprint,
                      calls.canPublishAutomaticStart(callID: callID)
                else {
                    // A terminal end began after `startAutomatic` produced its success. The
                    // completion callback owns detector teardown; never suppress early here.
                    return
                }
                let nowMs = msFromDate(Date())
                let bundleID = evidence.microphoneOwnerBundleID
                    ?? evidence.surface?.ownerBundleID
                let appName = evidence.microphoneOwnerDisplayName ?? bundleID.flatMap {
                    NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName
                }
                let initialContext = AutomaticCallContextEvidence(
                    callID: callID,
                    detectorFingerprint: fingerprint,
                    sourceAppBundleID: bundleID,
                    sourceAppName: appName,
                    trustedOriginHost: evidence.surface?.trustedOrigin?.host,
                    sourceIsKnownCallSurface:
                        AutomaticCallContextEvidence.isKnownCallSurface(evidence.surface)
                )
                var persistedInitialContext = false
                if let callRepository {
                    do {
                        try await callRepository.enrichAutomaticCallContext(
                            callID: callID,
                            detectorFingerprint: fingerprint,
                            sourceAppBundleID: initialContext.sourceAppBundleID,
                            sourceAppName: initialContext.sourceAppName,
                            trustedOriginHost: initialContext.trustedOriginHost,
                            replaceExistingSource: false,
                            nowMs: nowMs
                        )
                        persistedInitialContext = true
                    } catch {
                        persistedInitialContext = false
                    }
                }
                guard calls.canPublishAutomaticStart(callID: callID),
                      automaticCallFingerprint == fingerprint
                else {
                    return
                }
                let becameExcludedDuringStart = AutomaticCallExclusionBoundary.blocks(
                    sourceBundleID: initialContext.sourceAppBundleID,
                    excludedBundleIDs: Set(audioSettings.autoCallExcludedBundleIDs)
                )
                automaticCallContextEvidence = persistedInitialContext ? initialContext : nil
                guard automaticCallEndLifecycle.didStart(
                    callID: callID,
                    fingerprint: fingerprint
                ) else {
                    Log.meetingDetection.error(
                        "automatic_call_lifecycle_refused_start call_id=\(callID)"
                    )
                    return
                }
                cancelAutomaticCallSavedBanner()
                automaticCallBanner = AutomaticCallBannerState(
                    phase: .started,
                    callID: callID,
                    deadline: nil,
                    sourceAppName: initialContext.sourceAppName,
                    sourceAppBundleID: initialContext.sourceAppBundleID
                )
                if becameExcludedDuringStart {
                    // The Call already owns physical tracks, so a late Settings change preserves
                    // what was captured and performs one immediate user save. It is never silently
                    // released or reclassified as "This wasn't a call" deletion.
                    beginDetectedCallFinish(
                        callID: callID,
                        fingerprint: fingerprint,
                        reason: .user,
                        allowStartedPhase: true
                    )
                }
            }

        case let .activity(fingerprint):
            guard AutomaticCallActivityResumeGate.allowsResume(
                    evidenceIsStale: evidence.isStale,
                    microphoneAudioActive: evidence.microphoneAudioActive
                  ),
                  automaticCallFingerprint == fingerprint,
                  automaticCallFinalizationCallID == nil,
                  calls.snapshot.phase == .recording,
                  let callID = calls.snapshot.callID,
                  automaticCallEndLifecycle.resume(
                    callID: callID,
                    fingerprint: fingerprint
                  )
            else { return }
            audioSettings.meetingActive = true
            automaticCallEndGraceTask?.cancel()
            automaticCallEndGraceTask = nil
            if calls.canPublishAutomaticResume(callID: callID),
               automaticCallFingerprint == fingerprint {
                let bundleID = evidence.microphoneOwnerBundleID
                    ?? evidence.surface?.ownerBundleID
                    ?? automaticCallBanner?.sourceAppBundleID
                let appName = evidence.microphoneOwnerDisplayName ?? bundleID.flatMap {
                    NSRunningApplication.runningApplications(withBundleIdentifier: $0)
                        .first?.localizedName
                } ?? automaticCallBanner?.sourceAppName
                let baseline = automaticCallContextEvidence.flatMap {
                    $0.callID == callID ? $0 : nil
                } ?? AutomaticCallContextEvidence(
                    callID: callID,
                    detectorFingerprint: fingerprint,
                    sourceAppBundleID: nil,
                    sourceAppName: nil,
                    trustedOriginHost: nil,
                    sourceIsKnownCallSurface: false
                )
                let incomingIsKnownCallSurface =
                    AutomaticCallContextEvidence.isKnownCallSurface(evidence.surface)
                let enriched = baseline.merging(
                    sourceAppBundleID: bundleID,
                    sourceAppName: appName,
                    trustedOriginHost: evidence.surface?.trustedOrigin?.host,
                    sourceIsKnownCallSurface: incomingIsKnownCallSurface
                )
                if enriched != automaticCallContextEvidence,
                   let callRepository {
                    do {
                        try await callRepository.enrichAutomaticCallContext(
                            callID: callID,
                            detectorFingerprint: fingerprint,
                            sourceAppBundleID: enriched.sourceAppBundleID,
                            sourceAppName: enriched.sourceAppName,
                            trustedOriginHost: enriched.trustedOriginHost,
                            replaceExistingSource: incomingIsKnownCallSurface
                                && !baseline.sourceIsKnownCallSurface,
                            nowMs: msFromDate(Date())
                        )
                        if calls.snapshot.callID == callID,
                           automaticCallFingerprint == fingerprint {
                            automaticCallContextEvidence = enriched
                        }
                    } catch {
                        // Keep the previous cache so the next healthy evidence tick retries locally.
                    }
                }
                // Repository enrichment suspends MainActor. A newer end/grace transition owns the
                // UI if it happened while SQLite was busy; this older activity event must not
                // resurrect a started banner for a Call that is already ending or closed.
                guard self.automaticCallFingerprint == fingerprint,
                      self.automaticCallFinalizationCallID == nil,
                      self.calls.canPublishAutomaticResume(callID: callID),
                      self.automaticCallEndLifecycle.isRecording(
                        callID: callID,
                        fingerprint: fingerprint
                      ),
                      self.automaticCallBanner?.callID == callID
                else { return }
                automaticCallBanner = AutomaticCallBannerState(
                    phase: .started,
                    callID: callID,
                    deadline: nil,
                    sourceAppName: enriched.sourceAppName,
                    sourceAppBundleID: enriched.sourceAppBundleID
                )
            }

        case let .strongEnd(fingerprint):
            audioSettings.meetingActive = false
            guard automaticCallFingerprint == fingerprint,
                  calls.snapshot.phase == .recording,
                  automaticCallEndGraceTask == nil
            else { return }
            guard let callID = calls.snapshot.callID else { return }
            scheduleDetectedCallEndGrace(callID: callID, fingerprint: fingerprint)

        case let .becameIdle(fingerprint):
            audioSettings.meetingActive = false
            await meetingDetector?.releaseSession(fingerprint: fingerprint)
        }
    }

    private var isCallDiskAdmissionClosed: Bool {
        // `LowDiskGuard.state` owns the whole hysteresis interval and flips to `.paused` before
        // the first drain await. The live nullable volume query closes the smaller window before
        // the periodic guard observes an unplugged/unreadable external volume.
        AutomaticCallDiskAdmissionPolicy.isClosed(
            guardState: lowDiskGuard.state,
            recordingLowDiskPaused: recording.lowDiskPaused,
            availableBytes: storage?.availableCapacityForImportantUsage()
        )
    }

    private var isCallLifecycleAdmissionClosed: Bool {
        isCallDiskAdmissionClosed
            || recording.pausedUntil != nil
            || !recording.maintenancePermitsStart
            || storageSettings.relocationInProgress
            || automaticCallAdmissionBarrier.isClosed
            || !automaticCallSessionGate.isOpen
            || AutomaticCallRearmAdmissionGate.isClosed(
                releaseInProgressFingerprint: automaticCallRearmInProgressFingerprint
            )
            || !automaticCallRejectedEraseGate.allowsAutomaticCallAdmission
    }

    private var isAutomaticCallAdmissionTemporarilyClosed: Bool {
        isCallLifecycleAdmissionClosed
            || !CallAudioSourcePolicy.allowsAutomaticCallStart(
                audioMode: audioSettings.audioMode,
                manualOverride: audioSettings.manualAudioOverride,
                microphoneAvailable: permissions.snapshot.microphone == .granted,
                systemAudioAvailable: permissions.snapshot.screenRecording == .granted
            )
    }

    private func acquireAutomaticCallAdmissionBarrier(
        _ reason: AutomaticCallAdmissionBarrierReason
    ) -> AutomaticCallAdmissionBarrierLease {
        let wasClosed = isCallLifecycleAdmissionClosed
        let lease = automaticCallAdmissionBarrier.acquire(reason)
        audio?.closeCallFrameAdmission()
        if !wasClosed {
            calls.automaticStartAdmissionChanged(isClosed: true)
        }
        return lease
    }

    private func releaseAutomaticCallAdmissionBarrier(
        _ lease: AutomaticCallAdmissionBarrierLease
    ) {
        guard automaticCallAdmissionBarrier.release(lease) else { return }
        guard !isAutomaticCallAdmissionTemporarilyClosed else { return }
        Task { [weak meetingDetector] in
            await meetingDetector?.automaticCallAdmissionDidChange()
        }
    }

    private func scheduleDetectedCallEndGrace(callID: Int64, fingerprint: String) {
        guard automaticCallFingerprint == fingerprint,
              automaticCallFinalizationCallID == nil,
              automaticCallRejectionCallID == nil,
              automaticCallEndGraceTask == nil,
              calls.snapshot.phase == .recording,
              calls.snapshot.callID == callID
        else { return }

        guard let deadline = automaticCallEndLifecycle.beginGrace(
            callID: callID,
            fingerprint: fingerprint,
            now: Date()
        ) else { return }
        automaticCallBanner = AutomaticCallBannerState(
            phase: .endingGrace,
            callID: callID,
            deadline: deadline,
            sourceAppName: automaticCallBanner?.sourceAppName,
            sourceAppBundleID: automaticCallBanner?.sourceAppBundleID
        )
        automaticCallEndGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled,
                  let self,
                  self.automaticCallFingerprint == fingerprint,
                  self.automaticCallBanner?.phase == .endingGrace,
                  self.automaticCallBanner?.callID == callID
            else { return }
            self.automaticCallEndGraceTask = nil
            self.beginDetectedCallFinish(
                callID: callID,
                fingerprint: fingerprint,
                reason: .automatic
            )
        }
    }

    func endDetectedCallAndSave() {
        guard let banner = automaticCallBanner,
              banner.phase == .endingGrace,
              let fingerprint = automaticCallFingerprint
        else { return }
        beginDetectedCallFinish(
            callID: banner.callID,
            fingerprint: fingerprint,
            reason: .user,
            allowStartedPhase: false
        )
    }

    /// A confirmed per-app exclusion is intentionally separate from screen privacy. The current
    /// recording is preserved and finalized once; only later automatic Call admission changes.
    func neverAutoRecordDetectedApp(_ target: AutomaticCallExclusionTarget) {
        guard let banner = automaticCallBanner,
              banner.phase == .started || banner.phase == .endingGrace,
              banner.callID == target.callID,
              let fingerprint = automaticCallFingerprint,
              automaticCallFinalizationCallID == nil,
              automaticCallRejectionCallID == nil
        else { return }

        _ = audioSettings.addAutoCallExcludedApp(
            bundleID: target.bundleID,
            displayName: target.displayName
        )
        guard audioSettings.isAutoCallExcluded(target.bundleID) else { return }
        beginDetectedCallFinish(
            callID: banner.callID,
            fingerprint: fingerprint,
            reason: .user,
            allowStartedPhase: true
        )
    }

    /// Claims the finish synchronously so a double click, the grace timeout, and fresh detector
    /// activity cannot start competing terminal owners before the first suspension point.
    private func beginDetectedCallFinish(
        callID: Int64,
        fingerprint: String,
        reason: CallStopReason,
        allowStartedPhase: Bool = false
    ) {
        let phase = automaticCallBanner?.phase
        guard reason == .automatic || reason == .user,
              automaticCallFinalizationCallID == nil,
              automaticCallRejectionCallID == nil,
              automaticCallFingerprint == fingerprint,
              phase == .endingGrace || (allowStartedPhase && phase == .started),
              automaticCallBanner?.callID == callID,
              calls.snapshot.phase == .recording,
              calls.snapshot.callID == callID
        else { return }

        let sourceAppName = automaticCallBanner?.sourceAppName
        let sourceAppBundleID = automaticCallBanner?.sourceAppBundleID
        let finishIntent: AutomaticCallEndLifecycle.FinishIntent =
            reason == .automatic ? .automaticTimeout : .userSave
        guard automaticCallEndLifecycle.claimFinish(
            callID: callID,
            fingerprint: fingerprint,
            intent: finishIntent,
            allowWhileRecording: allowStartedPhase
        ) else { return }
        if reason == .user {
            // End & save is authoritative immediately. Detector suppression may suspend while it
            // freezes the old owner set, but no later audio frame belongs to the saved envelope.
            audio?.closeCallFrameAdmission()
        }
        automaticCallFinalizationCallID = callID
        automaticCallEndGraceTask?.cancel()
        automaticCallEndGraceTask = nil
        cancelAutomaticCallSavedBanner()
        automaticCallBanner = AutomaticCallBannerState(
            phase: .finalizing,
            callID: callID,
            deadline: nil,
            sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Timeout must make one final local CoreAudio check. If input returned before physical
            // teardown, the same Call resumes; an explicit End & save remains authoritative.
            let suppression = await self.meetingDetector?.suppressSession(
                fingerprint: fingerprint,
                resumeIfMicrophoneActive: reason == .automatic
            ) ?? .suppressed
            guard self.automaticCallFinalizationCallID == callID,
                  self.automaticCallFingerprint == fingerprint
            else { return }
            if AutomaticCallTimeoutResumeGate.allowsResume(
                microphoneActivityResumed: suppression == .activityResumed,
                callCanStillPublish: self.calls.canPublishAutomaticResume(callID: callID)
            ),
               self.automaticCallEndLifecycle.cancelAutomaticTimeoutForActivity(
                    callID: callID,
                    fingerprint: fingerprint
               ) {
                self.automaticCallFinalizationCallID = nil
                self.audioSettings.meetingActive = true
                self.automaticCallBanner = AutomaticCallBannerState(
                    phase: .started,
                    callID: callID,
                    deadline: nil,
                    sourceAppName: sourceAppName,
                    sourceAppBundleID: sourceAppBundleID
                )
                return
            }
            // An automatic timeout stays reversible through the final live microphone recheck.
            // Once that check confirms the end, close frame admission before any teardown await.
            self.audio?.closeCallFrameAdmission()
            self.audioSettings.meetingActive = false
            self.callDetectionPolicy.reject(fingerprint: fingerprint)
            let ended = await self.calls.finishAutomaticAndWait(reason: reason)
            guard self.automaticCallFinalizationCallID == callID,
                  self.automaticCallFingerprint == fingerprint
            else { return }

            self.automaticCallFinalizationCallID = nil
            if self.pendingAutomaticCallTemporarySuspension?.fingerprint == fingerprint {
                // A temporary gate arrived after this end had already sealed. The original
                // explicit/timeout finish remains authoritative; do not leak that late request
                // into a future detector session.
                self.pendingAutomaticCallTemporarySuspension = nil
            }
            let didFinish: Bool
            let didCloseExpectedEnvelope: Bool
            if let ended, ended.callID == callID {
                switch ended.phase {
                case .pendingTranscription, .ready, .readyDegraded:
                    // `ended` is the immutable outcome for Call A. A manual/REST Call B may have
                    // started after Store teardown resumed this continuation; B cannot revoke A's
                    // durable save or keep A's detector ownership alive.
                    didFinish = true
                    didCloseExpectedEnvelope = true
                case .idle, .failed:
                    didFinish = false
                    didCloseExpectedEnvelope = true
                case .starting, .recording, .finalizing:
                    didFinish = false
                    didCloseExpectedEnvelope = false
                }
            } else {
                didFinish = false
                didCloseExpectedEnvelope = false
            }
            _ = self.automaticCallEndLifecycle.complete(
                callID: callID,
                fingerprint: fingerprint,
                succeeded: didFinish
            )
            if didFinish {
                self.automaticCallFingerprint = nil
                self.showAutomaticCallSaved(
                    callID: callID,
                    sourceAppName: sourceAppName,
                    sourceAppBundleID: sourceAppBundleID
                )
                self.reprobeDeferredAutomaticCallSuccessorIfReady()
                return
            }

            if didCloseExpectedEnvelope {
                self.automaticCallFingerprint = nil
                self.reprobeDeferredAutomaticCallSuccessorIfReady()
            }
            let cause = self.calls.errorMessage
                ?? String(localized: "The call could not be finalized safely.")
            self.automaticCallBanner = AutomaticCallBannerState(
                phase: .saveFailed,
                callID: callID,
                deadline: nil,
                sourceAppName: sourceAppName,
                sourceAppBundleID: sourceAppBundleID,
                errorMessage: String(
                    localized: "The local recording was kept. \(cause)"
                )
            )
        }
    }

    private func showAutomaticCallSaved(
        callID: Int64,
        sourceAppName: String?,
        sourceAppBundleID: String?
    ) {
        cancelAutomaticCallSavedBanner()
        automaticCallBanner = AutomaticCallBannerState(
            phase: .saved,
            callID: callID,
            deadline: nil,
            sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID
        )
        let generation = automaticCallSavedBannerGeneration
        automaticCallSavedBannerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled,
                  let self,
                  self.automaticCallSavedBannerGeneration == generation,
                  self.automaticCallBanner?.phase == .saved,
                  self.automaticCallBanner?.callID == callID
            else { return }
            self.automaticCallSavedBannerTask = nil
            self.automaticCallBanner = nil
            _ = self.automaticCallEndLifecycle.dismissSaved(callID: callID)
        }
    }

    private func cancelAutomaticCallSavedBanner() {
        automaticCallSavedBannerGeneration &+= 1
        automaticCallSavedBannerTask?.cancel()
        automaticCallSavedBannerTask = nil
    }

    func rejectDetectedCall() {
        guard terminationPrivacyGate.allowsAutomaticRejection else { return }
        guard !automaticCallRejectionInProgress else { return }
        guard automaticCallFinalizationCallID == nil else { return }
        guard let fingerprint = automaticCallFingerprint else { return }
        guard let storage,
              let callID = calls.automaticRejectionCandidateCallID(),
              automaticCallBanner?.callID == callID
        else {
            // The one join window has already sealed. Never make a late click look accepted:
            // this call remains available in Calls for an explicit permanent delete.
            calls.setExternalError(
                String(localized: "The call is already finishing. Remove it from Calls when it appears.")
            )
            return
        }
        let journalExecutor = CallPrivacyIntentJournalExecutor(
            mediaRoot: storage.mediaDirectory
        )
        automaticCallRejectionCallID = callID
        automaticCallRejectionReceipt = nil
        automaticCallRejectionSuspensions[callID] =
            AutomaticCallRejectionSuspensionOwnership()
        guard let rejectionRequest = calls.requestAutomaticRejection(
            preflight: { @MainActor [weak self] in
                guard let self,
                      self.automaticCallRejectionCallID == callID
                else { return false }
                if let dispatcher = self.callAutomationDispatcher {
                    // Close new outbound admission immediately. An already-running transport is
                    // drained after physical audio teardown so receiver latency cannot keep the
                    // microphone and system tracks recording after this click.
                    await dispatcher.suspendAdmissionForRelocation()
                    self.automaticCallRejectionSuspensions[callID]?.automation = true
                }
                do {
                    self.automaticCallRejectionReceipt =
                        try await journalExecutor.persistAutomaticRejection(
                            callID: callID,
                            detectorFingerprint: fingerprint
                        )
                } catch {
                    await self.releaseAutomaticCallRejectionSuspensions(callID: callID)
                    self.calls.setExternalError(
                        String(localized: "The call is still recording because its privacy receipt could not be saved.")
                    )
                    return false
                }

                // The receipt is durable before physical stop. Detector suppression is local and
                // bounded; worker/transport drains happen after the tracks are closed but before
                // the rejection is projected or any evidence can be deleted.
                self.audio?.closeCallFrameAdmission()
                self.audioSettings.meetingActive = false
                self.callDetectionPolicy.reject(fingerprint: fingerprint)
                await self.meetingDetector?.suppressSession(fingerprint: fingerprint)
                self.automaticCallEndGraceTask?.cancel()
                self.automaticCallEndGraceTask = nil
                self.cancelAutomaticCallSavedBanner()
                return true
            }
        ),
              rejectionRequest.callID == callID
        else {
            automaticCallRejectionSuspensions.removeValue(forKey: callID)
            clearAutomaticCallRejection(callID: callID)
            calls.setExternalError(
                String(localized: "The call is already finishing. Remove it from Calls when it appears.")
            )
            return
        }

        automaticCallRejectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let rejectedCallID = await self.calls.rejectAutomaticAndWait(
                request: rejectionRequest
            )
            guard rejectedCallID == callID,
                  let receipt = self.automaticCallRejectionReceipt
            else {
                await self.releaseAutomaticCallRejectionSuspensions(callID: callID)
                self.clearAutomaticCallRejection(callID: callID)
                self.automaticCallRejectionTask = nil
                self.automaticCallRejectionReceipt = nil
                if AutomaticCallRejectionGraceRecovery.shouldRestartGrace(
                    bannerPhase: self.automaticCallBanner?.phase,
                    originalTimerExists: self.automaticCallEndGraceTask != nil
                ) {
                    // If the original timer still exists, the lifecycle is already in grace and
                    // must stay there. Rewinding it to recording would make that timer's eventual
                    // `claimFinish(allowWhileRecording: false)` fail forever. Only replace a timer
                    // that actually expired while rejection temporarily owned finalization.
                    _ = self.automaticCallEndLifecycle.resume(
                        callID: callID,
                        fingerprint: fingerprint
                    )
                    self.scheduleDetectedCallEndGrace(
                        callID: callID,
                        fingerprint: fingerprint
                    )
                }
                return
            }
            self.calls.setExternalError(nil)
            if self.automaticCallBanner?.callID == callID {
                self.automaticCallBanner = nil
            }
            if self.automaticCallFingerprint == fingerprint {
                self.automaticCallFingerprint = nil
            }
            if self.automaticCallFinalizationCallID == callID {
                self.automaticCallFinalizationCallID = nil
            }
            self.automaticCallEndLifecycle.reset()
            if self.pendingUserEndDetectorFingerprint == fingerprint {
                self.pendingUserEndDetectorFingerprint = nil
            }
            // Both tracks are physically closed. Release the detector envelope before any
            // potentially unbounded local-worker/webhook drain, so offline receivers can never
            // make Eye miss a successor microphone session. The durable receipt and per-call task
            // own all remaining privacy work independently.
            self.beginAutomaticCallEraseRetry(
                callID: callID,
                receipt: receipt,
                requiresPostStopDrain: true
            )
            self.clearAutomaticCallRejection(callID: callID)
            self.automaticCallRejectionTask = nil
            self.automaticCallRejectionReceipt = nil
            self.reprobeDeferredAutomaticCallSuccessorIfReady()
        }
    }

    /// The Call is already stopped and its privacy intent is fsync'd. Erasure can therefore retry
    /// independently without retaining the detector envelope or suppressing a different mic owner.
    private func beginAutomaticCallEraseRetry(
        callID: Int64,
        receipt: CallPrivacyIntentReceipt,
        requiresPostStopDrain: Bool = false
    ) {
        guard automaticCallEraseTasks[callID] == nil else { return }
        automaticCallRejectedEraseGate.enqueue(callID: callID)
        automaticCallEraseTasks[callID] = Task { @MainActor [weak self] in
            guard let self else { return }
            if requiresPostStopDrain {
                // Admission was already closed before the receipt fsync. Now that capture has
                // stopped, wait out old egress and local processing before projecting/deleting.
                await self.callAutomationDispatcher?.drainSuspendedDelivery()
                await self.acquireAutomaticCallPrivacyWorkerBarrier(callID: callID)
            }
            var retryDelaySeconds: Double = 1
            var rejectionProjected = false
            while !Task.isCancelled {
                do {
                    guard let callRepository = self.callRepository,
                          let deletionService = self.callEvidenceDeletionService,
                          let storage = self.storage
                    else {
                        throw CallPrivacyIntentJournalError.invalidReceipt
                    }
                    let journalExecutor = CallPrivacyIntentJournalExecutor(
                        mediaRoot: storage.mediaDirectory
                    )
                    if try await callRepository.isCallEraseComplete(callID: callID) {
                        if try await journalExecutor.contains(receipt) {
                            try await journalExecutor.remove(receipt)
                        }
                        if !rejectionProjected {
                            rejectionProjected = true
                            await self.releaseAutomaticCallRejectionSuspensions(callID: callID)
                        }
                        self.finishAutomaticCallEraseRetry(callID: callID)
                        return
                    }
                    let nowMs = msFromDate(Date())
                    try await callRepository.reconcileAutomaticRejectionIntents(
                        [receipt],
                        nowMs: nowMs
                    )
                    let durableIDs = try await callRepository.rejectedCallIDsPendingErase()
                    guard durableIDs.contains(callID) else {
                        throw CallPrivacyIntentJournalError.invalidReceipt
                    }
                    if !rejectionProjected {
                        rejectionProjected = true
                        // Only after the tombstone, worker cancellation, and undelivered-outbox
                        // removal share one committed transaction may queued processing resume.
                        await self.releaseAutomaticCallRejectionSuspensions(callID: callID)
                    }
                    _ = try await deletionService.erase(
                        callID: callID,
                        nowMs: nowMs
                    )
                    self.finishAutomaticCallEraseRetry(callID: callID)
                    return
                } catch {
                    self.calls.setExternalError(
                        String(localized: "The false call is stopped. Permanent local deletion is retrying.")
                    )
                    Log.audio.error(
                        "automatic false-call erase retrying call_id=\(callID) error_type=\(String(reflecting: type(of: error)), privacy: .public)"
                    )
                    do {
                        try await Task.sleep(for: .seconds(retryDelaySeconds))
                    } catch {
                        return
                    }
                    if retryDelaySeconds < 2 {
                        retryDelaySeconds = 2
                    } else if retryDelaySeconds < 5 {
                        retryDelaySeconds = 5
                    } else if retryDelaySeconds < 10 {
                        retryDelaySeconds = 10
                    } else if retryDelaySeconds < 20 {
                        retryDelaySeconds = 20
                    } else {
                        retryDelaySeconds = 30
                    }
                }
            }
        }
    }

    private func finishAutomaticCallEraseRetry(callID: Int64) {
        automaticCallRejectedEraseGate.finish(callID: callID)
        automaticCallEraseTasks[callID] = nil
        let retryMessage = String(
            localized: "The false call is stopped. Permanent local deletion is retrying."
        )
        if automaticCallRejectedEraseGate.allowsDataRootMutation,
           calls.errorMessage == retryMessage {
            calls.setExternalError(nil)
        }
    }

    private func acquireAutomaticCallPrivacyWorkerBarrier(callID: Int64) async {
        guard automaticCallRejectionSuspensions[callID] != nil,
              let callEvidenceWorkerBarrier else { return }
        _ = await callEvidenceWorkerBarrier.suspend()
        automaticCallRejectionSuspensions[callID]?.workerBarrier = true
    }

    private func releaseAutomaticCallRejectionSuspensions(callID: Int64) async {
        guard let ownership = automaticCallRejectionSuspensions.removeValue(
            forKey: callID
        ) else { return }
        if ownership.automation {
            await callAutomationDispatcher?.resumeAfterRelocation()
        }
        if ownership.workerBarrier {
            await callEvidenceWorkerBarrier?.resume()
        }
    }

    private func clearAutomaticCallRejection(callID: Int64) {
        if automaticCallRejectionCallID == callID {
            automaticCallRejectionCallID = nil
        }
    }

    /// A user Stop is definitive for the current detector surface. Policy rejection is synchronous,
    /// but the detector keeps that surface in its active slot until CallRecordingStore confirms its
    /// audio teardown. This serializes A's teardown before B can be admitted.
    private func handleUserRequestedCallEnd() {
        // Once false-call rejection owns the Store's open join window, a Call Control click may
        // join as a fallback but must not mint a second AppEnvironment finalization owner. The
        // rejection completion clears the shared envelope; a failed preflight still finishes via
        // the Store callback for that joined user request.
        guard automaticCallRejectionCallID == nil else { return }
        audio?.closeCallFrameAdmission()
        guard let fingerprint = automaticCallFingerprint ?? claimedCallDetectorFingerprint else {
            return
        }
        let automaticBanner = automaticCallBanner
        audioSettings.meetingActive = false
        automaticCallEndGraceTask?.cancel()
        automaticCallEndGraceTask = nil
        cancelAutomaticCallSavedBanner()
        pendingUserEndDetectorFingerprint = fingerprint
        callDetectionPolicy.reject(fingerprint: fingerprint)
        if let automaticBanner,
           automaticCallFingerprint == fingerprint,
           automaticCallFinalizationCallID == nil {
            guard automaticCallEndLifecycle.claimFinish(
                callID: automaticBanner.callID,
                fingerprint: fingerprint,
                intent: .externalUserEnd,
                allowWhileRecording: true
            ) else { return }
            automaticCallFinalizationCallID = automaticBanner.callID
            automaticCallBanner = AutomaticCallBannerState(
                phase: .finalizing,
                callID: automaticBanner.callID,
                deadline: nil,
                sourceAppName: automaticBanner.sourceAppName,
                sourceAppBundleID: automaticBanner.sourceAppBundleID
            )
        } else if automaticCallFinalizationCallID == nil {
            automaticCallBanner = nil
        }
    }

    private func handleCallEndCompleted(reason: CallStopReason, didFinish: Bool) {
        // Defense in depth for a user click that lands after physical stop has crossed its durable
        // boundary but before the MainActor completion callback runs. Such a click is terminal and
        // must never be converted back into a recoverable low-disk pause.
        // A user finish can join a false-call rejection while its durable preflight is open. If
        // that preflight fails, the Store still completes the joined user save, so resolve against
        // the currently owned envelope rather than leaking stale lifecycle UI.
        let resolution = AutomaticCallEndCompletionResolution.resolve(
            reportedReason: reason,
            pendingUserFingerprint: pendingUserEndDetectorFingerprint,
            automaticFingerprint: automaticCallFingerprint,
            claimedFingerprint: claimedCallDetectorFingerprint
        )
        let effectiveReason = resolution.effectiveReason
        guard let fingerprint = resolution.fingerprint else { return }
        let temporarySuspension = pendingAutomaticCallTemporarySuspension.flatMap {
            $0.fingerprint == fingerprint ? $0 : nil
        }
        if temporarySuspension != nil {
            pendingAutomaticCallTemporarySuspension = nil
        }
        let finalizingBanner = automaticCallBanner.flatMap { banner in
            banner.phase == .finalizing ? banner : nil
        }
        if !didFinish,
           effectiveReason == .privacy,
           let temporarySuspension,
           calls.snapshot.phase == .idle,
           calls.snapshot.callID == nil {
            // The gate joined an in-flight start that never acquired a usable source, so there is
            // no local Call to report as a failed save. Retain only the detector rearm ownership.
            holdTemporaryAutomaticCallSuspension(
                temporarySuspension,
                fingerprint: fingerprint
            )
            return
        }
        guard didFinish else {
            automaticCallFinalizationCallID = nil
            let failedBanner = finalizingBanner ?? (!calls.isActive ? automaticCallBanner : nil)
            if let failedBanner {
                if finalizingBanner != nil {
                    _ = automaticCallEndLifecycle.complete(
                        callID: failedBanner.callID,
                        fingerprint: fingerprint,
                        succeeded: false
                    )
                }
                let cause = calls.errorMessage
                    ?? String(localized: "The call could not be finalized safely.")
                automaticCallBanner = AutomaticCallBannerState(
                    phase: .saveFailed,
                    callID: failedBanner.callID,
                    deadline: nil,
                    sourceAppName: failedBanner.sourceAppName,
                    sourceAppBundleID: failedBanner.sourceAppBundleID,
                    errorMessage: String(localized: "The local recording was kept. \(cause)")
                )
            }
            if !calls.isActive {
                if finalizingBanner == nil {
                    automaticCallEndLifecycle.reset()
                }
                pendingUserEndDetectorFingerprint = nil
                if automaticCallFingerprint == fingerprint {
                    automaticCallFingerprint = nil
                }
                if claimedCallDetectorFingerprint == fingerprint {
                    claimedCallDetectorFingerprint = nil
                }
                Task { [weak meetingDetector] in
                    await meetingDetector?.suppressSession(fingerprint: fingerprint)
                }
                reprobeDeferredAutomaticCallSuccessorIfReady()
            }
            Log.meetingDetection.error(
                "call_end_unconfirmed detector_surface_retained=true"
            )
            return
        }

        audioSettings.meetingActive = false
        automaticCallEndGraceTask?.cancel()
        automaticCallEndGraceTask = nil
        automaticCallFinalizationCallID = nil
        pendingUserEndDetectorFingerprint = nil
        if effectiveReason == .privacy,
           let temporarySuspension {
            holdTemporaryAutomaticCallSuspension(
                temporarySuspension,
                fingerprint: fingerprint
            )
            return
        }
        if effectiveReason == .lowDisk {
            automaticCallEndLifecycle.reset()
            automaticCallBanner = nil
            // Preserve the exact identity while capture admission is closed. The pre-prepare
            // suppression froze its old owner set; recovery explicitly releases that temporary
            // boundary and re-arms the same still-running microphone session.
            lowDiskSuspendedDetectorFingerprint = fingerprint
            if automaticCallFingerprint == fingerprint {
                automaticCallFingerprint = nil
            }
            if claimedCallDetectorFingerprint == fingerprint {
                claimedCallDetectorFingerprint = nil
            }
            return
        }
        if effectiveReason == .maintenance {
            automaticCallEndLifecycle.reset()
            automaticCallBanner = nil
            // Quit is still cancellable after the Call Envelope closes. Preserve the identity;
            // cancelled-termination recovery releases the pre-prepare suppression and requalifies it.
            maintenanceSuspendedDetectorFingerprint = fingerprint
            if automaticCallFingerprint == fingerprint {
                automaticCallFingerprint = nil
            }
            if claimedCallDetectorFingerprint == fingerprint {
                claimedCallDetectorFingerprint = nil
            }
            return
        }
        callDetectionPolicy.reject(fingerprint: fingerprint)
        if automaticCallFingerprint == fingerprint {
            automaticCallFingerprint = nil
        }
        if claimedCallDetectorFingerprint == fingerprint {
            claimedCallDetectorFingerprint = nil
        }
        Task { [weak meetingDetector] in
            await meetingDetector?.suppressSession(fingerprint: fingerprint)
        }
        if let finalizingBanner {
            _ = automaticCallEndLifecycle.complete(
                callID: finalizingBanner.callID,
                fingerprint: fingerprint,
                succeeded: true
            )
            showAutomaticCallSaved(
                callID: finalizingBanner.callID,
                sourceAppName: finalizingBanner.sourceAppName,
                sourceAppBundleID: finalizingBanner.sourceAppBundleID
            )
        } else {
            automaticCallEndLifecycle.reset()
            automaticCallBanner = nil
        }
        reprobeDeferredAutomaticCallSuccessorIfReady()
    }

    private func reprobeDeferredAutomaticCallSuccessorIfReady() {
        guard automaticCallSuccessorProbeGate.consumeReprobeIfOwnerCleared(
            activeFingerprint: automaticCallFingerprint ?? claimedCallDetectorFingerprint
        ) else { return }
        Task { [weak meetingDetector] in
            await meetingDetector?.autoCallExclusionsDidChange()
        }
    }

    private func holdTemporaryAutomaticCallSuspension(
        _ suspension: AutomaticCallTemporarySuspension,
        fingerprint: String
    ) {
        audioSettings.meetingActive = false
        automaticCallEndGraceTask?.cancel()
        automaticCallEndGraceTask = nil
        automaticCallFinalizationCallID = nil
        pendingUserEndDetectorFingerprint = nil
        automaticCallEndLifecycle.reset()
        automaticCallBanner = nil
        suspendedAutomaticCall = suspension
        if automaticCallFingerprint == fingerprint {
            automaticCallFingerprint = nil
        }
        if claimedCallDetectorFingerprint == fingerprint {
            claimedCallDetectorFingerprint = nil
        }
        if AutomaticCallTemporaryRearmPolicy.allowsRelease(
            kind: suspension.kind,
            audioIsDisabled: CallAudioSourcePolicy.requestedSources(
                audioMode: audioSettings.audioMode,
                manualOverride: audioSettings.manualAudioOverride
            ).isEmpty,
            privacyPauseIsActive: recording.pausedUntil != nil,
            sessionLockIsActive: !automaticCallSessionGate.isOpen
        ) {
            // Any overlapping hard gate may reopen while physical teardown is suspended.
            resumeTemporarilySuspendedAutomaticCall(kind: suspension.kind)
        }
    }

    /// Reopens a temporary hard gate without requiring the external app to cycle its microphone.
    /// End & save and ordinary user stops never enter this path; they remain suppressed to real idle.
    private func resumeTemporarilySuspendedAutomaticCall(
        kind: AutomaticCallTemporarySuspensionKind
    ) {
        guard let suspension = suspendedAutomaticCall,
              automaticCallRearmInProgressFingerprint == nil
        else { return }
        _ = kind
        let audioIsDisabled = CallAudioSourcePolicy.requestedSources(
            audioMode: audioSettings.audioMode,
            manualOverride: audioSettings.manualAudioOverride
        ).isEmpty
        guard AutomaticCallTemporaryRearmPolicy.allowsRelease(
            kind: suspension.kind,
            audioIsDisabled: audioIsDisabled,
            privacyPauseIsActive: recording.pausedUntil != nil,
            sessionLockIsActive: !automaticCallSessionGate.isOpen
        ) else { return }

        // Keep admission closed until the detector actor has discarded the old fingerprint. The
        // AsyncStream is unbounded by design, so clearing policy/suspension before this await would
        // let an already queued positive A reopen a Call that no future detector session owns.
        callDetectionPolicy.reject(fingerprint: suspension.fingerprint)
        automaticCallRearmInProgressFingerprint = suspension.fingerprint
        Task { @MainActor [weak self, weak meetingDetector] in
            await meetingDetector?.releaseSession(fingerprint: suspension.fingerprint)
            guard let self,
                  self.automaticCallRearmInProgressFingerprint == suspension.fingerprint
            else { return }
            self.automaticCallRearmInProgressFingerprint = nil
            guard self.suspendedAutomaticCall == suspension else { return }

            let audioIsDisabled = CallAudioSourcePolicy.requestedSources(
                audioMode: self.audioSettings.audioMode,
                manualOverride: self.audioSettings.manualAudioOverride
            ).isEmpty
            guard AutomaticCallTemporaryRearmPolicy.allowsRelease(
                kind: suspension.kind,
                audioIsDisabled: audioIsDisabled,
                privacyPauseIsActive: self.recording.pausedUntil != nil,
                sessionLockIsActive: !self.automaticCallSessionGate.isOpen
            ) else { return }

            self.suspendedAutomaticCall = nil
            await meetingDetector?.automaticCallAdmissionDidChange()
        }
    }

    private func claimAutomaticCall(callID: Int64) {
        guard let fingerprint = automaticCallFingerprint,
              automaticCallFinalizationCallID == nil,
              automaticCallRejectionCallID == nil
        else { return }
        automaticCallEndGraceTask?.cancel()
        automaticCallEndGraceTask = nil
        cancelAutomaticCallSavedBanner()
        automaticCallEndLifecycle.reset()
        claimedCallDetectorFingerprint = fingerprint
        automaticCallFingerprint = nil
        automaticCallBanner = nil
        Task { [weak callRepository] in
            try? await callRepository?.updateCallCaptureContext(
                callID: callID,
                owner: .claimed,
                disposition: .confirmed,
                nowMs: msFromDate(Date())
            )
        }
    }

    func retryCallTranscription(callID: Int64) async -> String? {
        guard let callRepository else {
            return String(localized: "Call service is still starting. Try again in a moment.")
        }
        calls.setExternalError(nil)
        do {
            try await callRepository.retryFinalTranscript(
                callID: callID,
                nowMs: msFromDate(Date())
            )
            calls.setExternalError(nil)
            return nil
        } catch {
            let message = error.localizedDescription
            calls.setExternalError(message)
            return message
        }
    }

    func retryCallSpeakerProcessing(callID: Int64) async -> String? {
        guard let callRepository else {
            return String(localized: "Calls are still initializing.")
        }
        do {
            try await callRepository.retrySpeakerDiarization(callID: callID)
            await speakerDiarizationWorker?.resume()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
