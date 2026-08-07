import Foundation

/// Serializes ScreenCaptureKit control-plane calls across the persistent
/// screen stream and the system-audio stream. Actor isolation alone is not
/// enough here: actor methods are reentrant while an SCK call is suspended.
/// The explicit FIFO lease remains owned until the whole async body returns.
actor SCKResourceCoordinator {
    enum Owner: String, Sendable {
        case screen
        case systemAudio
    }

    enum Operation: String, Sendable {
        case start
        case update
        case stop
    }

    private struct Lease: Sendable {
        let id: UInt64
        let owner: Owner
        let operation: Operation
    }

    private struct Waiter {
        let lease: Lease
        let continuation: CheckedContinuation<Void, Never>
    }

    private var nextLeaseID: UInt64 = 0
    private var activeLease: Lease?
    private var waiters: [Waiter] = []

    /// Exposed for lifecycle diagnostics and deterministic concurrency tests.
    var pendingOperationCount: Int { waiters.count }

    /// Runs one complete SCK lifecycle operation without overlapping another
    /// screen/system-audio start, update, or stop. `nonsending` deliberately
    /// keeps the body on its caller's executor, so an actor-owned SCStream can
    /// be used without crossing a Sendable boundary.
    nonisolated(nonsending) func withExclusiveAccess<Result>(
        owner: Owner,
        operation: Operation,
        _ body: nonisolated(nonsending) () async throws -> Result
    ) async rethrows -> Result {
        let lease = await acquire(owner: owner, operation: operation)
        do {
            let result = try await body()
            await release(lease)
            return result
        } catch {
            await release(lease)
            throw error
        }
    }

    private func acquire(owner: Owner, operation: Operation) async -> Lease {
        nextLeaseID &+= 1
        let lease = Lease(
            id: nextLeaseID,
            owner: owner,
            operation: operation
        )
        guard activeLease != nil else {
            activeLease = lease
            return lease
        }

        await withCheckedContinuation { continuation in
            waiters.append(Waiter(lease: lease, continuation: continuation))
        }
        return lease
    }

    private func release(_ lease: Lease) {
        guard activeLease?.id == lease.id else {
            assertionFailure(
                "SCK resource lease released out of order: \(lease.owner.rawValue).\(lease.operation.rawValue)"
            )
            return
        }

        guard !waiters.isEmpty else {
            activeLease = nil
            return
        }

        let next = waiters.removeFirst()
        activeLease = next.lease
        next.continuation.resume()
    }
}
