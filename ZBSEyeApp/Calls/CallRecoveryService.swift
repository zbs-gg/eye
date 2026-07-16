import CryptoKit
import Foundation

/// Reconciles only call-owned durable state. It never starts capture or speech compute, and every
/// database mutation is delegated to CallRepository so bootstrap cannot create a second writer path.
actor CallRecoveryService {
    private let repository: CallRepository
    private let mediaRoot: URL
    private let fileManager: FileManager

    init(
        repository: CallRepository,
        mediaRoot: URL,
        fileManager: FileManager = .default
    ) {
        self.repository = repository
        self.mediaRoot = mediaRoot.resolvingSymlinksInPath().standardizedFileURL
        self.fileManager = fileManager
    }

    func recover(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) async throws -> CallRecoveryReport {
        _ = try CallHelperScratchStore(
            dataRoot: mediaRoot.deletingLastPathComponent(),
            fileManager: fileManager
        ).scavenge()
        var chunksFinalized = 0
        var chunksDiscarded = 0
        for chunk in try await repository.unfinalizedChunks() {
            guard let chunkID = chunk.id,
                  let url = containedURL(for: chunk.relativePath),
                  fileManager.fileExists(atPath: url.path),
                  let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let fileBytes = (attributes[.size] as? NSNumber)?.int64Value else {
                if let chunkID = chunk.id {
                    try await repository.discardRecoveredChunk(id: chunkID)
                    chunksDiscarded += 1
                }
                continue
            }

            let alignedBytes = fileBytes - (fileBytes % 2)
            guard alignedBytes > 0 else {
                try? fileManager.removeItem(at: url)
                try await repository.discardRecoveredChunk(id: chunkID)
                chunksDiscarded += 1
                continue
            }
            do {
                if alignedBytes != fileBytes {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.truncate(atOffset: UInt64(alignedBytes))
                    try handle.synchronize()
                    try handle.close()
                }
                let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
                    .map { String(format: "%02x", $0) }
                    .joined()
                try await repository.finalizeRecoveredChunk(
                    id: chunkID,
                    bytes: alignedBytes,
                    endSample: chunk.startSample + (alignedBytes / 2),
                    sha256: digest
                )
                chunksFinalized += 1
            } catch {
                try await repository.recordSourceGap(
                    callID: chunk.callId,
                    mediaGeneration: chunk.mediaGeneration,
                    source: chunk.source,
                    startMs: chunk.startMs,
                    endMs: max(chunk.startMs + 1, chunk.endMs),
                    reason: "unreadable_recovered_chunk",
                    nowMs: nowMs
                )
                try await repository.discardRecoveredChunk(id: chunkID)
                chunksDiscarded += 1
            }
        }

        let mutationReport = try await replayMutationJournal(nowMs: nowMs)
        let databaseReport = try await repository.recoverDatabaseState(nowMs: nowMs)
        return CallRecoveryReport(
            callsInterrupted: databaseReport.callsInterrupted,
            jobsReset: databaseReport.jobsReset,
            finalJobsCreated: databaseReport.finalJobsCreated,
            chunksFinalized: chunksFinalized,
            chunksDiscarded: chunksDiscarded,
            mutationsCompleted: mutationReport.completed,
            mutationsRolledBack: mutationReport.rolledBack
        )
    }

    private func replayMutationJournal(nowMs: Int64) async throws -> (completed: Int, rolledBack: Int) {
        // A versioned redaction is an already accepted privacy intent. Reuse the runtime executor
        // so bootstrap always moves it forward; only legacy path-list mutations below may roll back.
        let redactions = try await CallEvidenceDeletionService(
            repository: repository,
            mediaRoot: mediaRoot
        ).resumePendingRedactions(nowMs: nowMs)
        var completed = redactions.count
        var rolledBack = 0
        for mutation in try await repository.recoverableMutations() {
            // The executor above already attempted every versioned redaction. If its manifest is
            // corrupt, preserve the accepted generation tombstone and retryable journal row rather
            // than converting a privacy intent into a terminal failed/rolled-back mutation.
            if mutation.kind == .redaction,
               mutation.newRelativePathsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("{") {
                continue
            }
            guard let mutationID = mutation.id,
                  let oldPaths = decodePaths(mutation.oldRelativePathsJSON),
                  let newPaths = decodePaths(mutation.newRelativePathsJSON) else {
                if let mutationID = mutation.id {
                    try await repository.markMutation(
                        mutationID,
                        state: .failed,
                        nowMs: nowMs,
                        errorCode: "invalid_manifest"
                    )
                }
                continue
            }

            if mutation.kind == .erase {
                let allRemoved = try await removeUnreferenced(paths: oldPaths)
                if allRemoved {
                    try await repository.finalizeEraseCall(
                        mutationID: mutationID,
                        nowMs: nowMs
                    )
                    completed += 1
                } else {
                    try await repository.markMutation(
                        mutationID,
                        state: .cleanupPending,
                        nowMs: nowMs,
                        errorCode: "erase_cleanup_pending"
                    )
                }
                continue
            }

            switch mutation.state {
            case .staged:
                let allRemoved = try await removeUnreferenced(paths: newPaths)
                if allRemoved {
                    try await repository.markMutation(mutationID, state: .rolledBack, nowMs: nowMs)
                    rolledBack += 1
                } else {
                    try await repository.markMutation(
                        mutationID,
                        state: .failed,
                        nowMs: nowMs,
                        errorCode: "staged_path_referenced"
                    )
                }

            case .referenceSwapped, .cleanupPending, .completed:
                guard try await repository.mediaGeneration(callID: mutation.callId) == mutation.toGeneration else {
                    try await repository.markMutation(
                        mutationID,
                        state: .failed,
                        nowMs: nowMs,
                        errorCode: "generation_mismatch"
                    )
                    continue
                }
                let allRemoved = try await removeUnreferenced(paths: oldPaths)
                if allRemoved {
                    try await repository.markMutation(mutationID, state: .completed, nowMs: nowMs)
                    completed += 1
                } else {
                    try await repository.markMutation(
                        mutationID,
                        state: .cleanupPending,
                        nowMs: nowMs,
                        errorCode: "old_path_still_referenced"
                    )
                }

            case .rolledBack, .failed:
                break
            }
        }
        return (completed, rolledBack)
    }

    private func removeUnreferenced(paths: [String]) async throws -> Bool {
        var allRemoved = true
        for path in paths {
            guard let url = containedURL(for: path) else {
                allRemoved = false
                continue
            }
            if try await repository.isMediaPathReferenced(path) {
                allRemoved = false
                continue
            }
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
        return allRemoved
    }

    private func decodePaths(_ value: String) -> [String]? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    private func containedURL(for relativePath: String) -> URL? {
        guard ManagedAssetVerifier.isSafeRelativePath(relativePath) else { return nil }
        let candidate = mediaRoot
            .appending(path: relativePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPath = mediaRoot.path.hasSuffix("/") ? mediaRoot.path : mediaRoot.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { return nil }
        return candidate
    }
}
