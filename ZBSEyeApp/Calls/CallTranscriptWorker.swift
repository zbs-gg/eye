import Darwin
import Foundation

enum CallTranscriptWorkerRunResult: Sendable, Equatable {
    case suspended
    case modelUnavailable
    case idle
    case completed(jobID: Int64, final: Bool)
    case retryScheduled(jobID: Int64, errorCode: String)
    case failed(jobID: Int64, errorCode: String)
}

enum CallTranscriptWorkerError: Error, Sendable, Equatable {
    case invalidEvidence
    case invalidHelperResult
    case helperFailed
}

enum CallTranscriptBackend: Sendable, Equatable {
    case builtIn(WhisperModelManifest)
    case handy(HandySpeechBackendReference)

    var modelRelativePath: String {
        switch self {
        case let .builtIn(manifest): "ai/speech/v1/\(manifest.relativePath)"
        case .handy: "external/handy"
        }
    }

    var modelIdentitySHA256: String {
        switch self {
        case let .builtIn(manifest): manifest.sha256
        case let .handy(reference): reference.identitySHA256
        }
    }

    var runtimeRelease: String {
        switch self {
        case let .builtIn(manifest): manifest.runtimeRelease
        case let .handy(reference): reference.runtimeRelease
        }
    }

    var engine: String {
        switch self {
        case .builtIn: "whisper.cpp"
        case .handy: "handy/transcribe-cpp"
        }
    }

    var modelRevision: String {
        switch self {
        case let .builtIn(manifest): manifest.revision
        case let .handy(reference): reference.modelID
        }
    }

    var handyReference: HandySpeechBackendReference? {
        guard case let .handy(reference) = self else { return nil }
        return reference
    }
}

