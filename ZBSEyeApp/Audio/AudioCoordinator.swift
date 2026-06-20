import Foundation
import Observation
import GRDB

/// Оркестратор аудио-записи (@MainActor): два независимых лега — микрофон (AVAudioEngine) и системный
/// звук (ScreenCaptureKit). Разные права (mic vs screen recording), общий TranscriptionService.
/// Гейты (что включать) — снаружи (RecordingStore/AppEnvironment). @Observable — per-source флаги
/// (micRunning/systemRunning) питают честный индикатор записи в menubar/sidebar.
@MainActor
@Observable
final class AudioCoordinator {
    @ObservationIgnored private let micEngine: AudioCaptureEngine
    @ObservationIgnored private let systemEngine: SystemAudioCaptureEngine
    @ObservationIgnored private let micPipeline: AudioPipeline
    @ObservationIgnored private let systemPipeline: AudioPipeline
    @ObservationIgnored private let transcription: TranscriptionService
    @ObservationIgnored private var micTask: Task<Void, Never>?
    @ObservationIgnored private var systemTask: Task<Void, Never>?

    private(set) var isRunning = false
    private(set) var micStartFailed = false      // движок не стартанул (нет mic/устройства) — для health/UI
    private(set) var systemStartFailed = false   // SCStream не стартанул (нет screen-доступа/дисплея)
    private(set) var micRunning = false          // per-source индикатор: что реально пишется
    private(set) var systemRunning = false
    @ObservationIgnored var onSegment: (@MainActor () -> Void)?

    @ObservationIgnored private var micRestarts = RestartBudget()
    @ObservationIgnored private var systemRestarts = RestartBudget()
    /// Бамп на каждый start()/stop() координатора: рестарт-циклы прежней сессии самоустраняются.
    @ObservationIgnored private var legGeneration = 0
    /// Эпохи легов: хвост СТАРОГО runLeg не должен перетирать micRunning/systemRunning НОВОГО запуска.
    @ObservationIgnored private var micEpoch = 0
    @ObservationIgnored private var systemEpoch = 0

    init(storage: StorageManager, ingest: IngestService, config: AudioConfig = AudioConfig()) {
        let backend = SFSpeechBackend()
        let transcription = TranscriptionService(backend: backend, ingest: ingest, config: config)
        self.transcription = transcription
        self.micPipeline = AudioPipeline(storage: storage, ingest: ingest,
                                         transcription: transcription, config: config, channel: "mic")
        self.systemPipeline = AudioPipeline(storage: storage, ingest: ingest,
                                            transcription: transcription, config: config, channel: "system")
        self.micEngine = AudioCaptureEngine(config: config)
        self.systemEngine = SystemAudioCaptureEngine(config: config)

        // Устойчивость 24/7: смена аудио-устройства (AirPods) / смерть SCStream → авто-рестарт лега
        // с задержкой и бюджетом (анти-цикл при перманентной поломке). Раньше — молчаливая смерть.
        micEngine.onConfigurationChange = { [weak self] in
            Task { @MainActor in await self?.restartLeg(mic: true) }
        }
        systemEngine.onStreamStopped = { [weak self] in
            Task { @MainActor in await self?.restartLeg(mic: false) }
        }
    }

    /// Перезапуск лега после смерти движка. НЕ терминальный: бюджет (5/мин) гасит штормы рестартов,
    /// но после исчерпания — минутный отдых и новая попытка (устройство могло стабилизироваться;
    /// перманентная смерть лега до ручного вмешательства недопустима для 24/7-рекордера).
    /// generation-гард: ручной stop()/start() во время паузы делает этот цикл устаревшим.
    private func restartLeg(mic: Bool) async {
        guard isRunning else { return }
        let gen = legGeneration
        if mic { micRunning = false } else { systemRunning = false }
        Log.audio.info("\(mic ? "mic" : "system", privacy: .public) leg died — entering restart loop")
        while isRunning && legGeneration == gen && !Task.isCancelled {
            let budgetOK = mic ? micRestarts.allow() : systemRestarts.allow()
            if !budgetOK {
                if mic { micStartFailed = true } else { systemStartFailed = true }
                Log.audio.error("\(mic ? "mic" : "system", privacy: .public) leg: budget exhausted, cooling down 60s")
            }
            try? await Task.sleep(for: .seconds(budgetOK ? 1 : 60))
            guard isRunning, legGeneration == gen else { return }
            if mic {
                if startMicLeg() { return }
            } else {
                startSystemLeg()   // async-движок: провал старта вернётся новым restartLeg из catch
                return
            }
        }
    }

