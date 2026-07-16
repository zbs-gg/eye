import Foundation

enum SystemAudioCaptureTeardownOutcome: Sendable, Equatable {
    case notNeeded
    case stopped
    case failed(String)
    case timedOut

    var isConfirmedStopped: Bool {
        switch self {
        case .notNeeded, .stopped: true
        case .failed, .timedOut: false
        }
    }
}

private actor SystemAudioTeardownDeadlineResult {
    private var outcome: SystemAudioCaptureTeardownOutcome?
    private var waiters: [CheckedContinuation<SystemAudioCaptureTeardownOutcome, Never>] = []

    func resolve(_ outcome: SystemAudioCaptureTeardownOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: outcome) }
    }

    func value() async -> SystemAudioCaptureTeardownOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

/// A stop can invalidate `startCapture()` before ScreenCaptureKit returns the
/// physical stream. Keep that unresolved ownership awaitable so callers never
/// mistake "not published yet" for "confirmed stopped".
private final class SystemAudioPendingStartTeardownResult: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: SystemAudioCaptureTeardownOutcome?
    private var waiters: [CheckedContinuation<SystemAudioCaptureTeardownOutcome, Never>] = []

    func resolve(_ outcome: SystemAudioCaptureTeardownOutcome) {
        lock.lock()
        guard self.outcome == nil else {
            lock.unlock()
            return
        }
        self.outcome = outcome
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(returning: outcome) }
    }

    func value() async -> SystemAudioCaptureTeardownOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

enum SystemAudioTeardownDeadline {
    /// Bounds the caller without cancelling `teardown`: that task retains the
    /// hardware resource and must keep trying to reach its real completion.
    nonisolated static func wait(
        for teardown: Task<SystemAudioCaptureTeardownOutcome, Never>,
        timeout: Duration
    ) async -> SystemAudioCaptureTeardownOutcome {
        let result = SystemAudioTeardownDeadlineResult()
        let completion = Task {
            await result.resolve(await teardown.value)
        }
        let deadline = Task {
            guard timeout > .zero else {
                await result.resolve(.timedOut)
                return
            }
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await result.resolve(.timedOut)
        }
        let outcome = await result.value()
        deadline.cancel()
        completion.cancel()
        return outcome
    }
}

/// Sample callbacks run on SCK's queue while lifecycle control runs on the
/// MainActor. Store only an identity + Sendable sink behind a lock so ARC-backed
/// engine fields never cross that boundary unsynchronized.
final class SystemAudioFrameAdmission<Session: AnyObject, Sink: Sendable>:
    @unchecked Sendable {
    private let lock = NSLock()
    private var current: (sessionID: ObjectIdentifier, sink: Sink)?

    func open(session: Session, sink: Sink) {
        lock.lock()
        current = (ObjectIdentifier(session), sink)
        lock.unlock()
    }

    func sink(for session: Session) -> Sink? {
        lock.lock()
        defer { lock.unlock() }
        guard current?.sessionID == ObjectIdentifier(session) else { return nil }
        return current?.sink
    }

    func currentSink() -> Sink? {
        lock.lock()
        defer { lock.unlock() }
        return current?.sink
    }

    func close() -> Sink? {
        lock.lock()
        defer { lock.unlock() }
        let sink = current?.sink
        current = nil
        return sink
    }
}

/// Serializes ownership of the ScreenCaptureKit session separately from its
/// frame consumer. The concrete lifecycle behavior is exercised without TCC
/// or audio hardware in the unit-test target.
@MainActor
final class SystemAudioCaptureLifecycle<Session: AnyObject> {
    typealias StopOperation = @MainActor @Sendable (Session) async
        -> SystemAudioCaptureTeardownOutcome

    struct StartToken: Sendable, Equatable {
        fileprivate let generation: UInt64
    }

    private var generation: UInt64 = 0
    private var stopIntentGeneration: UInt64 = 0
    private var startingGeneration: UInt64?
    private var session: Session?
    private var teardown: (
        id: UInt64,
        task: Task<SystemAudioCaptureTeardownOutcome, Never>,
        operation: StopOperation
    )?
    private var teardownID: UInt64 = 0
    private var failedStopRecovery: StopOperation?
    private var rejectedStartTeardown: (
        generation: UInt64,
        operation: StopOperation,
        result: SystemAudioPendingStartTeardownResult,
        task: Task<SystemAudioCaptureTeardownOutcome, Never>
    )?

