import Foundation

enum CallAutomationDeliveryResult: Sendable, Equatable {
    case delivered(statusCode: Int)
    case retry(afterMs: Int64?, errorCode: String)
    case blocked(statusCode: Int?, errorCode: String)
}

protocol CallAutomationTransport: Sendable {
    func deliver(_ delivery: CallAutomationDelivery) async -> CallAutomationDeliveryResult
    func test(endpoint: URL, eventID: String, occurredAtMs: Int64) async -> CallAutomationDeliveryResult
}

/// Serial delivery owner. The call transaction only creates rows; this actor performs and records
/// delivery later, so receiver downtime cannot delay End or Whisper promotion.
actor CallAutomationDispatcher {
    typealias StatusDidChange = @Sendable () async -> Void

    private let repository: CallAutomationRepository
    private let transport: any CallAutomationTransport
    private let leaseDurationMs: Int64
    private let clock: @Sendable () -> Int64
    private var suspensionCount = 0
    private var stopped = false
    private var inFlight = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var loopTask: Task<Void, Never>?
    private var retryWakeTask: Task<Void, Never>?
    private var wakeContinuation: AsyncStream<Void>.Continuation?
    private var lastPruneAtMs: Int64?
    private var statusDidChange: StatusDidChange = {}

    init(
        repository: CallAutomationRepository,
        transport: any CallAutomationTransport,
        leaseDurationMs: Int64 = 30_000,
        clock: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.repository = repository
        self.transport = transport
        self.leaseDurationMs = leaseDurationMs
        self.clock = clock
    }

    func setStatusDidChange(_ callback: @escaping StatusDidChange) {
        statusDidChange = callback
    }

    func start() {
        guard loopTask == nil, !stopped else { return }
        let stream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            wakeContinuation = continuation
        }
        loopTask = Task { [weak self] in
            await self?.recoverAndPrune()
            for await _ in stream {
                guard let self else { return }
                await self.drainReadyEvents()
            }
        }
        wakeContinuation?.yield()
    }

    func kick() {
        guard suspensionCount == 0, !stopped else { return }
        wakeContinuation?.yield()
    }

    @discardableResult
    func runOne(
        nowMs: Int64,
        completionClock: (@Sendable () -> Int64)? = nil
    ) async -> Bool {
        guard suspensionCount == 0, !stopped, !inFlight else { return false }
        inFlight = true
        defer { finishDelivery() }
        let delivery: CallAutomationDelivery
        do {
            guard let claimed = try await repository.claimNext(
                nowMs: nowMs,
                leaseDurationMs: leaseDurationMs
            ) else { return false }
            delivery = claimed
        } catch {
            return false
        }

        let result = await transport.deliver(delivery)
        let completedAtMs = max(nowMs, completionClock?() ?? nowMs)
        do {
            switch result {
            case .delivered(let statusCode):
                try await repository.markDelivered(
                    eventID: delivery.event.eventID,
                    statusCode: statusCode,
                    nowMs: completedAtMs
                )
            case .retry(let requestedDelay, let errorCode):
                let delay = min(
                    max(1_000, requestedDelay ?? Self.retryDelayMs(forAttempt: delivery.event.attempts)),
                    300_000
                )
                let next = completedAtMs.addingReportingOverflow(delay)
                try await repository.markRetry(
                    eventID: delivery.event.eventID,
                    nextAttemptAtMs: next.overflow ? Int64.max : next.partialValue,
                    errorCode: errorCode,
                    nowMs: completedAtMs
                )
            case .blocked(let statusCode, let errorCode):
                try await repository.markBlocked(
                    eventID: delivery.event.eventID,
                    statusCode: statusCode,
                    errorCode: errorCode,
                    nowMs: completedAtMs
                )
            }
        } catch {
            // The sending lease is the recovery point. If acknowledgement persistence fails, the
            // same immutable event ID is reclaimed after the lease expires.
        }
        return true
    }

    static func retryDelayMs(forAttempt attempt: Int) -> Int64 {
        let exponent = min(max(0, attempt - 1), 8)
        return min(1_000 * (Int64(1) << exponent), 300_000)
    }

    func suspendAndDrainForRelocation() async {
        suspensionCount += 1
        retryWakeTask?.cancel()
        retryWakeTask = nil
        guard inFlight else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    func resumeAfterRelocation(nowMs: Int64? = nil) async {
        guard !stopped else { return }
        guard suspensionCount > 0 else { return }
        suspensionCount -= 1
        guard suspensionCount == 0 else { return }
        _ = try? await repository.recoverStaleLeases(nowMs: nowMs ?? clock())
        kick()
    }

    func shutdown() async {
        await suspendAndDrainForRelocation()
        stopped = true
        wakeContinuation?.finish()
        wakeContinuation = nil
        retryWakeTask?.cancel()
        retryWakeTask = nil
        loopTask?.cancel()
        loopTask = nil
    }

    private func drainReadyEvents() async {
        guard suspensionCount == 0, !stopped else { return }
        _ = try? await repository.recoverStaleLeases(nowMs: clock())
        await pruneDeliveredIfDue()
        while await runOne(nowMs: clock(), completionClock: clock) {}
        await statusDidChange()
        scheduleNextWake()
    }

    private func recoverAndPrune() async {
        let nowMs = clock()
        _ = try? await repository.recoverStaleLeases(nowMs: nowMs)
        await pruneDelivered(nowMs: nowMs)
    }

    private func pruneDeliveredIfDue() async {
        let nowMs = clock()
        let oneDayMs: Int64 = 24 * 60 * 60 * 1_000
        guard lastPruneAtMs.map({ nowMs - $0 >= oneDayMs }) ?? true else { return }
        await pruneDelivered(nowMs: nowMs)
    }

    private func pruneDelivered(nowMs: Int64) async {
        let sevenDaysMs: Int64 = 7 * 24 * 60 * 60 * 1_000
        _ = try? await repository.pruneDelivered(before: nowMs - sevenDaysMs)
        lastPruneAtMs = nowMs
    }

    private func scheduleNextWake() {
        retryWakeTask?.cancel()
        retryWakeTask = Task { [weak self, repository, clock] in
            let due: Int64?
            do {
                due = try await repository.nextDispatchAtMs()
            } catch {
                Log.app.error("call_automation_schedule_scan_failed")
                let fallback = clock().addingReportingOverflow(5_000)
                due = fallback.overflow ? Int64.max : fallback.partialValue
            }
            guard let due else { return }
            let now = clock()
            let delay = max(1, due - now)
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            await self?.kick()
        }
    }

    private func finishDelivery() {
        inFlight = false
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
