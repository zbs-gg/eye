import Foundation
import ZBSEyeWhisper

enum WhisperModelLifecycleState: String, Codable, Sendable, Equatable {
    case absent
    case downloading
    case paused
    case verifying
    case ready
    case failed
}

struct WhisperModelSnapshot: Codable, Sendable, Equatable {
    let state: WhisperModelLifecycleState
    let receivedBytes: Int64
    let expectedBytes: Int64
    let errorCode: String?

    static func absent(expectedBytes: Int64) -> WhisperModelSnapshot {
        WhisperModelSnapshot(
            state: .absent,
            receivedBytes: 0,
            expectedBytes: expectedBytes,
            errorCode: nil
        )
    }
}

struct WhisperModelInstallation: Codable, Sendable, Equatable {
    let manifestID: String
    let revision: String
    let sha256: String
    let expectedBytes: Int64
    let runtimeRelease: String
}

enum WhisperModelStoreError: Error, LocalizedError, Sendable, Equatable {
    case busy
    case downloadIncomplete
    case verificationFailed
    case smokeTestFailed
    case filesystem

    var errorDescription: String? {
        switch self {
        case .busy: "A Whisper model operation is already running."
        case .downloadIncomplete: "The Whisper model download is incomplete."
        case .verificationFailed: "The Whisper model failed integrity verification."
        case .smokeTestFailed: "Whisper could not load the verified model."
        case .filesystem: "The Whisper model could not be stored safely."
        }
    }
}