    func beginStart() async -> StartToken? {
        // A physical start is still suspended after Stop invalidated its token.
        // Do not admit a replacement until that start either fails or publishes
        // its rejected session into the retained teardown path below.
        guard rejectedStartTeardown == nil else { return nil }
        let entryStopIntentGeneration = stopIntentGeneration
        let previousTeardown = await drain()
        guard stopIntentGeneration == entryStopIntentGeneration else { return nil }
        switch previousTeardown {
        case .notNeeded, .stopped:
            break
        case .failed:
            guard await retryFailedStopIfNeeded() else { return nil }
            guard stopIntentGeneration == entryStopIntentGeneration else { return nil }
        case .timedOut:
            return nil
        }
        guard rejectedStartTeardown == nil else { return nil }
        if session != nil {
            guard await retryFailedStopIfNeeded() else { return nil }
            guard stopIntentGeneration == entryStopIntentGeneration else { return nil }
        }
        guard startingGeneration == nil, session == nil else { return nil }
        generation &+= 1
        startingGeneration = generation
        return StartToken(generation: generation)
    }

    func publishStarted(_ session: Session, token: StartToken) -> Bool {
        if startingGeneration == token.generation,
           generation == token.generation,
           self.session == nil {
            startingGeneration = nil
            self.session = session
            return true
        }

        // Stop won while the concrete capture API was suspended. It could not
        // stop a session that had not been published yet, so adopt the late
        // physical session and run the exact retained stop operation. A failed
        // outcome deliberately keeps both session ownership and the operation
        // for beginStart() to retry before admitting a replacement.
        if let rejectedStartTeardown,
           rejectedStartTeardown.generation == token.generation,
           self.session == nil,
           teardown == nil {
            self.rejectedStartTeardown = nil
            self.session = session
            let physicalTeardown = startTeardown(rejectedStartTeardown.operation)
            Task { @MainActor in
                let outcome = await physicalTeardown?.value
                    ?? .failed("late system-audio session teardown was not retained")
                rejectedStartTeardown.result.resolve(outcome)
            }
        }
        return false
    }

    func failStart(token: StartToken) {
        if startingGeneration == token.generation {
            startingGeneration = nil
        }
        if rejectedStartTeardown?.generation == token.generation {
            rejectedStartTeardown?.result.resolve(.notNeeded)
            rejectedStartTeardown = nil
        }
    }

    /// SCK already ended this exact session and invoked its delegate. There is
    /// no second stopCapture call to make; release ownership and allow restart.
    func acknowledgeExternalStop(sessionID: ObjectIdentifier) -> Bool {
        guard let session, ObjectIdentifier(session) == sessionID else { return false }
        generation &+= 1
        startingGeneration = nil
        self.session = nil
        failedStopRecovery = nil
        return true
    }

    @discardableResult
    func beginStop(
        _ operation: @escaping StopOperation
    ) -> Task<SystemAudioCaptureTeardownOutcome, Never>? {
        let rejectedGeneration = startingGeneration
        stopIntentGeneration &+= 1
        generation &+= 1
        startingGeneration = nil
        if let rejectedGeneration, session == nil {
            let result = SystemAudioPendingStartTeardownResult()
            let task = Task { await result.value() }
            rejectedStartTeardown = (rejectedGeneration, operation, result, task)
        }
        return startTeardown(operation)
    }

    private func startTeardown(
        _ operation: @escaping StopOperation
    ) -> Task<SystemAudioCaptureTeardownOutcome, Never>? {
        if let teardown { return teardown.task }
        guard let session else { return nil }
        teardownID &+= 1
        let id = teardownID
        let sessionID = ObjectIdentifier(session)
        let task = Task { @MainActor [weak self] in
            let outcome = await operation(session)
            self?.completeTeardown(
                id: id,
                sessionID: sessionID,
                outcome: outcome
            )
            return outcome
        }
        teardown = (id, task, operation)
        return task
    }

    func drain() async -> SystemAudioCaptureTeardownOutcome {
        if let pending = teardown {
            return await pending.task.value
        }
        if let pending = rejectedStartTeardown {
            return await pending.task.value
        }
        return .notNeeded
    }

    private func retryFailedStopIfNeeded() async -> Bool {
        guard session != nil,
              let failedStopRecovery,
              let retry = startTeardown(failedStopRecovery) else { return false }
        return (await retry.value).isConfirmedStopped
    }

    private func completeTeardown(
        id: UInt64,
        sessionID: ObjectIdentifier,
        outcome: SystemAudioCaptureTeardownOutcome
    ) {
        guard let completed = teardown,
              completed.id == id else { return }
        teardown = nil
        if outcome.isConfirmedStopped,
           let session,
           ObjectIdentifier(session) == sessionID {
            self.session = nil
            failedStopRecovery = nil
        } else if case .failed = outcome {
            failedStopRecovery = completed.operation
        } else {
            failedStopRecovery = nil
        }
    }
}
