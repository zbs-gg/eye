import Foundation

enum DatabaseWriterMaintenanceError: LocalizedError, Equatable {
    case suspendedForRelocation

    var errorDescription: String? {
        switch self {
        case .suspendedForRelocation:
            "Database maintenance is paused while storage is being moved."
        }
    }
}

struct DatabaseWriterDrainAcknowledgement: Sendable, Equatable {
    let activeOperations: Int
}

struct DatabaseWriterMaintenanceSnapshot: Sendable, Equatable {
    let activeOperations: Int
    let suspended: Bool
}

/// Atomic admission and drain barrier for database writers that suspend across
/// `await`. Actor FIFO is insufficient here: relocation can re-enter an actor
/// while an earlier operation is waiting on GRDB and would otherwise snapshot
/// the database before that operation finishes.
final class DatabaseWriterMaintenanceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeOperations = 0
    private var suspended = false
    private var waiters: [CheckedContinuation<DatabaseWriterDrainAcknowledgement, Never>] = []

    /// Returns false after maintenance has closed admission.
    func beginOperation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !suspended else { return false }
        activeOperations += 1
        return true
    }

    func finishOperation() {
        let completed: [CheckedContinuation<DatabaseWriterDrainAcknowledgement, Never>]
        lock.lock()
        precondition(activeOperations > 0, "unbalanced database writer maintenance gate")
        activeOperations -= 1
        if activeOperations == 0 {
            completed = waiters
            waiters.removeAll(keepingCapacity: false)
        } else {
            completed = []
        }
        lock.unlock()

        for waiter in completed {
            waiter.resume(returning: DatabaseWriterDrainAcknowledgement(activeOperations: 0))
        }
    }

    /// Closes admission first, then acknowledges only after all operations that
    /// entered before suspension have left their full async operation scope.
    func suspendAndDrain() async -> DatabaseWriterDrainAcknowledgement {
        await withCheckedContinuation { continuation in
            let completeImmediately: Bool
            lock.lock()
            suspended = true
            if activeOperations == 0 {
                completeImmediately = true
            } else {
                waiters.append(continuation)
                completeImmediately = false
            }
            lock.unlock()

            if completeImmediately {
                continuation.resume(
                    returning: DatabaseWriterDrainAcknowledgement(activeOperations: 0)
                )
            }
        }
    }

    /// Reopens admission after the relocation attempt has either failed or
    /// completed outside this process. Safe to call when already resumed.
    func resume() {
        lock.lock()
        guard suspended else {
            lock.unlock()
            return
        }
        precondition(activeOperations == 0 && waiters.isEmpty,
                     "database writer resumed before maintenance drain completed")
        suspended = false
        lock.unlock()
    }

    func snapshot() -> DatabaseWriterMaintenanceSnapshot {
        lock.lock()
        let value = DatabaseWriterMaintenanceSnapshot(
            activeOperations: activeOperations,
            suspended: suspended
        )
        lock.unlock()
        return value
    }
}
