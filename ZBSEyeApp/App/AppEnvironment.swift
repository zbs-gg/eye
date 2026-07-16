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
    let storageSettings: StorageSettingsStore
    let storageOperations = StorageOperationsStore()
    let resourceUsage: ResourceUsageStore
    let backupSettings = BackupSettingsStore()
    let builtInModels = BuiltInModelStore()
    let privacy = PrivacyStore()
    let rewards = RewardsStore()   // cosmetic rewards (theme/icon/menu-bar) — independent of the DB
    let workspace = WorkspaceStore()
    @ObservationIgnored private let keepMediaPolicyCoordinator = KeepMediaPolicyCoordinator()

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
    private(set) var callEvidenceDeletionService: CallEvidenceDeletionService?
    private(set) var callRecovery: CallRecoveryService?
    private(set) var retention: RetentionManager?
    @ObservationIgnored private var automaticRetentionAdmission: AutomaticRetentionAdmission?
    private(set) var timelineStore: TimelineStore?
    private(set) var ask: AskStore?
    private(set) var cartographer: CartographerStore?
    private(set) var httpServer: ZBSEyeHTTPServer?
    private(set) var automations: DaySummaryStore?
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
    @ObservationIgnored private(set) var llmRouter: LLMRouter?
    @ObservationIgnored private(set) var aiComputeCoordinator: AIComputeCoordinator?
    @ObservationIgnored private(set) var whisperModelStore: WhisperModelStore?
    @ObservationIgnored private(set) var callTranscriptWorker: CallTranscriptWorker?
    @ObservationIgnored private var callTranscriptWorkerTask: Task<Void, Never>?
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
        after phase: AppTerminationCriticalPhaseResult
    ) {
        recordingTerminationRecoveryTask?.cancel()
        recordingTerminationRecoveryTask = phase.recoveryTask { @MainActor [weak self] in
            guard let self else { return }
            self.recording.resumeAfterMaintenance()
            self.recordingTerminationRecoveryTask = nil
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
            self?.storageSettings.relocationInProgress == false
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
            ZBSEyeHTTPServer.log("data root unavailable (\(missing)) — bootstrap aborted (anti-split-brain)")
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
                if recoveryOwner == .quit {
                    let recordingPhase = await AppTerminationCriticalPhase.run(
                        timeout: AppTerminationDeadlinePolicy.recordingDrain
                    ) {
                        // The outer critical phase owns the only caller
                        // deadline. The underlying hardware teardown remains
                        // retained to real completion before recovery resumes.
                        await self.calls.endAndWait(reason: .maintenance)
                        let recordingDrain = await self.recording.pauseForMaintenanceAndDrain(
                            waitForTranscription: false
                        )
                        return recordingDrain.capture.activeCycles == 0
                            && recordingDrain.audio.activeLegs == 0
                            && recordingDrain.audio.systemCaptureOutcome.isConfirmedStopped
                    }
                    guard AppTerminationCriticalPhase.acceptsTermination(recordingPhase) else {
                        Log.audio.error("termination cancelled: recording drain was not confirmed before deadline")
                        self.recoverRecordingAfterCancelledTermination(after: recordingPhase)
                        return false
                    }
                }
                self.cancelBuiltInModelRecovery()
                let reconciliation = self.cancelBuiltInModelReconciliation()
                await self.callTranscriptWorker?.suspendAndDrain()
                await self.whisperModelStore?.suspendAndDrain()

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
                        self.recording.resumeAfterMaintenance()
                        await self.whisperModelStore?.resumeAfterDrain()
                        await self.callTranscriptWorker?.resume()
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
                        self.recording.resumeAfterMaintenance()
                        await self.whisperModelStore?.resumeAfterDrain()
                        await self.callTranscriptWorker?.resume()
                    } else {
                        self.relocationTerminationDrainTask = computePhase.operation
                    }
                    return false
                }
                await reconciliation?.value
                await self.builtInModels.shutdown()
                self.localAIMemoryPressureSource?.cancel()
                self.localAIMemoryPressureSource = nil
                if let router = self.llmRouter {
                    _ = await router.shutdown(timeout: .seconds(5))
                }
                if let owner = self.processProviderRuntimeOwner {
                    _ = await owner.shutdown(timeout: .seconds(5))
                }
                guard self.backupSettings.enabled, BackupManager.iCloudAvailable() else { return true }
                let keep = self.backupSettings.keepN
                await Self.withTimeout(seconds: 30) {
                    _ = try? await backupManager.makeBackup(keepN: keep)
                }
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
                let callTranscriptWorker = CallTranscriptWorker(
                    repository: callRepository,
                    computeCoordinator: computeCoordinator,
                    dataRoot: resolvedDataRoot,
                    modelStore: whisperModelStore
                )
                self.callTranscriptWorker = callTranscriptWorker
                await callEvidenceDeletionService.attachTranscriptWorker(
                    suspend: {
                        await callTranscriptWorker.suspendAndDrainForEvidenceMutation()
                    },
                    resume: { [weak self] in
                        let allowed = await MainActor.run {
                            self?.recording.lowDiskPaused == false
                                && self?.storageSettings.relocationInProgress == false
                        }
                        if allowed { await callTranscriptWorker.resume() }
                    }
                )
                speechModel.attach(
                    whisperModelStore,
                    suspendWorker: { await callTranscriptWorker.suspendAndDrain() },
                    resumeWorker: { [weak self] in
                        let allowed = await MainActor.run {
                            self?.recording.lowDiskPaused == false
                                && self?.storageSettings.relocationInProgress == false
                        }
                        if allowed { await callTranscriptWorker.resume() }
                    }
                )
                if storage.freeBytes() < DiskReservePolicy.standard.pauseBytes {
                    await callTranscriptWorker.suspendAndDrain()
                }
                callTranscriptWorkerTask = Task.detached(priority: .utility) {
                    await callTranscriptWorker.runLoop()
                }
                Task { @MainActor [speechModel] in
                    await speechModel.refresh()
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

            // Capture loop (the heart). Starts on toggle in RecordingStore.
            let coordinator = CaptureCoordinator(ingest: ingestService)
            coordinator.onFrame = { [weak rec = recording] in rec?.noteFrame() }
            // SCK dead despite a granted permission (-3801 etc.) → honest needsRestart instead of a false recording.
            coordinator.onCaptureBroken = { [weak self] in
                Log.capture.error("capture broken at granted permission -> needsRestart")
                self?.permissions.flagScreenNeedsRestart()
            }
            // A transient failure (wake/monitor change) passed — clear the ratchet, don't block recording.
            coordinator.onCaptureRecovered = { [weak self] in
                Log.capture.info("capture recovered -> clear needsRestart")
                self?.permissions.clearScreenNeedsRestart()
            }
            coordinator.onCycleOK = { [weak rec = recording] in rec?.noteCycleOK() }
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
            recording.blockedHint = { [weak self] in
                if self?.permissions.screenNeedsRestart == true {
                    return "Permission granted — restart ZBS Eye (Settings → Restart). Recording will turn on automatically"
                }
                return "No permissions (Screen Recording + Accessibility). Recording turns on automatically once granted; click again to cancel"
            }

            // Audio recording + on-device transcription (step 10). Gate — transcription on + mic granted.
            let audioCoordinator = AudioCoordinator(storage: storage, ingest: ingestService)
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
            let callAudio = CallAudioControl(
                installSink: { [weak audioCoordinator] sink in
                    await audioCoordinator?.installCallFrameSink(sink)
                },
                start: { [weak self, weak audioCoordinator] requested in
                    guard let audioCoordinator else { return .none }
                    let permitted = await MainActor.run { [weak self] in
                        guard let self else { return CallSourceSelection.none }
                        let diskOK = storage.freeBytes() >= DiskReservePolicy.standard.pauseBytes
                        guard !self.recording.lowDiskPaused, diskOK else {
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
                audio: callAudio
            )
            calls.requestedSources = { [weak self] in
                guard let self, self.audioSettings.audioMode != .off else { return .none }
                return CallSourceSelection(me: true, system: self.audioSettings.recordSystemAudio)
            }
            calls.attach(callCoordinator)
            // Clear the session-scoped manual audio override when recording truly stops (NOT on every
            // syncAudio re-sync — that fires each meeting edge and would wipe the override).
            recording.onSessionStop = { [weak self] in self?.audioSettings.clearManualOverride() }

            // Meeting detection → drives meetings-only capture. On-device (CoreAudio mic-in-use +
            // frontmost call app), no new permission. Runs for the app's lifetime; the consumer only
            // re-syncs audio while recording, and syncAudio() itself no-ops when not capturing.
            let detector = MeetingDetector()
            self.meetingDetector = detector
            self.meetingTask = Task { [weak self] in
                for await active in await detector.start() {
                    guard let self else { return }
                    self.audioSettings.meetingActive = active
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
            self.timelineStore = TimelineStore(search: searchSvc, timeline: timelineSvc,
                                               mediaDirectory: storage.mediaDirectory)

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
            let askService = AskService(retrieval: askRetrieval, router: llmRouter)
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
            let rec = recording
            let deps = ZBSEyeHTTPServer.Deps(
                search: searchSvc, timeline: timelineSvc, calls: callEvidenceQueryService,
                db: db, mediaDir: storage.mediaDirectory,
                token: token, version: AppVersion.current,
                isCapturing: { await MainActor.run { rec.isCapturing } },
                toggleCapture: { enable in
                    await MainActor.run {
                        if let enable, enable == rec.isCapturing { return rec.isCapturing }
                        rec.toggle()
                        return rec.isCapturing
                    }
                },
                mediaBytes: { storage.totalBytes() })
            let server = ZBSEyeHTTPServer(deps: deps)
            self.httpServer = server
            Task { [weak self] in
                let port = await server.start()
                ZBSEyeHTTPServer.log("bootstrap: start -> \(String(describing: port))")
                if let port { await MainActor.run { self?.server.setActive(port: port, token: token) } }
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
                    if let frames = try? await db.pool.read({ try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM screen_captures") ?? 0 }) {
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
            Log.app.error("bootstrap failed: \(String(describing: error), privacy: .public)")
            ZBSEyeHTTPServer.log("bootstrap: dataError \(error)")
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
        // Watcher (4s): (1) autostart on late permission grant; (2) degradation on permission revocation mid-run
        // (isCapturing would hang true with a dead capture); (3) audio-gate drift — mic/speech granted
        // AFTER recording started / lowDisk changed → re-sync the legs (previously required restarting recording).
        autostartTask = Task { [weak self] in
            var prevGates: (mic: Bool, system: Bool)? = nil
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self else { return }
                self.recording.startIfWanted()
                // permission revoked mid-run → honest degradation in the UI (instead of a forever-green dot)
                if self.recording.isCapturing {
                    if !self.permissions.allCriticalGranted {
                        self.recording.setDegraded(
                            self.permissions.screenNeedsRestart
                                ? "Capture broke — restart ZBS Eye"
                                : "Permissions revoked — capture isn't working")
                    } else {
                        self.recording.setDegraded(nil)
                    }
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
        if let callTranscriptWorker {
            ownsWorkerResume = await callTranscriptWorker
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
        let recordingDrainTask = Task { @MainActor [recording] in
            await recording.pauseForMaintenanceAndDrain()
        }

        let relocator = StorageRelocator()
        do {
            // Ordered barrier: stop transcript jobs before draining the model
            // store they read, then stop the remaining compute users. Capture
            // and audio stay independently paused for data consistency.
            if let builtInModelManager {
                _ = try await builtInModelManager.suspendAndDrainForRelocation()
            }
            await callTranscriptWorker?.suspendAndDrain()
            await whisperModelStore?.suspendAndDrain()
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
            let ingestDrain = await ingest.drain()
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
                    await self.callTranscriptWorker?.resume()
                    await self.builtInModels.refresh()
                    self.recording.resumeAfterMaintenance()
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
            // Stop speech scratch work first, then close the explicit Call
            // Envelope before draining the shared physical capture legs.
            await callTranscriptWorker?.suspendAndDrain()
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
            recording.resumeAfterLowDisk()
            await callTranscriptWorker?.resume()
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
                nowMs: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            calls.setExternalError(nil)
            return nil
        } catch {
            let message = error.localizedDescription
            calls.setExternalError(message)
            return message
        }
    }
}
