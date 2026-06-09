import Foundation

/// Очередь транскрипции (actor): принимает готовые AudioSegment, гоняет backend по одному, пишет
/// TranscriptionRecord в БД (FTS наполняется триггером). Bounded queue (drop-newest при переполнении).
/// Idle-unload backend через config.idleUnloadSeconds — не держим модель речи в RAM круглосуточно.
actor TranscriptionService {
    private let backend: any TranscriptionBackend
    private let ingest: IngestService
    private let config: AudioConfig

    private var queue: [AudioSegment] = []
    private var working = false
    private var idleUnloadTask: Task<Void, Never>?
    private var unloadRequested = false   // quiesce() во время дренажа → выгрузить ПОСЛЕ него, без гонки

    private(set) var transcribedCount = 0
    private(set) var droppedCount = 0
    private(set) var failedCount = 0
    private(set) var lastErrorKind: String?

    func snapshot() -> TranscriptionHealth {
        TranscriptionHealth(transcribed: transcribedCount, failed: failedCount,
                            dropped: droppedCount, lastErrorKind: lastErrorKind)
    }

    init(backend: any TranscriptionBackend, ingest: IngestService, config: AudioConfig) {
        self.backend = backend
        self.ingest = ingest
        self.config = config
    }

    func enqueue(_ seg: AudioSegment) {
        guard queue.count < config.maxQueuedSegments else { droppedCount += 1; return }
        unloadRequested = false   // появилась новая работа → отменяем устаревший запрос выгрузки прошлой сессии
        queue.append(seg)
        idleUnloadTask?.cancel(); idleUnloadTask = nil
        if !working { working = true; Task { await self.drain() } }
    }

    private func drain() async {
        while !queue.isEmpty {
            let seg = queue.removeFirst()
            do {
                let t = try await backend.transcribe(fileURL: seg.fileURL,
                                                     localeIdentifiers: config.localeIdentifiers,
                                                     minConfidence: config.minTranscriptConfidence,
                                                     timeout: config.transcribeTimeoutSec)
                try await ingest.ingest(TranscriptionRecord(
                    audioId: seg.audioId, text: t.text, language: t.language, engine: t.engine,
                    startOffset: 0, endOffset: seg.durationSec))
                transcribedCount += 1
            } catch {
                // транскрипция не удалась (нет on-device модели / низкая уверенность / не авторизовано) —
                // аудио остаётся записанным (найдётся по времени), просто без текста. Не роняем очередь.
                failedCount += 1
                if let te = error as? TranscriptionError { lastErrorKind = te.kind }
            }
        }
        working = false
        if unloadRequested {                          // quiesce пришёл во время дренажа — выгружаем сейчас
            unloadRequested = false
            idleUnloadTask?.cancel(); idleUnloadTask = nil
            await backend.unload()
        } else {
            scheduleIdleUnload()
        }
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        let secs = config.idleUnloadSeconds
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(secs))
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() async {
        guard !working, queue.isEmpty else { return }
        await backend.unload()
    }

    /// Мягкая остановка: даём очереди дотранскрибировать накопленное, затем выгружаем модель. Если дренаж
    /// идёт — помечаем unloadRequested (drain выгрузит в конце, без гонки reload). Если простаиваем — сразу.
    func quiesce() async {
        if working || !queue.isEmpty {
            unloadRequested = true
        } else {
            idleUnloadTask?.cancel(); idleUnloadTask = nil
            await backend.unload()
        }
    }
}
