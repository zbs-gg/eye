import Darwin
import Foundation

enum StorageManagerError: Error, Sendable, Equatable {
    case capturedMediaValidationFailed(String)
}

/// Media location (HEIC/m4a). Paths in the DB are relative (`relativePath`), resolved against
/// the current mediaDirectory. Relocation via a security-scoped bookmark is Phase 2 (step 11); for now, default.
final class StorageManager: Sendable {
    let mediaDirectory: URL
    private let deleteFileOperation: @Sendable (URL) throws -> Void

    init() throws {
        self.mediaDirectory = StorageLocation.mediaDirectory()   // honors relocate
        self.deleteFileOperation = { try FileManager.default.removeItem(at: $0) }
    }

    /// Explicit root for isolated verification harnesses. Production callers
    /// continue to use `StorageLocation`; this seam prevents a physical gate
    /// from writing into the user's recorder history.
    init(mediaDirectory: URL) throws {
        self.mediaDirectory = mediaDirectory.standardizedFileURL
        self.deleteFileOperation = { try FileManager.default.removeItem(at: $0) }
        try FileManager.default.createDirectory(
            at: self.mediaDirectory,
            withIntermediateDirectories: true
        )
    }

    /// Failure-injection seam for destructive-path verification. Production
    /// callers use the two initializers above.
    init(
        mediaDirectory: URL,
        deleteFile: @escaping @Sendable (URL) throws -> Void
    ) throws {
        self.mediaDirectory = mediaDirectory.standardizedFileURL
        self.deleteFileOperation = deleteFile
        try FileManager.default.createDirectory(
            at: self.mediaDirectory,
            withIntermediateDirectories: true
        )
    }

    func url(forRelative relativePath: String) -> URL {
        mediaDirectory.appendingPathComponent(relativePath)
    }

    /// Writes the frame data, returns the relative path.
    func writeFrame(_ data: Data, timestamp: Date, displayIndex: Int) throws -> String {
        let name = "screen_\(Int64(timestamp.timeIntervalSince1970 * 1000))_\(displayIndex).heic"
        try data.write(to: url(forRelative: name), options: .atomic)
        return name
    }

    func deleteFile(relativePath: String) throws {
        try deleteFileOperation(url(forRelative: relativePath))
    }

    /// Destructive retention revalidates immutable capture media while its
    /// permit lease and database transaction are both held. `lstat` rejects
    /// symlinks; exact size rejects missing, stale, truncated, and zero files.
    func validateCapturedMediaFile(
        relativePath: String,
        expectedBytes: Int64
    ) throws {
        guard expectedBytes > 0 else {
            throw StorageManagerError.capturedMediaValidationFailed(relativePath)
        }
        var metadata = stat()
        let url = url(forRelative: relativePath)
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size == expectedBytes else {
            throw StorageManagerError.capturedMediaValidationFailed(relativePath)
        }
    }

    func fileSize(relativePath: String) -> Int? {
        try? url(forRelative: relativePath).resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    /// Free space on the media volume (for the disk-guard: don't hammer the disk by writing 24/7).
    func freeBytes() -> Int64 {
        availableCapacityForImportantUsage() ?? .max
    }

    /// Admission checks must distinguish an unreadable volume from abundant space.
    /// UI-only callers can keep using `freeBytes`; capture treats nil as unsafe.
    func availableCapacityForImportantUsage() -> Int64? {
        let vals = try? mediaDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let bytes = vals?.volumeAvailableCapacityForImportantUsage,
              bytes >= 0 else { return nil }
        return Int64(bytes)
    }

    func totalBytes() -> Int64 {
        guard let en = FileManager.default.enumerator(at: mediaDirectory,
                  includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in en {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
