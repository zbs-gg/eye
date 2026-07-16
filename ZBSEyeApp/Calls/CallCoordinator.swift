import Foundation

enum CallCoordinatorPhase: String, Sendable, Equatable {
    case idle
    case starting
    case recording
    case finalizing
    case pendingTranscription
    case ready
    case readyDegraded
    case failed
}

enum CallSourceState: String, Sendable, Equatable {
    case recording
    case disabled
    case unavailable
    case gap
}

struct CallSourceSelection: Sendable, Equatable {
    let me: Bool
    let system: Bool

    static let none = CallSourceSelection(me: false, system: false)
    var isEmpty: Bool { !me && !system }
}

enum CallStopReason: String, Sendable, Equatable {
    case user
    case privacy
    case maintenance
    case lowDisk = "low_disk"

    var persistenceCode: String? {
        switch self {
        case .user: nil
        case .privacy: "privacy_pause"
        case .maintenance: "maintenance_stop"
        case .lowDisk: "low_disk_stop"
        }
    }
}

enum CallCoordinatorError: LocalizedError, Sendable, Equatable {
    case noRequestedSource
    case noAvailableSource
    case notRecording
    case bookmarkClosed
    case missingIdentity

    var errorDescription: String? {
        switch self {
        case .noRequestedSource: String(localized: "Choose at least one audio source.")
        case .noAvailableSource: String(localized: "No requested audio source could start.")
        case .notRecording: String(localized: "No call is being recorded.")
        case .bookmarkClosed: String(localized: "This call is already ending.")
        case .missingIdentity: String(localized: "The call could not create a durable identity.")
        }
    }
}

struct CallCoordinatorSnapshot: Sendable, Equatable {
    let phase: CallCoordinatorPhase
    let callID: Int64?
    let me: CallSourceState
    let system: CallSourceState
    let bookmarkCount: Int
    let stopReason: CallStopReason?

    static let idle = CallCoordinatorSnapshot(
        phase: .idle,
        callID: nil,
        me: .disabled,
        system: .disabled,
        bookmarkCount: 0,
        stopReason: nil
    )
}

struct CallAudioControl: Sendable {
    let installSink: @Sendable (CallAudioFrameSink?) async -> Void
    let start: @Sendable (CallSourceSelection) async -> CallSourceSelection
    let acceptedTargets: @Sendable () async -> AudioIngressTargets
    let drainGaps: @Sendable () async -> [AudioIngressGap]
    let stop: @Sendable () async -> Void
}

