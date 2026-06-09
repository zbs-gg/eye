import Foundation

/// Оркестратор аудио-записи (@MainActor): владеет engine + pipeline + transcription. Стартует/останавливает
/// по toggle записи. Гейт (включена транскрипция + mic-доступ) — снаружи (RecordingStore/AppEnvironment).
@MainActor
final class AudioCoordinator {
    private let engine: AudioCaptureEngine
    private let pipeline: AudioPipeline
    private let transcription: TranscriptionService
    private var consumeTask: Task<Void, Never>?

    private(set) var isRunning = false
    var onSegment: (@MainActor () -> Void)?

    init(storage: StorageManager, ingest: IngestService, config: AudioConfig = AudioConfig()) {
        let backend = SFSpeechBackend()
        self.transcription = TranscriptionService(backend: backend, ingest: ingest, config: config)
        self.pipeline = AudioPipeline(storage: storage, ingest: ingest,
                                      transcription: transcription, config: config)
        self.engine = AudioCaptureEngine(config: config)
    }

    func start() {
        guard !isRunning else { return }
        let stream: AsyncStream<AudioFrame>
        do { stream = try engine.start() } catch { return }   // нет mic/устройства — тихо не стартуем
        isRunning = true
        let pipeline = self.pipeline
        let transcription = self.transcription
        let previous = consumeTask   // дождаться ПОЛНОГО завершения прошлого цикла (дренаж+flush+quiesce)
        consumeTask = Task { [weak self] in
            await previous?.value                 // сериализация циклов: новый reset не опередит старый flush
            await pipeline.reset()
            for await frame in stream {
                let closed = await pipeline.feed(frame)
                if closed { Task { @MainActor in self?.onSegment?() } }
            }
            // flushFinal ВНУТРИ consumeTask после полного дренажа буфера — последний feed гарантированно
            // раньше flush на том же потоке управления (нет гонки stop-flush vs трейлинг-feed).
            await pipeline.flushFinal()
            await transcription.quiesce()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.stop()   // continuation.finish() → for-await завершится → flushFinal+quiesce внутри consumeTask.
        // consumeTask НЕ зануляем: следующий start() дождётся его через previous?.value (сериализация циклов).
    }

    func health() async -> TranscriptionHealth { await transcription.snapshot() }
}