/// Serial durable-job executor. Audio capture never calls into this actor: it
/// consumes only immutable, finalized spool ranges after their DB watermarks
/// have been frozen.
actor CallTranscriptWorker {
    typealias ModelReadiness = @Sendable () async -> Bool
    typealias BackendProvider = @Sendable () async -> CallTranscriptBackend?
    typealias HelperLauncher = @Sendable (
        _ manifest: WhisperHelperJobManifest,
        _ manifestRelativePath: String,
        _ dataRoot: URL
    ) async throws -> WhisperHelperResult
    typealias HelperCancellation = @Sendable () -> Void

    private static let maximumRangeBytes: Int64 = 16 * 1_024 * 1_024
    private static let pcmSampleRate: Int64 = 16_000
    private static let bytesPerSample: Int64 = 2

    private let repository: CallRepository
    private let computeCoordinator: AIComputeCoordinator
    private let dataRoot: URL
    private let modelManifest: WhisperModelManifest
    private let backendProvider: BackendProvider
    private let helperLauncher: HelperLauncher
    private let cancelHelper: HelperCancellation
    private let afterSourceTransition: @Sendable () async -> Void
    private var suspended = false
    private var activeOperation: Task<CallTranscriptWorkerRunResult, Never>?

    init(
        repository: CallRepository,
        computeCoordinator: AIComputeCoordinator,
        dataRoot: URL,
        modelManifest: WhisperModelManifest = .largeV3Turbo,
        modelReadiness: @escaping ModelReadiness,
        helperLauncher: @escaping HelperLauncher,
        cancelHelper: @escaping HelperCancellation,
        afterSourceTransition: @escaping @Sendable () async -> Void = {}
    ) {
        self.repository = repository
        self.computeCoordinator = computeCoordinator
        self.dataRoot = dataRoot.standardizedFileURL
        self.modelManifest = modelManifest
        backendProvider = {
            await modelReadiness() ? .builtIn(modelManifest) : nil
        }
        self.helperLauncher = helperLauncher
        self.cancelHelper = cancelHelper
        self.afterSourceTransition = afterSourceTransition
    }

    init(
        repository: CallRepository,
        computeCoordinator: AIComputeCoordinator,
        dataRoot: URL,
        modelStore: WhisperModelStore,
        handyModelStore: HandySpeechModelStore,
        modelManifest: WhisperModelManifest = .largeV3Turbo,
        executablePath: String = Bundle.main.executableURL?.path ?? CommandLine.arguments[0],
        afterSourceTransition: @escaping @Sendable () async -> Void = {}
    ) {
        let builtInRunner = WhisperHelperProcessRunner(executablePath: executablePath)
        self.repository = repository
        self.computeCoordinator = computeCoordinator
        self.dataRoot = dataRoot.standardizedFileURL
        self.modelManifest = modelManifest
        backendProvider = {
            if await modelStore.snapshot().state == .ready {
                return .builtIn(modelManifest)
            }
            let external = await handyModelStore.snapshot()
            guard external.state == .ready, let reference = external.backend else { return nil }
            return .handy(reference)
        }
        helperLauncher = { manifest, relativePath, root in
            return try await builtInRunner.run(
                manifest: manifest,
                manifestRelativePath: relativePath,
                dataRoot: root
            )
        }
        cancelHelper = {
            builtInRunner.cancel()
        }
        self.afterSourceTransition = afterSourceTransition
    }

    func runOne(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) async
        -> CallTranscriptWorkerRunResult {
        guard !suspended else { return .suspended }
        if let activeOperation { return await activeOperation.value }

        let operation = Task { [weak self] in
            guard let self else { return CallTranscriptWorkerRunResult.suspended }
            return await self.performOne(nowMs: nowMs)
        }
        activeOperation = operation
        let result = await operation.value
        if activeOperation != nil { activeOperation = nil }
        return result
    }

    func runLoop() async {
        while !Task.isCancelled {
            let result = await runOne()
            switch result {
            case .completed, .failed:
                await afterSourceTransition()
            default:
                break
            }
            let finalWaiting: Bool
            switch result {
            case .retryScheduled, .failed:
                finalWaiting = await repository.hasClaimableFinalTranscriptJob()
            default:
                finalWaiting = false
            }
            let delay = Self.loopDelay(after: result, finalWaiting: finalWaiting)
            try? await Task.sleep(for: delay)
        }
    }

    static func loopDelay(
        after result: CallTranscriptWorkerRunResult,
        finalWaiting: Bool
    ) -> Duration {
        switch result {
        case .completed:
            return .milliseconds(100)
        case .retryScheduled:
            return finalWaiting ? .seconds(1) : .seconds(10)
        case .failed:
            return finalWaiting ? .milliseconds(100) : .seconds(30)
        case .idle, .modelUnavailable, .suspended:
            return .seconds(5)
        }
    }

    func suspendAndDrain() async {
        _ = await suspendAndDrainForEvidenceMutation()
    }

    /// Returns true only to the caller that changed the worker from running to
    /// suspended. That caller may resume after its mutation gate is clear;
    /// nested maintenance must leave an already-suspended worker alone.
    func suspendAndDrainForEvidenceMutation() async -> Bool {
        let ownsResume = !suspended
        suspended = true
        cancelHelper()
        guard let operation = activeOperation else { return ownsResume }
        operation.cancel()
        _ = await operation.value
        if activeOperation != nil { activeOperation = nil }
        return ownsResume
    }

    func resume() {
        suspended = false
    }

    private func performOne(nowMs: Int64) async -> CallTranscriptWorkerRunResult {
        guard !suspended, !Task.isCancelled else { return .suspended }
        guard let backend = await backendProvider() else { return .modelUnavailable }

        let lease: AIComputeLease
        do {
            lease = try await computeCoordinator.acquireSpeech()
        } catch {
            return .suspended
        }

        var claimedJobID: Int64?
        do {
            try Task.checkCancellation()
            guard let job = try await repository.claimNextTranscriptJob(nowMs: nowMs),
                  let jobID = job.id else {
                await lease.release()
                return .idle
            }
            claimedJobID = jobID
            let evidence = try await repository.transcriptJobEvidence(jobID: jobID)
            let ranges = try Self.plannedAudioRanges(evidence: evidence)

            let converted: [CallTranscriptSegmentDraft]
            if ranges.isEmpty {
                converted = []
            } else {
                try Task.checkCancellation()
                let result = try await runHelperBatch(
                    ranges,
                    evidence: evidence,
                    backend: backend
                )
                converted = try Self.validateAndConvert(
                    result: result,
                    ranges: ranges,
                    evidence: evidence,
                    backend: backend
                )
            }
            try Task.checkCancellation()
            let segments = [CallAudioSource.me, .system].flatMap { source in
                TranscriptOverlapReconciler.reconcile(
                    committed: [],
                    incoming: converted.filter { $0.source == source },
                    logicalStartMs: job.logicalStartMs,
                    logicalEndMs: job.logicalEndMs
                )
            }.sorted(by: Self.segmentOrder)
            let degraded = evidence.call.degradationReason != nil || ranges.isEmpty
            let commit = try await repository.commitTranscriptJob(
                jobID: jobID,
                segments: segments,
                language: "und",
                engine: backend.engine,
                modelRevision: backend.modelRevision,
                degraded: degraded,
                nowMs: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            await lease.release()
            return .completed(jobID: jobID, final: commit.final)
        } catch {
            await lease.release()
            guard let jobID = claimedJobID else { return .idle }
            let disposition = Self.failureDisposition(for: error)
            let failureTime = Int64(Date().timeIntervalSince1970 * 1_000)
            let persistedState = await Self.persistFailureState(
                repository: repository,
                jobID: jobID,
                code: disposition.code,
                retryable: disposition.retryable,
                nowMs: failureTime
            )
            guard let persistedState else {
                return .failed(jobID: jobID, errorCode: "state_persist_failed")
            }
            return persistedState == .pending
                ? .retryScheduled(jobID: jobID, errorCode: disposition.code)
                : .failed(jobID: jobID, errorCode: disposition.code)
        }
    }

    private nonisolated static func persistFailureState(
        repository: CallRepository,
        jobID: Int64,
        code: String,
        retryable: Bool,
        nowMs: Int64
    ) async -> CallTranscriptJobState? {
        await Task.detached(priority: .utility) {
            for attempt in 0..<3 {
                do {
                    return try await repository.failTranscriptJob(
                        jobID: jobID,
                        errorCode: code,
                        retryable: retryable,
                        nowMs: nowMs
                    )
                } catch {
                    guard attempt < 2 else { return nil }
                    try? await Task.sleep(for: .milliseconds(100 * (attempt + 1)))
                }
            }
            return nil
        }.value
    }

    private func runHelperBatch(
        _ ranges: [WhisperHelperAudioRange],
        evidence: CallTranscriptJobEvidence,
        backend: CallTranscriptBackend
    ) async throws -> WhisperHelperResult {
        let helperID = UUID().uuidString.lowercased()
        let scratch = CallHelperScratchStore(dataRoot: dataRoot)
        do {
            try scratch.prepareForJob(helperID)
        } catch {
            throw CallTranscriptWorkerError.invalidEvidence
        }
        let jobRoot = "call-helper/jobs/\(helperID)"
        let manifestRelativePath = "\(jobRoot)/manifest.json"
        let resultRelativePath = "\(jobRoot)/result.json"
        let jobDirectory: URL
        let manifestURL: URL
        do {
            jobDirectory = try ManagedAssetVerifier.containedURL(
                root: dataRoot,
                relativePath: jobRoot
            )
            manifestURL = try ManagedAssetVerifier.containedURL(
                root: dataRoot,
                relativePath: manifestRelativePath
            )
        } catch {
            throw CallTranscriptWorkerError.invalidEvidence
        }
        try FileManager.default.createDirectory(
            at: jobDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: jobDirectory) }

        let manifest = WhisperHelperJobManifest(
            formatVersion: 1,
            jobID: helperID,
            callID: evidence.call.id ?? evidence.job.callId,
            callGeneration: evidence.job.mediaGeneration,
            modelRelativePath: backend.modelRelativePath,
            modelSHA256: backend.modelIdentitySHA256,
            handyBackend: backend.handyReference,
            resultRelativePath: resultRelativePath,
            audioRanges: ranges
        )
        do {
            let encoded = try JSONEncoder().encode(manifest)
            try encoded.write(to: manifestURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: manifestURL.path
            )
        } catch {
            throw CallTranscriptWorkerError.invalidEvidence
        }
        let result = try await helperLauncher(manifest, manifestRelativePath, dataRoot)
        guard (try? scratch.inventory().bytes).map({
            $0 <= CallHelperScratchStore.maximumGlobalBytes
        }) == true else {
            throw CallTranscriptWorkerError.invalidHelperResult
        }
        guard result.jobID == helperID else {
            throw CallTranscriptWorkerError.invalidHelperResult
        }
        return result
    }

    static func plannedAudioRanges(
        evidence: CallTranscriptJobEvidence
    ) throws -> [WhisperHelperAudioRange] {
        guard evidence.call.id == evidence.job.callId,
              evidence.call.mediaGeneration == evidence.job.mediaGeneration,
              evidence.job.coverageFrozen else {
            throw CallTranscriptWorkerError.invalidEvidence
        }
        let lowerBoundMs = evidence.job.kind == .checkpoint
            ? evidence.job.contextStartMs
            : evidence.job.logicalStartMs
        let upperBoundMs = evidence.job.logicalEndMs
        guard lowerBoundMs <= upperBoundMs else {
            throw CallTranscriptWorkerError.invalidEvidence
        }

        let sortedChunks = evidence.chunks.sorted {
            ($0.source.rawValue, $0.epoch, $0.sequence)
                < ($1.source.rawValue, $1.epoch, $1.sequence)
        }
        var planned: [WhisperHelperAudioRange] = []
        for chunk in sortedChunks {
            guard chunk.callId == evidence.job.callId,
                  chunk.mediaGeneration == evidence.job.mediaGeneration,
                  chunk.bytes > 0,
                  chunk.relativePath.hasPrefix("calls/") else {
                throw CallTranscriptWorkerError.invalidEvidence
            }
            let watermark = switch chunk.source {
            case .me: evidence.job.meEndSample
            case .system: evidence.job.systemEndSample
            }
            guard let watermark, watermark > chunk.startSample else { continue }

            let timeStartMs = max(lowerBoundMs, chunk.startMs)
            let timeEndMs = min(upperBoundMs, chunk.endMs)
            guard timeStartMs < timeEndMs else { continue }
            let startFromTime = chunk.startSample
                + ((timeStartMs - chunk.startMs) * pcmSampleRate / 1_000)
            let endFromTime = chunk.startSample
                + ((timeEndMs - chunk.startMs) * pcmSampleRate / 1_000)
            let startSample = max(chunk.startSample, startFromTime)
            let endSample = min(chunk.endSample, endFromTime, watermark)
            guard endSample > startSample else { continue }

            let offsetBytes = (startSample - chunk.startSample) * bytesPerSample
            let maximumByMetadata = min(
                (endSample - startSample) * bytesPerSample,
                chunk.bytes - offsetBytes
            )
            guard offsetBytes >= 0,
                  maximumByMetadata > 0,
                  maximumByMetadata.isMultiple(of: bytesPerSample) else {
                throw CallTranscriptWorkerError.invalidEvidence
            }
            let absoluteStartMs = chunk.startMs
                + ((startSample - chunk.startSample) * 1_000 / pcmSampleRate)
            let callRelativeStartSample = max(
                0,
                (absoluteStartMs - evidence.call.startTs) * pcmSampleRate / 1_000
            )
            var consumed: Int64 = 0
            while consumed < maximumByMetadata {
                let length = min(maximumRangeBytes, maximumByMetadata - consumed)
                planned.append(
                    WhisperHelperAudioRange(
                        source: chunk.source,
                        relativePath: "media/\(chunk.relativePath)",
                        offsetBytes: offsetBytes + consumed,
                        lengthBytes: length,
                        sampleRate: Int(pcmSampleRate),
                        startSample: callRelativeStartSample + consumed / bytesPerSample
                    )
                )
                consumed += length
            }
        }
        return planned
    }

    private static func validateAndConvert(
        result: WhisperHelperResult,
        ranges: [WhisperHelperAudioRange],
        evidence: CallTranscriptJobEvidence,
        backend: CallTranscriptBackend
    ) throws -> [CallTranscriptSegmentDraft] {
        guard result.formatVersion == 1,
              UUID(uuidString: result.jobID)?.uuidString.lowercased() == result.jobID,
              result.callID == evidence.job.callId,
              result.callGeneration == evidence.job.mediaGeneration,
              result.modelSHA256 == backend.modelIdentitySHA256,
              result.runtimeRelease == backend.runtimeRelease,
              result.segments.count <= 100_000 else {
            throw CallTranscriptWorkerError.invalidHelperResult
        }

        var bounds: [CallAudioSource: (Double, Double)] = [:]
        for range in ranges {
            let start = Double(range.startSample) / Double(range.sampleRate)
            let end = start
                + Double(range.lengthBytes / bytesPerSample) / Double(range.sampleRate)
            if let existing = bounds[range.source] {
                bounds[range.source] = (min(existing.0, start), max(existing.1, end))
            } else {
                bounds[range.source] = (start, end)
            }
        }

        return try result.segments.map { segment in
            guard segment.startSeconds.isFinite,
                  segment.endSeconds.isFinite,
                  segment.startSeconds >= 0,
                  segment.endSeconds >= segment.startSeconds,
                  let sourceBounds = bounds[segment.source],
                  segment.startSeconds >= sourceBounds.0 - 1,
                  segment.endSeconds <= sourceBounds.1 + 1,
                  segment.text.utf8.count <= 1_000_000 else {
                throw CallTranscriptWorkerError.invalidHelperResult
            }
            return CallTranscriptSegmentDraft(
                source: segment.source,
                startMs: evidence.call.startTs + Int64((segment.startSeconds * 1_000).rounded()),
                endMs: evidence.call.startTs + Int64((segment.endSeconds * 1_000).rounded()),
                text: segment.text
            )
        }.sorted(by: segmentOrder)
    }

    private static func segmentOrder(
        _ lhs: CallTranscriptSegmentDraft,
        _ rhs: CallTranscriptSegmentDraft
    ) -> Bool {
        (lhs.startMs, lhs.endMs, lhs.source.rawValue, lhs.text)
            < (rhs.startMs, rhs.endMs, rhs.source.rawValue, rhs.text)
    }

    private static func failureDisposition(for error: Error) -> (code: String, retryable: Bool) {
        if error is CancellationError { return ("helper_cancelled", true) }
        if let workerError = error as? CallTranscriptWorkerError {
            switch workerError {
            case .invalidEvidence: return ("invalid_evidence", false)
            case .invalidHelperResult: return ("invalid_helper_result", false)
            case .helperFailed: return ("helper_failed", true)
            }
        }
        return ("helper_failed", true)
    }
}

