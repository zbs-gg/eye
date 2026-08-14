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
        // File receipts survive the exact failure mode SQLite cannot represent: both runtime
        // rejection writes failed and the process died. Project them before any generic recovery
        // can create final transcript work or webhook outbox rows.
        let privacyReceipts = try await CallPrivacyIntentJournalExecutor(
            mediaRoot: mediaRoot,
            fileManager: fileManager
        ).pendingAutomaticRejections()
        try await repository.reconcileAutomaticRejectionIntents(
            privacyReceipts,
            nowMs: nowMs
        )

        _ = try CallHelperScratchStore(
            dataRoot: mediaRoot.deletingLastPathComponent(),
            fileManager: fileManager
        ).scavenge()
        try await repository.recoverOpenVideoSpans(nowMs: nowMs)
        try await reconcileVideoPostprocessBackups(nowMs: nowMs)
        removeAbandonedVideoPartials()
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
        let privacyDeletion = CallEvidenceDeletionService(
            repository: repository,
            mediaRoot: mediaRoot
        )
        var rejectedErasesCompleted = 0
        for callID in try await repository.rejectedCallIDsPendingErase() {
            _ = try await privacyDeletion.erase(callID: callID, nowMs: nowMs)
            rejectedErasesCompleted += 1
        }
        return CallRecoveryReport(
            callsInterrupted: databaseReport.callsInterrupted,
            jobsReset: databaseReport.jobsReset,
            finalJobsCreated: databaseReport.finalJobsCreated,
            chunksFinalized: chunksFinalized,
            chunksDiscarded: chunksDiscarded,
            mutationsCompleted: mutationReport.completed + rejectedErasesCompleted,
            mutationsRolledBack: mutationReport.rolledBack
        )
    }

    private func removeAbandonedVideoPartials() {
        let callsRoot = mediaRoot.appendingPathComponent("calls", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: callsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }
        for case let url as URL in enumerator where
            url.pathExtension == "partial"
                || url.lastPathComponent.hasSuffix(".partial.mp4")
                || url.lastPathComponent.hasSuffix(".mix.m4a") {
            let target = url.standardizedFileURL
            let resolved = target.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(callsRoot.path + "/") else { continue }
            // Delete the enumerated scratch entry, not a possible symlink
            // target that merely happens to live under the same media root.
            try? fileManager.removeItem(at: target)
        }
    }

    /// `replaceItemAt` publishes muxed bytes before the generation-bound row
    /// can commit its new hash. A crash in that narrow window leaves the old,
    /// still-authoritative bytes in `.silent-backup`. Reconcile against the DB
    /// instead of treating that rollback copy as disposable scratch.
    private func reconcileVideoPostprocessBackups(nowMs: Int64) async throws {
        let callsRoot = mediaRoot.appendingPathComponent("calls", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: callsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }
        let backups = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  url.lastPathComponent.hasSuffix(".silent-backup"),
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
            else { return nil }
            return url
        }
        let rootPath = mediaRoot.standardizedFileURL.path + "/"
        let callsRootPath = callsRoot.path + "/"
        for unresolvedBackupURL in backups {
            let backupName = unresolvedBackupURL.lastPathComponent
            let originalName = String(backupName.dropLast(".silent-backup".count))
            guard !originalName.isEmpty else { continue }
            let backupURL = unresolvedBackupURL.resolvingSymlinksInPath()
                .standardizedFileURL
            let originalURL = unresolvedBackupURL.deletingLastPathComponent()
                .appendingPathComponent(originalName)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard backupURL.path.hasPrefix(callsRootPath),
                  originalURL.path.hasPrefix(callsRootPath),
                  originalURL.path.hasPrefix(rootPath) else { continue }
            let relativePath = String(originalURL.path.dropFirst(rootPath.count))
            guard let segment = try await repository.videoSegmentForPostprocessRecovery(
                relativePath: relativePath
            ) else {
                // Unknown bytes can still be the only recovery copy. Preserve
                // them for explicit reconciliation instead of guessing.
                continue
            }

            if fileMatchesSegment(originalURL, segment: segment) {
                try? fileManager.removeItem(at: backupURL)
                continue
            }
            guard fileMatchesSegment(backupURL, segment: segment) else {
                try? await repository.markCallDegraded(
                    callID: segment.callId,
                    reason: "video_postprocess_recovery_mismatch",
                    nowMs: nowMs
                )
                continue
            }

            do {
                if fileManager.fileExists(atPath: originalURL.path) {
                    _ = try fileManager.replaceItemAt(originalURL, withItemAt: backupURL)
                } else {
                    try fileManager.moveItem(at: backupURL, to: originalURL)
                }
                guard fileMatchesSegment(originalURL, segment: segment) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            } catch {
                try? await repository.markCallDegraded(
                    callID: segment.callId,
                    reason: "video_postprocess_recovery_mismatch",
                    nowMs: nowMs
                )
            }
        }
    }

    private func fileMatchesSegment(
        _ url: URL,
        segment: CallVideoSegmentRow
    ) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              Int64(data.count) == segment.bytes else { return false }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return digest == segment.sha256
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
