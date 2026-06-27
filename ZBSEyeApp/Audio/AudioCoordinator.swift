import Foundation
import Observation
import GRDB

/// Audio-recording orchestrator (@MainActor): two independent legs — microphone (AVAudioEngine) and system
/// audio (ScreenCaptureKit). Different permissions (mic vs screen recording), a shared TranscriptionService.
/// The gates (what to enable) live outside (RecordingStore/AppEnvironment). @Observable — per-source flags
/// (micRunning/systemRunning) feed the honest recording indicator in the menubar/sidebar.
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
    private(set) var micStartFailed = false      // the engine did not start (no mic/device) — for health/UI
    private(set) var systemStartFailed = false   // SCStream did not start (no screen access/display)
    private(set) var micRunning = false          // per-source indicator: what is actually being recorded
    private(set) var systemRunning = false
    @ObservationIgnored var onSegment: (@MainActor () -> Void)?

    @ObservationIgnored private var micRestarts = RestartBudget()
    @ObservationIgnored private var systemRestarts = RestartBudget()
    /// Bumped on every coordinator start()/stop(): restart loops from the previous session self-terminate.
    @ObservationIgnored private var legGeneration = 0
    /// Leg epochs: the tail of an OLD runLeg must not overwrite the micRunning/systemRunning of a NEW start.
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

        // 24/7 resilience: an audio-device change (AirPods) / SCStream death → auto-restart the leg
        // with a delay and a budget (anti-loop on a permanent breakage). Previously — a silent death.
        micEngine.onConfigurationChange = { [weak self] in
            Task { @MainActor in await self?.restartLeg(mic: true) }
        }
        systemEngine.onStreamStopped = { [weak self] in
            Task { @MainActor in await self?.restartLeg(mic: false) }
        }
    }

    /// Restart a leg after the engine dies. NOT terminal: the budget (5/min) quenches restart storms,
    /// but once exhausted — a one-minute rest and a fresh attempt (the device may have stabilized;
    /// a permanent leg death until manual intervention is unacceptable for a 24/7 recorder).
    /// generation guard: a manual stop()/start() during the pause makes this loop stale.
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
                startSystemLeg()   // async engine: a start failure will come back as a new restartLeg from catch
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
        systemEngine.stop()   // finish() will close the stream → for-await completes → flushFinal inside the leg
        // Wait for both legs (their flushFinal), then unload the model — in the background (we're @MainActor, not awaiting).
        let mt = micTask, st = systemTask, transcription = self.transcription
        Task { await mt?.value; await st?.value; await transcription.quiesce() }
        // We do NOT nil out micTask/systemTask: the next start waits for them via previous (serialization of cycles).
    }

    func health() async -> TranscriptionHealth { await transcription.snapshot() }

    /// Backfill: audio segments WITHOUT a transcript (a crash lost the in-memory queue / a transient failure) —
    /// re-transcribe them. A 7-day window (we don't grind on permanent failures like music forever), the file must
    /// exist. Called from bootstrap with a delay.
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
        if queued > 0 { Log.audio.info("transcription backfill: \(queued) segments queued") }
    }

    /// Privacy reset of in-flight audio: an open VAD segment lives in memory (neither in the DB nor on disk) —
    /// deleteRange does not see it, and otherwise "erase forever" would still leave up to 28s of speech captured
    /// BEFORE the click (the canonical scenario: said a password → hits delete). Plus a cleanup of the transcription queue.
    func discardInFlight(from: Date, to: Date) async {
        await micPipeline.reset()
        await systemPipeline.reset()
        await transcription.purgeQueued(from: from, to: to)
    }

    // MARK: legs

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

    /// System leg: engine.start() is async (SCStream.startCapture), so the whole leg lives inside a Task.
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
                    // a transient start failure (displays reconfiguring) must not be terminal
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

    /// Shared leg consumer: waits for the previous cycle to finish, reset, drain, flushFinal (all on one
    /// control flow — without a flush vs trailing-feed race).
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
            // epoch guard: the tail of an OLD leg after an auto-restart does not overwrite the NEW indicator
            await MainActor.run { if self?.micEpoch == epoch { self?.micRunning = false } }
        }
    }
}

/// Auto-restart budget: at most 5 per minute — anti-loop on a permanent device breakage.
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
