import CryptoKit
import Foundation

protocol LLMSelectionSnapshotProviding: Sendable {
    /// Returns nil when no exact active pair is authorized for this consumer.
    func currentSnapshot(for consumer: AIConsumer) async -> ProviderSelectionSnapshot?
}

struct LLMAdapterRegistration: Sendable {
    let providerID: String
    let executedLocally: Bool
    let adapter: any LLMAdapter
}

protocol LLMAdapterRegistering: Sendable {
    /// Exact provider lookup. The router never asks for, or selects, a fallback.
    func registration(for providerID: String) async -> LLMAdapterRegistration?
}

private actor LLMRouterShutdownResult {
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func resolve(_ value: Bool) {
        guard result == nil else { return }
        result = value
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: value) }
    }

    func value() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

enum LLMRouterError: Error, Sendable, Equatable {
    case noAuthorizedSelection
    case invalidPriority
    case invalidRequest
    case adapterUnavailable
    case adapterFailed
    case superseded
    case queueFull
    case selectionChanged
    case provenanceMismatch
    case timedOut
    case callerCancelled
    case preempted
    case routerUnhealthy
    case routerShuttingDown
}

enum LLMRouterUnhealthyReason: String, Sendable, Equatable {
    case drainAcknowledgementTimedOut
}

enum LLMRouterHealth: Sendable, Equatable {
    case healthy
    case unhealthy(LLMRouterUnhealthyReason)
}

struct LLMRouterJobDiagnostic: Sendable, Equatable {
    let requestID: UUID
    let consumer: AIConsumer
    let priority: LLMRequestPriority
    let providerID: String
    let modelID: String
    let selectionRevision: SelectionRevision
    let authorizationEpoch: AuthorizationEpoch
}

/// Prompt-free, immutable value snapshot. Callers cannot mutate router state or
/// recover request content through diagnostics.
struct LLMRouterDiagnostics: Sendable, Equatable {
    let health: LLMRouterHealth
    let active: LLMRouterJobDiagnostic?
    let queued: [LLMRouterJobDiagnostic]
    let labelBacklogCount: Int
    let isWaitingForDrain: Bool
    let ownedTimeoutCount: Int
}

