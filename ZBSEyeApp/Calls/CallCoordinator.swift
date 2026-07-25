import Foundation

enum CallCoordinatorPhase: String, Sendable, Equatable {
    case idle
    case starting
    case recording
    case recoveryTail = "recovery_tail"
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
    case automatic
    case privacy
    case maintenance
    case lowDisk = "low_disk"

    var persistenceCode: String? {
        switch self {
        case .user, .automatic: nil
        case .privacy: "privacy_pause"
        case .maintenance: "maintenance_stop"
        case .lowDisk: "low_disk_stop"
        }
    }

    /// A later, stronger terminal intent must win while one physical teardown is shared.
    /// In particular, an explicit user/privacy stop can never be downgraded to a recoverable
    /// low-disk pause merely because the low-disk request reached the audio engine first.
    func merged(with requested: CallStopReason) -> CallStopReason {
        requested.priority > priority ? requested : self
    }

    private var priority: Int {
        switch self {
        case .lowDisk: 0
        case .automatic: 1
        case .maintenance: 2
        case .privacy: 3
        case .user: 4
        }
    }
}

enum SealedCallEndDisposition: Sendable, Equatable {
    case finish(CallStopReason)
    case rejectAutomatic

    var stopReason: CallStopReason {
        switch self {
        case .finish(let reason): reason
        case .rejectAutomatic: .privacy
        }
    }

    func merged(with requested: SealedCallEndDisposition) -> SealedCallEndDisposition {
        switch (self, requested) {
        case (.rejectAutomatic, _), (_, .rejectAutomatic):
            .rejectAutomatic
        case let (.finish(current), .finish(next)):
            .finish(current.merged(with: next))
        }
    }
}

struct PreparedCallEnd: Sendable, Equatable {
    fileprivate let token: UUID
    let callID: Int64
    let me: CallSourceState
    let system: CallSourceState
    let bookmarkCount: Int

    func finalizingSnapshot(disposition: SealedCallEndDisposition) -> CallCoordinatorSnapshot {
        CallCoordinatorSnapshot(
            phase: .finalizing,
            callID: callID,
            me: me,
            system: system,
            bookmarkCount: bookmarkCount,
            stopReason: disposition.stopReason
        )
    }
}

enum CallCoordinatorError: LocalizedError, Sendable, Equatable {
    case noRequestedSource
    case noAvailableSource
    case notRecording
    case bookmarkClosed
    case missingIdentity
    case evidencePersistenceFailed
    case stalePreparedEnd