/// `Process` is intentionally contained behind a lock-owned, cancellable
/// bridge. No shell is involved and stdout/stderr never carry transcript data.
final class WhisperHelperProcessRunner: @unchecked Sendable {
    static let maximumRuntime: Duration = .seconds(20 * 60)
    private let executablePath: String
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false

    init(executablePath: String) {
        self.executablePath = executablePath
    }

    func run(
        manifest: WhisperHelperJobManifest,
        manifestRelativePath: String,
        dataRoot: URL
    ) async throws -> WhisperHelperResult {
        prepareRun()
        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority: .utility) { [self] in
                let child = Process()
                child.executableURL = URL(fileURLWithPath: executablePath)
                child.arguments = [WhisperHelperCommand.flag, manifestRelativePath]
                child.standardOutput = FileHandle.nullDevice
                child.standardError = FileHandle.nullDevice

                try launch(child)
                defer { clear(child) }
                try await Self.waitForExit(child)
                guard child.terminationStatus == 0 else {
                    throw CallTranscriptWorkerError.helperFailed
                }
                let resultURL = dataRoot.appendingPathComponent(manifest.resultRelativePath)
                guard let size = try? resultURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size > 0,
                      size <= WhisperHelperCommand.maximumResultBytes,
                      let data = try? Data(contentsOf: resultURL),
                      let decoded = try? JSONDecoder().decode(WhisperHelperResult.self, from: data) else {
                    throw CallTranscriptWorkerError.invalidHelperResult
                }
                return decoded
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: { [self] in
            cancel()
        }
    }

    func cancel() {
        let child = lock.withLock { () -> Process? in
            cancellationRequested = true
            return process
        }
        if let child { Self.forceTerminate(child) }
    }

    private func prepareRun() {
        lock.withLock { cancellationRequested = false }
    }

    private func launch(_ child: Process) throws {
        try lock.withLock {
            guard !cancellationRequested else { throw CancellationError() }
            process = child
            do {
                try child.run()
            } catch {
                process = nil
                throw CallTranscriptWorkerError.helperFailed
            }
        }
    }

    private func clear(_ child: Process) {
        lock.withLock {
            if process === child { process = nil }
        }
    }

    private static func waitForExit(_ child: Process) async throws {
        let deadline = ContinuousClock.now.advanced(by: maximumRuntime)
        while child.isRunning {
            if ContinuousClock.now >= deadline {
                forceTerminate(child)
                child.waitUntilExit()
                throw CallTranscriptWorkerError.helperFailed
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func forceTerminate(_ child: Process) {
        guard child.isRunning else { return }
        child.terminate()
        if child.isRunning, child.processIdentifier > 0 {
            _ = Darwin.kill(child.processIdentifier, SIGKILL)
        }
    }
}
