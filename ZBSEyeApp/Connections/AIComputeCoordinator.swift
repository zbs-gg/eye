import Foundation

enum SemanticQueryFallbackReason: String, Sendable, Equatable {
    case localGeneration
    case speechTranscription
    case computeSuspended
    case secondaryProcess
}

enum SemanticQueryAdmission: Sendable {
    case granted(AIComputeLease)
    case ftsOnly(SemanticQueryFallbackReason)
}

enum AIComputeLeaseKind: String, Sendable, Equatable {
    case semanticQuery
    case backgroundEmbedding
    case localGeneration
    case speechTranscription
}

enum AIComputeCoordinatorError: Error, Sendable, Equatable {
    case generationAlreadyPending
    case speechAlreadyPending
    case speechHasPriority
    case suspended
}

struct AIComputeVectorBackfillHooks: Sendable {
    let suspendAndDrain: @Sendable () async -> Void
    let resume: @Sendable () async -> Void

    static let noop = AIComputeVectorBackfillHooks(
        suspendAndDrain: {},
        resume: {}
    )
}

struct AIComputeCoordinatorSnapshot: Sendable, Equatable {
    let activeSemanticQueries: Int
    let activeBackgroundEmbeddings: Int
    let generationPending: Bool
    let generationActive: Bool
    let speechPending: Bool
    let speechActive: Bool
    let externallySuspended: Bool
}

/// An idempotently releasable process-wide compute lease. A value may be
/// copied across tasks; the coordinator owns truth and ignores duplicate
/// releases by lease identity.
struct AIComputeLease: Sendable {
    let id: UUID
    let kind: AIComputeLeaseKind
    fileprivate let coordinator: AIComputeCoordinator

    func release() async {
        await coordinator.release(id: id, kind: kind)
    }
}

