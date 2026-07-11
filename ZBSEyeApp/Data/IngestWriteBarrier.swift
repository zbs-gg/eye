import Foundation

struct IngestDrainAcknowledgement: Sendable, Equatable {
    let activeWrites: Int
}

/// Reentrancy-safe write counter for IngestService. The service actor may
/// accept `drain()` while an earlier `db.pool.write` is suspended, so actor FIFO
/// alone is not a barrier. This lock protects the counter across those awaits
/// and resumes maintenance waiters only after every write leaves.
final class IngestWriteBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var activeWrites = 0
    private var waiters: [CheckedContinuation<IngestDrainAcknowledgement, Never>] = []

    func beginWrite() {
        lock.lock()
        activeWrites += 1
        lock.unlock()
    }

    func finishWrite() {
        let completed: [CheckedContinuation<IngestDrainAcknowledgement, Never>]
        lock.lock()
        precondition(activeWrites > 0, "unbalanced ingest write barrier")
        activeWrites -= 1
        if activeWrites == 0 {
            completed = waiters
            waiters.removeAll(keepingCapacity: false)
        } else {
            completed = []
        }
        lock.unlock()

        for waiter in completed {
            waiter.resume(returning: IngestDrainAcknowledgement(activeWrites: 0))
        }
    }

    func drain() async -> IngestDrainAcknowledgement {
        await withCheckedContinuation { continuation in
            lock.lock()
            if activeWrites == 0 {
                lock.unlock()
                continuation.resume(
                    returning: IngestDrainAcknowledgement(activeWrites: 0)
                )
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
