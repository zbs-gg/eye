import Foundation

/// App-lifetime admission for the service graph. Repeated lifecycle requests
/// must share one initialization owner.
@MainActor
final class AppBootstrapGate {
    private enum State {
        case idle
        case running(Task<Void, Never>)
        case completed
    }

    private var state: State = .idle

    func run(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) async {
        switch state {
        case .completed:
            return
        case .running(let task):
            await task.value
        case .idle:
            // This unstructured task is app-lifetime work. Caller cancellation
            // must not tear down a half-built service graph or let another
            // lifecycle request build a second one.
            let task = Task { @MainActor in await operation() }
            state = .running(task)
            await task.value
            state = .completed
        }
    }
}