/// The shared generation control plane. Exactly one adapter task may exist at
/// a time. Selection and authorization are captured before enqueue and checked
/// again at dispatch and after generation, making stale results unusable.
actor LLMRouter {
    private struct Waiter {
        let continuation: CheckedContinuation<LLMResponse, any Error>
    }

    private struct WorkItem {
        let internalID: UUID
        let sequence: UInt64
        let request: LLMRequest
        let snapshot: ProviderSelectionSnapshot
        let contentFingerprint: String
        var waiters: [UUID: Waiter]
    }

    private enum ExecutionOutcome: Sendable {
        case success(LLMResponse)
        case failure(LLMRouterError)
    }

    private struct ActiveGeneration {
        var item: WorkItem
        let task: Task<ExecutionOutcome, Never>
        var cancellationReason: LLMRouterError?
        var hasDrainWatchdog: Bool
    }

    private let snapshotProvider: any LLMSelectionSnapshotProviding
    private let adapterRegistry: any LLMAdapterRegistering
    private let labelBacklogLimit: Int
    private let drainAcknowledgementTimeout: Duration

    private var health: LLMRouterHealth = .healthy
    private var active: ActiveGeneration?
    private var interactivePending: [AIConsumer: WorkItem] = [:]
    private var scheduledSummaryPending: WorkItem?
    private var labelPending: [WorkItem] = []
    private var nextSequence: UInt64 = 0
    private var isScheduling = false
    private var shutdownRequested = false
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    init(
        snapshotProvider: any LLMSelectionSnapshotProviding,
        adapterRegistry: any LLMAdapterRegistering,
        labelBacklogLimit: Int = 16,
        drainAcknowledgementTimeout: Duration = .seconds(1)
    ) {
        self.snapshotProvider = snapshotProvider
        self.adapterRegistry = adapterRegistry
        self.labelBacklogLimit = max(1, labelBacklogLimit)
        if drainAcknowledgementTimeout <= .zero {
            self.drainAcknowledgementTimeout = .milliseconds(1)
        } else {
            self.drainAcknowledgementTimeout = min(
                drainAcknowledgementTimeout,
                .seconds(1)
            )
        }
    }

    nonisolated static func expectedPriority(
        for consumer: AIConsumer
    ) -> LLMRequestPriority {
        switch consumer {
        case .ask:
            return .ask
        case .dailyInsights, .manualSummary:
            return .explicitInsight
        case .scheduledSummary:
            return .scheduledSummary
        case .generatedLabels:
            return .generatedLabels
        }
    }

    func generate(_ request: LLMRequest) async throws -> LLMResponse {
        try validate(request)
        guard let snapshot = await snapshotProvider.currentSnapshot(for: request.consumer) else {
            throw LLMRouterError.noAuthorizedSelection
        }
        return try await enqueueAndWait(request, snapshot: snapshot)
    }

    /// A consumer that budgets against a concrete provider/model snapshot can
    /// require that exact snapshot at enqueue. This prevents a selection switch
    /// between budgeting and router admission from allocating against a
    /// different model's context window.
    func generate(
        _ request: LLMRequest,
        expectedSelection: ProviderSelectionSnapshot
    ) async throws -> LLMResponse {
        try validate(request)
        guard let current = await snapshotProvider.currentSnapshot(for: request.consumer) else {
            throw LLMRouterError.noAuthorizedSelection
        }
        guard current == expectedSelection else {
            throw LLMRouterError.selectionChanged
        }
        return try await enqueueAndWait(request, snapshot: expectedSelection)
    }

    private func validate(_ request: LLMRequest) throws {
        guard request.priority == Self.expectedPriority(for: request.consumer) else {
            throw LLMRouterError.invalidPriority
        }
        guard request.maximumOutputTokens > 0, request.timeout > .zero else {
            throw LLMRouterError.invalidRequest
        }
        guard !shutdownRequested else { throw LLMRouterError.routerShuttingDown }
        guard isHealthy else { throw LLMRouterError.routerUnhealthy }
    }

    private func enqueueAndWait(
        _ request: LLMRequest,
        snapshot: ProviderSelectionSnapshot
    ) async throws -> LLMResponse {
        guard !Task.isCancelled else { throw LLMRouterError.callerCancelled }
        guard !shutdownRequested else { throw LLMRouterError.routerShuttingDown }
        guard isHealthy else { throw LLMRouterError.routerUnhealthy }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: LLMRouterError.callerCancelled)
                    return
                }
                enqueue(
                    request: request,
                    snapshot: snapshot,
                    waiterID: waiterID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    /// Call this after a provider/model switch, disconnect, or consent revoke.
    /// Dispatch/result checks remain fail-closed even if a caller misses the
    /// notification; this method makes queued and active cancellation prompt.
    func selectionOrAuthorizationDidChange() async {
        guard !shutdownRequested else { return }
        if let currentActive = active {
            let current = await snapshotProvider.currentSnapshot(
                for: currentActive.item.request.consumer
            )
            if active?.item.internalID == currentActive.item.internalID,
               current != currentActive.item.snapshot {
                requestActiveDrain(reason: .selectionChanged)
            }
        }

        let probes = pendingItems().map {
            ($0.internalID, $0.request.consumer, $0.snapshot)
        }
        for (internalID, consumer, captured) in probes {
            let current = await snapshotProvider.currentSnapshot(for: consumer)
            guard current != captured,
                  let stale = removePending(internalID: internalID) else { continue }
            resolve(stale, with: .failure(.selectionChanged))
        }
        requestSchedulingIfNeeded()
    }

    /// Permanently closes admission, resolves queued callers, cancels the
    /// active adapter, and waits only up to `timeout` for its cleanup
    /// acknowledgement. Process-backed adapters use task cancellation to reap
    /// their dedicated process groups before app termination continues.
    @discardableResult
    func shutdown(timeout: Duration) async -> Bool {
        shutdownRequested = true

        let queued = removeAllPending()
        for item in queued {
            resolve(item, with: .failure(.routerShuttingDown))
        }
        cancelAllTimeouts()
        isScheduling = false

        guard var current = active else { return true }
        current.cancellationReason = .routerShuttingDown
        let waiters = current.item.waiters
        current.item.waiters.removeAll()
        active = current
        resolve(waiters, with: .failure(.routerShuttingDown))

        let internalID = current.item.internalID
        let task = current.task
        task.cancel()
        let completed = await Self.waitForCompletion(of: task, timeout: timeout)
        if completed {
            let outcome = await task.value
            activeFinished(internalID: internalID, outcome: outcome)
        }
        return completed
    }

    private nonisolated static func waitForCompletion(
        of task: Task<ExecutionOutcome, Never>,
        timeout: Duration
    ) async -> Bool {
        let result = LLMRouterShutdownResult()
        let completion = Task {
            _ = await task.value
            await result.resolve(true)
        }
        let deadline = Task {
            guard timeout > .zero else {
                await result.resolve(false)
                return
            }
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await result.resolve(false)
        }
        let completed = await result.value()
        deadline.cancel()
        completion.cancel()
        return completed
    }

    func diagnostics() -> LLMRouterDiagnostics {
        let queuedItems = pendingItems().sorted(by: Self.higherPrecedence)
        return LLMRouterDiagnostics(
            health: health,
            active: active.map { diagnostic(for: $0.item) },
            queued: queuedItems.map(diagnostic),
            labelBacklogCount: labelPending.count,
            isWaitingForDrain: active?.cancellationReason != nil,
            ownedTimeoutCount: timeoutTasks.count
        )
    }

    // MARK: enqueue and coalescing

    private func enqueue(
        request: LLMRequest,
        snapshot: ProviderSelectionSnapshot,
        waiterID: UUID,
        continuation: CheckedContinuation<LLMResponse, any Error>
    ) {
        guard !shutdownRequested else {
            continuation.resume(throwing: LLMRouterError.routerShuttingDown)
            return
        }
        guard isHealthy else {
            continuation.resume(throwing: LLMRouterError.routerUnhealthy)
            return
        }

        let fingerprint = Self.contentFingerprint(for: request)
        let waiter = Waiter(continuation: continuation)

        if attachToActiveIfEquivalent(
            request: request,
            snapshot: snapshot,
            fingerprint: fingerprint,
            waiterID: waiterID,
            waiter: waiter
        ) {
            return
        }

        nextSequence &+= 1
        let item = WorkItem(
            internalID: UUID(),
            sequence: nextSequence,
            request: request,
            snapshot: snapshot,
            contentFingerprint: fingerprint,
            waiters: [waiterID: waiter]
        )

        switch request.consumer {
        case .ask, .dailyInsights, .manualSummary:
            if var existing = interactivePending[request.consumer],
               Self.isEquivalent(existing, to: request, snapshot: snapshot, fingerprint: fingerprint) {
                existing.waiters[waiterID] = waiter
                interactivePending[request.consumer] = existing
                return
            }
            if let superseded = interactivePending.updateValue(item, forKey: request.consumer) {
                resolve(superseded, with: .failure(.superseded))
            }

        case .scheduledSummary:
            if var existing = scheduledSummaryPending,
               Self.isEquivalent(existing, to: request, snapshot: snapshot, fingerprint: fingerprint) {
                existing.waiters[waiterID] = waiter
                scheduledSummaryPending = existing
                return
            }
            if let superseded = scheduledSummaryPending {
                resolve(superseded, with: .failure(.superseded))
            }
            scheduledSummaryPending = item

        case .generatedLabels:
            if let index = labelPending.firstIndex(where: {
                Self.isEquivalent($0, to: request, snapshot: snapshot, fingerprint: fingerprint)
            }) {
                labelPending[index].waiters[waiterID] = waiter
                return
            }
            guard labelPending.count < labelBacklogLimit else {
                continuation.resume(throwing: LLMRouterError.queueFull)
                return
            }
            labelPending.append(item)
        }

        armTimeout(for: item)
        preemptIfNeeded(for: request.priority)
        requestSchedulingIfNeeded()
    }

    private func attachToActiveIfEquivalent(
        request: LLMRequest,
        snapshot: ProviderSelectionSnapshot,
        fingerprint: String,
        waiterID: UUID,
        waiter: Waiter
    ) -> Bool {
        guard var current = active,
              current.cancellationReason == nil,
              Self.isEquivalent(
                  current.item,
                  to: request,
                  snapshot: snapshot,
                  fingerprint: fingerprint
              ) else { return false }
        current.item.waiters[waiterID] = waiter
        active = current
        return true
    }

    private nonisolated static func isEquivalent(
        _ item: WorkItem,
        to request: LLMRequest,
        snapshot: ProviderSelectionSnapshot,
        fingerprint: String
    ) -> Bool {
        item.snapshot == snapshot
            && item.contentFingerprint == fingerprint
            && hasEquivalentPayload(item.request, request)
    }

    private nonisolated static func hasEquivalentPayload(
        _ lhs: LLMRequest,
        _ rhs: LLMRequest
    ) -> Bool {
        lhs.consumer == rhs.consumer
            && lhs.priority == rhs.priority
            && lhs.systemPrompt == rhs.systemPrompt
            && lhs.userPrompt == rhs.userPrompt
            && lhs.maximumOutputTokens == rhs.maximumOutputTokens
            && lhs.timeout == rhs.timeout
            && lhs.localOutputContract == rhs.localOutputContract
    }

    private func armTimeout(for item: WorkItem) {
        let internalID = item.internalID
        let timeout = item.request.timeout
        timeoutTasks[internalID] = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.timeoutFired(internalID: internalID)
        }
    }

    private func timeoutFired(internalID: UUID) {
        guard timeoutTasks.removeValue(forKey: internalID) != nil else { return }
        itemTimedOut(internalID: internalID)
    }

    private func cancelTimeout(for internalID: UUID) {
        timeoutTasks.removeValue(forKey: internalID)?.cancel()
    }

    private func cancelAllTimeouts() {
        let tasks = Array(timeoutTasks.values)
        timeoutTasks.removeAll(keepingCapacity: false)
        for task in tasks { task.cancel() }
    }

    // MARK: scheduler

    private func requestSchedulingIfNeeded() {
        guard isAcceptingWork,
              active == nil,
              !isScheduling,
              !pendingItems().isEmpty else { return }
        isScheduling = true
        Task { await self.runScheduler() }
    }

    private func runScheduler() async {
        defer {
            isScheduling = false
            if active == nil { requestSchedulingIfNeeded() }
        }

        while isAcceptingWork, active == nil {
            guard let candidate = highestPending() else { return }

            let current = await snapshotProvider.currentSnapshot(
                for: candidate.request.consumer
            )
            guard isAcceptingWork, active == nil else { return }
            guard pendingItem(internalID: candidate.internalID) != nil else { continue }
            guard highestPending()?.internalID == candidate.internalID else { continue }
            guard current == candidate.snapshot else {
                if let stale = removePending(internalID: candidate.internalID) {
                    resolve(stale, with: .failure(.selectionChanged))
                }
                continue
            }

            guard let registration = await adapterRegistry.registration(
                for: candidate.snapshot.providerID
            ), registration.providerID == candidate.snapshot.providerID else {
                if let unavailable = removePending(internalID: candidate.internalID) {
                    resolve(unavailable, with: .failure(.adapterUnavailable))
                }
                continue
            }

            let revalidated = await snapshotProvider.currentSnapshot(
                for: candidate.request.consumer
            )
            guard isAcceptingWork, active == nil else { return }
            guard pendingItem(internalID: candidate.internalID) != nil else { continue }
            guard highestPending()?.internalID == candidate.internalID else { continue }
            guard revalidated == candidate.snapshot else {
                if let stale = removePending(internalID: candidate.internalID) {
                    resolve(stale, with: .failure(.selectionChanged))
                }
                continue
            }

            guard let ready = removePending(internalID: candidate.internalID) else { continue }
            start(ready, registration: registration)
            return
        }
    }

    private func start(
        _ item: WorkItem,
        registration: LLMAdapterRegistration
    ) {
        let snapshotProvider = self.snapshotProvider
        let request = item.request
        let snapshot = item.snapshot
        let task = Task {
            await Self.execute(
                request: request,
                snapshot: snapshot,
                registration: registration,
                snapshotProvider: snapshotProvider
            )
        }
        active = ActiveGeneration(
            item: item,
            task: task,
            cancellationReason: nil,
            hasDrainWatchdog: false
        )
        let internalID = item.internalID
        Task {
            let outcome = await task.value
            activeFinished(internalID: internalID, outcome: outcome)
        }
    }

    private nonisolated static func execute(
        request: LLMRequest,
        snapshot: ProviderSelectionSnapshot,
        registration: LLMAdapterRegistration,
        snapshotProvider: any LLMSelectionSnapshotProviding
    ) async -> ExecutionOutcome {
        do {
            let response = try await registration.adapter.generate(
                request: request,
                selection: snapshot
            )
            try Task.checkCancellation()

            guard response.provenance.providerID == snapshot.providerID,
                  response.provenance.modelID == snapshot.modelID,
                  response.provenance.executedLocally == registration.executedLocally else {
                return .failure(.provenanceMismatch)
            }

            let current = await snapshotProvider.currentSnapshot(
                for: request.consumer
            )
            try Task.checkCancellation()
            guard current == snapshot else {
                return .failure(.selectionChanged)
            }
            return .success(response)
        } catch is CancellationError {
            return .failure(.adapterFailed)
        } catch {
            return .failure(.adapterFailed)
        }
    }

    private func activeFinished(
        internalID: UUID,
        outcome: ExecutionOutcome
    ) {
        guard let finished = active,
              finished.item.internalID == internalID else { return }
        active = nil

        if let cancellationReason = finished.cancellationReason {
            resolve(finished.item, with: .failure(cancellationReason))
        } else {
            resolve(finished.item, with: outcome)
        }
        requestSchedulingIfNeeded()
    }

    // MARK: cancellation, timeout, and drain acknowledgement

    private func preemptIfNeeded(for newPriority: LLMRequestPriority) {
        guard let current = active,
              current.cancellationReason == nil,
              newPriority > current.item.request.priority else { return }
        requestActiveDrain(reason: .preempted)
    }

    private func requestActiveDrain(reason: LLMRouterError) {
        guard var current = active else { return }
        if current.cancellationReason == nil {
            current.cancellationReason = reason
        }
        current.task.cancel()

        if !current.hasDrainWatchdog {
            current.hasDrainWatchdog = true
            let internalID = current.item.internalID
            let timeout = drainAcknowledgementTimeout
            Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                drainTimedOut(internalID: internalID)
            }
        }
        active = current
    }

    private func drainTimedOut(internalID: UUID) {
        guard var current = active,
              current.item.internalID == internalID,
              current.cancellationReason != nil else { return }

        cancelTimeout(for: current.item.internalID)
        health = .unhealthy(.drainAcknowledgementTimedOut)
        let activeWaiters = current.item.waiters
        current.item.waiters.removeAll()
        active = current
        resolve(activeWaiters, with: .failure(.routerUnhealthy))

        let queued = removeAllPending()
        for item in queued {
            resolve(item, with: .failure(.routerUnhealthy))
        }
        isScheduling = false
    }

    private func cancel(waiterID: UUID) {
        if var current = active,
           let waiter = current.item.waiters.removeValue(forKey: waiterID) {
            active = current
            waiter.continuation.resume(throwing: LLMRouterError.callerCancelled)
            if current.item.waiters.isEmpty {
                cancelTimeout(for: current.item.internalID)
                requestActiveDrain(reason: .callerCancelled)
            }
            return
        }

        if let waiter = removePendingWaiter(waiterID: waiterID) {
            waiter.continuation.resume(throwing: LLMRouterError.callerCancelled)
            requestSchedulingIfNeeded()
        }
    }

    private func itemTimedOut(internalID: UUID) {
        if var current = active, current.item.internalID == internalID {
            let waiters = current.item.waiters
            current.item.waiters.removeAll()
            active = current
            resolve(waiters, with: .failure(.timedOut))
            requestActiveDrain(reason: .timedOut)
            return
        }

        if let timedOut = removePending(internalID: internalID) {
            resolve(timedOut, with: .failure(.timedOut))
            requestSchedulingIfNeeded()
        }
    }

    // MARK: queue storage

    private func highestPending() -> WorkItem? {
        pendingItems().max { lhs, rhs in
            if lhs.request.priority != rhs.request.priority {
                return lhs.request.priority < rhs.request.priority
            }
            return lhs.sequence > rhs.sequence
        }
    }

    private nonisolated static func higherPrecedence(
        _ lhs: WorkItem,
        _ rhs: WorkItem
    ) -> Bool {
        if lhs.request.priority != rhs.request.priority {
            return lhs.request.priority > rhs.request.priority
        }
        return lhs.sequence < rhs.sequence
    }

    private func pendingItems() -> [WorkItem] {
        Array(interactivePending.values)
            + [scheduledSummaryPending].compactMap { $0 }
            + labelPending
    }

    private func pendingItem(internalID: UUID) -> WorkItem? {
        pendingItems().first { $0.internalID == internalID }
    }

    private func removePending(internalID: UUID) -> WorkItem? {
        for consumer in Array(interactivePending.keys) {
            if interactivePending[consumer]?.internalID == internalID {
                return interactivePending.removeValue(forKey: consumer)
            }
        }
        if scheduledSummaryPending?.internalID == internalID {
            defer { scheduledSummaryPending = nil }
            return scheduledSummaryPending
        }
        if let index = labelPending.firstIndex(where: { $0.internalID == internalID }) {
            return labelPending.remove(at: index)
        }
        return nil
    }

    private func removePendingWaiter(waiterID: UUID) -> Waiter? {
        for consumer in Array(interactivePending.keys) {
            guard var item = interactivePending[consumer],
                  let waiter = item.waiters.removeValue(forKey: waiterID) else { continue }
            if item.waiters.isEmpty {
                interactivePending.removeValue(forKey: consumer)
                cancelTimeout(for: item.internalID)
            } else {
                interactivePending[consumer] = item
            }
            return waiter
        }

        if var item = scheduledSummaryPending,
           let waiter = item.waiters.removeValue(forKey: waiterID) {
            if item.waiters.isEmpty {
                scheduledSummaryPending = nil
                cancelTimeout(for: item.internalID)
            } else {
                scheduledSummaryPending = item
            }
            return waiter
        }

        for index in labelPending.indices {
            guard let waiter = labelPending[index].waiters.removeValue(forKey: waiterID) else {
                continue
            }
            if labelPending[index].waiters.isEmpty {
                let removed = labelPending.remove(at: index)
                cancelTimeout(for: removed.internalID)
            }
            return waiter
        }
        return nil
    }

    private func removeAllPending() -> [WorkItem] {
        let items = pendingItems()
        interactivePending.removeAll()
        scheduledSummaryPending = nil
        labelPending.removeAll()
        return items
    }

    // MARK: results and diagnostics

    private func resolve(_ item: WorkItem, with outcome: ExecutionOutcome) {
        cancelTimeout(for: item.internalID)
        resolve(item.waiters, with: outcome)
    }

    private func resolve(
        _ waiters: [UUID: Waiter],
        with outcome: ExecutionOutcome
    ) {
        for waiter in waiters.values {
            switch outcome {
            case .success(let response):
                waiter.continuation.resume(returning: response)
            case .failure(let error):
                waiter.continuation.resume(throwing: error)
            }
        }
    }

    private func diagnostic(for item: WorkItem) -> LLMRouterJobDiagnostic {
        LLMRouterJobDiagnostic(
            requestID: item.request.id,
            consumer: item.request.consumer,
            priority: item.request.priority,
            providerID: item.snapshot.providerID,
            modelID: item.snapshot.modelID,
            selectionRevision: item.snapshot.selectionRevision,
            authorizationEpoch: item.snapshot.authorizationEpoch
        )
    }

    private var isHealthy: Bool {
        health == .healthy
    }

    private var isAcceptingWork: Bool {
        isHealthy && !shutdownRequested
    }

    private nonisolated static func contentFingerprint(
        for request: LLMRequest
    ) -> String {
        var data = Data()
        append(request.consumer.rawValue, to: &data)
        append(String(request.priority.rawValue), to: &data)
        append(request.systemPrompt, to: &data)
        append(request.userPrompt, to: &data)
        append(String(request.maximumOutputTokens), to: &data)
        let components = request.timeout.components
        append(String(components.seconds), to: &data)
        append(String(components.attoseconds), to: &data)
        if let contract = request.localOutputContract {
            append("local-output-contract", to: &data)
            append(contract.purpose.rawValue, to: &data)
            append(contract.language.rawValue, to: &data)
            append(String(contract.allowedSources.count), to: &data)
            for source in contract.allowedSources.sorted() {
                append(source, to: &data)
            }
        } else {
            append("no-local-output-contract", to: &data)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func append(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        var count = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(bytes)
    }
}
