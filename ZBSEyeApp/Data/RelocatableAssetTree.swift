import CryptoKit
import Darwin
import Foundation

enum RelocatableAssetTreeError: Error, Sendable, Equatable {
    case unsafeEntry(String)
    case destinationOccupied
    case parityMismatch
}

struct RelocatableAssetTreeInventory: Sendable, Equatable {
    struct File: Sendable, Equatable, Comparable {
        let relativePath: String
        let bytes: Int64
        let sha256: String

        static func < (lhs: File, rhs: File) -> Bool {
            lhs.relativePath < rhs.relativePath
        }
    }

    let files: [File]
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

/// Copy/verify helper for relocatable non-database assets. Every regular file
/// is compared by path, size, and a streaming SHA-256 digest. Symlinks and
/// special files fail closed: relocation must never turn an unexpected link
/// into an off-root copy.
enum RelocatableAssetTree {
    static func inventoryIfPresent(
        at root: URL,
        fileManager: FileManager = .default
    ) throws -> RelocatableAssetTreeInventory? {
        var rootMetadata = stat()
        guard lstat(root.path, &rootMetadata) == 0 else {
            if errno == ENOENT { return nil }
            throw RelocatableAssetTreeError.unsafeEntry(root.lastPathComponent)
        }
        guard (rootMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw RelocatableAssetTreeError.unsafeEntry(root.lastPathComponent)
        }

        var files: [RelocatableAssetTreeInventory.File] = []
        func walk(_ directory: URL, prefix: String) throws {
            let names: [String]
            do {
                names = try fileManager.contentsOfDirectory(atPath: directory.path)
                    .sorted()
            } catch {
                throw RelocatableAssetTreeError.unsafeEntry(
                    prefix.isEmpty ? root.lastPathComponent : prefix
                )
            }

            for name in names {
                let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
                let url = directory.appendingPathComponent(name)
                var metadata = stat()
                guard lstat(url.path, &metadata) == 0 else {
                    throw RelocatableAssetTreeError.unsafeEntry(relative)
                }
                switch metadata.st_mode & S_IFMT {
                case S_IFDIR:
                    try walk(url, prefix: relative)
                case S_IFREG:
                    files.append(try inventoryFile(
                        at: url,
                        relativePath: relative,
                        expectedMetadata: metadata
                    ))
                default:
                    // Symlinks, sockets, devices, and entries that changed
                    // type during enumeration are never relocation inputs.
                    throw RelocatableAssetTreeError.unsafeEntry(relative)
                }
            }
        }
        try walk(root, prefix: "")
        return RelocatableAssetTreeInventory(files: files.sorted())
    }

    @discardableResult
    static func copyIfPresent(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws -> RelocatableAssetTreeInventory? {
        guard let sourceInventory = try inventoryIfPresent(
            at: source,
            fileManager: fileManager
        ) else {
            return nil
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw RelocatableAssetTreeError.destinationOccupied
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: source, to: destination)
        guard let copied = try inventoryIfPresent(
            at: destination,
            fileManager: fileManager
        ),
              copied == sourceInventory else {
            throw RelocatableAssetTreeError.parityMismatch
        }
        return copied
    }

    private static func inventoryFile(
        at url: URL,
        relativePath: String,
        expectedMetadata: stat
    ) throws -> RelocatableAssetTreeInventory.File {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw RelocatableAssetTreeError.unsafeEntry(relativePath)
        }
        defer { _ = close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              sameFileIdentity(before, expectedMetadata),
              before.st_size >= 0 else {
            throw RelocatableAssetTreeError.unsafeEntry(relativePath)
        }

        var hasher = SHA256()
        var bytesRead: Int64 = 0
        var buffer = Data(count: 1_048_576)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw RelocatableAssetTreeError.unsafeEntry(relativePath)
            }
            let nextTotal = bytesRead.addingReportingOverflow(Int64(count))
            guard !nextTotal.overflow else {
                throw RelocatableAssetTreeError.unsafeEntry(relativePath)
            }
            bytesRead = nextTotal.partialValue
            hasher.update(data: buffer.prefix(count))
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0,
              sameFileSnapshot(before, after),
              bytesRead == before.st_size else {
            throw RelocatableAssetTreeError.unsafeEntry(relativePath)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return RelocatableAssetTreeInventory.File(
            relativePath: relativePath,
            bytes: bytesRead,
            sha256: digest
        )
    }

    private static func sameFileIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
    }

    private static func sameFileSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        sameFileIdentity(lhs, rhs)
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
