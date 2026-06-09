import Foundation

/// Оркестратор аудио-записи (@MainActor): два независимых лега — микрофон (AVAudioEngine) и системный
/// звук (ScreenCaptureKit). Разные права (mic vs screen recording), общий TranscriptionService.
/// Гейты (что включать) — снаружи (RecordingStore/AppEnvironment).
@MainActor
final class AudioCoordinator {
    private let micEngine: AudioCaptureEngine
    private let systemEngine: SystemAudioCaptureEngine
    private let micPipeline: AudioPipeline
    private let systemPipeline: AudioPipeline
    private let transcription: TranscriptionService
    private var micTask: Task<Void, Never>?
    private var systemTask: Task<Void, Never>?

    private(set) var isRunning = false
    private(set) var micStartFailed = false      // движок не стартанул (нет mic/устройства) — для health/UI
    private(set) var systemStartFailed = false   // SCStream не стартанул (нет screen-доступа/дисплея)
    var onSegment: (@MainActor () -> Void)?

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
    }

    func start(mic: Bool, system: Bool) {
        guard !isRunning, mic || system else { return }
        isRunning = true
        if mic { startMicLeg() }
        if system { startSystemLeg() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        micEngine.stop()
        systemEngine.stop()   // finish() закроет stream → for-await завершится → flushFinal внутри лега
        // Дождаться обоих легов (их flushFinal), затем выгрузить модель — в фоне (мы @MainActor, не await'им).
        let mt = micTask, st = systemTask, transcription = self.transcription
        Task { await mt?.value; await st?.value; await transcription.quiesce() }
        // micTask/systemTask НЕ зануляем: следующий start ждёт их через previous (сериализация циклов).
    }

    func health() async -> TranscriptionHealth { await transcription.snapshot() }

    // MARK: легы

    private func startMicLeg() {
        micStartFailed = false
        let stream: AsyncStream<AudioFrame>
        do { stream = try micEngine.start() }
        catch { micStartFailed = true; return }   // нет mic/устройства — surface в health, не молча
        micTask = runLeg(stream: stream, pipeline: micPipeline, previous: micTask)
    }

    /// Системный лег: engine.start() async (SCStream.startCapture), поэтому весь лег — внутри Task.
    private func startSystemLeg() {
        systemStartFailed = false
        let previous = systemTask
        let engine = systemEngine
        let pipeline = systemPipeline
        systemTask = Task { [weak self] in
            await previous?.value
            let stream: AsyncStream<AudioFrame>
            do { stream = try await engine.start() }
            catch { await MainActor.run { self?.systemStartFailed = true }; return }
            await pipeline.reset()
            for await frame in stream {
                let closed = await pipeline.feed(frame)
                if closed { Task { @MainActor in self?.onSegment?() } }
            }
            await pipeline.flushFinal()
        }
    }

    /// Общий консьюмер лега: ждёт завершения прошлого цикла, reset, дренаж, flushFinal (всё на одном
    /// потоке управления — без гонки flush vs трейлинг-feed).
    private func runLeg(stream: AsyncStream<AudioFrame>, pipeline: AudioPipeline,
                        previous: Task<Void, Never>?) -> Task<Void, Never> {
        Task { [weak self] in
            await previous?.value
            await pipeline.reset()
            for await frame in stream {
                let closed = await pipeline.feed(frame)
                if closed { Task { @MainActor in self?.onSegment?() } }
            }
            await pipeline.flushFinal()
        }
    }
}
