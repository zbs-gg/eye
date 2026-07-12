enum AppTerminationReplyAction: Sendable, Equatable {
    case reply(Bool)
    case resetTerminationGuard
    case showRetryAlert
}

enum AppTerminationReplyPlan {
    static func actions(shouldTerminate: Bool) -> [AppTerminationReplyAction] {
        shouldTerminate
            ? [.reply(true)]
            : [.reply(false), .resetTerminationGuard, .showRetryAlert]
    }
}

enum AppTerminationRecoveryOwner: Sendable, Equatable {
    case quit
    case relocationHandoff

    var recoversServiceGraphInline: Bool {
        self == .quit
    }
}

enum AppTerminationDeadlinePolicy {
    /// Real ScreenCaptureKit/CoreAudio teardown exceeded six seconds on the
    /// release machine even though the remote queues stopped successfully.
    /// Keep Quit fail-closed, but give the acknowledged hardware drain enough
    /// time to finish instead of forcing the user through a retry loop.
    static let recordingDrain: Duration = .seconds(15)
}

enum AppTerminationCriticalPhaseOutcome: Sendable, Equatable {
    case completed(Bool)
    case timedOut
    case cancelled
}

@MainActor
struct AppTerminationCriticalPhaseResult {
    let outcome: AppTerminationCriticalPhaseOutcome
    let operation: Task<Bool, Never>

    /// A timed-out task may ignore cancellation while it still owns hardware or
    /// model state. Retain it to real completion, then recover only if this
    /// recovery task still belongs to the current Quit attempt.
    func recoveryTask(
        _ recover: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            _ = await operation.value
            guard !Task.isCancelled else { return }
            await recover()
        }
    }
}

@MainActor
enum AppTerminationCriticalPhase {
    static func acceptsTermination(_ result: AppTerminationCriticalPhaseResult) -> Bool {
        result.outcome == .completed(true)
    }

    static func run(
        timeout: Duration,
        operation: @escaping @MainActor @Sendable () async -> Bool
    ) async -> AppTerminationCriticalPhaseResult {
        let task = Task { @MainActor in await operation() }
        let wait = await LocalRuntimeTaskDeadline.wait(
            for: task,
            timeout: timeout
        )
        let outcome: AppTerminationCriticalPhaseOutcome
        switch wait {
        case .completed:
            outcome = .completed(await task.value)
        case .timedOut:
            task.cancel()
            outcome = .timedOut
        case .cancelled:
            task.cancel()
            outcome = .cancelled
        }
        return AppTerminationCriticalPhaseResult(
            outcome: outcome,
            operation: task
        )
    }
}
