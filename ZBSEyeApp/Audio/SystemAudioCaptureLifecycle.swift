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

    func beginStart() async -> StartToken? {
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
        guard startingGeneration == token.generation,
              generation == token.generation,
              self.session == nil else { return false }
        startingGeneration = nil
        self.session = session
        return true
    }

    func failStart(token: StartToken) {
        guard startingGeneration == token.generation else { return }
        startingGeneration = nil
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
        stopIntentGeneration &+= 1
        generation &+= 1
        startingGeneration = nil
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
        guard let pending = teardown else { return .notNeeded }
        return await pending.task.value
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
