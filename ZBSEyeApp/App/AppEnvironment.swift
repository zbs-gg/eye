import Foundation
import AppKit
import Observation

/// Корневое состояние приложения. Единственный @Observable, инжектится через .environment.
/// Владеет всеми store'ами (по плану v2 — вместо разрозненных @State и 14-биндингового антипаттерна).
@MainActor
@Observable
final class AppEnvironment {
    let permissions = PermissionsStore()
    let recording = RecordingStore()
    let server = ServerStore()
    let connections = ConnectionStore()   // конфиг LLM/назначения persist'ится сам, db не нужна
    let audioSettings = AudioSettingsStore()
    let storageSettings = StorageSettingsStore()
    let backupSettings = BackupSettingsStore()
    let privacy = PrivacyStore()

    var selectedSection: SidebarSection = .timeline

    /// Первый запуск → онбординг (consent «пишется всё» + права). Persist: показывается до завершения.
    var showOnboarding = !UserDefaults.standard.bool(forKey: "zbseye.onboarding.done")

    func completeOnboarding(startRecording: Bool) {
        UserDefaults.standard.set(true, forKey: "zbseye.onboarding.done")
        showOnboarding = false
        if startRecording {
            if !recording.isCapturing { recording.toggle() }
        } else {
            // «Позже» — явный отказ в consent-точке: остановить возможный автостарт из-под шторки
            // и снять взведённое намерение (иначе запись стартанула бы сама вопреки отказу).
            recording.disarm()
        }
    }

    // Data-слой (создаётся в bootstrap; nil до инициализации / при ошибке).
    private(set) var database: ZBSEyeDatabase?
    private(set) var ingest: IngestService?
    private(set) var retention: RetentionManager?
    private(set) var timelineStore: TimelineStore?
    private(set) var httpServer: ZBSEyeHTTPServer?
    private(set) var pipes: DaySummaryStore?
    private(set) var audio: AudioCoordinator?
    private(set) var storage: StorageManager?   // для Settings-хранилища (занято/удаление/Finder)
    private(set) var db: ZBSEyeDatabase?         // для Settings-разбивки размера / бэкапа
    private(set) var export: ExportService?
    private(set) var screenpipeImporter: ScreenpipeImporter?
    private(set) var dataError: String?

