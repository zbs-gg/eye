import Foundation

enum CallEvidenceDeletionError: Error, LocalizedError, Sendable, Equatable {
    case activeCallMustEnd
    case unsafeMediaPath
    case cleanupIncomplete
    case mutationInProgress

    var errorDescription: String? {
        switch self {
        case .activeCallMustEnd:
            "End the active call before deleting its evidence. Nothing was deleted."
        case .unsafeMediaPath:
            "Call evidence referenced an unsafe media path. Nothing outside Eye was touched."
        case .cleanupIncomplete:
            "Call evidence is hidden, but file cleanup must finish before deletion is complete."
        case .mutationInProgress:
            "Another call privacy change is still finishing."
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
    private var mutationInProgress = false

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
        let referencedPaths = try await repository.referencedCallMediaPaths()
        var pendingPaths = Set(
            try await repository.pendingErasePreparations().flatMap(\.relativePaths)
        )
        for mutation in try await repository.pendingRedactions() {
            pendingPaths.formUnion(decodePaths(mutation.oldRelativePathsJSON) ?? [])
            if let manifest = CallRedactionManifestV1.decode(mutation.newRelativePathsJSON) {
                pendingPaths.formUnion(manifest.survivors.map(\.relativePath))
            }
        }
        pendingPaths.subtract(referencedPaths)
        let pendingBytes = try bytesOnDisk(for: Array(pendingPaths))
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
        try acquireMutationLease()
        defer { releaseMutationLease() }
        return try await eraseWithWorkerBarrier(callID: callID, nowMs: nowMs)
    }

    private func eraseWithWorkerBarrier(callID: Int64, nowMs: Int64) async throws -> CallEraseReport {
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

    func redact(
        callID: Int64,
        fromMs: Int64,
        toMs: Int64,
        nowMs: Int64
    ) async throws -> CallRedactionReport {
        try acquireMutationLease()
        defer { releaseMutationLease() }
        _ = try await resumePendingRedactionsWithWorkerBarrier(nowMs: nowMs)
        // File and metadata validation happens before the durable privacy intent. Once beginRedaction
        // commits, every failure is crash-forward and must never restore stale transcript evidence.
        let snapshot = try await repository.redactionSnapshot(callID: callID)
        let manifest = try CallRedactionPlanner(mediaRoot: mediaRoot).makeManifest(
            snapshot: snapshot,
            fromMs: fromMs,
            toMs: toMs
        )
        let ownsResume = await suspendWorker?() ?? false
        do {
            _ = try CallHelperScratchStore(
                dataRoot: mediaRoot.deletingLastPathComponent(),
                fileManager: fileManager
            ).scavenge()
            let mutation = try await repository.beginRedaction(
                manifest: manifest,
                nowMs: nowMs
            )
            guard let mutationID = mutation.id else {
                throw CallRepositoryError.invalidMediaMutation(callID)
            }
            let report = try await resumeRedaction(
                mutationID: mutationID,
                manifest: manifest,
                initialState: mutation.state,
                nowMs: nowMs
            )
            if ownsResume { await resumeWorker?() }
            return report
        } catch {
            if ownsResume { await resumeWorker?() }
            throw error
        }
    }

    func redactIntersectingRange(
        fromMs: Int64,
        toMs: Int64,
        nowMs: Int64
    ) async throws -> [CallRedactionReport] {
        try acquireMutationLease()
        defer { releaseMutationLease() }
        _ = try await resumePendingRedactionsWithWorkerBarrier(nowMs: nowMs)
        let callIDs = try await repository.callIDsIntersecting(fromMs: fromMs, toMs: toMs)
        // Preflight every envelope before accepting the first privacy intent. This prevents a corrupt
        // later call from causing a surprising half-applied multi-call range deletion.
        var manifests: [CallRedactionManifestV1] = []
        manifests.reserveCapacity(callIDs.count)
        let planner = try CallRedactionPlanner(mediaRoot: mediaRoot)
        for callID in callIDs {
            let snapshot = try await repository.redactionSnapshot(callID: callID)
            manifests.append(
                try planner.makeManifest(snapshot: snapshot, fromMs: fromMs, toMs: toMs)
            )
        }
        guard !manifests.isEmpty else { return [] }

        let ownsResume = await suspendWorker?() ?? false
        do {
            _ = try CallHelperScratchStore(
                dataRoot: mediaRoot.deletingLastPathComponent(),
                fileManager: fileManager
            ).scavenge()
            var reports: [CallRedactionReport] = []
            reports.reserveCapacity(manifests.count)
            for manifest in manifests {
                let mutation = try await repository.beginRedaction(
                    manifest: manifest,
                    nowMs: nowMs
                )
                guard let mutationID = mutation.id else {
                    throw CallRepositoryError.invalidMediaMutation(manifest.callID)
                }
                reports.append(
                    try await resumeRedaction(
                        mutationID: mutationID,
                        manifest: manifest,
                        initialState: mutation.state,
                        nowMs: nowMs
                    )
                )
            }
            if ownsResume { await resumeWorker?() }
            return reports
        } catch {
            if ownsResume { await resumeWorker?() }
            throw error
        }
    }

    @discardableResult
    func resumePendingRedactions(nowMs: Int64) async throws -> [CallRedactionReport] {
        try acquireMutationLease()
        defer { releaseMutationLease() }
        return try await resumePendingRedactionsWithWorkerBarrier(nowMs: nowMs)
    }

    private func resumePendingRedactionsWithWorkerBarrier(
        nowMs: Int64
    ) async throws -> [CallRedactionReport] {
        let ownsResume = await suspendWorker?() ?? false
        do {
            _ = try CallHelperScratchStore(
                dataRoot: mediaRoot.deletingLastPathComponent(),
                fileManager: fileManager
            ).scavenge()
            let pending = try await repository.pendingRedactions()
            var reports: [CallRedactionReport] = []
            reports.reserveCapacity(pending.count)
            for mutation in pending {
                let encoded = mutation.newRelativePathsJSON
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Legacy journal rows stored a bare path array and are replayed by
                // CallRecoveryService's compatibility path below this executor.
                guard encoded.hasPrefix("{") else { continue }
                guard let mutationID = mutation.id,
                      let manifest = CallRedactionManifestV1.decode(mutation.newRelativePathsJSON) else {
                    // The privacy intent was already accepted, so malformed recovery data
                    // must fail closed: erase the whole envelope instead of preserving PCM.
                    _ = try await eraseWhileWorkerDrained(callID: mutation.callId, nowMs: nowMs)
                    continue
                }
                reports.append(
                    try await resumeRedaction(
                        mutationID: mutationID,
                        manifest: manifest,
                        initialState: mutation.state,
                        nowMs: nowMs
                    )
                )
            }
            if ownsResume { await resumeWorker?() }
            return reports
        } catch {
            if ownsResume { await resumeWorker?() }
            throw error
        }
    }

    func resumePendingErases(nowMs: Int64) async throws -> [CallEraseReport] {
        try acquireMutationLease()
        defer { releaseMutationLease() }
        let ownsResume = await suspendWorker?() ?? false
        do {
            let pending = try await repository.pendingErasePreparations()
            var reports: [CallEraseReport] = []
            reports.reserveCapacity(pending.count)
            for preparation in pending {
                reports.append(
                    try await eraseWhileWorkerDrained(
                        callID: preparation.callID,
                        nowMs: nowMs
                    )
                )
            }
            if ownsResume { await resumeWorker?() }
            return reports
        } catch {
            if ownsResume { await resumeWorker?() }
            throw error
        }
    }

    private func eraseWhileWorkerDrained(callID: Int64, nowMs: Int64) async throws -> CallEraseReport {
        _ = try CallHelperScratchStore(
            dataRoot: mediaRoot.deletingLastPathComponent(),
            fileManager: fileManager
        ).scavenge()
        let prepared = try await repository.beginEraseCall(
            callID: callID,
            nowMs: nowMs,
            additionalRelativePaths: try callDirectoryRelativePaths(callID: callID)
        )
        let bytesOnDisk = try bytesOnDisk(for: prepared.relativePaths)
        let secureRoot = try SecureCallSpoolRoot(root: mediaRoot)
        var deleted = 0
        var cleanupComplete = true
        for path in prepared.relativePaths {
            do {
                if try secureRoot.removeFile(relativePath: path) {
                    deleted += 1
                }
            } catch {
                cleanupComplete = false
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

    private func resumeRedaction(
        mutationID: Int64,
        manifest: CallRedactionManifestV1,
        initialState: CallMediaMutationState,
        nowMs: Int64
    ) async throws -> CallRedactionReport {
        let files = try CallRedactionFileStore(mediaRoot: mediaRoot)
        var state = initialState
        if state == .staged {
            do {
                try files.stageAndVerify(manifest)
                try await repository.commitRedactionReferenceSwap(
                    mutationID: mutationID,
                    manifest: manifest,
                    nowMs: nowMs
                )
                state = .referenceSwapped
            } catch {
                try? await repository.markMutation(
                    mutationID,
                    state: .staged,
                    nowMs: nowMs,
                    errorCode: "redaction_stage_pending"
                )
                throw error
            }
        }
        if state == .referenceSwapped || state == .cleanupPending {
            do {
                _ = try files.removeObsolete(manifest)
                try await repository.completeRedaction(mutationID: mutationID, nowMs: nowMs)
            } catch {
                try? await repository.markMutation(
                    mutationID,
                    state: .cleanupPending,
                    nowMs: nowMs,
                    errorCode: "redaction_cleanup_pending"
                )
                throw CallEvidenceDeletionError.cleanupIncomplete
            }
        }
        return CallRedactionReport(
            callID: manifest.callID,
            fromGeneration: manifest.fromGeneration,
            toGeneration: manifest.toGeneration,
            bytesRemoved: manifest.bytesRemoved
        )
    }

    func eraseOldest(before cutoffMs: Int64? = nil, nowMs: Int64) async throws -> CallEraseReport? {
        try acquireMutationLease()
        defer { releaseMutationLease() }
        guard let callID = try await repository.oldestErasableCallID(before: cutoffMs) else {
            return nil
        }
        return try await eraseWithWorkerBarrier(callID: callID, nowMs: nowMs)
    }

    @discardableResult
    func sweepOrphanedCallFiles(graceSeconds: TimeInterval = 60) async throws -> Int {
        try acquireMutationLease()
        defer { releaseMutationLease() }
        let known = try await repository.referencedCallMediaPaths()
        let root = StorageLocation.callEvidenceRoot(
            under: mediaRoot.deletingLastPathComponent()
        )
        let cutoff = Date().addingTimeInterval(-graceSeconds)
        let secureRoot = try SecureCallSpoolRoot(root: mediaRoot)
        var deleted = 0
        for (url, modifiedAt) in try regularCallFiles(root: root) {
            let relative = relativePath(for: url)
            guard !known.contains(relative),
                  (modifiedAt ?? .distantPast) <= cutoff else { continue }
            if try secureRoot.removeFile(relativePath: relative) { deleted += 1 }
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

    private func callDirectoryRelativePaths(callID: Int64) throws -> [String] {
        let root = StorageLocation.callEvidenceRoot(
            under: mediaRoot.deletingLastPathComponent()
        ).appendingPathComponent(String(callID), isDirectory: true)
        return try regularCallFiles(root: root).map { relativePath(for: $0.0) }
    }

    private func decodePaths(_ json: String) -> [String]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    private func acquireMutationLease() throws {
        guard !mutationInProgress else {
            throw CallEvidenceDeletionError.mutationInProgress
        }
        mutationInProgress = true
    }

    private func releaseMutationLease() {
        mutationInProgress = false
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
