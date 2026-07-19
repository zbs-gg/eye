import Foundation

enum SpeakerDiarizationModelLifecycleState: String, Codable, Sendable, Equatable {
    case absent
    case downloading
    case paused
    case verifying
    case ready
    case failed
}

struct SpeakerDiarizationModelSnapshot: Codable, Sendable, Equatable {
    let state: SpeakerDiarizationModelLifecycleState
    let receivedBytes: Int64
    let expectedBytes: Int64
    let errorCode: String?

    static func absent(expectedBytes: Int64) -> Self {
        Self(state: .absent, receivedBytes: 0, expectedBytes: expectedBytes, errorCode: nil)
    }
}

enum SpeakerDiarizationModelStoreError: Error, LocalizedError, Sendable, Equatable {
    case busy
    case downloadIncomplete
    case verificationFailed
    case filesystem

    var errorDescription: String? {
        switch self {
        case .busy: "A speaker model operation is already running."
        case .downloadIncomplete: "The speaker model download is incomplete."
        case .verificationFailed: "The speaker model failed integrity verification."
        case .filesystem: "The speaker model could not be stored safely."
        }
    }
}

struct SpeakerDiarizationModelTransport: Sendable {
    typealias Progress = @Sendable (ManagedAssetDownloadResumeState) async -> Void
    let download: @Sendable (
        _ plan: ManagedAssetDownloadPlan,
        _ resume: ManagedAssetDownloadResumeState?,
        _ progress: @escaping Progress
    ) async throws -> ManagedAssetDownloadOutcome
    let suspendAndDrain: @Sendable () async -> Void
    let resumeAfterDrain: @Sendable () async -> Void
    let cancelAndDrain: @Sendable () async -> Void

    static func live(root: URL) -> Self {
        let client = ManagedAssetDownloadClient(
            allowedAssetHosts: WhisperModelStore.allowedAssetHosts,
            progressCheckpointBytes: 256 * 1_024,
            capacityCheck: { progress in
                let available = (try? root.resourceValues(
                    forKeys: [.volumeAvailableCapacityForImportantUsageKey]
                ).volumeAvailableCapacityForImportantUsage).flatMap { $0 } ?? 0
                let reserve: Int64 = 512 * 1_024 * 1_024
                let required = max(0, progress.remainingBytes) + reserve
                return Int64(available) >= required
                    ? .sufficient
                    : .insufficient(requiredBytes: required, availableBytes: Int64(available))
            }
        )
        return Self(
            download: { plan, resume, progress in
                try await client.download(plan: plan, resumeState: resume, onProgress: progress)
            },
            suspendAndDrain: { _ = await client.suspendAndDrain() },
            resumeAfterDrain: { await client.resumeAfterDrain() },
            cancelAndDrain: { _ = await client.cancelAndDrain() }
        )
    }
}

