import Foundation

enum CallEvidenceDeletionError: Error, LocalizedError, Sendable, Equatable {
    case activeCallMustEnd
    case unsafeMediaPath
    case cleanupIncomplete

    var errorDescription: String? {
        switch self {
        case .activeCallMustEnd:
            "End the active call before deleting its evidence. Nothing was deleted."
        case .unsafeMediaPath:
            "Call evidence referenced an unsafe media path. Nothing outside Eye was touched."
        case .cleanupIncomplete:
            "Call evidence is hidden, but file cleanup must finish before deletion is complete."
        }
    }
}

struct CallErasePreparation: Sendable, Equatable {
    let mutationID: Int64
    let callID: Int64
    let relativePaths: [String]
    let bytes: Int64
}

struct CallEraseReport: Sendable, Equatable {
    let callID: Int64
    let filesDeleted: Int
    let bytesDeleted: Int64
}

/// Orchestrates whole-envelope deletion. CallRepository owns the atomic DB
/// tombstone; this actor owns only contained file cleanup. A crash after the
/// tombstone is replayed by CallRecoveryService before the call disappears.
actor CallEvidenceDeletionService {
    typealias WorkerSuspend = @Sendable () async -> Bool
    typealias WorkerResume = @Sendable () async -> Void

    private let repository: CallRepository
    private let mediaRoot: URL
    private let fileManager: FileManager
    private var suspendWorker: WorkerSuspend?
    private var resumeWorker: WorkerResume?

    init(
        repository: CallRepository,
        mediaRoot: URL,
        fileManager: FileManager = .default
    ) {
        self.repository = repository
        self.mediaRoot = mediaRoot.resolvingSymlinksInPath().standardizedFileURL
        self.fileManager = fileManager
    }

    func attachTranscriptWorker(
        suspend: @escaping WorkerSuspend,
        resume: @escaping WorkerResume
    ) {
        suspendWorker = suspend
        resumeWorker = resume
    }

    func requireNoActiveCall() async throws {
        if let callID = try await repository.recordingCallID() {
            throw CallRepositoryError.activeCallMustEnd(callID)
        }
    }

    func evidenceBytes() async throws -> Int64 {
        let callBytes = try await repository.callEvidenceBytes()
        let pendingPaths = try await repository.pendingErasePreparations()
            .flatMap(\.relativePaths)
        let pendingBytes = try bytesOnDisk(for: pendingPaths)
        let scratchBytes = try CallHelperScratchStore(
            dataRoot: mediaRoot.deletingLastPathComponent(),
            fileManager: fileManager
        ).inventory().bytes
        let withPending = callBytes.addingReportingOverflow(pendingBytes)
        let subtotal = withPending.overflow ? Int64.max : withPending.partialValue
        let total = subtotal.addingReportingOverflow(scratchBytes)
        return total.overflow ? Int64.max : total.partialValue
    }

    func erase(callID: Int64, nowMs: Int64) async throws -> CallEraseReport {
        let ownsResume = await suspendWorker?() ?? false
        do {
            let report = try await eraseWhileWorkerDrained(callID: callID, nowMs: nowMs)
            if ownsResume { await resumeWorker?() }
            return report
        } catch {
            if ownsResume { await resumeWorker?() }
            throw error
        }
    }

    func resumePendingErases(nowMs: Int64) async throws -> [CallEraseReport] {
        let pending = try await repository.pendingErasePreparations()
        var reports: [CallEraseReport] = []
        reports.reserveCapacity(pending.count)
        for preparation in pending {
            reports.append(try await erase(callID: preparation.callID, nowMs: nowMs))
        }
        return reports
    }

    private func eraseWhileWorkerDrained(callID: Int64, nowMs: Int64) async throws -> CallEraseReport {
        _ = try CallHelperScratchStore(
            dataRoot: mediaRoot.deletingLastPathComponent(),
            fileManager: fileManager
        ).scavenge()
        let prepared = try await repository.beginEraseCall(callID: callID, nowMs: nowMs)
        let bytesOnDisk = try bytesOnDisk(for: prepared.relativePaths)
        var deleted = 0
        var cleanupComplete = true
        for path in prepared.relativePaths {
            guard let url = containedURL(for: path) else {
                cleanupComplete = false
                continue
            }
            if fileManager.fileExists(atPath: url.path) {
                do {
                    try fileManager.removeItem(at: url)
                    deleted += 1
                } catch {
                    cleanupComplete = false
                }
            }
        }
        guard cleanupComplete else {
            throw CallEvidenceDeletionError.cleanupIncomplete
        }
        try await repository.finalizeEraseCall(
            mutationID: prepared.mutationID,
            nowMs: nowMs
        )
        removeEmptyCallDirectory(callID: callID)
        return CallEraseReport(
            callID: callID,
            filesDeleted: deleted,
            bytesDeleted: prepared.bytes > 0 ? prepared.bytes : bytesOnDisk
        )
    }

    func eraseOldest(before cutoffMs: Int64? = nil, nowMs: Int64) async throws -> CallEraseReport? {
        guard let callID = try await repository.oldestErasableCallID(before: cutoffMs) else {
            return nil
        }
        return try await erase(callID: callID, nowMs: nowMs)
    }

    @discardableResult
    func sweepOrphanedCallFiles(graceSeconds: TimeInterval = 60) async throws -> Int {
        let known = try await repository.referencedCallMediaPaths()
        let root = StorageLocation.callEvidenceRoot(
            under: mediaRoot.deletingLastPathComponent()
        )
        let cutoff = Date().addingTimeInterval(-graceSeconds)
        var deleted = 0
        for (url, modifiedAt) in try regularCallFiles(root: root) {
            let relative = relativePath(for: url)
            guard !known.contains(relative),
                  (modifiedAt ?? .distantPast) <= cutoff else { continue }
            try fileManager.removeItem(at: url)
            deleted += 1
        }
        return deleted
    }

    private func regularCallFiles(root: URL) throws -> [(URL, Date?)] {
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
                ],
                options: []
              ) else { return [] }
        var result: [(URL, Date?)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
            )
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            result.append((url, values.contentModificationDate))
        }
        return result
    }

    private func containedURL(for relativePath: String) -> URL? {
        guard ManagedAssetVerifier.isSafeRelativePath(relativePath) else {
            return nil
        }
        let candidate = mediaRoot
            .appendingPathComponent(relativePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let prefix = mediaRoot.path.hasSuffix("/") ? mediaRoot.path : mediaRoot.path + "/"
        guard candidate.path.hasPrefix(prefix) else { return nil }
        return candidate
    }

    private func bytesOnDisk(for relativePaths: [String]) throws -> Int64 {
        var total: Int64 = 0
        var visited: Set<String> = []
        for path in relativePaths {
            guard let url = containedURL(for: path) else {
                throw CallEvidenceDeletionError.unsafeMediaPath
            }
            guard visited.insert(url.path).inserted,
                  fileManager.fileExists(atPath: url.path) else { continue }
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isSymbolicLink != true, values.isRegularFile == true else {
                throw CallEvidenceDeletionError.unsafeMediaPath
            }
            let next = total.addingReportingOverflow(Int64(values.fileSize ?? 0))
            total = next.overflow ? Int64.max : next.partialValue
        }
        return total
    }

    private func relativePath(for url: URL) -> String {
        let prefix = mediaRoot.path.hasSuffix("/") ? mediaRoot.path : mediaRoot.path + "/"
        return String(url.standardizedFileURL.path.dropFirst(prefix.count))
    }

    private func removeEmptyCallDirectory(callID: Int64) {
        let root = StorageLocation.callEvidenceRoot(
            under: mediaRoot.deletingLastPathComponent()
        ).appendingPathComponent(String(callID), isDirectory: true)
        if (try? fileManager.contentsOfDirectory(atPath: root.path).isEmpty) == true {
            try? fileManager.removeItem(at: root)
        }
    }
}