actor CallCoordinator {
    private struct ActiveCall: Sendable {
        let id: Int64
        let startedAtMs: Int64
        let baselines: AudioIngressTargets
        let spool: CallAudioSpoolSession
        var lastBookmarkEndMs: Int64
        var bookmarkCount: Int
    }

    private let repository: CallRepository
    private let mediaRoot: URL
    private let audio: CallAudioControl
    private let now: @Sendable () -> Date
    private let barrierTimeout: Duration
    private var active: ActiveCall?
    private var current = CallCoordinatorSnapshot.idle
    private var commandTail: Task<Void, Never>?

    init(
        repository: CallRepository,
        mediaRoot: URL,
        audio: CallAudioControl,
        now: @escaping @Sendable () -> Date = Date.init,
        barrierTimeout: Duration = .seconds(2)
    ) {
        self.repository = repository
        self.mediaRoot = mediaRoot
        self.audio = audio
        self.now = now
        self.barrierTimeout = barrierTimeout
    }

    func snapshot() -> CallCoordinatorSnapshot { current }

    func start(
        request: CallSourceSelection,
        idempotencyKey: String = UUID().uuidString
    ) async throws -> CallCoordinatorSnapshot {
        try await enqueue { [self] in
            try await performStart(request: request, idempotencyKey: idempotencyKey)
        }
    }

    func bookmark(
        idempotencyKey: String = UUID().uuidString
    ) async throws -> CallBookmarkRow {
        try await enqueue { [self] in
            try await performBookmark(idempotencyKey: idempotencyKey)
        }
    }

    func end(
        idempotencyKey: String = UUID().uuidString,
        reason: CallStopReason
    ) async throws -> CallCoordinatorSnapshot {
        try await enqueue { [self] in
            try await performEnd(idempotencyKey: idempotencyKey, reason: reason)
        }
    }

    private func performStart(
        request: CallSourceSelection,
        idempotencyKey: String
    ) async throws -> CallCoordinatorSnapshot {
        if active != nil { return current }
        guard current.phase != .starting, current.phase != .finalizing else { return current }
        current = .idle
        guard !request.isEmpty else { throw CallCoordinatorError.noRequestedSource }

        current = CallCoordinatorSnapshot(
            phase: .starting,
            callID: nil,
            me: request.me ? .unavailable : .disabled,
            system: request.system ? .unavailable : .disabled,
            bookmarkCount: 0,
            stopReason: nil
        )
        let startedAtMs = milliseconds(now())
        let row = try await repository.createCall(
            startedAtMs: startedAtMs,
            idempotencyKey: idempotencyKey
        )
        guard let callID = row.id else {
            current = .idle
            throw CallCoordinatorError.missingIdentity
        }
        let baselines = await audio.acceptedTargets()
        let spool = try CallAudioSpoolSession(
            root: mediaRoot,
            callID: callID,
            requested: request,
            repository: repository,
            mediaGeneration: row.mediaGeneration
        )
        await audio.installSink { frame in
            await spool.consume(frame)
        }
        let actual = await audio.start(request)
        guard !actual.isEmpty else {
            await audio.installSink(nil)
            await spool.closeAdmission()
            await audio.stop()
            try await repository.discardEmptyCall(id: callID)
            current = .idle
            throw CallCoordinatorError.noAvailableSource
        }
        // Keep requested transiently unavailable legs eligible for the same
        // Call Envelope when the engine's bounded auto-restart recovers them.
        await spool.setOwnedSources(request)

        let partial = (request.me && !actual.me) || (request.system && !actual.system)
        if partial {
            try await repository.markCallDegraded(
                callID: callID,
                reason: "source_unavailable",
                nowMs: milliseconds(now())
            )
        }
        active = ActiveCall(
            id: callID,
            startedAtMs: startedAtMs,
            baselines: baselines,
            spool: spool,
            lastBookmarkEndMs: startedAtMs,
            bookmarkCount: 0
        )
        current = CallCoordinatorSnapshot(
            phase: .recording,
            callID: callID,
            me: sourceState(requested: request.me, actual: actual.me),
            system: sourceState(requested: request.system, actual: actual.system),
            bookmarkCount: 0,
            stopReason: nil
        )
        return current
    }

    private func performBookmark(idempotencyKey: String) async throws -> CallBookmarkRow {
        guard var active else {
            if current.phase == .finalizing || current.phase == .pendingTranscription {
                throw CallCoordinatorError.bookmarkClosed
            }
            throw CallCoordinatorError.notRecording
        }
        guard current.phase == .recording else { throw CallCoordinatorError.bookmarkClosed }

        let acceptedAtMs = milliseconds(now())
        let targets = await audio.acceptedTargets()
        let creation = try await repository.createBookmark(
            callID: active.id,
            idempotencyKey: idempotencyKey,
            acceptedAtMs: acceptedAtMs,
            meIngressTarget: target(targets.me, after: active.baselines.me),
            systemIngressTarget: target(targets.system, after: active.baselines.system),
            logicalStartMs: active.lastBookmarkEndMs,
            logicalEndMs: acceptedAtMs,
            contextStartMs: max(active.startedAtMs, active.lastBookmarkEndMs - 45_000)
        )
        let coverage = await freezeCoverage(
            spool: active.spool,
            targets: targets,
            baselines: active.baselines
        )
        if coverage.degraded {
            try await repository.markCallDegraded(
                callID: active.id,
                reason: "source_gap",
                nowMs: milliseconds(now())
            )
        }
        guard let bookmarkID = creation.bookmark.id,
              let jobID = creation.job.id else {
            throw CallCoordinatorError.missingIdentity
        }
        let bookmark = try await repository.freezeBookmarkCoverage(
            bookmarkID: bookmarkID,
            jobID: jobID,
            meEndSample: coverage.meEndSample,
            systemEndSample: coverage.systemEndSample,
            degraded: coverage.degraded,
            nowMs: milliseconds(now())
        )
        active.lastBookmarkEndMs = acceptedAtMs
        active.bookmarkCount += 1
        self.active = active
        current = CallCoordinatorSnapshot(
            phase: .recording,
            callID: active.id,
            me: sourceStateAfterCoverage(
                current.me,
                endSample: coverage.meEndSample,
                gap: coverage.meGap
            ),
            system: sourceStateAfterCoverage(
                current.system,
                endSample: coverage.systemEndSample,
                gap: coverage.systemGap
            ),
            bookmarkCount: active.bookmarkCount,
            stopReason: nil
        )
        return bookmark
    }

    private func performEnd(
        idempotencyKey: String,
        reason: CallStopReason
    ) async throws -> CallCoordinatorSnapshot {
        guard let active else { return current }
        current = CallCoordinatorSnapshot(
            phase: .finalizing,
            callID: active.id,
            me: current.me,
            system: current.system,
            bookmarkCount: active.bookmarkCount,
            stopReason: reason
        )

        let targets = await audio.acceptedTargets()
        let finalCoverage = await freezeCoverage(
            spool: active.spool,
            targets: targets,
            baselines: active.baselines
        )
        await audio.installSink(nil)
        await active.spool.closeAdmission()
        let finished = try await active.spool.finish()
        await audio.stop()
        _ = try await repository.endCall(
            callID: active.id,
            idempotencyKey: idempotencyKey,
            endedAtMs: milliseconds(now()),
            meEndSample: finished.meEndSample,
            systemEndSample: finished.systemEndSample,
            degradationReason: reason.persistenceCode
                ?? ((finalCoverage.degraded || finished.degraded) ? "source_gap" : nil)
        )
        self.active = nil
        current = CallCoordinatorSnapshot(
            phase: .pendingTranscription,
            callID: active.id,
            me: sourceStateAfterCoverage(
                current.me,
                endSample: finished.meEndSample,
                gap: finished.meGap
            ),
            system: sourceStateAfterCoverage(
                current.system,
                endSample: finished.systemEndSample,
                gap: finished.systemGap
            ),
            bookmarkCount: active.bookmarkCount,
            stopReason: reason
        )
        return current
    }

    private func freezeCoverage(
        spool: CallAudioSpoolSession,
        targets: AudioIngressTargets,
        baselines: AudioIngressTargets
    ) async -> CallSpoolCoverage {
        let initialGaps = await audio.drainGaps()
        await spool.record(gaps: initialGaps)
        let deadline = ContinuousClock.now.advanced(by: barrierTimeout)
        while ContinuousClock.now < deadline,
              !(await spool.hasCoverage(targets: targets, baselines: baselines)) {
            try? await Task.sleep(for: .milliseconds(10))
            await spool.record(gaps: await audio.drainGaps())
        }
        await spool.record(gaps: await audio.drainGaps())
        return (try? await spool.flush(
            targets: targets,
            baselines: baselines
        )) ?? .empty
    }

    private func enqueue<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = commandTail
        let task = Task<T, Error> {
            await previous?.value
            return try await operation()
        }
        commandTail = Task { _ = try? await task.value }
        return try await task.value
    }

    private func target(_ value: Int64?, after baseline: Int64?) -> Int64? {
        guard let value else { return nil }
        guard let baseline else { return value }
        return value > baseline ? value : nil
    }

    private func sourceState(requested: Bool, actual: Bool) -> CallSourceState {
        if actual { return .recording }
        return requested ? .unavailable : .disabled
    }

    private func sourceStateAfterCoverage(
        _ previous: CallSourceState,
        endSample: Int64?,
        gap: Bool
    ) -> CallSourceState {
        if gap { return .gap }
        if endSample != nil { return .recording }
        return previous
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

struct CallSpoolCoverage: Sendable, Equatable {
    let meEndSample: Int64?
    let systemEndSample: Int64?
    let meGap: Bool
    let systemGap: Bool

    static let empty = CallSpoolCoverage(
        meEndSample: nil,
        systemEndSample: nil,
        meGap: false,
        systemGap: false
    )

    var degraded: Bool { meGap || systemGap }
}

private actor CallAudioSpoolSession {
    private let me: CallSpoolLeg?
    private let system: CallSpoolLeg?
    private var owned: CallSourceSelection
    private var accepting = true

    init(
        root: URL,
        callID: Int64,
        requested: CallSourceSelection,
        repository: CallRepository,
        mediaGeneration: Int
    ) throws {
        owned = requested
        me = requested.me ? try CallSpoolLeg(
            root: root,
            callID: callID,
            source: .me,
            repository: repository,
            mediaGeneration: mediaGeneration
        ) : nil
        system = requested.system ? try CallSpoolLeg(
            root: root,
            callID: callID,
            source: .system,
            repository: repository,
            mediaGeneration: mediaGeneration
        ) : nil
    }

    func setOwnedSources(_ selection: CallSourceSelection) { owned = selection }
    func closeAdmission() { accepting = false }

    func consume(_ frame: AudioFrame) async -> Bool {
        guard accepting else { return false }
        switch frame.timing.source {
        case .me:
            guard owned.me, let me else { return false }
            return await me.consume(frame)
        case .system:
            guard owned.system, let system else { return false }
            return await system.consume(frame)
        }
    }

    func record(gaps: [AudioIngressGap]) async {
        for gap in gaps {
            switch gap.source {
            case .me: await me?.record(gap: gap)
            case .system: await system?.record(gap: gap)
            }
        }
    }

    func hasCoverage(targets: AudioIngressTargets, baselines: AudioIngressTargets) async -> Bool {
        let meReady = await me?.covers(targets.me, baseline: baselines.me) ?? true
        let systemReady = await system?.covers(targets.system, baseline: baselines.system) ?? true
        return meReady && systemReady
    }

    func flush(targets: AudioIngressTargets, baselines: AudioIngressTargets) async throws -> CallSpoolCoverage {
        let meState = try await me?.flush(target: targets.me, baseline: baselines.me)
        let systemState = try await system?.flush(target: targets.system, baseline: baselines.system)
        return CallSpoolCoverage(
            meEndSample: meState?.endSample,
            systemEndSample: systemState?.endSample,
            meGap: meState?.gap ?? false,
            systemGap: systemState?.gap ?? false
        )
    }

    func finish() async throws -> CallSpoolCoverage {
        let meState = try await me?.finish()
        let systemState = try await system?.finish()
        return CallSpoolCoverage(
            meEndSample: meState?.endSample,
            systemEndSample: systemState?.endSample,
            meGap: meState?.gap ?? false,
            systemGap: systemState?.gap ?? false
        )
    }
}

private actor CallSpoolLeg {
    private let spool: CallSpool
    private let source: CallAudioSource
    private var resampler: CallPCM16Resampler?
    private var epoch: Int?
    private var lastFrame: AudioFrameTiming?
    private var lastConsumedSequence: Int64?
    private var gaps = BoundedAudioIngressGaps()

    init(
        root: URL,
        callID: Int64,
        source: CallAudioSource,
        repository: CallRepository,
        mediaGeneration: Int
    ) throws {
        self.source = source
        spool = try CallSpool(
            root: root,
            callID: callID,
            source: source,
            policy: CallSpoolPolicy(),
            repository: repository,
            mediaGeneration: mediaGeneration
        )
    }

    func consume(_ frame: AudioFrame) async -> Bool {
        guard frame.timing.source == source else { return false }
        do {
            if epoch != frame.timing.epoch {
                try await finishResamplerTail()
                let previousEnd = await spool.snapshot().watermark?.endSample ?? 0
                try await spool.beginEpoch(
                    CallSpoolEpochDescriptor(
                        epoch: frame.timing.epoch,
                        captureSampleRate: Int(frame.timing.captureSampleRate.rounded()),
                        startSample: previousEnd,
                        startHostTimeNs: frame.timing.normalizedHostTimeNs,
                        startedAtMs: Int64((frame.timing.capturedAt.timeIntervalSince1970 * 1_000).rounded())
                    )
                )
                resampler = CallPCM16Resampler(
                    inputSampleRate: frame.timing.captureSampleRate,
                    outputSampleRate: 16_000
                )
                epoch = frame.timing.epoch
            }
            guard var resampler else { return false }
            let data = resampler.append(frame.samples)
            self.resampler = resampler
            _ = try await spool.appendPCM16LE(
                data,
                sampleCount: data.count / 2,
                ingressSequence: frame.timing.ingressSequence,
                normalizedHostTimeNs: frame.timing.normalizedHostTimeNs
            )
            lastFrame = frame.timing
            lastConsumedSequence = frame.timing.ingressSequence
            return true
        } catch {
            gaps.record(
                AudioIngressGap(
                    source: source,
                    epoch: frame.timing.epoch,
                    firstIngressSequence: frame.timing.ingressSequence,
                    lastIngressSequence: frame.timing.ingressSequence,
                    reason: .sourceUnavailable
                )
            )
            return true
        }
    }

    func record(gap: AudioIngressGap) async {
        guard gap.source == source else { return }
        gaps.record(gap)
        try? await spool.recordGap(gap)
    }

    func covers(_ target: Int64?, baseline: Int64?) -> Bool {
        guard let target else { return true }
        if let baseline, target <= baseline { return true }
        if let lastConsumedSequence, lastConsumedSequence >= target { return true }
        return gaps.covers(source: source, sequence: target)
    }

    func flush(target: Int64?, baseline: Int64?) async throws -> (endSample: Int64?, gap: Bool) {
        let reached = covers(target, baseline: baseline)
        let watermark = try await spool.flushDurableWatermark()
        if let target { gaps.prune(source: source, through: target) }
        return (watermark?.endSample, !reached || gaps.hadAnyGap)
    }

    func finish() async throws -> (endSample: Int64?, gap: Bool) {
        try await finishResamplerTail()
        let snapshot = try await spool.finish()
        return (snapshot.watermark?.endSample, gaps.hadAnyGap)
    }

    private func finishResamplerTail() async throws {
        guard var resampler, let lastFrame else { return }
        let data = resampler.finish()
        self.resampler = nil
        guard !data.isEmpty else { return }
        _ = try await spool.appendPCM16LE(
            data,
            sampleCount: data.count / 2,
            ingressSequence: lastFrame.ingressSequence,
            normalizedHostTimeNs: lastFrame.normalizedHostTimeNs
        )
    }
}