    func start(mic: Bool, system: Bool) {
        guard !isRunning, mic || system else { return }
        isRunning = true
        legGeneration += 1
        if mic { _ = startMicLeg() }
        if system { startSystemLeg() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        legGeneration += 1
        micRunning = false
        systemRunning = false
        micEngine.stop()
        systemEngine.stop()   // finish() закроет stream → for-await завершится → flushFinal внутри лега
        // Дождаться обоих легов (их flushFinal), затем выгрузить модель — в фоне (мы @MainActor, не await'им).
        let mt = micTask, st = systemTask, transcription = self.transcription
        Task { await mt?.value; await st?.value; await transcription.quiesce() }
        // micTask/systemTask НЕ зануляем: следующий start ждёт их через previous (сериализация циклов).
    }

    func health() async -> TranscriptionHealth { await transcription.snapshot() }

    /// Backfill: аудио-сегменты БЕЗ транскрипта (краш потерял in-memory очередь / транзиентный фейл) —
    /// дотранскрибировать. Окно 7 дней (вечные фейлы вроде музыки не молотим бесконечно), файл должен
    /// существовать. Вызывается из bootstrap с задержкой.
    func backfillUntranscribed(db: ZBSEyeDatabase, storage: StorageManager) async {
        struct Item: Sendable { let id: Int64; let ts: Int64; let dur: Double; let rel: String; let channel: String }
        let weekAgoMs = msFromDate(Date().addingTimeInterval(-7 * 86_400))
        let items: [Item] = (try? await db.pool.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT a.id AS id, a.ts AS ts, a.durationSec AS dur, a.relativePath AS rel, a.channel AS channel
                FROM audio_captures a LEFT JOIN transcriptions t ON t.audioId = a.id
                WHERE t.id IS NULL AND a.ts > ? ORDER BY a.ts DESC LIMIT 200
                """, arguments: [weekAgoMs]).map {
                Item(id: $0["id"], ts: $0["ts"], dur: $0["dur"], rel: $0["rel"], channel: $0["channel"])
            }
        }) ?? []
        guard !items.isEmpty else { return }
        var queued = 0
        for item in items {
            let url = storage.url(forRelative: item.rel)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            await transcription.enqueue(AudioSegment(
                audioId: item.id, fileURL: url, ts: dateFromMs(item.ts),
                durationSec: item.dur, channel: item.channel))
            queued += 1
        }
        if queued > 0 { Log.audio.info("transcription backfill: \(queued) сегментов в очередь") }
    }

    /// Privacy-сброс in-flight аудио: открытый VAD-сегмент живёт в памяти (ни в БД, ни на диске) —
    /// deleteRange его не видит, и «стереть навсегда» иначе переживал бы до 28с речи, захваченной
    /// ДО клика (каноничный сценарий: произнёс пароль → жмёт удалить). Плюс чистка очереди транскрипции.
    func discardInFlight(from: Date, to: Date) async {
        await micPipeline.reset()
        await systemPipeline.reset()
        await transcription.purgeQueued(from: from, to: to)
    }

    // MARK: легы

    @discardableResult
    private func startMicLeg() -> Bool {
        micStartFailed = false
        let stream: AsyncStream<AudioFrame>
        do { stream = try micEngine.start() }
        catch {
            micStartFailed = true
            Log.audio.error("mic engine start failed: \(String(describing: error), privacy: .public)")
            return false
        }
        micEpoch += 1
        micRunning = true
        micTask = runLeg(stream: stream, pipeline: micPipeline, previous: micTask, epoch: micEpoch)
        return true
    }

    /// Системный лег: engine.start() async (SCStream.startCapture), поэтому весь лег — внутри Task.
    private func startSystemLeg() {
        systemStartFailed = false
        let previous = systemTask
        let engine = systemEngine
        let pipeline = systemPipeline
        systemEpoch += 1
        let epoch = systemEpoch
        systemTask = Task { [weak self] in
            await previous?.value
            let stream: AsyncStream<AudioFrame>
            do { stream = try await engine.start() }
            catch {
                Log.audio.error("system audio start failed: \(String(describing: error), privacy: .public)")
                await MainActor.run {
                    self?.systemStartFailed = true
                    // транзиентный провал старта (дисплеи перестраиваются) не должен быть терминальным
                    Task { @MainActor in await self?.restartLeg(mic: false) }
                }
                return
            }
            await MainActor.run { self?.systemRunning = true }
            await pipeline.reset()
            for await frame in stream {
                let closed = await pipeline.feed(frame)
                if closed { Task { @MainActor in self?.onSegment?() } }
            }
            await pipeline.flushFinal()
            await MainActor.run { if self?.systemEpoch == epoch { self?.systemRunning = false } }
        }
    }

    /// Общий консьюмер лега: ждёт завершения прошлого цикла, reset, дренаж, flushFinal (всё на одном
    /// потоке управления — без гонки flush vs трейлинг-feed).
    private func runLeg(stream: AsyncStream<AudioFrame>, pipeline: AudioPipeline,
                        previous: Task<Void, Never>?, epoch: Int) -> Task<Void, Never> {
        Task { [weak self] in
            await previous?.value
            await pipeline.reset()
            for await frame in stream {
                let closed = await pipeline.feed(frame)
                if closed { Task { @MainActor in self?.onSegment?() } }
            }
            await pipeline.flushFinal()
            // epoch-гард: хвост СТАРОГО лега после авто-рестарта не перетирает индикатор НОВОГО
            await MainActor.run { if self?.micEpoch == epoch { self?.micRunning = false } }
        }
    }
}

/// Бюджет авто-рестартов: максимум 5 за минуту — анти-цикл при перманентной поломке устройства.
private struct RestartBudget {
    private var stamps: [Date] = []
    mutating func allow() -> Bool {
        let now = Date()
        stamps = stamps.filter { now.timeIntervalSince($0) < 60 }
        guard stamps.count < 5 else { return false }
        stamps.append(now)
        return true
    }
}
