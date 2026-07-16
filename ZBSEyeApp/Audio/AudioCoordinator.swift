import Foundation
import Observation
import GRDB

struct AudioDrainAcknowledgement: Sendable, Equatable {
    let hadActiveAudio: Bool
    let activeLegs: Int
    let transcriptionDrained: Bool
    let systemCaptureOutcome: SystemAudioCaptureTeardownOutcome
}

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
    @ObservationIgnored private var systemTask: Task<
        SystemAudioCaptureTeardownOutcome?,
        Never
    >?

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
    /// Relocation closes the background-backfill admission path too; otherwise
    /// it could enqueue a transcript after the audio legs had acknowledged.
    @ObservationIgnored private var maintenanceSuspended = false
    @ObservationIgnored private var callFrameSink: CallAudioFrameSink?
    @ObservationIgnored private var legacyIntent = CallSourceSelection.none
    @ObservationIgnored private var explicitCallIntent = CallSourceSelection.none
    @ObservationIgnored private var systemStarting = false

    private var desiredSources: CallSourceSelection {
        CallSourceSelection(
            me: legacyIntent.me || explicitCallIntent.me,
            system: legacyIntent.system || explicitCallIntent.system
        )
    }

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
        guard isRunning, mic ? desiredSources.me : desiredSources.system else { return }
        let gen = legGeneration
        if mic { micRunning = false } else { systemRunning = false }
        Log.audio.info("\(mic ? "mic" : "system", privacy: .public) leg died — entering restart loop")
        while isRunning && legGeneration == gen
                && (mic ? desiredSources.me : desiredSources.system)
                && !Task.isCancelled {
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
        legacyIntent = CallSourceSelection(me: mic, system: system)
        guard mic || system else { return }
        maintenanceSuspended = false
        ensurePhysicalSources()
    }

    func stop() {
        legacyIntent = .none
        guard explicitCallIntent.isEmpty else { return }
        guard isRunning else { return }
        let tasks = stopAdmission()
        let transcription = self.transcription
        Task {
            _ = await tasks.systemCapture?.value
            await tasks.mic?.value
            _ = await tasks.system?.value
            await transcription.quiesce()
        }
    }

    /// Stops both audio admission legs and the physical SCK session, then waits
    /// for each VAD `flushFinal` and its audio-row write. Relocation also drains
    /// transcription; normal termination leaves that resumable work to backfill.
    func stopAndDrain(
        waitForTranscription: Bool = true,
        systemCaptureTimeout: Duration? = nil
    ) async -> AudioDrainAcknowledgement {
        maintenanceSuspended = true
        explicitCallIntent = .none
        let wasRunning = isRunning
        let tasks = stopAdmission()
        let hardwareDrain = Task { @MainActor in
            let direct = await tasks.systemCapture?.value ?? .notNeeded
            let lateStart = await tasks.system?.value ?? .notNeeded
            return Self.combineCaptureOutcomes(direct, lateStart)
        }
        let systemCaptureOutcome: SystemAudioCaptureTeardownOutcome
        if let systemCaptureTimeout {
            systemCaptureOutcome = await SystemAudioTeardownDeadline.wait(
                for: hardwareDrain,
                timeout: systemCaptureTimeout
            )
        } else {
            systemCaptureOutcome = await hardwareDrain.value
        }
        await tasks.mic?.value
        if waitForTranscription {
            await transcription.drainAndQuiesce()
        } else {
            // The saved audio row will be picked up by the next-launch
            // backfill. A normal quit must wait for hardware and VAD flush,
            // not potentially minutes of speech recognition backlog.
            await transcription.quiesce()
        }
        return AudioDrainAcknowledgement(
            hadActiveAudio: wasRunning,
            activeLegs: systemCaptureOutcome.isConfirmedStopped ? 0 : 1,
            transcriptionDrained: waitForTranscription,
            systemCaptureOutcome: systemCaptureOutcome
        )
    }

    private func stopAdmission() -> (
        mic: Task<Void, Never>?,
        system: Task<SystemAudioCaptureTeardownOutcome?, Never>?,
        systemCapture: Task<SystemAudioCaptureTeardownOutcome, Never>?
    ) {
        isRunning = false
        legGeneration += 1
        systemStarting = false
        micRunning = false
        systemRunning = false
        micEngine.stop()
        // finish() closes the frame stream so runLeg can flushFinal; the
        // returned task separately owns SCStream/CoreAudio teardown.
        let systemCapture = systemEngine.stop()
        // We do NOT nil out micTask/systemTask: the next start waits for them via previous (serialization of cycles).
        return (micTask, systemTask, systemCapture)
    }

    private nonisolated static func combineCaptureOutcomes(
        _ first: SystemAudioCaptureTeardownOutcome,
        _ second: SystemAudioCaptureTeardownOutcome
    ) -> SystemAudioCaptureTeardownOutcome {
        for outcome in [first, second] {
            if !outcome.isConfirmedStopped { return outcome }
        }
        return first == .stopped || second == .stopped ? .stopped : .notNeeded
    }

    func health() async -> TranscriptionHealth { await transcription.snapshot() }

    func installCallFrameSink(_ sink: CallAudioFrameSink?) {
        callFrameSink = sink
    }

    func beginExplicitCall(_ requested: CallSourceSelection) async -> CallSourceSelection {
        guard !requested.isEmpty, !maintenanceSuspended else { return .none }
        explicitCallIntent = requested
        ensurePhysicalSources()

        if requested.system, !systemRunning, !systemStartFailed {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline,
                  isRunning, desiredSources.system,
                  !systemRunning, !systemStartFailed {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        let actual = CallSourceSelection(
            me: requested.me && micRunning,
            system: requested.system && systemRunning
        )
        if actual.isEmpty {
            explicitCallIntent = .none
            if legacyIntent.isEmpty { stop() }
        }
        return actual
    }

    func endExplicitCall() async {
        explicitCallIntent = .none
        guard isRunning else { return }
        if legacyIntent.isEmpty {
            let tasks = stopAdmission()
            _ = await tasks.systemCapture?.value
            await tasks.mic?.value
            _ = await tasks.system?.value
            await transcription.quiesce()
            maintenanceSuspended = false
            return
        }

        let needsReconcile = (micRunning && !legacyIntent.me)
            || (systemRunning && !legacyIntent.system)
        if needsReconcile {
            let retained = legacyIntent
            let tasks = stopAdmission()
            _ = await tasks.systemCapture?.value
            await tasks.mic?.value
            _ = await tasks.system?.value
            maintenanceSuspended = false
            legacyIntent = retained
            ensurePhysicalSources()
        }
    }

    func acceptedIngressTargets() -> AudioIngressTargets {
        AudioIngressTargets(
            me: micEngine.latestAcceptedIngressSequence,
            system: systemEngine.latestAcceptedIngressSequence
        )
    }

    func drainIngressGaps() -> [AudioIngressGap] {
        micEngine.drainIngressGaps() + systemEngine.drainIngressGaps()
    }

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
            guard !maintenanceSuspended else { break }
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
        if micRunning { return true }
        micStartFailed = false
        let stream: AsyncStream<AudioFrame>
        do { stream = try micEngine.start() }
        catch {
            micStartFailed = true
            Log.audio.error("mic_engine_start_failed")
            return false
        }
        micEpoch += 1
        micRunning = true
        micTask = runLeg(stream: stream, pipeline: micPipeline, previous: micTask, epoch: micEpoch)
        return true
    }

    /// System leg: engine.start() is async (SCStream.startCapture), so the whole leg lives inside a Task.
    private func startSystemLeg() {
        guard !systemRunning, !systemStarting else { return }
        systemStarting = true
        systemStartFailed = false
        let previous = systemTask
        let engine = systemEngine
        let pipeline = systemPipeline
        let generation = legGeneration
        systemEpoch += 1
        let epoch = systemEpoch
        systemTask = Task { @MainActor [weak self] in
            _ = await previous?.value
            let stream: AsyncStream<AudioFrame>
            do {
                stream = try await engine.start()
            } catch let cancellation as SystemAudioCaptureStartCancelled {
                self?.systemStarting = false
                return cancellation.teardownOutcome
            } catch is CancellationError {
                self?.systemStarting = false
                return nil
            } catch {
                Log.audio.error("system_audio_start_failed")
                guard let self, self.isRunning,
                      self.legGeneration == generation else { return nil }
                self.systemStarting = false
                self.systemStartFailed = true
                // a transient start failure (displays reconfiguring) must not be terminal
                Task { @MainActor in await self.restartLeg(mic: false) }
                return nil
            }
            guard let self, self.isRunning,
                  self.legGeneration == generation else {
                self?.systemStarting = false
                return await engine.stopAndDrain()
            }
            self.systemStarting = false
            self.systemRunning = true
            await pipeline.reset()
            for await frame in stream {
                if await self.routeToCallIfOwned(frame) { continue }
                let closed = await pipeline.feed(frame)
                if closed { self.onSegment?() }
            }
            await pipeline.flushFinal()
            if self.systemEpoch == epoch { self.systemRunning = false }
            return nil
        }
    }

    private func ensurePhysicalSources() {
        let union = desiredSources
        guard !union.isEmpty else { return }
        if !isRunning {
            isRunning = true
            legGeneration += 1
        }
        if union.me, !micRunning { _ = startMicLeg() }
        if union.system, !systemRunning { startSystemLeg() }
    }

    /// Shared leg consumer: waits for the previous cycle to finish, reset, drain, flushFinal (all on one
    /// control flow — without a flush vs trailing-feed race).
    private func runLeg(stream: AsyncStream<AudioFrame>, pipeline: AudioPipeline,
                        previous: Task<Void, Never>?, epoch: Int) -> Task<Void, Never> {
        Task { [weak self] in
            await previous?.value
            await pipeline.reset()
            for await frame in stream {
                if await self?.routeToCallIfOwned(frame) == true { continue }
                let closed = await pipeline.feed(frame)
                if closed { Task { @MainActor in self?.onSegment?() } }
            }
            await pipeline.flushFinal()
            // epoch guard: the tail of an OLD leg after an auto-restart does not overwrite the NEW indicator
            await MainActor.run { if self?.micEpoch == epoch { self?.micRunning = false } }
        }
    }

    private func routeToCallIfOwned(_ frame: AudioFrame) async -> Bool {
        guard let callFrameSink else { return false }
        return await callFrameSink(frame)
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
