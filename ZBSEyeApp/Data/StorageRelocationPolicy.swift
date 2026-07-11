import Darwin
import Foundation

enum StorageRelocationProcessLockError: Error, LocalizedError, Sendable, Equatable {
    case alreadyOwned
    case unsafeLockFile
    case filesystem(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .alreadyOwned:
            "ZBS Eye is using this data folder. Quit the app before relocating it."
        case .unsafeLockFile:
            "The ZBS Eye data-folder process lock is not a safe local file."
        case .filesystem(let operation, let code):
            "ZBS Eye could not secure the data folder: \(operation) (errno \(code))."
        }
    }
}

/// Kernel-backed exclusive ownership of a data root while the GUI can write to
/// it or a headless relocation can copy it. The descriptor intentionally stays
/// open for this object's lifetime; the kernel releases it after a crash, so a
/// stale-file cleanup heuristic is neither needed nor safe.
final class StorageRelocationProcessLock: @unchecked Sendable {
    static let lockFileName = ".data-root.process.lock"

    private let descriptor: Int32

    init(dataRoot: URL) throws {
        let lockURL = dataRoot.appendingPathComponent(
            Self.lockFileName,
            isDirectory: false
        )
        let descriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP {
                throw StorageRelocationProcessLockError.unsafeLockFile
            }
            throw StorageRelocationProcessLockError.filesystem(
                operation: "open",
                code: code
            )
        }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let code = errno
            close(descriptor)
            throw StorageRelocationProcessLockError.filesystem(
                operation: "inspect",
                code: code
            )
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_uid == geteuid() else {
            close(descriptor)
            throw StorageRelocationProcessLockError.unsafeLockFile
        }
        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            let code = errno
            close(descriptor)
            throw StorageRelocationProcessLockError.filesystem(
                operation: "secure",
                code: code
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw StorageRelocationProcessLockError.alreadyOwned
            }
            throw StorageRelocationProcessLockError.filesystem(
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

enum RelocationError: LocalizedError {
    case sameLocation
    case destinationOccupied(String)
    case capacityUnavailable
    case insufficientSpace(needed: Int64, free: Int64)
    case verifyFailed(String)

    var errorDescription: String? {
        switch self {
        case .sameLocation:
            "This is already the current data folder"
        case let .destinationOccupied(path):
            "The selected folder already contains ZBS Eye data (\(path)) — pick another one"
        case .capacityUnavailable:
            "ZBS Eye could not verify free space on the selected volume"
        case let .insufficientSpace(needed, free):
            "Not enough space: need ~\(needed / 1_000_000) MB, \(free / 1_000_000) MB free"
        case let .verifyFailed(message):
            "Move not confirmed: \(message). The data at the old location is intact."
        }
    }
}

enum StorageRelocationPolicy {
    static let captureReserveBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let safetyMarginBytes: Int64 = 512 * 1024 * 1024

    static func destinationRoot(
        currentRoot: URL,
        chosenParent: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let current = currentRoot.resolvingSymlinksInPath().standardizedFileURL
        let parent = chosenParent.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RelocationError.verifyFailed("the selected destination is unavailable")
        }

        let destination = parent.appendingPathComponent("ZBS Eye", isDirectory: true)
        let resolvedDestination = destination.resolvingSymlinksInPath().standardizedFileURL
        let caseSensitive = (try? parent.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames) ?? true
        let currentPath = comparablePath(current.path, caseSensitive: caseSensitive)
        let destinationPath = comparablePath(
            resolvedDestination.path,
            caseSensitive: caseSensitive
        )
        guard !sameOrDescendant(currentPath, of: destinationPath),
              !sameOrDescendant(destinationPath, of: currentPath) else {
            throw RelocationError.sameLocation
        }

        if fileManager.fileExists(atPath: destination.path) {
            if (try? destination.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            ).isSymbolicLink) == true {
                throw RelocationError.destinationOccupied(destination.path)
            }
            do {
                _ = try fileManager.contentsOfDirectory(atPath: destination.path)
            } catch {
                throw RelocationError.verifyFailed(
                    "the existing destination could not be inspected safely"
                )
            }
        }
        return destination
    }

    static func requiredFreeBytes(
        databaseBytes: Int64,
        mediaBytes: Int64,
        modelBytes: Int64
    ) throws -> Int64 {
        var total: Int64 = 0
        for value in [
            databaseBytes,
            mediaBytes,
            modelBytes,
            captureReserveBytes,
            safetyMarginBytes,
        ] {
            guard value >= 0 else {
                throw RelocationError.verifyFailed("relocation size was negative")
            }
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else {
                throw RelocationError.verifyFailed("relocation size overflowed")
            }
            total = result.partialValue
        }
        return total
    }

    @discardableResult
    static func requireCapacity(
        requiredBytes: Int64,
        availableBytes: Int64?
    ) throws -> Int64 {
        guard let availableBytes else { throw RelocationError.capacityUnavailable }
        guard availableBytes >= requiredBytes else {
            throw RelocationError.insufficientSpace(
                needed: requiredBytes,
                free: availableBytes
            )
        }
        return availableBytes
    }

    private static func comparablePath(_ path: String, caseSensitive: Bool) -> String {
        let normalized = path.precomposedStringWithCanonicalMapping
        return caseSensitive ? normalized : normalized.lowercased()
    }

    private static func sameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }
}

/// Owns every mutation of an existing relocation destination. Inspection is
/// deliberately outside the mutation block: if it fails, the user's existing
/// directory has not been renamed, removed, or written.
enum StorageRelocationDestinationTransaction {
    @discardableResult
    static func run<Result>(
        destinationRoot: URL,
        replacementRoot: URL,
        fileManager: FileManager = .default,
        operation: () throws -> Result
    ) throws -> Result {
        let destinationExisted = fileManager.fileExists(atPath: destinationRoot.path)
        let destinationWasOccupied: Bool
        if destinationExisted {
            do {
                destinationWasOccupied = try !fileManager
                    .contentsOfDirectory(atPath: destinationRoot.path)
                    .isEmpty
            } catch {
                throw RelocationError.verifyFailed(
                    "the existing destination could not be inspected safely"
                )
            }
        } else {
            destinationWasOccupied = false
        }

        var movedToReplacement = false
        var ownsDestinationRoot = false
        do {
            if destinationWasOccupied {
                guard !fileManager.fileExists(atPath: replacementRoot.path) else {
                    throw RelocationError.destinationOccupied(replacementRoot.path)
                }
                try fileManager.moveItem(
                    at: destinationRoot,
                    to: replacementRoot
                )
                movedToReplacement = true
            }

            try fileManager.createDirectory(
                at: destinationRoot,
                withIntermediateDirectories: true
            )
            ownsDestinationRoot = true
            return try operation()
        } catch {
            let operationError = error
            guard ownsDestinationRoot || movedToReplacement else {
                throw operationError
            }
            do {
                if fileManager.fileExists(atPath: destinationRoot.path) {
                    try fileManager.removeItem(at: destinationRoot)
                }
                if movedToReplacement {
                    try fileManager.moveItem(
                        at: replacementRoot,
                        to: destinationRoot
                    )
                } else if destinationExisted {
                    try fileManager.createDirectory(
                        at: destinationRoot,
                        withIntermediateDirectories: true
                    )
                }
            } catch {
                throw RelocationError.verifyFailed(
                    "relocation failed and the previous destination could not be restored"
                )
            }
            throw operationError
        }
    }
}
