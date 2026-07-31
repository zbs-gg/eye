import Foundation
import AppKit
import Observation
import UserNotifications

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

    init() {
        let storageSettings = StorageSettingsStore()
        self.storageSettings = storageSettings
        resourceUsage = ResourceUsageStore(dataBytes: { [weak storageSettings] in
            storageSettings?.totalBytes ?? 0
        })
        audioSettings.onCaptureConfigurationChanged = { [weak self] in
            self?.recording.syncAudio()
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
                onReject: { [weak self] in self?.rejectDetectedCall() },
                onUndo: { [weak self] in self?.undoDetectedCallEnd() }
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
    @ObservationIgnored private var callDetectionPolicy = CallDetectionPolicy()
    @ObservationIgnored private var automaticCallFingerprint: String?
    @ObservationIgnored private var claimedCallDetectorFingerprint: String?
    @ObservationIgnored private var pendingUserEndDetectorFingerprint: String?
    @ObservationIgnored private var lowDiskSuspendedDetectorFingerprint: String?
    @ObservationIgnored private var maintenanceSuspendedDetectorFingerprint: String?
    @ObservationIgnored private var automaticCallEndGraceTask: Task<Void, Never>?
    @ObservationIgnored private var automaticCallRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var automaticCallRecoveryGeneration: UInt64 = 0
    @ObservationIgnored private var automaticCallRejectionTask: Task<Void, Never>?
    @ObservationIgnored private var automaticCallRejectionReceipt: CallPrivacyIntentReceipt?
    @ObservationIgnored private var automaticCallRejectionOwnsAutomationSuspension = false
    @ObservationIgnored private var automaticCallRejectionOwnsTranscriptSuspension = false
    @ObservationIgnored private var automaticCallRejectionOwnsSpeakerSuspension = false
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
            await meetingDetector?.releaseSession(fingerprint: fingerprint)
            callDetectionPolicy.resetAfterCompletion()
            maintenanceSuspendedDetectorFingerprint = nil
        }
        captureHealthController?.setSuspension(nil, nowMs: Self.epochMs())
        if let lease { recording.resumeAfterMaintenance(lease) }
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
        calls.admissionAllowed = { [weak self] in
            guard let self else { return false }
            return !self.storageSettings.relocationInProgress
                && self.recording.pausedUntil == nil
                && !self.recording.lowDiskPaused
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
                    automaticRejectionTaskActive: self.automaticCallRejectionTask != nil,
                    automaticRejectionCallID: self.automaticCallRejectionCallID
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
                    self.captureHealthController?.setSuspension(
                        .maintenance,
                        nowMs: Self.epochMs()
                    )
                    await self.drainCaptureCoveragePersistence()
                    let lease = self.recording.acquireMaintenanceLease(.termination)
                    recordingMaintenanceLease = lease
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
                                    .suspendAndDrainForEvidenceMutation()
                            },
                            resume: { await callTranscriptWorker.resume() }
                        ),
                        .init(
                            suspend: {
                                await speakerDiarizationWorker
                                    .suspendAndDrainForEvidenceMutation()
                            },
                            resume: { await speakerDiarizationWorker.resume() }
                        ),
                    ]
                )
                await callEvidenceDeletionService.attachTranscriptWorker(
                    suspend: { await callEvidenceWorkerBarrier.suspend() },
                    resume: { [weak self] in
                        let allowed = await MainActor.run {
                            self?.recording.lowDiskPaused == false
                                && self?.storageSettings.relocationInProgress == false
                        }
                        if allowed { await callEvidenceWorkerBarrier.resume() }
                    }
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
            captureHealthController.setSnapshotSink { [weak self] snapshot in
                self?.captureHealth = snapshot
            }
            permissions.onSnapshotChanged = { [weak captureHealthController] snapshot in
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
            }

            // Capture loop (the heart). Starts on toggle in RecordingStore.
            let coordinator = CaptureCoordinator(
                ingest: ingestService,
                browserContent: browserContent,
                healthController: captureHealthController
            )
            coordinator.onFrame = { [weak rec = recording] in rec?.noteFrame() }
            // The independent disk monitor owns transitions. This cycle gate is
            // only a final admission check while an asynchronous drain settles.
            coordinator.diskOK = { [weak self] in
                guard let self else { return false }
                return !self.recording.lowDiskPaused
            }
            coordinator.isIgnoredApp = { [weak self] in self?.privacy.isIgnored($0) ?? false }
            coordinator.ignoredBundleIds = { [weak self] in Set(self?.privacy.ignoredBundleIds ?? []) }
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
                healthController: captureHealthController
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
                    await audioCoordinator?.installCallFrameSink(sink)
                },
                start: { [weak self, weak audioCoordinator] requested in
                    guard let audioCoordinator else { return .none }
                    let permitted = await MainActor.run { [weak self] in
                        guard let self else { return CallSourceSelection.none }
                        guard !self.isCallDiskAdmissionClosed else {
                            return CallSourceSelection.none
                        }
                        return CallSourceSelection(
                            me: requested.me && self.permissions.snapshot.microphone == .granted,
                            system: requested.system
                                && self.permissions.snapshot.screenRecording == .granted
                        )
                    }
                    return await audioCoordinator.beginExplicitCall(permitted)
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
                    audioMode: self.audioSettings.audioMode
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

            // Meeting detection drives meetings-only capture. CoreAudio identifies native apps or
            // qualified Chromium roots; bounded Accessibility confirms a real call surface without
            // prompting or persisting browser text. syncAudio() itself no-ops when not capturing.
            let detector = MeetingDetector()
            self.meetingDetector = detector
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
            self.timelineStore = TimelineStore(
                search: searchSvc,
                timeline: timelineSvc,
                coverage: coverageQuery,
                mediaDirectory: storage.mediaDirectory
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.calls.endAndWait(reason: .privacy)
            self.recording.pauseFor(minutes: minutes)
        }
    }

    /// History deletion (privacy): lastSeconds=nil → everything. Returns a report for the UI.
    func deleteHistory(lastSeconds: TimeInterval?) async -> PruneReport? {
        guard !storageSettings.relocationInProgress, let retention else { return nil }
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
        // CRITICAL (privacy): an open VAD segment lives in memory — deleteRange doesn't see it.
        // We flush in-flight audio BEFORE the delete, otherwise "said a password → wipe" would survive
        // up to 28s of speech captured before the click (it would close and land in the DB AFTER the delete).
        await audio?.discardInFlight(from: dateFromMs(fromMs), to: lastSeconds == nil ? now : dateFromMs(toMs))
        let report = try? await retention.deleteRange(fromMs: fromMs, toMs: toMs)
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
              automaticCallRejectionCallID == nil else {
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
            // Low disk is a temporary admission barrier, not a user rejection. Drop only the
            // detector's pre-pause active identity and reset the pure reducer immediately before
            // reopening capture, so the same still-running call can be qualified again.
            if let fingerprint = lowDiskSuspendedDetectorFingerprint {
                await meetingDetector?.releaseSession(fingerprint: fingerprint)
                callDetectionPolicy.resetAfterCompletion()
                lowDiskSuspendedDetectorFingerprint = nil
            }
            captureHealthController?.setSuspension(nil, nowMs: Self.epochMs())
            recording.resumeAfterLowDisk()
            await callTranscriptWorker?.resume()
            await speakerDiarizationWorker?.resume()
        }
    }

    private func handleCallDetection(
        _ decision: CallDetectionDecision,
        evidence: CallEvidenceSnapshot
    ) async {
        switch decision {
        case .none:
            audioSettings.meetingActive = false

        case let .start(fingerprint):
            audioSettings.meetingActive = true
            if isAutomaticCallAdmissionTemporarilyClosed {
                // A call first appearing while a temporary admission barrier is closed is not a
                // failed/rejected call. Release only this detector identity so the same still-
                // running surface can qualify again after privacy pause/relocation/low disk ends.
                audioSettings.meetingActive = false
                callDetectionPolicy.resetAfterCompletion()
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
                callDetectionPolicy.resetAfterCompletion()
                await meetingDetector?.releaseSession(fingerprint: fingerprint)
                if automaticCallFingerprint == fingerprint {
                    automaticCallFingerprint = nil
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
                let bundleID = evidence.surface?.ownerBundleID
                let appName = bundleID.flatMap {
                    NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName
                }
                try? await callRepository?.upsertCallContext(
                    CallContextRow(
                        callId: callID,
                        captureOwner: .automatic,
                        disposition: .active,
                        detectorFingerprintHash: fingerprint,
                        sourceAppBundleID: bundleID,
                        sourceAppName: appName,
                        trustedOriginHost: evidence.surface?.trustedOrigin?.host,
                        title: nil,
                        participantsJSON: "[]",
                        createdAtMs: nowMs,
                        updatedAtMs: nowMs
                    )
                )
                guard calls.canPublishAutomaticStart(callID: callID),
                      automaticCallFingerprint == fingerprint
                else {
                    return
                }
                automaticCallBanner = AutomaticCallBannerState(
                    phase: .started,
                    callID: callID,
                    deadline: nil
                )
            }

        case let .activity(fingerprint):
            guard automaticCallFingerprint == fingerprint else { return }
            audioSettings.meetingActive = true
            automaticCallEndGraceTask?.cancel()
            automaticCallEndGraceTask = nil
            if calls.snapshot.phase == .recoveryTail {
                guard let undoRequest = calls.requestAutomaticUndo() else {
                    // The deadline may already own physical teardown. Do not cancel that owner's
                    // post-commit cleanup; a later detector tick can qualify a successor normally.
                    return
                }
                cancelAutomaticCallRecovery()
                guard await calls.undoAutomaticEndAndWait(request: undoRequest) != nil else {
                    restoreAutomaticCallRecoveryAfterFailedUndo(
                        callID: undoRequest.callID,
                        fingerprint: fingerprint
                    )
                    return
                }
            }
            if let callID = calls.snapshot.callID,
               calls.canPublishAutomaticResume(callID: callID),
               automaticCallFingerprint == fingerprint {
                automaticCallBanner = AutomaticCallBannerState(
                    phase: .started,
                    callID: callID,
                    deadline: nil
                )
            }

        case let .strongEnd(fingerprint):
            audioSettings.meetingActive = false
            guard automaticCallFingerprint == fingerprint,
                  calls.snapshot.phase == .recording,
                  automaticCallEndGraceTask == nil
            else { return }
            let callID = calls.snapshot.callID ?? 0
            let deadline = Date().addingTimeInterval(30)
            automaticCallBanner = AutomaticCallBannerState(
                phase: .endingGrace,
                callID: callID,
                deadline: deadline
            )
            automaticCallEndGraceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled,
                      let self,
                      self.automaticCallFingerprint == fingerprint
                else { return }
                self.automaticCallEndGraceTask = nil
                await self.beginAutomaticRecoveryTail(callID: callID, fingerprint: fingerprint)
            }

        case .becameIdle:
            audioSettings.meetingActive = false
            await meetingDetector?.releaseSession()
        }
    }

    private var isCallDiskAdmissionClosed: Bool {
        recording.lowDiskPaused
            || (storage?.freeBytes() ?? 0) < DiskReservePolicy.standard.pauseBytes
    }

    private var isAutomaticCallAdmissionTemporarilyClosed: Bool {
        isCallDiskAdmissionClosed
            || recording.pausedUntil != nil
            || storageSettings.relocationInProgress
    }

    private func cancelAutomaticCallRecovery() {
        automaticCallRecoveryGeneration &+= 1
        automaticCallRecoveryTask?.cancel()
        automaticCallRecoveryTask = nil
    }

    private func beginAutomaticRecoveryTail(callID: Int64, fingerprint: String) async {
        guard automaticCallFingerprint == fingerprint,
              await calls.softEndAutomaticAndWait() != nil
        else { return }
        scheduleAutomaticCallRecovery(callID: callID, fingerprint: fingerprint)
    }

    private func scheduleAutomaticCallRecovery(callID: Int64, fingerprint: String) {
        guard automaticCallFingerprint == fingerprint,
              calls.canScheduleAutomaticEnd
        else { return }
        let deadline = Date().addingTimeInterval(15)
        automaticCallBanner = AutomaticCallBannerState(
            phase: .endedUndo,
            callID: callID,
            deadline: deadline
        )
        cancelAutomaticCallRecovery()
        let recoveryGeneration = automaticCallRecoveryGeneration
        automaticCallRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled,
                  let self,
                  self.automaticCallFingerprint == fingerprint,
                  self.automaticCallRecoveryGeneration == recoveryGeneration
            else { return }
            let committed = await self.calls.commitAutomaticEndAndWait()
            guard !Task.isCancelled,
                  self.automaticCallRecoveryGeneration == recoveryGeneration,
                  self.automaticCallFingerprint == fingerprint
            else { return }
            if committed?.phase != .pendingTranscription
                || committed?.stopReason != .automatic {
                if self.calls.canScheduleAutomaticEnd {
                    // No end was admitted (for example, a transient competing claim disappeared).
                    // Keep the exact lifecycle owner alive and give it one fresh bounded deadline.
                    self.automaticCallRecoveryTask = nil
                    self.scheduleAutomaticCallRecovery(
                        callID: callID,
                        fingerprint: fingerprint
                    )
                    return
                }
                guard !self.calls.isActive else { return }
                // Physical teardown failed after closing audio. Preserve the failed Call row, but
                // suppress only this detector surface and release the active slot so a different
                // call can still start without relaunching Eye.
                self.automaticCallRecoveryTask = nil
                self.automaticCallFingerprint = nil
                self.automaticCallBanner = nil
                self.audioSettings.meetingActive = false
                self.callDetectionPolicy.reject(fingerprint: fingerprint)
                await self.meetingDetector?.suppressSession(fingerprint: fingerprint)
                return
            }
            self.automaticCallRecoveryTask = nil
            self.automaticCallFingerprint = nil
            self.automaticCallBanner = nil
            self.callDetectionPolicy.resetAfterCompletion()
            await self.meetingDetector?.releaseSession(fingerprint: fingerprint)
        }
    }

    private func restoreAutomaticCallRecoveryAfterFailedUndo(
        callID: Int64,
        fingerprint: String
    ) {
        // A coordinator error must not strand a call in recoveryTail forever. If a stronger
        // terminal owner invalidated Undo, canScheduleAutomaticEnd is false and that owner keeps
        // exclusive responsibility for cleanup.
        scheduleAutomaticCallRecovery(callID: callID, fingerprint: fingerprint)
    }

    func rejectDetectedCall() {
        guard terminationPrivacyGate.allowsAutomaticRejection else { return }
        guard !automaticCallRejectionInProgress else { return }
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
        automaticCallRejectionOwnsAutomationSuspension = false
        automaticCallRejectionOwnsTranscriptSuspension = false
        automaticCallRejectionOwnsSpeakerSuspension = false
        guard let rejectionRequest = calls.requestAutomaticRejection(
            preflight: { @MainActor [weak self] in
                guard let self,
                      self.automaticCallRejectionCallID == callID
                else { return false }
                if let dispatcher = self.callAutomationDispatcher {
                    // Close outbound admission before the potentially slow receipt fsync. A
                    // previously queued checkpoint/transcript event must not escape after the
                    // user has clicked "Not a call".
                    await dispatcher.suspendAndDrainForRelocation()
                    self.automaticCallRejectionOwnsAutomationSuspension = true
                }
                do {
                    self.automaticCallRejectionReceipt =
                        try await journalExecutor.persistAutomaticRejection(
                            callID: callID,
                            detectorFingerprint: fingerprint
                        )
                } catch {
                    if self.automaticCallRejectionOwnsAutomationSuspension {
                        await self.callAutomationDispatcher?.resumeAfterRelocation()
                        self.automaticCallRejectionOwnsAutomationSuspension = false
                    }
                    self.calls.setExternalError(
                        String(localized: "The call is still recording because its privacy receipt could not be saved.")
                    )
                    return false
                }

                // The dispatcher is already drained, and the receipt is durable before any
                // physical stop. Only now suppress the detector and drain evidence workers.
                self.audioSettings.meetingActive = false
                self.callDetectionPolicy.reject(fingerprint: fingerprint)
                self.automaticCallEndGraceTask?.cancel()
                self.automaticCallEndGraceTask = nil
                self.cancelAutomaticCallRecovery()
                self.automaticCallRejectionOwnsTranscriptSuspension =
                    await self.callTranscriptWorker?.suspendAndDrainForEvidenceMutation() ?? false
                self.automaticCallRejectionOwnsSpeakerSuspension =
                    await self.speakerDiarizationWorker?.suspendAndDrainForEvidenceMutation() ?? false
                return true
            }
        ),
              rejectionRequest.callID == callID
        else {
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
                await self.releaseAutomaticCallRejectionSuspensions()
                self.clearAutomaticCallRejection(callID: callID)
                self.automaticCallRejectionTask = nil
                self.automaticCallRejectionReceipt = nil
                return
            }
            var retryDelaySeconds: Double = 1
            while !Task.isCancelled {
                do {
                    guard let callRepository = self.callRepository,
                          let deletionService = self.callEvidenceDeletionService
                    else {
                        throw CallPrivacyIntentJournalError.invalidReceipt
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
                    _ = try await deletionService.erase(
                        callID: callID,
                        nowMs: nowMs
                    )
                    break
                } catch {
                    self.calls.setExternalError(
                        String(localized: "The false call is stopped. Permanent local deletion is retrying.")
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
                    continue
                }
            }
            guard !Task.isCancelled else { return }

            self.calls.setExternalError(nil)
            if self.automaticCallBanner?.callID == callID {
                self.automaticCallBanner = nil
            }
            await self.meetingDetector?.suppressSession(fingerprint: fingerprint)
            if self.automaticCallFingerprint == fingerprint {
                self.automaticCallFingerprint = nil
            }
            if self.pendingUserEndDetectorFingerprint == fingerprint {
                self.pendingUserEndDetectorFingerprint = nil
            }
            // Keep the exclusion markers live through the final await. Otherwise Quit can acquire
            // its lease and have this older task resume workers during shutdown.
            await self.releaseAutomaticCallRejectionSuspensions()
            self.clearAutomaticCallRejection(callID: callID)
            self.automaticCallRejectionTask = nil
            self.automaticCallRejectionReceipt = nil
        }
    }

    private func releaseAutomaticCallRejectionSuspensions() async {
        if automaticCallRejectionOwnsAutomationSuspension {
            await callAutomationDispatcher?.resumeAfterRelocation()
            automaticCallRejectionOwnsAutomationSuspension = false
        }
        let workersMayResume =
            !recording.lowDiskPaused
                && !storageSettings.relocationInProgress
        if workersMayResume, automaticCallRejectionOwnsTranscriptSuspension {
            await callTranscriptWorker?.resume()
        }
        if workersMayResume, automaticCallRejectionOwnsSpeakerSuspension {
            await speakerDiarizationWorker?.resume()
        }
        automaticCallRejectionOwnsTranscriptSuspension = false
        automaticCallRejectionOwnsSpeakerSuspension = false
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
        guard let fingerprint = automaticCallFingerprint ?? claimedCallDetectorFingerprint else {
            return
        }
        audioSettings.meetingActive = false
        automaticCallEndGraceTask?.cancel()
        automaticCallEndGraceTask = nil
        cancelAutomaticCallRecovery()
        automaticCallBanner = nil
        pendingUserEndDetectorFingerprint = fingerprint
        callDetectionPolicy.reject(fingerprint: fingerprint)
    }

    private func handleCallEndCompleted(reason: CallStopReason, didFinish: Bool) {
        // Defense in depth for a user click that lands after physical stop has crossed its durable
        // boundary but before the MainActor completion callback runs. Such a click is terminal and
        // must never be converted back into a recoverable low-disk pause.
        let effectiveReason: CallStopReason =
            pendingUserEndDetectorFingerprint == nil ? reason : .user
        let fingerprint: String?
        if effectiveReason == .user {
            fingerprint = pendingUserEndDetectorFingerprint
        } else {
            fingerprint = automaticCallFingerprint ?? claimedCallDetectorFingerprint
        }
        guard let fingerprint else { return }
        guard didFinish else {
            Log.meetingDetection.error(
                "call_end_unconfirmed detector_surface_retained=true"
            )
            return
        }

        audioSettings.meetingActive = false
        automaticCallEndGraceTask?.cancel()
        automaticCallEndGraceTask = nil
        cancelAutomaticCallRecovery()
        automaticCallBanner = nil
        pendingUserEndDetectorFingerprint = nil
        if effectiveReason == .lowDisk {
            // Keep the exact detector session alive while capture admission is closed. Recovery
            // releases and re-arms it atomically; rejecting here would suppress a continuing call
            // for the full two-minute disappearance tombstone.
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
            // Quit is still cancellable after the Call Envelope closes. Preserve ownership without
            // suppressing the surface; cancelled-termination recovery releases and requalifies it.
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
    }

    func undoDetectedCallEnd() {
        guard let fingerprint = automaticCallFingerprint,
              let undoRequest = calls.requestAutomaticUndo()
        else {
            // Once the automatic deadline owns teardown, Undo is no longer accepted and must not
            // cancel the task that clears detector state after its durable commit.
            return
        }
        cancelAutomaticCallRecovery()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.calls.undoAutomaticEndAndWait(request: undoRequest) != nil,
                  let callID = self.calls.snapshot.callID,
                  self.calls.canPublishAutomaticResume(callID: callID)
            else {
                self.restoreAutomaticCallRecoveryAfterFailedUndo(
                    callID: undoRequest.callID,
                    fingerprint: fingerprint
                )
                return
            }
            guard self.automaticCallFingerprint == fingerprint else { return }
            self.automaticCallBanner = AutomaticCallBannerState(
                phase: .started,
                callID: callID,
                deadline: nil
            )
        }
    }

    private func claimAutomaticCall(callID: Int64) {
        guard let fingerprint = automaticCallFingerprint else { return }
        automaticCallEndGraceTask?.cancel()
        automaticCallEndGraceTask = nil
        cancelAutomaticCallRecovery()
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