    @ObservationIgnored private var retentionTask: Task<Void, Never>?
    @ObservationIgnored private var backupTask: Task<Void, Never>?
    @ObservationIgnored private(set) var backupManager: BackupManager?
    @ObservationIgnored private var autostartTask: Task<Void, Never>?
    @ObservationIgnored private var emergencyPruneInFlight = false
    @ObservationIgnored private var lastEmergencyPruneAt: Date?
    /// Минимум свободного места: ниже — захват приостанавливается + экстренный prune (диск не добиваем).
    private nonisolated static let minFreeBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Гонка операции против таймаута — чтобы бэкап на выходе не подвесил quit навсегда.
    nonisolated static func withTimeout(seconds: Double, _ op: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await op() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            _ = await group.next()
            group.cancelAll()
        }
    }

    /// Порядок запуска фоновых сервисов. Пока — пробы прав + Data-слой; capture/server/pipes добавятся
    /// по мере появления модулей (Фаза 2, шаги 3+).
    func bootstrap() async {
        ZBSEyeHTTPServer.log("bootstrap: begin")
        // Crash-маркер: при прошлом запуске флаг чистого выхода не выставился → сессия умерла
        // некорректно (kill/краш/паника ядра). Видно в Console.app при удалённой диагностике.
        let cleanKey = "zbseye.cleanShutdown"
        if UserDefaults.standard.object(forKey: cleanKey) != nil,
           !UserDefaults.standard.bool(forKey: cleanKey) {
            Log.app.error("предыдущая сессия завершилась НЕкорректно (crash/kill) — проверь дыры в истории")
            ZBSEyeHTTPServer.log("CRASH-MARKER: предыдущая сессия завершилась некорректно (crash/kill)")
        }
        UserDefaults.standard.set(false, forKey: cleanKey)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            UserDefaults.standard.set(true, forKey: cleanKey)
        }
        await permissions.refreshAll()
        // АНТИ-SPLIT-BRAIN: если данные были перенесены на том, который сейчас недоступен — НЕ стартуем
        // на legacy «с нуля» (иначе пустая история + раскол новых кадров). Просим подключить и перезапустить.
        if let missing = StorageLocation.unavailableConfiguredPath() {
            self.dataError = "Папка данных недоступна: \(missing). Подключи диск/том и перезапусти ZBS Eye — "
                + "запись выключена, чтобы не раздвоить «вечную память»."
            ZBSEyeHTTPServer.log("data root unavailable (\(missing)) — bootstrap прерван (анти-split-brain)")
            return
        }
        do {
            let storage = try StorageManager()
            self.storage = storage
            let db = try ZBSEyeDatabase(path: ZBSEyeDatabase.defaultURL().path)
            self.db = db
            let backupManager = BackupManager(db: db, storage: storage)
            self.backupManager = backupManager
            backupSettings.manager = backupManager
            backupSettings.refresh()
            // Бэкап на выходе (applicationShouldTerminate → terminateLater): успеть снапшот до смерти
            // процесса (willTerminate уже не успел бы — там процесс умирает синхронно). С таймаутом 30с.
            ZBSEyeAppDelegate.onTerminate = { [weak self] in
                guard let self, self.backupSettings.enabled, BackupManager.iCloudAvailable() else { return }
                let keep = self.backupSettings.keepN
                await Self.withTimeout(seconds: 30) {
                    _ = try? await backupManager.makeBackup(keepN: keep)
                }
            }
            ZBSEyeHTTPServer.log("bootstrap: db ok")
            self.database = db
            // Отдельные embedder для ingest и search — иначе тяжёлый embed на захвате блокирует
            // эмбеддинг поискового запроса (head-of-line, по ревью). Скачивание модели при этом
            // ОДНО на процесс (E5ModelProvider сериализует; кеш в Application Support).
            let ingestEmbedder = EmbeddingService()
            let ingestService = IngestService(db: db, storage: storage, embedder: ingestEmbedder)
            self.ingest = ingestService

            // Backfill semantic-индекса (кадры без вектора: дроп миграции v3 / оффлайн first-run).
            // Тот же embedder, что у ingest — третью копию модели в RAM не грузим. Старт с задержкой,
            // чтобы не конкурировать с запуском.
            let backfill = VectorBackfill(db: db, embedder: ingestEmbedder)
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(30))
                await backfill.run()
            }
            let retention = RetentionManager(db: db, storage: storage)
            self.retention = retention

            // Capture loop (сердце). Стартует по toggle в RecordingStore.
            let coordinator = CaptureCoordinator(ingest: ingestService)
            coordinator.onFrame = { [weak rec = recording] in rec?.noteFrame() }
            // SCK мёртв при выданном праве (-3801 и пр.) → честный needsRestart вместо ложной записи.
            coordinator.onCaptureBroken = { [weak self] in
                Log.capture.error("capture broken at granted permission -> needsRestart")
                self?.permissions.flagScreenNeedsRestart()
            }
            // Транзиентный сбой (wake/смена мониторов) прошёл — снять ratchet, не блокировать запись.
            coordinator.onCaptureRecovered = { [weak self] in
                Log.capture.info("capture recovered -> clear needsRestart")
                self?.permissions.clearScreenNeedsRestart()
            }
            coordinator.onCycleOK = { [weak rec = recording] in rec?.noteCycleOK() }
            // Disk-guard: при < minFree пропускаем захват, поднимаем статус и запускаем экстренный prune.
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
            // Запись честная: без критичных прав не стартует (вместо ложной зелёной точки).
            recording.canCapture = { [weak self] in self?.permissions.allCriticalGranted ?? false }
            recording.blockedHint = { [weak self] in
                if self?.permissions.screenNeedsRestart == true {
                    return "Право выдано — перезапусти ZBS Eye (Настройки → Перезапустить). Запись включится автоматически"
                }
                return "Нет прав (Запись экрана + Универсальный доступ). Запись включится автоматически после выдачи; повторный клик — отмена"
            }

            // Аудио-запись + on-device транскрипция (шаг 10). Гейт — транскрипция вкл + mic granted.
            let audioCoordinator = AudioCoordinator(storage: storage, ingest: ingestService)
            audioCoordinator.onSegment = { [weak rec = recording] in rec?.noteAudioChunk() }
            recording.audio = audioCoordinator
            // Гейты ЗАПИСИ звука (без speech-права: сырой звук ценен сам по себе — найдёшь по времени
            // и прослушаешь в таймлайне; транскрипция отдельно, при наличии speech). Микрофон требует
            // mic-доступ; системный звук — Screen Recording (уже выдан для экрана) + отдельный тумблер.
            recording.micEnabled = { [weak self] in
                guard let self else { return false }
                return self.audioSettings.transcriptionEnabled
                    && !self.recording.lowDiskPaused        // disk-guard гейтит и аудио (не только экран)
                    && self.permissions.snapshot.microphone == .granted
            }
            recording.systemEnabled = { [weak self] in
                guard let self else { return false }
                return self.audioSettings.transcriptionEnabled
                    && self.audioSettings.recordSystemAudio
                    && !self.recording.lowDiskPaused
                    && self.permissions.snapshot.screenRecording == .granted
            }
            self.audio = audioCoordinator
            // Дотранскрибировать сегменты, оставшиеся без текста (краш/фейл) — через минуту после старта.
            Task { [weak audioCoordinator] in
                try? await Task.sleep(for: .seconds(60))
                await audioCoordinator?.backfillUntranscribed(db: db, storage: storage)
            }

            // Поиск (гибрид FTS+vector) + таймлайн.
            let searchSvc = SearchService(db: db, embedder: EmbeddingService())
            let timelineSvc = TimelineService(db: db)
            self.timelineStore = TimelineStore(search: searchSvc, timeline: timelineSvc,
                                               mediaDirectory: storage.mediaDirectory)

            // Pipe v1 «саммари дня»: collect→LLM→write. Свой LocalLLMClient (stateless actor).
            let summarySvc = DailySummaryService(db: db, client: LocalLLMClient())
            let pipesStore = DaySummaryStore(service: summarySvc, connections: connections)
            pipesStore.startScheduler()   // «конспект сам в конце дня» (тик 5 мин, гейты внутри)
            self.pipes = pipesStore

            // Экспорт (анти-lock-in): markdown по дням ± медиа.
            self.export = ExportService(db: db, summary: summarySvc, mediaDirectory: storage.mediaDirectory)
            self.screenpipeImporter = ScreenpipeImporter(db: db)

            // Локальный REST /v1 (auth на всё кроме /health).
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

            // Retention НЕПРЕРЫВНО (не только на старте): сразу + каждые 30 мин. 24/7-аптайм неделями
            // не должен уводить диск за лимит между перезапусками.
            retentionTask = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    // политика юзера из Settings (0 = без лимита → nil)
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
                    try? await Task.sleep(for: .seconds(1800))
                }
            }

            // iCloud-бэкап: каждые 6ч (+ ручной в Settings + на выходе). Гейты внутри (enabled && iCloud).
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
                        Log.app.info("iCloud backup: \(StorageSettingsStore.format(r.compressedBytes)) (\(r.frames) кадров)")
                    }
                }
            }
        } catch {
            self.dataError = String(describing: error)
            Log.app.error("bootstrap failed: \(String(describing: error), privacy: .public)")
            ZBSEyeHTTPServer.log("bootstrap: dataError \(error)")
        }

        // Поллинг прав (юзер выдаёт в Системных настройках — UI и автостарт подхватывают сами).
        permissions.startPolling()
        // Автостарт: «вечная память» возобновляется после ребута/краша, если юзер её включал.
        recording.startIfWanted()
        // Watcher (4с): (1) автостарт при поздней выдаче прав; (2) деградация при отзыве прав mid-run
        // (isCapturing висел бы true при мёртвом захвате); (3) дрейф аудио-гейтов — выдали mic/speech
        // ПОСЛЕ старта записи / сменился lowDisk → пере-синк легов (раньше требовало рестарта записи).
        autostartTask = Task { [weak self] in
            var prevGates: (mic: Bool, system: Bool)? = nil
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self else { return }
                self.recording.startIfWanted()
                // отзыв прав mid-run → честная деградация в UI (вместо вечной зелёной точки)
                if self.recording.isCapturing {
                    if !self.permissions.allCriticalGranted {
                        self.recording.setDegraded(
                            self.permissions.screenNeedsRestart
                                ? "Захват сломался — перезапусти ZBS Eye"
                                : "Права отозваны — захват не работает")
                    } else {
                        self.recording.setDegraded(nil)
                    }
                    // дрейф аудио-гейтов (новые права/настройки/lowDisk) → пересинк легов
                    let gates = (self.recording.micEnabled(), self.recording.systemEnabled())
                    if let prev = prevGates, prev != gates { self.recording.syncAudio() }
                    prevGates = gates
                } else {
                    prevGates = nil
                }
            }
        }
    }

    /// Удаление истории (privacy): lastSeconds=nil → всё. Возвращает отчёт для UI.
    func deleteHistory(lastSeconds: TimeInterval?) async -> PruneReport? {
        guard let retention else { return nil }
        // Верхняя граница фиксируется НА МОМЕНТ клика: при идущей записи «удалить 15 минут» не должно
        // зацепить кадры, записанные во время самого удаления (батчи идут секунды).
        let now = Date()
        let toMs: Int64 = lastSeconds == nil ? Int64.max : msFromDate(now)
        let fromMs: Int64 = lastSeconds.map { msFromDate(now.addingTimeInterval(-$0)) } ?? 0
        // КРИТИЧНО (privacy): открытый VAD-сегмент живёт в памяти — deleteRange его не видит.
        // Сбрасываем in-flight аудио ДО удаления, иначе «произнёс пароль → стереть» переживало бы
        // до 28с речи, захваченной до клика (закрылось бы и легло в БД ПОСЛЕ удаления).
        await audio?.discardInFlight(from: dateFromMs(fromMs), to: lastSeconds == nil ? now : dateFromMs(toMs))
        let report = try? await retention.deleteRange(fromMs: fromMs, toMs: toMs)
        if let r = report {
            Log.retention.info("manual delete: frames \(r.framesDeleted) audio \(r.audioDeleted)")
        }
        await storageSettings.refresh(storage: storage, db: db)
        // курсор таймлайна мог указывать в стёртое — обновить
        await timelineStore?.load()
        return report
    }

    /// Перенос всей памяти в выбранную папку (T1): пауза захвата → online backup БД + copy media →
    /// verify (integrity + COUNT-parity) → flip StorageLocation → relaunch. Источник НЕ трогаем (copy);
    /// при ошибке возобновляем запись, данные на старом месте целы.
    func relocate(to chosen: URL) async {
        guard let db, let storage, !storageSettings.relocationInProgress else { return }
        storageSettings.relocationInProgress = true
        storageSettings.relocationError = nil
        storageSettings.relocationProgress = 0
        storageSettings.relocationStatus = "Останавливаю запись…"
        recording.pauseForMaintenance()
        audio?.stop()
        // Дренаж: stop()/VAD-сегмент дописывают in-flight кадр/аудио детачнутыми задачами в СТАРЫЙ root.
        // Ждём ~1.2с, чтобы они закоммитились в БД и записали media ДО online-backup-снапшота и снапшота
        // списка media — иначе граничный кадр/сегмент осиротел бы (файл вне копии / строка вне бэкапа).
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
            storageSettings.relocationStatus = "Перенесено (\(report.mediaFilesCopied) медиа). Перезапуск…"
            try? await Task.sleep(for: .milliseconds(600))   // дать UI показать статус
            AppRelauncher.relaunch()
        } catch {
            storageSettings.relocationInProgress = false
            storageSettings.relocationError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            recording.startIfWanted()   // миграция не удалась — возобновить запись
        }
    }

    /// Экстренный prune при low-disk: таргетирует СВОБОДНОЕ место (×2 порога паузы = гистерезис),
    /// а не политику 7д/20GB — иначе при диске, забитом не нами, prune ничего не удалял бы и пауза
    /// записи никогда не самоизлечивалась. Cooldown 10 мин — без чёрна каждый capture-тик.
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
    case timeline = "Таймлайн"
    case pipes = "Плагины"
    case connections = "Подключения"
    case settings = "Настройки"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .timeline:    return "clock.arrow.circlepath"
        case .pipes:       return "powerplug"
        case .connections: return "app.connected.to.app.below.fill"
        case .settings:    return "gearshape"
        }
    }
}