/// Coordinates the two in-process model stacks without ever involving the
/// capture or audio pipelines:
///
/// - existing query/background e5 work drains before MLX generation starts;
/// - a pending or active MLX generation makes new semantic queries fall back
///   to FTS immediately rather than blocking the user;
/// - background backfill is suspended and drained through retained hooks;
/// - an external maintenance suspension drains every compute lease.
actor AIComputeCoordinator {
    private enum DrainTarget {
        case e5
        case speechPrerequisites
        case all
    }

    private struct DrainWaiter {
        let target: DrainTarget
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let vectorBackfill: AIComputeVectorBackfillHooks
    private var semanticQueries: Set<UUID> = []
    private var backgroundEmbeddings: Set<UUID> = []
    private var activeGeneration: UUID?
    private var generationPending = false
    private var activeSpeech: UUID?
    private var speechPending = false
    private var externallySuspended = false
    private var drainWaiters: [UUID: DrainWaiter] = [:]

    init(vectorBackfill: AIComputeVectorBackfillHooks) {
        self.vectorBackfill = vectorBackfill
    }

    func acquireSemanticQuery() -> SemanticQueryAdmission {
        if externallySuspended {
            return .ftsOnly(.computeSuspended)
        }
        if speechPending || activeSpeech != nil {
            return .ftsOnly(.speechTranscription)
        }
        if generationPending || activeGeneration != nil {
            return .ftsOnly(.localGeneration)
        }
        let id = UUID()
        semanticQueries.insert(id)
        return .granted(
            AIComputeLease(id: id, kind: .semanticQuery, coordinator: self)
        )
    }

    /// Background indexing is opportunistic. A nil admission tells the caller
    /// to retain its durable queue and retry after resume.
    func acquireBackgroundEmbedding() -> AIComputeLease? {
        guard !externallySuspended,
              !generationPending,
              activeGeneration == nil,
              !speechPending,
              activeSpeech == nil else { return nil }
        let id = UUID()
        backgroundEmbeddings.insert(id)
        return AIComputeLease(
            id: id,
            kind: .backgroundEmbedding,
            coordinator: self
        )
    }

    func acquireGeneration() async throws -> AIComputeLease {
        try Task.checkCancellation()
        guard !externallySuspended else {
            throw AIComputeCoordinatorError.suspended
        }
        guard !generationPending, activeGeneration == nil else {
            throw AIComputeCoordinatorError.generationAlreadyPending
        }
        guard !speechPending, activeSpeech == nil else {
            throw AIComputeCoordinatorError.speechHasPriority
        }

        generationPending = true
        await vectorBackfill.suspendAndDrain()
        do {
            try Task.checkCancellation()
            try await waitUntilDrained(.e5)
            try Task.checkCancellation()
            guard !externallySuspended else {
                throw AIComputeCoordinatorError.suspended
            }
            let id = UUID()
            activeGeneration = id
            generationPending = false
            wakeSatisfiedDrainWaiters()
            return AIComputeLease(
                id: id,
                kind: .localGeneration,
                coordinator: self
            )
        } catch {
            generationPending = false
            wakeSatisfiedDrainWaiters()
            if !externallySuspended, !speechPending, activeSpeech == nil {
                await vectorBackfill.resume()
            }
            throw error
        }
    }

    /// Speech waits for current semantic/generation work, then owns compute
    /// exclusively. Capture and audio spooling never acquire this lease.
    func acquireSpeech() async throws -> AIComputeLease {
        try Task.checkCancellation()
        guard !externallySuspended else {
            throw AIComputeCoordinatorError.suspended
        }
        guard !speechPending, activeSpeech == nil else {
            throw AIComputeCoordinatorError.speechAlreadyPending
        }

        speechPending = true
        await vectorBackfill.suspendAndDrain()
        do {
            try Task.checkCancellation()
            try await waitUntilDrained(.speechPrerequisites)
            try Task.checkCancellation()
            guard !externallySuspended else {
                throw AIComputeCoordinatorError.suspended
            }
            let id = UUID()
            activeSpeech = id
            speechPending = false
            wakeSatisfiedDrainWaiters()
            return AIComputeLease(
                id: id,
                kind: .speechTranscription,
                coordinator: self
            )
        } catch {
            speechPending = false
            wakeSatisfiedDrainWaiters()
            if !externallySuspended, !generationPending, activeGeneration == nil {
                await vectorBackfill.resume()
            }
            throw error
        }
    }

    /// Used by storage relocation and app shutdown. It does not cancel a
    /// generation by itself: the runtime drainer owns cancellation and this
    /// method provides the acknowledgement that no model work remains.
    func suspendAndDrain() async throws {
        externallySuspended = true
        await vectorBackfill.suspendAndDrain()
        try Task.checkCancellation()
        try await waitUntilDrained(.all)
        try Task.checkCancellation()
    }

    func resume() async {
        guard externallySuspended else { return }
        externallySuspended = false
        if !generationPending, activeGeneration == nil,
           !speechPending, activeSpeech == nil {
            await vectorBackfill.resume()
        }
    }

    func snapshot() -> AIComputeCoordinatorSnapshot {
        AIComputeCoordinatorSnapshot(
            activeSemanticQueries: semanticQueries.count,
            activeBackgroundEmbeddings: backgroundEmbeddings.count,
            generationPending: generationPending,
            generationActive: activeGeneration != nil,
            speechPending: speechPending,
            speechActive: activeSpeech != nil,
            externallySuspended: externallySuspended
        )
    }

    fileprivate func release(id: UUID, kind: AIComputeLeaseKind) async {
        var shouldResumeBackfill = false
        switch kind {
        case .semanticQuery:
            semanticQueries.remove(id)
        case .backgroundEmbedding:
            backgroundEmbeddings.remove(id)
        case .localGeneration:
            guard activeGeneration == id else { return }
            activeGeneration = nil
            shouldResumeBackfill = !externallySuspended
                && !generationPending
                && !speechPending
                && activeSpeech == nil
        case .speechTranscription:
            guard activeSpeech == id else { return }
            activeSpeech = nil
            shouldResumeBackfill = !externallySuspended
                && !generationPending
                && activeGeneration == nil
                && !speechPending
        }
        wakeSatisfiedDrainWaiters()
        if shouldResumeBackfill {
            await vectorBackfill.resume()
        }
    }

    private func waitUntilDrained(_ target: DrainTarget) async throws {
        if isDrained(target) { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if isDrained(target) {
                    continuation.resume()
                } else {
                    drainWaiters[waiterID] = DrainWaiter(
                        target: target,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelDrainWaiter(waiterID) }
        }
    }

    private func cancelDrainWaiter(_ id: UUID) {
        drainWaiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }

    private func isDrained(_ target: DrainTarget) -> Bool {
        let e5Drained = semanticQueries.isEmpty && backgroundEmbeddings.isEmpty
        switch target {
        case .e5:
            return e5Drained
        case .speechPrerequisites:
            return e5Drained && activeGeneration == nil && !generationPending
        case .all:
            return e5Drained
                && activeGeneration == nil
                && !generationPending
                && activeSpeech == nil
                && !speechPending
        }
    }

    private func wakeSatisfiedDrainWaiters() {
        let ready = drainWaiters.compactMap { id, waiter in
            isDrained(waiter.target) ? id : nil
        }
        for id in ready {
            drainWaiters.removeValue(forKey: id)?.continuation.resume()
        }
    }
}