/// Optional, explicit-download lifecycle for the compact FluidAudio assets.
/// Only a complete checksum-verified directory is atomically promoted to the
/// path visible to the same-signed helper.
actor SpeakerDiarizationModelStore {
    private let root: URL
    private let manifest: SpeakerDiarizationModelManifest
    private let transport: SpeakerDiarizationModelTransport
    private let fileManager: FileManager
    private var operationActive = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var current: SpeakerDiarizationModelSnapshot

    init(
        root: URL,
        manifest: SpeakerDiarizationModelManifest = .fluidAudio0155,
        transport: SpeakerDiarizationModelTransport? = nil,
        fileManager: FileManager = .default
    ) {
        self.root = root.standardizedFileURL
        self.manifest = manifest
        self.transport = transport ?? .live(root: root)
        self.fileManager = fileManager
        current = .absent(expectedBytes: manifest.expectedBytes)
    }

    func snapshot() -> SpeakerDiarizationModelSnapshot { current }

    func refresh() -> SpeakerDiarizationModelSnapshot {
        guard !operationActive else { return current }
        if verifiedBytes(at: modelDirectory) == manifest.expectedBytes {
            current = readySnapshot
        } else {
            let received = stagedBytes()
            current = received > 0
                ? pausedSnapshot(receivedBytes: received)
                : .absent(expectedBytes: manifest.expectedBytes)
        }
        return current
    }

    func isReady() -> Bool {
        verifiedBytes(at: modelDirectory) == manifest.expectedBytes
    }

    func install() async throws -> SpeakerDiarizationModelSnapshot {
        guard !operationActive else { throw SpeakerDiarizationModelStoreError.busy }
        if isReady() {
            current = readySnapshot
            return current
        }
        operationActive = true
        defer { finishOperation() }
        try prepareDirectories()

        var completedBytes = verifiedCandidateBytes()
        current = downloadingSnapshot(receivedBytes: completedBytes)

        for file in manifest.files {
            if verifies(file, under: candidateDirectory) { continue }
            try removeInvalidCandidate(file)
            let partial = partialURL(for: file)
            let resumeURL = resumeURL(for: file)
            try fileManager.createDirectory(
                at: partial.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let resume = loadResumeState(at: resumeURL)
            let plan = ManagedAssetDownloadPlan(
                sourceURL: manifest.sourceURL(for: file),
                revision: manifest.modelRevision,
                manifestFingerprintSHA256: file.sha256,
                expectedBytes: file.expectedBytes,
                partialFileURL: partial
            )
            let base = completedBytes
            let outcome: ManagedAssetDownloadOutcome
            do {
                outcome = try await transport.download(plan, resume) { [weak self] state in
                    await self?.acceptProgress(baseBytes: base, state: state, resumeURL: resumeURL)
                }
            } catch {
                current = failedSnapshot("download_failed", receivedBytes: stagedBytes())
                throw error
            }

            switch outcome {
            case .completed(let state):
                try persistResumeState(state, at: resumeURL)
                try promotePartial(file, partialURL: partial, resumeURL: resumeURL)
                completedBytes += file.expectedBytes
                current = downloadingSnapshot(receivedBytes: completedBytes)
            case .paused(let state), .interrupted(let state):
                if let state { try persistResumeState(state, at: resumeURL) }
                current = pausedSnapshot(receivedBytes: stagedBytes())
                return current
            case .pausedLowDisk(let state, _, _):
                if let state { try persistResumeState(state, at: resumeURL) }
                current = SpeakerDiarizationModelSnapshot(
                    state: .paused,
                    receivedBytes: stagedBytes(),
                    expectedBytes: manifest.expectedBytes,
                    errorCode: "low_disk"
                )
                return current
            case .cancelled:
                try removeStaging()
                current = .absent(expectedBytes: manifest.expectedBytes)
                return current
            }
        }

        current = SpeakerDiarizationModelSnapshot(
            state: .verifying,
            receivedBytes: manifest.expectedBytes,
            expectedBytes: manifest.expectedBytes,
            errorCode: nil
        )
        guard verifiedBytes(at: candidateDirectory) == manifest.expectedBytes else {
            current = failedSnapshot("verification_failed", receivedBytes: stagedBytes())
            throw SpeakerDiarizationModelStoreError.verificationFailed
        }
        try promoteCandidate()
        current = readySnapshot
        return current
    }

    func suspendAndDrain() async {
        await transport.suspendAndDrain()
        await waitForOperation()
    }

    func resumeAfterDrain() async {
        await transport.resumeAfterDrain()
    }

    func cancel() async throws -> SpeakerDiarizationModelSnapshot {
        await transport.cancelAndDrain()
        await waitForOperation()
        try removeStaging()
        current = isReady() ? readySnapshot : .absent(expectedBytes: manifest.expectedBytes)
        return current
    }

    func remove() throws -> SpeakerDiarizationModelSnapshot {
        guard !operationActive else { throw SpeakerDiarizationModelStoreError.busy }
        do {
            if fileManager.fileExists(atPath: modelDirectory.path) {
                try fileManager.removeItem(at: modelDirectory)
            }
            try removeStaging()
            current = .absent(expectedBytes: manifest.expectedBytes)
            return current
        } catch {
            current = failedSnapshot("removal_failed", receivedBytes: 0)
            throw SpeakerDiarizationModelStoreError.filesystem
        }
    }

    private var modelDirectory: URL {
        root.appendingPathComponent(DiarizationHelperCommand.modelRepositoryDirectory, isDirectory: true)
    }

    private var stagingDirectory: URL { root.appendingPathComponent("staging", isDirectory: true) }

    private var candidateDirectory: URL {
        stagingDirectory
            .appendingPathComponent("candidate", isDirectory: true)
            .appendingPathComponent(DiarizationHelperCommand.modelRepositoryDirectory, isDirectory: true)
    }

    private var downloadsDirectory: URL {
        stagingDirectory.appendingPathComponent("downloads", isDirectory: true)
    }

    private var readySnapshot: SpeakerDiarizationModelSnapshot {
        SpeakerDiarizationModelSnapshot(
            state: .ready,
            receivedBytes: manifest.expectedBytes,
            expectedBytes: manifest.expectedBytes,
            errorCode: nil
        )
    }

    private func downloadingSnapshot(receivedBytes: Int64) -> SpeakerDiarizationModelSnapshot {
        SpeakerDiarizationModelSnapshot(
            state: .downloading,
            receivedBytes: min(receivedBytes, manifest.expectedBytes),
            expectedBytes: manifest.expectedBytes,
            errorCode: nil
        )
    }

    private func pausedSnapshot(receivedBytes: Int64) -> SpeakerDiarizationModelSnapshot {
        SpeakerDiarizationModelSnapshot(
            state: .paused,
            receivedBytes: min(receivedBytes, manifest.expectedBytes),
            expectedBytes: manifest.expectedBytes,
            errorCode: nil
        )
    }

    private func failedSnapshot(_ code: String, receivedBytes: Int64) -> SpeakerDiarizationModelSnapshot {
        SpeakerDiarizationModelSnapshot(
            state: .failed,
            receivedBytes: min(receivedBytes, manifest.expectedBytes),
            expectedBytes: manifest.expectedBytes,
            errorCode: code
        )
    }

    private func prepareDirectories() throws {
        do {
            try fileManager.createDirectory(at: candidateDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        } catch {
            throw SpeakerDiarizationModelStoreError.filesystem
        }
    }

    private func partialURL(for file: SpeakerDiarizationModelFile) -> URL {
        downloadsDirectory.appendingPathComponent(file.relativePath + ".partial")
    }

    private func resumeURL(for file: SpeakerDiarizationModelFile) -> URL {
        downloadsDirectory.appendingPathComponent(file.relativePath + ".resume.json")
    }

    private func verifies(_ file: SpeakerDiarizationModelFile, under directory: URL) -> Bool {
        (try? ManagedAssetVerifier.verifyFile(
            root: directory,
            relativePath: file.relativePath,
            expectedBytes: file.expectedBytes,
            sha256: file.sha256
        )) != nil
    }

    private func verifiedBytes(at directory: URL) -> Int64 {
        (try? SpeakerDiarizationModelVerifier.verify(
            directory: directory,
            manifest: manifest,
            fileManager: fileManager
        )) ?? 0
    }

    private func verifiedCandidateBytes() -> Int64 {
        manifest.files.reduce(0) { total, file in
            total + (verifies(file, under: candidateDirectory) ? file.expectedBytes : 0)
        }
    }

    private func stagedBytes() -> Int64 {
        let completed = verifiedCandidateBytes()
        let partials = manifest.files.reduce(Int64(0)) { total, file in
            total + (loadResumeState(at: resumeURL(for: file))?.receivedBytes ?? 0)
        }
        return min(manifest.expectedBytes, completed + partials)
    }

    private func removeInvalidCandidate(_ file: SpeakerDiarizationModelFile) throws {
        let url = candidateDirectory.appendingPathComponent(file.relativePath)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func promotePartial(
        _ file: SpeakerDiarizationModelFile,
        partialURL: URL,
        resumeURL: URL
    ) throws {
        guard (try? ManagedAssetVerifier.verifyFile(
            root: downloadsDirectory,
            relativePath: String(partialURL.path.dropFirst(downloadsDirectory.path.count + 1)),
            expectedBytes: file.expectedBytes,
            sha256: file.sha256
        )) != nil else {
            try? fileManager.removeItem(at: partialURL)
            current = failedSnapshot("verification_failed", receivedBytes: stagedBytes())
            throw SpeakerDiarizationModelStoreError.verificationFailed
        }
        let destination = candidateDirectory.appendingPathComponent(file.relativePath)
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: partialURL, to: destination)
            try? fileManager.removeItem(at: resumeURL)
        } catch {
            throw SpeakerDiarizationModelStoreError.filesystem
        }
    }

    private func promoteCandidate() throws {
        let previous = root.appendingPathComponent("speaker-diarization.previous", isDirectory: true)
        do {
            if fileManager.fileExists(atPath: previous.path) { try fileManager.removeItem(at: previous) }
            if fileManager.fileExists(atPath: modelDirectory.path) {
                try fileManager.moveItem(at: modelDirectory, to: previous)
            }
            do {
                try fileManager.moveItem(at: candidateDirectory, to: modelDirectory)
            } catch {
                if fileManager.fileExists(atPath: previous.path) {
                    try? fileManager.moveItem(at: previous, to: modelDirectory)
                }
                throw SpeakerDiarizationModelStoreError.filesystem
            }
            guard verifiedBytes(at: modelDirectory) == manifest.expectedBytes else {
                try? fileManager.removeItem(at: modelDirectory)
                if fileManager.fileExists(atPath: previous.path) {
                    try? fileManager.moveItem(at: previous, to: modelDirectory)
                }
                throw SpeakerDiarizationModelStoreError.verificationFailed
            }
            if fileManager.fileExists(atPath: previous.path) { try fileManager.removeItem(at: previous) }
            if fileManager.fileExists(atPath: stagingDirectory.path) {
                try fileManager.removeItem(at: stagingDirectory)
            }
        } catch let error as SpeakerDiarizationModelStoreError {
            throw error
        } catch {
            throw SpeakerDiarizationModelStoreError.filesystem
        }
    }

    private func loadResumeState(at url: URL) -> ManagedAssetDownloadResumeState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ManagedAssetDownloadResumeState.self, from: data)
    }

    private func persistResumeState(_ state: ManagedAssetDownloadResumeState, at url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    private func acceptProgress(
        baseBytes: Int64,
        state: ManagedAssetDownloadResumeState,
        resumeURL: URL
    ) {
        try? persistResumeState(state, at: resumeURL)
        current = downloadingSnapshot(receivedBytes: baseBytes + state.receivedBytes)
    }

    private func removeStaging() throws {
        if fileManager.fileExists(atPath: stagingDirectory.path) {
            try fileManager.removeItem(at: stagingDirectory)
        }
    }

    private func waitForOperation() async {
        guard operationActive else { return }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func finishOperation() {
        operationActive = false
        let waiters = operationWaiters
        operationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }
}