    var errorDescription: String? {
        switch self {
        case .noRequestedSource: String(localized: "Choose at least one audio source.")
        case .noAvailableSource: String(localized: "No requested audio source could start.")
        case .notRecording: String(localized: "No call is being recorded.")
        case .bookmarkClosed: String(localized: "This call is already ending.")
        case .missingIdentity: String(localized: "The call could not create a durable identity.")
        case .evidencePersistenceFailed: String(localized: "Call evidence could not be saved safely.")
        case .stalePreparedEnd: String(localized: "This call ending operation is no longer current.")
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
        var softEnd: SoftEnd?
        var evidenceDegradationReason: String?
    }

    private struct SoftEnd: Sendable {
        let boundaryAtMs: Int64
        let coverage: CallSpoolCoverage
        let tail: CallRecoveryTail
    }

    private struct PreparedEndState: Sendable {
        let publicValue: PreparedCallEnd
        let idempotencyKey: String
        let endedAtMs: Int64
        let finished: CallSpoolCoverage
        let evidenceDegradationReason: String?
    }

    private let repository: CallRepository
    private let mediaRoot: URL
    private let audio: CallAudioControl
    private let now: @Sendable () -> Date
    private let barrierTimeout: Duration
    private let beforeSoftEndUndo: @Sendable () async -> Void
    private let afterSourceTransition: @Sendable () async -> Void
    private var active: ActiveCall?
    private var preparedEnd: PreparedEndState?
    private var current = CallCoordinatorSnapshot.idle
    private var commandTail: Task<Void, Never>?

    init(
        repository: CallRepository,
        mediaRoot: URL,
        audio: CallAudioControl,
        now: @escaping @Sendable () -> Date = Date.init,
        barrierTimeout: Duration = .seconds(2),
        beforeSoftEndUndo: @escaping @Sendable () async -> Void = {},
        afterSourceTransition: @escaping @Sendable () async -> Void = {}
    ) {
        self.repository = repository
        self.mediaRoot = mediaRoot
        self.audio = audio
        self.now = now
        self.barrierTimeout = barrierTimeout
        self.beforeSoftEndUndo = beforeSoftEndUndo
        self.afterSourceTransition = afterSourceTransition
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
        guard active != nil || preparedEnd != nil else { return current }
        let prepared: PreparedCallEnd
        do {
            prepared = try await prepareEnd(
                idempotencyKey: idempotencyKey,
                initialReason: reason
            )
        } catch CallCoordinatorError.notRecording {
            return current
        }
        return try await commitPreparedEnd(
            prepared,
            disposition: .finish(reason)
        )
    }

    func prepareEnd(
        idempotencyKey: String = UUID().uuidString,
        initialReason: CallStopReason
    ) async throws -> PreparedCallEnd {
        try await enqueue { [self] in
            try await performPrepareEnd(
                idempotencyKey: idempotencyKey,
                initialReason: initialReason
            )
        }
    }

    func commitPreparedEnd(
        _ prepared: PreparedCallEnd,
        disposition: SealedCallEndDisposition
    ) async throws -> CallCoordinatorSnapshot {
        try await enqueue { [self] in
            try await performCommitPreparedEnd(prepared, disposition: disposition)
        }
    }

    func softEnd() async throws -> CallCoordinatorSnapshot {
        try await enqueue { [self] in try await performSoftEnd() }
    }

    func undoSoftEnd() async throws -> CallCoordinatorSnapshot {
        try await enqueue { [self] in try await performUndoSoftEnd() }
    }

    func commitSoftEnd(
        idempotencyKey: String = UUID().uuidString
    ) async throws -> CallCoordinatorSnapshot {
        try await end(idempotencyKey: idempotencyKey, reason: .automatic)
    }

    /// Stops an automatically-created false positive without creating final transcript work or lifecycle
    /// webhooks. The caller must immediately run physical call erasure; the interrupted row is only a
    /// crash-forward bridge that makes the evidence eligible for safe deletion.
    func rejectAutomatic() async throws -> CallCoordinatorSnapshot {
        guard active != nil || preparedEnd != nil else { return current }
        let prepared: PreparedCallEnd
        do {
            prepared = try await prepareEnd(initialReason: .privacy)
        } catch CallCoordinatorError.notRecording {
            return current
        }
        return try await commitPreparedEnd(prepared, disposition: .rejectAutomatic)
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
            baselines: baselines,
            startedAtMs: startedAtMs,
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
            bookmarkCount: 0,
            softEnd: nil,
            evidenceDegradationReason: partial ? "source_unavailable" : nil
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
        guard preparedEnd == nil, current.phase != .finalizing else {
            throw CallCoordinatorError.bookmarkClosed
        }
        if active?.softEnd != nil {
            _ = try await performUndoSoftEnd()
        }
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
        let coverage = try await freezeCoverage(
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
            if active.evidenceDegradationReason == nil {
                active.evidenceDegradationReason = "source_gap"
            }
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

    private func performSoftEnd() async throws -> CallCoordinatorSnapshot {
        guard var active else { throw CallCoordinatorError.notRecording }
        if active.softEnd != nil { return current }
        guard current.phase == .recording else { throw CallCoordinatorError.bookmarkClosed }

        let targets = await audio.acceptedTargets()
        let coverage = try await freezeCoverage(
            spool: active.spool,
            targets: targets,
            baselines: active.baselines
        )
        let tail = CallRecoveryTail(maxDuration: 15, maximumBytes: 16 * 1_024 * 1_024)
        await audio.installSink { frame in await tail.consume(frame) }
        active.softEnd = SoftEnd(
            boundaryAtMs: milliseconds(now()),
            coverage: coverage,
            tail: tail
        )
        self.active = active
        current = CallCoordinatorSnapshot(
            phase: .recoveryTail,
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
            stopReason: .automatic
        )
        return current
    }

    private func performUndoSoftEnd() async throws -> CallCoordinatorSnapshot {
        guard preparedEnd == nil, current.phase == .recoveryTail else {
            throw CallCoordinatorError.bookmarkClosed
        }
        guard var active else { throw CallCoordinatorError.notRecording }
        guard let softEnd = active.softEnd else { return current }
        await beforeSoftEndUndo()
        let spool = active.spool
        await softEnd.tail.forward { frame in await spool.consume(frame) }
        active.softEnd = nil
        self.active = active
        current = CallCoordinatorSnapshot(
            phase: .recording,
            callID: active.id,
            me: current.me,
            system: current.system,
            bookmarkCount: active.bookmarkCount,
            stopReason: nil
        )
        return current
    }

    private func performPrepareEnd(
        idempotencyKey: String,
        initialReason: CallStopReason
    ) async throws -> PreparedCallEnd {
        if let preparedEnd {
            return preparedEnd.publicValue
        }
        guard let active else { throw CallCoordinatorError.notRecording }
        current = CallCoordinatorSnapshot(
            phase: .finalizing,
            callID: active.id,
            me: current.me,
            system: current.system,
            bookmarkCount: active.bookmarkCount,
            stopReason: initialReason
        )

        let finalCoverage: CallSpoolCoverage
        let finished: CallSpoolCoverage
        let endedAtMs: Int64
        do {
            if let softEnd = active.softEnd {
                await softEnd.tail.discard()
                finalCoverage = softEnd.coverage
                endedAtMs = softEnd.boundaryAtMs
            } else {
                let targets = await audio.acceptedTargets()
                finalCoverage = try await freezeCoverage(
                    spool: active.spool,
                    targets: targets,
                    baselines: active.baselines
                )
                endedAtMs = milliseconds(now())
            }
            await audio.installSink(nil)
            await active.spool.closeAdmission()
            finished = try await active.spool.finish()
            await audio.stop()
        } catch {
            await audio.installSink(nil)
            await active.spool.closeAdmission()
            await audio.stop()
            let failedAtMs = milliseconds(now())
            try? await repository.markCallInterrupted(
                callID: active.id,
                endedAtMs: failedAtMs,
                reason: "evidence_persistence_failed",
                nowMs: failedAtMs
            )
            self.active = nil
            current = CallCoordinatorSnapshot(
                phase: .failed,
                callID: active.id,
                me: current.me == .disabled ? .disabled : .gap,
                system: current.system == .disabled ? .disabled : .gap,
                bookmarkCount: active.bookmarkCount,
                stopReason: initialReason
            )
            throw error
        }
        let evidenceDegradationReason =
            active.evidenceDegradationReason
                ?? ((finalCoverage.degraded || finished.degraded) ? "source_gap" : nil)
        let prepared = PreparedCallEnd(
            token: UUID(),
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
            bookmarkCount: active.bookmarkCount
        )
        preparedEnd = PreparedEndState(
            publicValue: prepared,
            idempotencyKey: idempotencyKey,
            endedAtMs: endedAtMs,
            finished: finished,
            evidenceDegradationReason: evidenceDegradationReason
        )
        current = prepared.finalizingSnapshot(disposition: .finish(initialReason))
        return prepared
    }

    private func performCommitPreparedEnd(
        _ prepared: PreparedCallEnd,
        disposition: SealedCallEndDisposition
    ) async throws -> CallCoordinatorSnapshot {
        guard let preparedState = preparedEnd else { return current }
        guard preparedState.publicValue.token == prepared.token,
              preparedState.publicValue.callID == prepared.callID
        else { throw CallCoordinatorError.stalePreparedEnd }
        current = prepared.finalizingSnapshot(disposition: disposition)
        do {
            switch disposition {
            case .rejectAutomatic:
                let rejectedAtMs = milliseconds(now())
                try await repository.markCallInterrupted(
                    callID: prepared.callID,
                    endedAtMs: rejectedAtMs,
                    reason: "automatic_rejected",
                    nowMs: rejectedAtMs
                )

            case .finish(let reason):
                _ = try await repository.endCall(
                    callID: prepared.callID,
                    idempotencyKey: preparedState.idempotencyKey,
                    endedAtMs: preparedState.endedAtMs,
                    meEndSample: preparedState.finished.meEndSample,
                    systemEndSample: preparedState.finished.systemEndSample,
                    degradationReason:
                        reason.persistenceCode
                            ?? preparedState.evidenceDegradationReason
                )
                // The call.ended row is inserted in the same transaction above. Only now may the
                // dispatcher observe it; no mutable stop-reason reconciliation follows.
                await afterSourceTransition()
            }
        } catch {
            let failedAtMs = milliseconds(now())
            try? await repository.markCallInterrupted(
                callID: prepared.callID,
                endedAtMs: failedAtMs,
                reason: disposition == .rejectAutomatic
                    ? "automatic_reject_incomplete"
                    : "evidence_persistence_failed",
                nowMs: failedAtMs
            )
            self.active = nil
            self.preparedEnd = nil
            current = disposition == .rejectAutomatic
                ? .idle
                : CallCoordinatorSnapshot(
                    phase: .failed,
                    callID: prepared.callID,
                    me: prepared.me == .disabled ? .disabled : .gap,
                    system: prepared.system == .disabled ? .disabled : .gap,
                    bookmarkCount: prepared.bookmarkCount,
                    stopReason: disposition.stopReason
                )
            throw error
        }
        self.active = nil
        self.preparedEnd = nil
        switch disposition {
        case .rejectAutomatic:
            current = .idle
        case .finish(let reason):
            current = CallCoordinatorSnapshot(
                phase: .pendingTranscription,
                callID: prepared.callID,
                me: prepared.me,
                system: prepared.system,
                bookmarkCount: prepared.bookmarkCount,
                stopReason: reason
            )
        }
        return current
    }

    private func freezeCoverage(
        spool: CallAudioSpoolSession,
        targets: AudioIngressTargets,
        baselines: AudioIngressTargets
    ) async throws -> CallSpoolCoverage {
        let initialGaps = await audio.drainGaps()
        try await spool.record(gaps: initialGaps)
        let deadline = ContinuousClock.now.advanced(by: barrierTimeout)
        while ContinuousClock.now < deadline,
              !(await spool.hasCoverage(targets: targets, baselines: baselines)) {
            try? await Task.sleep(for: .milliseconds(10))
            try await spool.record(gaps: await audio.drainGaps())
        }
        try await spool.record(gaps: await audio.drainGaps())
        return try await spool.flush(
            targets: targets,
            baselines: baselines
        )
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

private actor CallRecoveryTail {
    private let maxDuration: TimeInterval
    private let maximumBytes: Int
    private var frames: [AudioFrame] = []
    private var bytes = 0
    private var forwardSink: CallAudioFrameSink?
    private var discarding = false

    init(maxDuration: TimeInterval, maximumBytes: Int) {
        self.maxDuration = maxDuration
        self.maximumBytes = maximumBytes
    }

    func consume(_ frame: AudioFrame) async -> Bool {
        if discarding { return true }
        if let forwardSink { return await forwardSink(frame) }
        frames.append(frame)
        bytes += frame.samples.count * MemoryLayout<Float>.size
        trim()
        return true
    }

    /// Replays every buffered frame before forwarding new arrivals. Actor reentrancy can append to
    /// `frames` while a batch is replaying, so drain in batches and publish the forwarding sink only
    /// after the buffer remains empty.
    func forward(to sink: @escaping CallAudioFrameSink) async {
        guard !discarding else { return }
        while !frames.isEmpty {
            let batch = frames
            frames.removeAll(keepingCapacity: true)
            bytes = 0
            for frame in batch { _ = await sink(frame) }
        }
        forwardSink = sink
    }

    func discard() {
        frames.removeAll(keepingCapacity: false)
        bytes = 0
        forwardSink = nil
        discarding = true
    }

    private func trim() {
        guard let newest = frames.last?.timing.capturedAt else { return }
        while let first = frames.first,
              bytes > maximumBytes
                || newest.timeIntervalSince(first.timing.capturedAt) > maxDuration {
            bytes -= first.samples.count * MemoryLayout<Float>.size
            frames.removeFirst()
        }
    }
}

private actor CallAudioSpoolSession {
    private let me: CallSpoolLeg?
    private let system: CallSpoolLeg?
    private let baselines: AudioIngressTargets
    private let startedAtMs: Int64
    private var owned: CallSourceSelection
    private var accepting = true
    private var boundaryRejected = AudioIngressTargets(me: nil, system: nil)

    init(
        root: URL,
        callID: Int64,
        requested: CallSourceSelection,
        baselines: AudioIngressTargets,
        startedAtMs: Int64,
        repository: CallRepository,
        mediaGeneration: Int
    ) throws {
        owned = requested
        self.baselines = baselines
        self.startedAtMs = startedAtMs
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
        let capturedAtMs = Int64(
            (frame.timing.capturedAt.timeIntervalSince1970 * 1_000).rounded()
        )
        switch frame.timing.source {
        case .me:
            guard owned.me, let me else { return false }
            if let baseline = baselines.me,
               frame.timing.ingressSequence <= baseline { return false }
            if capturedAtMs < startedAtMs {
                boundaryRejected = AudioIngressTargets(
                    me: max(boundaryRejected.me ?? Int64.min, frame.timing.ingressSequence),
                    system: boundaryRejected.system
                )
                return false
            }
            return await me.consume(frame)
        case .system:
            guard owned.system, let system else { return false }
            if let baseline = baselines.system,
               frame.timing.ingressSequence <= baseline { return false }
            if capturedAtMs < startedAtMs {
                boundaryRejected = AudioIngressTargets(
                    me: boundaryRejected.me,
                    system: max(
                        boundaryRejected.system ?? Int64.min,
                        frame.timing.ingressSequence
                    )
                )
                return false
            }
            return await system.consume(frame)
        }
    }

    func record(gaps: [AudioIngressGap]) async throws {
        for rawGap in gaps {
            guard let gap = admittedGap(rawGap) else { continue }
            switch gap.source {
            case .me: try await me?.record(gap: gap)
            case .system: try await system?.record(gap: gap)
            }
        }
    }

    private func admittedGap(_ gap: AudioIngressGap) -> AudioIngressGap? {
        let baseline = switch gap.source {
        case .me: baselines.me
        case .system: baselines.system
        }
        if let baseline, gap.lastIngressSequence <= baseline { return nil }
        if let endMs = gap.endMs, endMs <= startedAtMs { return nil }
        let firstSequence = baseline.map {
            max(gap.firstIngressSequence, $0 == Int64.max ? $0 : $0 + 1)
        } ?? gap.firstIngressSequence
        guard firstSequence <= gap.lastIngressSequence else { return nil }
        guard let originalStart = gap.startMs, let originalEnd = gap.endMs else {
            return AudioIngressGap(
                source: gap.source,
                epoch: gap.epoch,
                firstIngressSequence: firstSequence,
                lastIngressSequence: gap.lastIngressSequence,
                reason: gap.reason,
                startHostTimeNs: firstSequence == gap.firstIngressSequence
                    ? gap.startHostTimeNs : nil,
                endHostTimeNs: gap.endHostTimeNs,
                startMs: nil,
                endMs: nil
            )
        }
        let startMs = max(startedAtMs, originalStart)
        return AudioIngressGap(
            source: gap.source,
            epoch: gap.epoch,
            firstIngressSequence: firstSequence,
            lastIngressSequence: gap.lastIngressSequence,
            reason: gap.reason,
            startHostTimeNs: startMs == originalStart
                && firstSequence == gap.firstIngressSequence ? gap.startHostTimeNs : nil,
            endHostTimeNs: gap.endHostTimeNs,
            startMs: startMs,
            endMs: max(startMs + 1, originalEnd)
        )
    }

    func hasCoverage(targets: AudioIngressTargets, baselines: AudioIngressTargets) async -> Bool {
        let effective = effectiveBaselines(baselines)
        let meReady = await me?.covers(targets.me, baseline: effective.me) ?? true
        let systemReady = await system?.covers(targets.system, baseline: effective.system) ?? true
        return meReady && systemReady
    }

    func flush(targets: AudioIngressTargets, baselines: AudioIngressTargets) async throws -> CallSpoolCoverage {
        let effective = effectiveBaselines(baselines)
        let meState = try await me?.flush(target: targets.me, baseline: effective.me)
        let systemState = try await system?.flush(target: targets.system, baseline: effective.system)
        return CallSpoolCoverage(
            meEndSample: meState?.endSample,
            systemEndSample: systemState?.endSample,
            meGap: meState?.gap ?? false,
            systemGap: systemState?.gap ?? false
        )
    }

    private func effectiveBaselines(_ original: AudioIngressTargets) -> AudioIngressTargets {
        AudioIngressTargets(
            me: [original.me, boundaryRejected.me].compactMap { $0 }.max(),
            system: [original.system, boundaryRejected.system].compactMap { $0 }.max()
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
    private let repository: CallRepository
    private let callID: Int64
    private let mediaGeneration: Int
    private var resampler: CallPCM16Resampler?
    private var captureEpoch: Int?
    private var spoolEpoch = -1
    private var needsNewEpoch = false
    private var lastFrame: AudioFrameTiming?
    private var lastConsumedSequence: Int64?
    private var gaps = BoundedAudioIngressGaps()
    private var unresolvedDurableGaps: [AudioIngressGap] = []
    private var fatalPersistenceFailure = false

    init(
        root: URL,
        callID: Int64,
        source: CallAudioSource,
        repository: CallRepository,
        mediaGeneration: Int
    ) throws {
        self.source = source
        self.repository = repository
        self.callID = callID
        self.mediaGeneration = mediaGeneration
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
            if captureEpoch != frame.timing.epoch || needsNewEpoch {
                if let captureEpoch,
                   captureEpoch != frame.timing.epoch,
                   let lastFrame {
                    try await record(
                        gap: Self.restartGap(
                            from: lastFrame,
                            previousEpoch: captureEpoch,
                            to: frame.timing
                        )
                    )
                }
                try await finishResamplerTail()
                let previousEnd = await spool.snapshot().watermark?.endSample ?? 0
                spoolEpoch += 1
                let epochStartMs = Self.startMs(for: frame.timing)
                try await spool.beginEpoch(
                    CallSpoolEpochDescriptor(
                        epoch: spoolEpoch,
                        captureSampleRate: Int(frame.timing.captureSampleRate.rounded()),
                        startSample: previousEnd,
                        startHostTimeNs: frame.timing.normalizedHostTimeNs,
                        startedAtMs: epochStartMs
                    )
                )
                resampler = CallPCM16Resampler(
                    inputSampleRate: frame.timing.captureSampleRate,
                    outputSampleRate: 16_000
                )
                captureEpoch = frame.timing.epoch
                needsNewEpoch = false
                try await resolveUnboundedGaps(endingAtMs: epochStartMs)
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
            do {
                try await record(
                    gap: Self.gap(for: frame.timing, reason: .sourceUnavailable)
                )
            } catch {
                fatalPersistenceFailure = true
            }
            return true
        }
    }

    func record(gap: AudioIngressGap) async throws {
        guard gap.source == source else { return }
        gaps.record(gap)
        needsNewEpoch = true
        if let startMs = gap.startMs, let endMs = gap.endMs, endMs > startMs {
            try await persistGap(gap, startMs: startMs, endMs: endMs)
        } else {
            unresolvedDurableGaps.append(gap)
        }
        try await spool.recordGap(gap)
    }

    func covers(_ target: Int64?, baseline: Int64?) -> Bool {
        guard let target else { return true }
        if let baseline, target <= baseline { return true }
        if let lastConsumedSequence, lastConsumedSequence >= target { return true }
        return gaps.covers(source: source, sequence: target)
    }

    func flush(target: Int64?, baseline: Int64?) async throws -> (endSample: Int64?, gap: Bool) {
        guard !fatalPersistenceFailure else {
            throw CallCoordinatorError.evidencePersistenceFailed
        }
        let reached = covers(target, baseline: baseline)
        let watermark = try await spool.flushDurableWatermark()
        if let target { gaps.prune(source: source, through: target) }
        return (watermark?.endSample, !reached || gaps.hadAnyGap)
    }

    func finish() async throws -> (endSample: Int64?, gap: Bool) {
        guard !fatalPersistenceFailure else {
            throw CallCoordinatorError.evidencePersistenceFailed
        }
        try await finishResamplerTail()
        let terminal = lastFrame.map(Self.endMs(for:))
            ?? Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        try await resolveUnboundedGaps(endingAtMs: terminal + 1)
        let snapshot = try await spool.finish()
        return (snapshot.watermark?.endSample, gaps.hadAnyGap)
    }

    private func resolveUnboundedGaps(endingAtMs: Int64) async throws {
        guard !unresolvedDurableGaps.isEmpty else { return }
        let inferredStart = lastFrame.map(Self.endMs(for:)) ?? endingAtMs - 1
        let startMs = min(inferredStart, endingAtMs - 1)
        let pending = unresolvedDurableGaps
        for gap in pending {
            try await persistGap(gap, startMs: startMs, endMs: max(startMs + 1, endingAtMs))
        }
        unresolvedDurableGaps.removeAll(keepingCapacity: true)
    }

    private func persistGap(_ gap: AudioIngressGap, startMs: Int64, endMs: Int64) async throws {
        try await repository.recordSourceGap(
            callID: callID,
            mediaGeneration: mediaGeneration,
            source: source,
            startMs: startMs,
            endMs: endMs,
            reason: gap.reason.rawValue,
            nowMs: endMs
        )
    }

    private static func gap(
        for timing: AudioFrameTiming,
        reason: AudioIngressGapReason
    ) -> AudioIngressGap {
        let durationNs = Int64(
            (Double(timing.frameCount) / timing.captureSampleRate * 1_000_000_000).rounded()
        )
        let startMs = Self.startMs(for: timing)
        return AudioIngressGap(
            source: timing.source,
            epoch: timing.epoch,
            firstIngressSequence: timing.ingressSequence,
            lastIngressSequence: timing.ingressSequence,
            reason: reason,
            startHostTimeNs: timing.normalizedHostTimeNs,
            endHostTimeNs: timing.normalizedHostTimeNs + max(1, durationNs),
            startMs: startMs,
            endMs: max(startMs + 1, Self.endMs(for: timing))
        )
    }

    private static func restartGap(
        from previous: AudioFrameTiming,
        previousEpoch: Int,
        to next: AudioFrameTiming
    ) -> AudioIngressGap {
        let startMs = endMs(for: previous)
        let endMs = max(startMs + 1, Self.startMs(for: next))
        let previousDurationNs = Int64(
            (Double(previous.frameCount) / previous.captureSampleRate * 1_000_000_000).rounded()
        )
        let startHost = previous.normalizedHostTimeNs + max(1, previousDurationNs)
        return AudioIngressGap(
            source: next.source,
            epoch: previousEpoch,
            firstIngressSequence: next.ingressSequence,
            lastIngressSequence: next.ingressSequence,
            reason: .sourceRestart,
            startHostTimeNs: startHost,
            endHostTimeNs: max(startHost + 1, next.normalizedHostTimeNs),
            startMs: startMs,
            endMs: endMs
        )
    }

    private static func startMs(for timing: AudioFrameTiming) -> Int64 {
        Int64((timing.capturedAt.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func endMs(for timing: AudioFrameTiming) -> Int64 {
        startMs(for: timing) + max(
            1,
            Int64((Double(timing.frameCount) / timing.captureSampleRate * 1_000).rounded())
        )
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
