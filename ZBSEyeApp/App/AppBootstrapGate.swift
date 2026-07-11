import Foundation

/// App-lifetime admission for the service graph. SwiftUI may recreate the
/// window task, but initialization must have exactly one owner.
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
            // This unstructured task is app-lifetime work: closing the window
            // may cancel SwiftUI's `.task`, but must not tear down a half-built
            // service graph or let the next window build a second one.
            let task = Task { @MainActor in await operation() }
            state = .running(task)
            await task.value
            state = .completed
        }
    }
}
