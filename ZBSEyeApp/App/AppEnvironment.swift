import Foundation
import AppKit
import Observation
import UserNotifications

/// Root application state. The single @Observable, injected via .environment.
/// Owns all the stores (per the v2 plan — instead of scattered @State and the 14-binding antipattern).
@MainActor
@Observable
final class AppEnvironment {
    let permissions = PermissionsStore()
    let recording = RecordingStore()
    let server = ServerStore()
    let connections = ConnectionStore()   // LLM/destination config persists itself, no db needed
    let audioSettings = AudioSettingsStore()
    let storageSettings = StorageSettingsStore()
    let backupSettings = BackupSettingsStore()
    let privacy = PrivacyStore()
    let rewards = RewardsStore()   // cosmetic rewards (theme/icon/menu-bar) — independent of the DB

    var selectedSection: SidebarSection = .timeline

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
    private(set) var retention: RetentionManager?
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
    private(set) var achievements: AchievementStore?

    @ObservationIgnored private var retentionTask: Task<Void, Never>?
    @ObservationIgnored private var backupTask: Task<Void, Never>?
    @ObservationIgnored private(set) var backupManager: BackupManager?
    @ObservationIgnored private var autostartTask: Task<Void, Never>?
    @ObservationIgnored private var meetingDetector: MeetingDetector?
    @ObservationIgnored private var meetingTask: Task<Void, Never>?
    @ObservationIgnored private(set) var browserHistoryImporter: BrowserHistoryImporter?
    @ObservationIgnored private var browserHistoryTask: Task<Void, Never>?
    @ObservationIgnored private var emergencyPruneInFlight = false
    @ObservationIgnored private var lastEmergencyPruneAt: Date?
    /// Minimum free space: below this — capture is paused + emergency prune (we don't fill the disk to the brim).
    private nonisolated static let minFreeBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Race an operation against a timeout — so a backup on exit doesn't hang quit forever.
    nonisolated static func withTimeout(seconds: Double, _ op: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await op() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            _ = await group.next()
            group.cancelAll()
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
        ZBSEyeHTTPServer.log("bootstrap: begin")
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
            let storage = try StorageManager()
            self.storage = storage
            let db = try ZBSEyeDatabase(path: ZBSEyeDatabase.defaultURL().path)
            self.db = db
            // Gamification: progress and milestones
            self.progress = ProgressStore(db: db)
            let backupManager = BackupManager(db: db, storage: storage)
            self.backupManager = backupManager
            backupSettings.manager = backupManager
            backupSettings.refresh()
            // Backup on exit (applicationShouldTerminate → terminateLater): snapshot in time before the process
            // dies (willTerminate would be too late — the process dies synchronously there). With a 30s timeout.
            ZBSEyeAppDelegate.onTerminate = { [weak self] in
                guard let self, self.backupSettings.enabled, BackupManager.iCloudAvailable() else { return }
                let keep = self.backupSettings.keepN
                await Self.withTimeout(seconds: 30) {
                    _ = try? await backupManager.makeBackup(keepN: keep)
                }
            }
            ZBSEyeHTTPServer.log("bootstrap: db ok")
            self.database = db
            // Separate embedders for ingest and search — otherwise a heavy embed on capture blocks
            // the embedding of a search query (head-of-line, per review). The model download is still
            // ONE per process (E5ModelProvider serializes; cache in Application Support).
            let ingestEmbedder = EmbeddingService()
            let ingestService = IngestService(db: db, storage: storage, embedder: ingestEmbedder)
            self.ingest = ingestService

            // Backfill of the semantic index (frames without a vector: dropped v3 migration / offline first-run).
            // The same embedder as ingest — we don't load a third copy of the model into RAM. Start delayed,
            // so it doesn't compete with launch.
            let backfill = VectorBackfill(db: db, embedder: ingestEmbedder)
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(30))
                await backfill.run()
            }
            let retention = RetentionManager(db: db, storage: storage)
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
            // Disk-guard: at < minFree we skip capture, raise the status, and kick off an emergency prune.
            coordinator.diskOK = { [weak self] in
                guard let self else { return false }
                let ok = storage.freeBytes() > Self.minFreeBytes
                if self.recording.lowDiskPaused != !ok { self.recording.setLowDisk(!ok) }
                if !ok { self.emergencyPrune() }
                return ok
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
            let searchSvc = SearchService(db: db, embedder: EmbeddingService())
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

            // "The day in activities": scenes on top of screen_captures (without a new table).
            let sceneSvc = SceneService(repo: activityRepo)
            self.sceneStore = SceneStore(service: sceneSvc, timeline: timelineSvc)

            // "Ask your memory": a RAG answer through the same hybrid search + a local LLM (its own
            // LocalLLMClient, a stateless actor). The localhost-only gate is inside — private history doesn't leave.
            let askService = AskService(search: searchSvc, client: LocalLLMClient(), db: db)
            self.ask = AskStore(service: askService, connections: connections)

            // Cartographer: AI insights for the day (on-device, read-only). Its own LocalLLMClient (stateless actor).
            let cartographerSvc = CartographerService(repo: activityRepo, client: LocalLLMClient())
            self.cartographer = CartographerStore(service: cartographerSvc, connections: connections)

            // Automation v1 "day summary": collect→LLM→write. Its own LocalLLMClient (stateless actor).
            let summarySvc = DailySummaryService(repo: activityRepo, client: LocalLLMClient())
            let automationsStore = DaySummaryStore(service: summarySvc, connections: connections)
            automationsStore.startScheduler()   // "a recap by itself at the end of the day" (5-min tick, gates inside)
            self.automations = automationsStore

            // Export (anti-lock-in): markdown by day ± media.
            self.export = ExportService(db: db, summary: summarySvc, mediaDirectory: storage.mediaDirectory)
            self.historyImporter = HistoryImporter(db: db)

            // Local REST /v1 (auth on everything except /health).
            let token = KeychainStore.apiToken()
            let rec = recording
            let deps = ZBSEyeHTTPServer.Deps(
                search: searchSvc, timeline: timelineSvc, db: db, mediaDir: storage.mediaDirectory,
                token: token, version: "0.1.0",
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
                    // the user's policy from Settings (0 = no limit → nil)
                    let policy = await MainActor.run { () -> (Int?, Int64?) in
                        guard let s = self?.storageSettings else {
                            return (RetentionPolicy.defaultDays, RetentionPolicy.defaultMaxBytes)
                        }
                        return (s.effectiveDays, s.effectiveMaxBytes)
                    }
                    let report = try? await retention.prune(retentionDays: policy.0, maxBytes: policy.1)
                    if let r = report, r.framesDeleted + r.audioDeleted + r.orphansDeleted > 0 {
                        Log.retention.info("prune: frames \(r.framesDeleted) audio \(r.audioDeleted) orphans \(r.orphansDeleted)")
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

    /// History deletion (privacy): lastSeconds=nil → everything. Returns a report for the UI.
    func deleteHistory(lastSeconds: TimeInterval?) async -> PruneReport? {
        guard let retention else { return nil }
        // The upper bound is fixed AT THE MOMENT of the click: with recording running, "delete 15 minutes" must not
        // catch frames recorded during the deletion itself (batches take seconds).
        let now = Date()
        let toMs: Int64 = lastSeconds == nil ? Int64.max : msFromDate(now)
        let fromMs: Int64 = lastSeconds.map { msFromDate(now.addingTimeInterval(-$0)) } ?? 0
        // CRITICAL (privacy): an open VAD segment lives in memory — deleteRange doesn't see it.
        // We flush in-flight audio BEFORE the delete, otherwise "said a password → wipe" would survive
        // up to 28s of speech captured before the click (it would close and land in the DB AFTER the delete).
        await audio?.discardInFlight(from: dateFromMs(fromMs), to: lastSeconds == nil ? now : dateFromMs(toMs))
        let report = try? await retention.deleteRange(fromMs: fromMs, toMs: toMs)
        if let r = report {
            Log.retention.info("manual delete: frames \(r.framesDeleted) audio \(r.audioDeleted)")
        }
        await storageSettings.refresh(storage: storage, db: db)
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

    /// Move all of memory to a chosen folder (T1): pause capture → online DB backup + copy media →
    /// verify (integrity + COUNT parity) → flip StorageLocation → relaunch. We don't touch the source (copy);
    /// on error we resume recording, the data at the old location is intact.
    func relocate(to chosen: URL) async {
        guard let db, let storage, !storageSettings.relocationInProgress else { return }
        storageSettings.relocationInProgress = true
        storageSettings.relocationError = nil
        storageSettings.relocationProgress = 0
        storageSettings.relocationStatus = "Stopping recording…"
        recording.pauseForMaintenance()
        audio?.stop()
        // Drain: stop()/the VAD segment finish writing the in-flight frame/audio via detached tasks to the OLD root.
        // We wait ~1.2s for them to commit to the DB and write media BEFORE the online-backup snapshot and the snapshot
        // of the media list — otherwise a boundary frame/segment would be orphaned (file outside the copy / row outside the backup).
        try? await Task.sleep(for: .milliseconds(1200))

        let relocator = StorageRelocator()
        do {
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
            AchievementCounters.set(.relocated)   // "To Your Own Disk" achievement
            storageSettings.relocationStatus = "Moved (\(report.mediaFilesCopied) media). Restarting…"
            try? await Task.sleep(for: .milliseconds(600))   // let the UI show the status
            AppRelauncher.relaunch()
        } catch {
            storageSettings.relocationInProgress = false
            storageSettings.relocationError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            recording.startIfWanted()   // migration failed — resume recording
        }
    }

    /// Emergency prune on low-disk: targets FREE space (×2 the pause threshold = hysteresis),
    /// not the 7d/20GB policy — otherwise, with a disk filled by data that isn't ours, prune would delete nothing
    /// and the recording pause would never self-heal. Cooldown 10 min — no churn on every capture tick.
    private func emergencyPrune() {
        guard !emergencyPruneInFlight, let retention else { return }
        if let last = lastEmergencyPruneAt, Date().timeIntervalSince(last) < 600 { return }
        emergencyPruneInFlight = true
        lastEmergencyPruneAt = Date()
        Task.detached(priority: .utility) { [weak self] in
            Log.retention.warning("low disk -> emergency prune (target free \(Self.minFreeBytes * 2))")
            let r = try? await retention.pruneUntilFree(targetFreeBytes: Self.minFreeBytes * 2)
            if let r, r.framesDeleted + r.audioDeleted == 0 {
                Log.retention.warning("emergency prune freed nothing — disk full by other data")
            }
            await MainActor.run { self?.emergencyPruneInFlight = false }
        }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case timeline = "Timeline"
    case activities = "Activities"
    case ask = "Ask"
    case cartographer = "Daily Insights"
    case automations = "Automations"
    case connections = "Connections"
    case progress = "Progress"
    case achievements = "Achievements"
    case appearance = "Appearance"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .timeline:     return "clock.arrow.circlepath"
        case .activities:   return "calendar.day.timeline.left"
        case .ask:          return "questionmark.bubble"
        case .cartographer: return "map"
        case .automations:  return "powerplug"
        case .connections:  return "app.connected.to.app.below.fill"
        case .progress:     return "chart.bar.fill"
        case .achievements: return "rosette"
        case .appearance:   return "paintpalette"
        case .settings:     return "gearshape"
        }
    }
}