/// Speech-specific lifecycle built on the shared hardened asset transport.
/// It never activates or mutates an AI provider and never contacts the network
/// after a model reaches `ready`.
actor WhisperModelStore {
    typealias SmokeTest = @Sendable (URL) throws -> Void

    static let allowedAssetHosts: Set<String> = [
        "huggingface.co",
        "cas-bridge.xethub.hf.co",
        "us.aws.cdn.hf.co",
    ]

    private let root: URL
    private let manifest: WhisperModelManifest
    private let downloadClient: ManagedAssetDownloadClient
    private let smokeTest: SmokeTest
    private let fileManager: FileManager
    private var operationActive = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var current: WhisperModelSnapshot

    init(
        root: URL,
        manifest: WhisperModelManifest = .largeV3Turbo,
        downloadClient: ManagedAssetDownloadClient? = nil,
        fileManager: FileManager = .default,
        smokeTest: SmokeTest? = nil
    ) {
        self.root = root.standardizedFileURL
        self.manifest = manifest
        self.fileManager = fileManager
        self.smokeTest = smokeTest ?? { _ in
            try WhisperModelSmokeTester.run()
        }
        current = .absent(expectedBytes: manifest.expectedBytes)
        self.downloadClient = downloadClient ?? ManagedAssetDownloadClient(
            allowedAssetHosts: Self.allowedAssetHosts,
            capacityCheck: { progress in
                let available = (try? root.resourceValues(
                    forKeys: [.volumeAvailableCapacityForImportantUsageKey]
                ).volumeAvailableCapacityForImportantUsage).flatMap { $0 } ?? 0
                let reserve: Int64 = 2 * 1_024 * 1_024 * 1_024
                let required = max(0, progress.remainingBytes) + reserve
                return Int64(available) >= required
                    ? .sufficient
                    : .insufficient(requiredBytes: required, availableBytes: Int64(available))
            }
        )
    }

    func snapshot() -> WhisperModelSnapshot { current }

    func refresh() async -> WhisperModelSnapshot {
        guard !operationActive else { return current }
        do {
            let marker = try JSONDecoder().decode(
                WhisperModelInstallation.self,
                from: Data(contentsOf: markerURL)
            )
            guard marker == installation else { throw WhisperModelStoreError.verificationFailed }
            _ = try ManagedAssetVerifier.verifyFile(
                root: root,
                relativePath: manifest.relativePath,
                expectedBytes: manifest.expectedBytes,
                sha256: manifest.sha256
            )
            current = WhisperModelSnapshot(
                state: .ready,
                receivedBytes: manifest.expectedBytes,
                expectedBytes: manifest.expectedBytes,
                errorCode: nil
            )
        } catch {
            current = resumeSnapshot() ?? .absent(expectedBytes: manifest.expectedBytes)
        }
        return current
    }

    func install() async throws -> WhisperModelSnapshot {
        guard !operationActive else { throw WhisperModelStoreError.busy }
        operationActive = true
        defer { finishOperation() }
        try prepareDirectories()

        let resume = loadResumeState()
        current = WhisperModelSnapshot(
            state: .downloading,
            receivedBytes: resume?.receivedBytes ?? 0,
            expectedBytes: manifest.expectedBytes,
            errorCode: nil
        )
        let plan = ManagedAssetDownloadPlan(
            sourceURL: manifest.sourceURL,
            revision: manifest.revision,
            manifestFingerprintSHA256: manifest.sha256,
            expectedBytes: manifest.expectedBytes,
            partialFileURL: partialURL
        )

        let outcome: ManagedAssetDownloadOutcome
        do {
            outcome = try await downloadClient.download(
                plan: plan,
                resumeState: resume,
                onProgress: { [weak self] state in
                    await self?.acceptProgress(state)
                }
            )
        } catch {
            current = WhisperModelSnapshot(
                state: .failed,
                receivedBytes: loadResumeState()?.receivedBytes ?? 0,
                expectedBytes: manifest.expectedBytes,
                errorCode: "download_failed"
            )
            throw error
        }

        switch outcome {
        case .completed(let state):
            try persistResumeState(state)
            return try promoteVerifiedPartial()
        case .paused(let state), .interrupted(let state):
            if let state { try persistResumeState(state) }
            current = pausedSnapshot(state)
            return current
        case .pausedLowDisk(let state, _, _):
            if let state { try persistResumeState(state) }
            current = WhisperModelSnapshot(
                state: .paused,
                receivedBytes: state?.receivedBytes ?? 0,
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

    func cancel() async throws -> WhisperModelSnapshot {
        _ = await downloadClient.cancelAndDrain()
        await waitForOperation()
        try removeStaging()
        current = .absent(expectedBytes: manifest.expectedBytes)
        return current
    }

    func suspendAndDrain() async {
        _ = await downloadClient.suspendAndDrain()
        await waitForOperation()
    }

    func resumeAfterDrain() async {
        await downloadClient.resumeAfterDrain()
    }

    func remove() throws -> WhisperModelSnapshot {
        guard !operationActive else { throw WhisperModelStoreError.busy }
        do {
            if fileManager.fileExists(atPath: modelDirectory.path) {
                try fileManager.removeItem(at: modelDirectory)
            }
            if fileManager.fileExists(atPath: stagingDirectory.path) {
                try fileManager.removeItem(at: stagingDirectory)
            }
            if fileManager.fileExists(atPath: markerURL.path) {
                try fileManager.removeItem(at: markerURL)
            }
            guard !fileManager.fileExists(atPath: modelDirectory.path),
                  !fileManager.fileExists(atPath: stagingDirectory.path),
                  !fileManager.fileExists(atPath: markerURL.path) else {
                throw WhisperModelStoreError.filesystem
            }
            current = .absent(expectedBytes: manifest.expectedBytes)
            return current
        } catch {
            current = failed("removal_failed")
            throw WhisperModelStoreError.filesystem
        }
    }

    private var stagingDirectory: URL {
        root.appendingPathComponent("staging", isDirectory: true)
    }

    private var partialURL: URL {
        stagingDirectory.appendingPathComponent("model.partial")
    }

    private var resumeURL: URL {
        stagingDirectory.appendingPathComponent("resume.json")
    }

    private var markerURL: URL {
        root.appendingPathComponent("installation.json")
    }

    private var modelDirectory: URL {
        root.appendingPathComponent("model", isDirectory: true)
    }

    private var modelURL: URL {
        root.appendingPathComponent(manifest.relativePath)
    }

    private var installation: WhisperModelInstallation {
        WhisperModelInstallation(
            manifestID: manifest.id,
            revision: manifest.revision,
            sha256: manifest.sha256,
            expectedBytes: manifest.expectedBytes,
            runtimeRelease: manifest.runtimeRelease
        )
    }

    private func prepareDirectories() throws {
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        } catch {
            throw WhisperModelStoreError.filesystem
        }
    }

    private func promoteVerifiedPartial() throws -> WhisperModelSnapshot {
        current = WhisperModelSnapshot(
            state: .verifying,
            receivedBytes: manifest.expectedBytes,
            expectedBytes: manifest.expectedBytes,
            errorCode: nil
        )
        do {
            _ = try ManagedAssetVerifier.verifyFile(
                root: stagingDirectory,
                relativePath: "model.partial",
                expectedBytes: manifest.expectedBytes,
                sha256: manifest.sha256
            )
        } catch {
            try? removeStaging()
            current = failed("verification_failed")
            throw WhisperModelStoreError.verificationFailed
        }
        do {
            try smokeTest(partialURL)
        } catch {
            current = failed("smoke_failed")
            throw WhisperModelStoreError.smokeTestFailed
        }

        do {
            try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: modelURL.path) {
                _ = try fileManager.replaceItemAt(modelURL, withItemAt: partialURL)
            } else {
                try fileManager.moveItem(at: partialURL, to: modelURL)
            }
            try JSONEncoder().encode(installation).write(to: markerURL, options: .atomic)
            try? fileManager.removeItem(at: resumeURL)
        } catch {
            current = failed("promotion_failed")
            throw WhisperModelStoreError.filesystem
        }
        current = WhisperModelSnapshot(
            state: .ready,
            receivedBytes: manifest.expectedBytes,
            expectedBytes: manifest.expectedBytes,
            errorCode: nil
        )
        return current
    }

    private func acceptProgress(_ state: ManagedAssetDownloadResumeState) async {
        try? persistResumeState(state)
        current = WhisperModelSnapshot(
            state: .downloading,
            receivedBytes: state.receivedBytes,
            expectedBytes: manifest.expectedBytes,
            errorCode: nil
        )
    }

    private func loadResumeState() -> ManagedAssetDownloadResumeState? {
        guard let data = try? Data(contentsOf: resumeURL) else { return nil }
        return try? JSONDecoder().decode(ManagedAssetDownloadResumeState.self, from: data)
    }

    private func persistResumeState(_ state: ManagedAssetDownloadResumeState) throws {
        try prepareDirectories()
        try JSONEncoder().encode(state).write(to: resumeURL, options: .atomic)
    }

    private func resumeSnapshot() -> WhisperModelSnapshot? {
        guard let state = loadResumeState() else { return nil }
        return pausedSnapshot(state)
    }

    private func pausedSnapshot(_ state: ManagedAssetDownloadResumeState?) -> WhisperModelSnapshot {
        WhisperModelSnapshot(
            state: .paused,
            receivedBytes: state?.receivedBytes ?? 0,
            expectedBytes: manifest.expectedBytes,
            errorCode: nil
        )
    }

    private func failed(_ code: String) -> WhisperModelSnapshot {
        WhisperModelSnapshot(
            state: .failed,
            receivedBytes: loadResumeState()?.receivedBytes ?? 0,
            expectedBytes: manifest.expectedBytes,
            errorCode: code
        )
    }

    private func removeStaging() throws {
        if fileManager.fileExists(atPath: stagingDirectory.path) {
            try fileManager.removeItem(at: stagingDirectory)
        }
    }

    private func waitForOperation() async {
        guard operationActive else { return }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func finishOperation() {
        operationActive = false
        let waiters = operationWaiters
        operationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }
}

enum WhisperModelSmokeTester {
    static func run() throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw WhisperModelStoreError.smokeTestFailed
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            WhisperModelSmokeCommand.flag,
            WhisperModelSmokeCommand.expectedRelativePath,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw WhisperModelStoreError.smokeTestFailed
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw WhisperModelStoreError.smokeTestFailed
        }
    }
}
