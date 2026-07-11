import Darwin
import Foundation

enum BuiltInModelProcessLockError: Error, LocalizedError, Sendable, Equatable {
    case alreadyOwned
    case unsafeLockFile
    case filesystem(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .alreadyOwned:
            "Another ZBS Eye process already owns the built-in model store."
        case .unsafeLockFile:
            "The built-in model process lock is not a safe local file."
        case .filesystem(let operation, let code):
            "Built-in model process lock failed: \(operation) (errno \(code))."
        }
    }
}

/// Kernel-backed, crash-safe ownership of one model root. The descriptor stays
/// open for the manager's lifetime; process exit releases the advisory lock
/// even after a crash, so no stale lock cleanup heuristic is required.
final class BuiltInModelProcessLock: @unchecked Sendable {
    private let descriptor: Int32

    init(modelRoot: URL) throws {
        let lockURL = modelRoot.appending(path: ".process.lock", directoryHint: .notDirectory)
        let descriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw BuiltInModelProcessLockError.filesystem(
                operation: "open",
                code: errno
            )
        }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let code = errno
            close(descriptor)
            throw BuiltInModelProcessLockError.filesystem(
                operation: "inspect",
                code: code
            )
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_uid == geteuid() else {
            close(descriptor)
            throw BuiltInModelProcessLockError.unsafeLockFile
        }
        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            let code = errno
            close(descriptor)
            throw BuiltInModelProcessLockError.filesystem(
                operation: "secure",
                code: code
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw BuiltInModelProcessLockError.alreadyOwned
            }
            throw BuiltInModelProcessLockError.filesystem(
                operation: "acquire",
                code: code
            )
        }
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
}
