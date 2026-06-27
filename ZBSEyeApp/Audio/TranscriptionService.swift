import Foundation

/// Transcription queue (actor): accepts ready AudioSegments, runs the backend one at a time, writes a
/// TranscriptionRecord to the DB (FTS is filled by a trigger). Bounded queue (drop-newest on overflow).
/// Idle-unloads the backend via config.idleUnloadSeconds — we don't keep the speech model in RAM around the clock.
actor TranscriptionService {
    private let backend: any TranscriptionBackend
    private let ingest: IngestService
    private let config: AudioConfig

    private var queue: [AudioSegment] = []
    private var working = false
    private var idleUnloadTask: Task<Void, Never>?
    private var unloadRequested = false   // quiesce() during the drain → unload AFTER it, without a race

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
        unloadRequested = false   // new work arrived → cancel a stale unload request from the previous session
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
                    audioId: seg.audioId, ts: seg.ts, text: t.text, language: t.language, engine: t.engine,
                    speaker: seg.channel == "mic" ? "me" : "other",
                    startOffset: 0, endOffset: seg.durationSec))
                transcribedCount += 1
            } catch {
                // transcription failed (no on-device model / low confidence / not authorized) —
                // the audio stays recorded (findable by time), just without text. Don't drop the queue.
                failedCount += 1
                if let te = error as? TranscriptionError { lastErrorKind = te.kind }
            }
        }
        working = false
        if unloadRequested {                          // quiesce came in during the drain — unload now
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

    /// Privacy cleanup of the queue: segments with a ts in the deleted range must not get transcribed
    /// (their rows/files were already wiped by deleteRange; without cleanup a transcript for a dead audioId would fail on FK,
    /// but the very act of processing deleted content is unnecessary).
    func purgeQueued(from: Date, to: Date) {
        queue.removeAll { $0.ts >= from && $0.ts <= to }
    }

    /// Soft stop: let the queue finish transcribing what's accumulated, then unload the model. If a drain
    /// is in progress — mark unloadRequested (drain unloads at the end, without a reload race). If idle — immediately.
    func quiesce() async {
        if working || !queue.isEmpty {
            unloadRequested = true
        } else {
            idleUnloadTask?.cancel(); idleUnloadTask = nil
            await backend.unload()
        }
    }
}
