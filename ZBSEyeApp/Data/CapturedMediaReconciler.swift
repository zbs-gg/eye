import Darwin
import Foundation
import GRDB

/// Performs the expensive database/filesystem proof required before a
/// persisted finite Keep Media policy may reopen automatic deletion. This is a
/// startup/admission boundary, not a scheduler or rendering metric.
enum CapturedMediaReconciler {
    private enum Kind: Int, Sendable, Equatable {
        case frame = 0
        case audio = 1
    }

    private struct Reference: Sendable, Equatable {
        let kind: Kind
        let id: Int64
        let ts: Int64
        let relativePath: String?
        let bytes: Int64?

        var isImportedWithoutMedia: Bool {
            relativePath == nil || relativePath == "imported"
        }
    }

    private struct FileSnapshot: Sendable, Equatable {
        let relativePath: String
        let bytes: Int64
        let device: UInt64
        let inode: UInt64
        let mode: UInt16
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }

    private enum FilesystemSnapshotError: Error {
        case unreadable
        case unsafe
    }

    static func reconcile(
        db: ZBSEyeDatabase,
        storage: StorageManager,
        afterFirstSnapshot: (@Sendable () async -> Void)? = nil
    ) async -> KeepMediaInventoryEvidence {
        let firstReferences: [Reference]
        do {
            firstReferences = try await references(in: db)
        } catch {
            return .uncertain(.databaseReadFailed)
        }

        let firstFiles: [FileSnapshot]
        do {
            firstFiles = try await filesystemSnapshot(at: storage.mediaDirectory)
        } catch FilesystemSnapshotError.unsafe {
            return .uncertain(.unsafeRelativePath)
        } catch {
            return .uncertain(.filesystemReadFailed)
        }

        await afterFirstSnapshot?()

        let secondReferences: [Reference]
        do {
            secondReferences = try await references(in: db)
        } catch {
            return .uncertain(.databaseReadFailed)
        }
        let secondFiles: [FileSnapshot]
        do {
            secondFiles = try await filesystemSnapshot(at: storage.mediaDirectory)
        } catch FilesystemSnapshotError.unsafe {
            return .uncertain(.unsafeRelativePath)
        } catch {
            return .uncertain(.filesystemReadFailed)
        }

        guard firstReferences == secondReferences,
              firstFiles == secondFiles else {
            return .uncertain(.changedDuringReconciliation)
        }

        let capturedReferences = secondReferences.filter { !$0.isImportedWithoutMedia }
        var referencedPaths = Set<String>()
        var expectedBytes: Int64 = 0
        for reference in capturedReferences {
            guard let path = reference.relativePath,
                  isSafeRelativePath(path) else {
                return .uncertain(.unsafeRelativePath)
            }
            guard let bytes = reference.bytes, bytes > 0 else {
                return .uncertain(.byteMetadataMismatch)
            }
            guard referencedPaths.insert(path).inserted else {
                return .uncertain(.byteMetadataMismatch)
            }
            let next = expectedBytes.addingReportingOverflow(bytes)
            guard !next.overflow else {
                return .uncertain(.byteMetadataMismatch)
            }
            expectedBytes = next.partialValue
        }

        let filesByPath = Dictionary(uniqueKeysWithValues: secondFiles.map {
            ($0.relativePath, $0)
        })
        for reference in capturedReferences {
            guard let path = reference.relativePath,
                  let expected = reference.bytes,
                  let file = filesByPath[path] else {
                return .uncertain(.referencedFileMissing)
            }
            guard file.bytes == expected else {
                return .uncertain(.byteMetadataMismatch)
            }
        }

        let orphanedCapturedMedia = secondFiles.contains { file in
            isCapturedMediaPath(file.relativePath)
                && !referencedPaths.contains(file.relativePath)
        }
        guard !orphanedCapturedMedia else {
            return .uncertain(.orphanCapturedMedia)
        }
        return .reconciled(capturedMediaBytes: expectedBytes)
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.utf8.contains(0) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { component in
            component != "." && component != ".." && !component.isEmpty
        }
    }

    private static func references(in database: ZBSEyeDatabase) async throws -> [Reference] {
        try await database.pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, ts, 0 AS kind, relativePath, bytes FROM screen_captures
                UNION ALL
                SELECT id, ts, 1 AS kind, relativePath, bytes FROM audio_captures
                ORDER BY kind, id
                """)
            return try rows.map { row in
                guard let kind = Kind(rawValue: row["kind"] as Int) else {
                    throw DatabaseError(message: "unknown captured-media kind")
                }
                return Reference(
                    kind: kind,
                    id: row["id"],
                    ts: row["ts"],
                    relativePath: row["relativePath"],
                    bytes: row["bytes"]
                )
            }
        }
    }

    private static func filesystemSnapshot(at root: URL) async throws -> [FileSnapshot] {
        try await Task.detached(priority: .utility) {
            var rootMetadata = stat()
            guard lstat(root.path, &rootMetadata) == 0,
                  (rootMetadata.st_mode & S_IFMT) == S_IFDIR else {
                throw FilesystemSnapshotError.unreadable
            }

            var files: [FileSnapshot] = []
            func walk(_ directory: URL, prefix: String) throws {
                let names: [String]
                do {
                    names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
                } catch {
                    throw FilesystemSnapshotError.unreadable
                }
                for name in names {
                    let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
                    let url = directory.appendingPathComponent(name)
                    var metadata = stat()
                    guard lstat(url.path, &metadata) == 0 else {
                        throw FilesystemSnapshotError.unreadable
                    }
                    switch metadata.st_mode & S_IFMT {
                    case S_IFDIR:
                        try walk(url, prefix: relative)
                    case S_IFREG:
                        guard metadata.st_size >= 0 else {
                            throw FilesystemSnapshotError.unsafe
                        }
                        files.append(FileSnapshot(
                            relativePath: relative,
                            bytes: metadata.st_size,
                            device: UInt64(metadata.st_dev),
                            inode: UInt64(metadata.st_ino),
                            mode: metadata.st_mode,
                            modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
                            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
                            changedSeconds: Int64(metadata.st_ctimespec.tv_sec),
                            changedNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
                        ))
                    default:
                        // Symlinks, sockets, devices, and other special files
                        // are never safe inputs to destructive reconciliation.
                        throw FilesystemSnapshotError.unsafe
                    }
                }
            }
            try walk(root, prefix: "")
            return files
        }.value
    }

    private static func isCapturedMediaPath(_ path: String) -> Bool {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "heic", "m4a": true
        default: false
        }
    }
}
