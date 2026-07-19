import Darwin
import Foundation

enum SpeakerDiarizationWorkerRunResult: Sendable, Equatable {
    case suspended
    case modelUnavailable
    case idle
    case completed(callID: Int64, revisionID: Int64)
    case failed(callID: Int64, errorCode: String)
}

enum SpeakerDiarizationWorkerError: Error, Sendable, Equatable {
    case invalidEvidence
    case invalidHelperResult
    case helperFailed
}

/// Combines independent post-processing workers behind the deletion service's
/// one suspend/resume hook without accidentally reopening a worker that was
/// already suspended by model maintenance or low-disk admission.
actor CallEvidenceWorkerBarrier {
    struct Worker: Sendable {
        let suspend: @Sendable () async -> Bool
        let resume: @Sendable () async -> Void
    }

    private let workers: [Worker]
    private var ownedIndices: [Int] = []

    init(workers: [Worker]) {
        self.workers = workers
    }

    func suspend() async -> Bool {
        ownedIndices.removeAll(keepingCapacity: true)
        for (index, worker) in workers.enumerated() where await worker.suspend() {
            ownedIndices.append(index)
        }
        return !ownedIndices.isEmpty
    }

    func resume() async {
        let indices = ownedIndices
        ownedIndices.removeAll(keepingCapacity: true)
        for index in indices {
            await workers[index].resume()
        }
    }
}

/// Serial post-processing worker. It never sees live capture buffers and it
/// never downloads a model: only a checksum-verified optional installation can
/// admit a helper job.
actor SpeakerDiarizationWorker {
    typealias ModelReadiness = @Sendable () async -> Bool
    typealias HelperLauncher = @Sendable (
        _ manifest: DiarizationHelperJobManifest,
        _ manifestRelativePath: String,
        _ dataRoot: URL
    ) async throws -> DiarizationHelperResult
    typealias HelperCancellation = @Sendable () -> Void

    private static let pcmSampleRate: Int64 = 16_000
    private static let bytesPerSample: Int64 = 2
    private static let maximumRangeBytes: Int64 = 16 * 1_024 * 1_024

    private let repository: CallRepository
    private let computeCoordinator: AIComputeCoordinator
    private let dataRoot: URL
    private let modelManifest: SpeakerDiarizationModelManifest
    private let modelReadiness: ModelReadiness
    private let helperLauncher: HelperLauncher
    private let cancelHelper: HelperCancellation
    private let afterTransition: @Sendable () async -> Void
    private var suspended = false
    private var activeOperation: Task<SpeakerDiarizationWorkerRunResult, Never>?
    private var failedEvidence: Set<String> = []

    init(
        repository: CallRepository,
        computeCoordinator: AIComputeCoordinator,
        dataRoot: URL,
        modelManifest: SpeakerDiarizationModelManifest = .fluidAudio0155,
        modelReadiness: @escaping ModelReadiness,
        helperLauncher: @escaping HelperLauncher,
        cancelHelper: @escaping HelperCancellation,
        afterTransition: @escaping @Sendable () async -> Void = {}
    ) {
        self.repository = repository
        self.computeCoordinator = computeCoordinator
        self.dataRoot = dataRoot.standardizedFileURL
        self.modelManifest = modelManifest
        self.modelReadiness = modelReadiness
        self.helperLauncher = helperLauncher
        self.cancelHelper = cancelHelper
        self.afterTransition = afterTransition
    }

    init(
        repository: CallRepository,
        computeCoordinator: AIComputeCoordinator,
        dataRoot: URL,
        modelManifest: SpeakerDiarizationModelManifest = .fluidAudio0155,
        executablePath: String = Bundle.main.executableURL?.path ?? CommandLine.arguments[0],
        afterTransition: @escaping @Sendable () async -> Void = {}
    ) {
        let runner = SpeakerDiarizationHelperProcessRunner(executablePath: executablePath)
        let modelDirectory = dataRoot
            .appendingPathComponent(DiarizationHelperCommand.modelsRelativePath, isDirectory: true)
            .appendingPathComponent(DiarizationHelperCommand.modelRepositoryDirectory, isDirectory: true)
        self.init(
            repository: repository,
            computeCoordinator: computeCoordinator,
            dataRoot: dataRoot,
            modelManifest: modelManifest,
            modelReadiness: {
                await Task.detached(priority: .utility) {
                    (try? SpeakerDiarizationModelVerifier.verify(
                        directory: modelDirectory,
                        manifest: modelManifest
                    )) == modelManifest.expectedBytes
                }.value
            },
            helperLauncher: { manifest, relativePath, root in
                try await runner.run(
                    manifest: manifest,
                    manifestRelativePath: relativePath,
                    dataRoot: root
                )
            },
            cancelHelper: { runner.cancel() },
            afterTransition: afterTransition
        )
    }

    func runOne(
        nowMs: Int64 = msFromDate(Date())
    ) async -> SpeakerDiarizationWorkerRunResult {
        guard !suspended else { return .suspended }
        if let activeOperation { return await activeOperation.value }
        let operation = Task { [weak self] in
            guard let self else { return SpeakerDiarizationWorkerRunResult.suspended }
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
            if case .completed = result { await afterTransition() }
            try? await Task.sleep(for: Self.loopDelay(after: result))
        }
    }

    static func loopDelay(after result: SpeakerDiarizationWorkerRunResult) -> Duration {
        switch result {
        case .completed: .milliseconds(100)
        case .failed: .seconds(30)
        case .idle, .modelUnavailable, .suspended: .seconds(5)
        }
    }

    func suspendAndDrain() async {
        _ = await suspendAndDrainForEvidenceMutation()
    }

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
        failedEvidence.removeAll()
    }

    private func performOne(nowMs: Int64) async -> SpeakerDiarizationWorkerRunResult {
        guard !suspended, !Task.isCancelled else { return .suspended }
        let evidence: CallSpeakerDiarizationEvidence
        do {
            guard let candidate = try await repository.nextSpeakerDiarizationEvidence(
                excluding: failedEvidence
            ) else { return .idle }
            evidence = candidate
        } catch {
            return .idle
        }
        guard await modelReadiness() else { return .modelUnavailable }
        guard let callID = evidence.call.id else { return .idle }

        let lease: AIComputeLease
        do {
            lease = try await computeCoordinator.acquireSpeech()
        } catch {
            return .suspended
        }
        var pendingRevisionID: Int64?
        do {
            try Task.checkCancellation()
            let ranges = try Self.plannedAudioRanges(evidence: evidence)
            guard !ranges.isEmpty else {
                throw SpeakerDiarizationWorkerError.invalidEvidence
            }
            guard let transcriptRevisionID = evidence.transcriptRevision.id else {
                throw SpeakerDiarizationWorkerError.invalidEvidence
            }
            let pendingRevision = try await repository.beginInitialSpeakerRevision(
                callID: callID,
                mediaGeneration: evidence.call.mediaGeneration,
                expectedTranscriptRevisionID: transcriptRevisionID,
                engine: "FluidAudio",
                modelRevision: modelManifest.modelRevision,
                nowMs: nowMs
            )
            guard let claimedRevisionID = pendingRevision.id else {
                throw SpeakerDiarizationWorkerError.invalidEvidence
            }
            pendingRevisionID = claimedRevisionID
            let result = try await runHelper(ranges: ranges, evidence: evidence)
            let clusters = try Self.validateAndAlign(
                result: result,
                ranges: ranges,
                evidence: evidence,
                modelManifest: modelManifest
            )
            try Task.checkCancellation()
            let revision = try await repository.completeInitialSpeakerRevision(
                revisionID: claimedRevisionID,
                callID: callID,
                mediaGeneration: evidence.call.mediaGeneration,
                expectedTranscriptRevisionID: transcriptRevisionID,
                clusters: clusters,
                nowMs: nowMs
            )
            guard let revisionID = revision.id else {
                throw SpeakerDiarizationWorkerError.invalidHelperResult
            }
            await lease.release()
            return .completed(callID: callID, revisionID: revisionID)
        } catch {
            await lease.release()
            if let pendingRevisionID {
                if error is CancellationError {
                    try? await repository.cancelInitialSpeakerRevision(revisionID: pendingRevisionID)
                } else {
                    try? await repository.failInitialSpeakerRevision(revisionID: pendingRevisionID)
                }
            }
            if error is CancellationError { return .suspended }
            failedEvidence.insert(evidence.identity)
            return .failed(callID: callID, errorCode: Self.errorCode(for: error))
        }
    }

    private func runHelper(
        ranges: [DiarizationHelperAudioRange],
        evidence: CallSpeakerDiarizationEvidence
    ) async throws -> DiarizationHelperResult {
        guard let callID = evidence.call.id else {
            throw SpeakerDiarizationWorkerError.invalidEvidence
        }
        let jobID = UUID().uuidString.lowercased()
        let jobRoot = "call-helper/diarization/\(jobID)"
        let manifestRelativePath = "\(jobRoot)/manifest.json"
        let resultRelativePath = "\(jobRoot)/result.json"
        let jobDirectory: URL
        let manifestURL: URL
        do {
            jobDirectory = try ManagedAssetVerifier.containedURL(root: dataRoot, relativePath: jobRoot)
            manifestURL = try ManagedAssetVerifier.containedURL(
                root: dataRoot,
                relativePath: manifestRelativePath
            )
            try FileManager.default.createDirectory(
                at: jobDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SpeakerDiarizationWorkerError.invalidEvidence
        }
        defer { try? FileManager.default.removeItem(at: jobDirectory) }

        let manifest = DiarizationHelperJobManifest(
            formatVersion: 1,
            jobID: jobID,
            callID: callID,
            callGeneration: evidence.call.mediaGeneration,
            modelsRelativePath: DiarizationHelperCommand.modelsRelativePath,
            resultRelativePath: resultRelativePath,
            clusteringThreshold: 0.7,
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
            throw SpeakerDiarizationWorkerError.invalidEvidence
        }
        let result = try await helperLauncher(manifest, manifestRelativePath, dataRoot)
        guard result.jobID == jobID else {
            throw SpeakerDiarizationWorkerError.invalidHelperResult
        }
        return result
    }

    static func plannedAudioRanges(
        evidence: CallSpeakerDiarizationEvidence
    ) throws -> [DiarizationHelperAudioRange] {
        guard let callID = evidence.call.id,
              let endMs = evidence.call.endTs,
              evidence.call.state == .ready,
              evidence.transcriptRevision.id == evidence.call.preferredRevisionId,
              evidence.transcriptRevision.callId == callID,
              evidence.transcriptRevision.mediaGeneration == evidence.call.mediaGeneration,
              evidence.transcriptRevision.kind == .final,
              evidence.transcriptRevision.state == .ready,
              endMs >= evidence.call.startTs else {
            throw SpeakerDiarizationWorkerError.invalidEvidence
        }

        var planned: [DiarizationHelperAudioRange] = []
        var sourceEndSample: [CallAudioSource: Int64] = [:]
        let chunks = evidence.chunks.sorted {
            ($0.source.rawValue, $0.startMs, $0.epoch, $0.sequence)
                < ($1.source.rawValue, $1.startMs, $1.epoch, $1.sequence)
        }
        for chunk in chunks {
            guard chunk.callId == callID,
                  chunk.mediaGeneration == evidence.call.mediaGeneration,
                  chunk.finalized,
                  chunk.bytes > 0,
                  chunk.relativePath.hasPrefix("calls/"),
                  chunk.endMs > chunk.startMs,
                  chunk.endSample > chunk.startSample else {
                throw SpeakerDiarizationWorkerError.invalidEvidence
            }
            let boundedStartMs = max(evidence.call.startTs, chunk.startMs)
            let boundedEndMs = min(endMs, chunk.endMs)
            guard boundedStartMs < boundedEndMs else { continue }

            let samplesFromChunkStart = (boundedStartMs - chunk.startMs) * pcmSampleRate / 1_000
            let boundedSamples = (boundedEndMs - boundedStartMs) * pcmSampleRate / 1_000
            let metadataSamples = min(
                chunk.endSample - chunk.startSample - samplesFromChunkStart,
                chunk.bytes / bytesPerSample - samplesFromChunkStart
            )
            var sampleCount = min(boundedSamples, metadataSamples)
            var offsetSamples = samplesFromChunkStart
            var callRelativeStart = (boundedStartMs - evidence.call.startTs) * pcmSampleRate / 1_000
            if let previousEnd = sourceEndSample[chunk.source], callRelativeStart < previousEnd {
                let overlap = previousEnd - callRelativeStart
                offsetSamples += overlap
                sampleCount -= overlap
                callRelativeStart = previousEnd
            }
            guard offsetSamples >= 0, sampleCount > 0 else { continue }

            var consumedSamples: Int64 = 0
            let maximumRangeSamples = maximumRangeBytes / bytesPerSample
            while consumedSamples < sampleCount {
                let count = min(maximumRangeSamples, sampleCount - consumedSamples)
                planned.append(
                    DiarizationHelperAudioRange(
                        source: chunk.source,
                        relativePath: "media/\(chunk.relativePath)",
                        offsetBytes: (offsetSamples + consumedSamples) * bytesPerSample,
                        lengthBytes: count * bytesPerSample,
                        sampleRate: Int(pcmSampleRate),
                        startSample: callRelativeStart + consumedSamples
                    )
                )
                consumedSamples += count
            }
            sourceEndSample[chunk.source] = callRelativeStart + sampleCount
        }
        let total = planned.reduce(into: Int64(0)) { sum, range in
            let next = sum.addingReportingOverflow(range.lengthBytes)
            sum = next.overflow ? Int64.max : next.partialValue
        }
        guard total > 0, total <= DiarizationHelperCommand.maximumInputBytes else {
            throw SpeakerDiarizationWorkerError.invalidEvidence
        }
        return planned
    }

    static func validateAndAlign(
        result: DiarizationHelperResult,
        ranges: [DiarizationHelperAudioRange],
        evidence: CallSpeakerDiarizationEvidence,
        modelManifest: SpeakerDiarizationModelManifest
    ) throws -> [CallSpeakerClusterDraft] {
        guard let callID = evidence.call.id,
              result.formatVersion == 1,
              UUID(uuidString: result.jobID)?.uuidString.lowercased() == result.jobID,
              result.callID == callID,
              result.callGeneration == evidence.call.mediaGeneration,
              result.packageVersion == modelManifest.packageVersion,
              result.modelRevision == modelManifest.modelRevision,
              result.segments.count <= 1_000_000 else {
            throw SpeakerDiarizationWorkerError.invalidHelperResult
        }

        var bounds: [CallAudioSource: (Double, Double)] = [:]
        for range in ranges {
            let start = Double(range.startSample) / Double(range.sampleRate)
            let end = start + Double(range.lengthBytes / bytesPerSample) / Double(range.sampleRate)
            if let current = bounds[range.source] {
                bounds[range.source] = (min(current.0, start), max(current.1, end))
            } else {
                bounds[range.source] = (start, end)
            }
        }

        var raw: [String: CallSpeakerClusterDraft] = [:]
        for segment in result.segments {
            guard segment.startSeconds.isFinite,
                  segment.endSeconds.isFinite,
                  segment.quality.isFinite,
                  segment.startSeconds >= 0,
                  segment.endSeconds > segment.startSeconds,
                  (0...1).contains(segment.quality),
                  !segment.clusterKey.isEmpty,
                  segment.clusterKey.utf8.count <= 128,
                  segment.clusterKey.hasPrefix("\(segment.source.rawValue):"),
                  !segment.clusterKey.unicodeScalars.contains(where: {
                    $0.value < 32 || $0.value == 127
                  }),
                  let sourceBounds = bounds[segment.source],
                  segment.startSeconds >= sourceBounds.0 - 1,
                  segment.endSeconds <= sourceBounds.1 + 1 else {
                throw SpeakerDiarizationWorkerError.invalidHelperResult
            }
            let interval = CallSpeakerIntervalDraft(
                source: segment.source,
                startMs: evidence.call.startTs + Int64((segment.startSeconds * 1_000).rounded()),
                endMs: evidence.call.startTs + Int64((segment.endSeconds * 1_000).rounded())
            )
            let existing = raw[segment.clusterKey]
            raw[segment.clusterKey] = CallSpeakerClusterDraft(
                clusterKey: segment.clusterKey,
                displayName: nil,
                namingProvenance: .anonymous,
                intervals: (existing?.intervals ?? []) + [interval]
            )
        }

        let rawClusters = raw.values.sorted { $0.clusterKey < $1.clusterKey }
        let transcript = evidence.transcriptSegments.map {
            CallTranscriptSegmentDraft(
                source: $0.source,
                startMs: $0.startMs,
                endMs: $0.endMs,
                text: $0.text
            )
        }
        let aligned = CallTranscriptSpeakerAligner.align(transcript, to: rawClusters)
        var intervalsByCluster: [String: [CallSpeakerIntervalDraft]] = [:]
        for item in aligned {
            guard let key = item.speakerClusterKey else { continue }
            intervalsByCluster[key, default: []].append(
                .init(
                    source: item.segment.source,
                    startMs: item.segment.startMs,
                    endMs: item.segment.endMs
                )
            )
        }
        if !transcript.isEmpty, intervalsByCluster.isEmpty {
            throw SpeakerDiarizationWorkerError.invalidHelperResult
        }
        return rawClusters.compactMap { cluster in
            guard let intervals = intervalsByCluster[cluster.clusterKey], !intervals.isEmpty else {
                return nil
            }
            return CallSpeakerClusterDraft(
                clusterKey: cluster.clusterKey,
                displayName: nil,
                namingProvenance: .anonymous,
                intervals: intervals
            )
        }
    }

    private static func errorCode(for error: Error) -> String {
        if let workerError = error as? SpeakerDiarizationWorkerError {
            switch workerError {
            case .invalidEvidence: "invalid_evidence"
            case .invalidHelperResult: "invalid_helper_result"
            case .helperFailed: "helper_failed"
            }
        } else {
            "helper_failed"
        }
    }
}

/// Same-binary, no-shell helper bridge. stdout/stderr are discarded so neither
/// transcript text nor local paths become log payloads. The lock guards every
/// access to the mutable Process/cancellation pair across detached tasks.
final class SpeakerDiarizationHelperProcessRunner: @unchecked Sendable {
    static let maximumRuntime: Duration = .seconds(30 * 60)

    private let executablePath: String
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false

    init(executablePath: String) {
        self.executablePath = executablePath
    }

    func run(
        manifest: DiarizationHelperJobManifest,
        manifestRelativePath: String,
        dataRoot: URL
    ) async throws -> DiarizationHelperResult {
        prepareRun()
        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority: .utility) { [self] in
                let child = Process()
                child.executableURL = URL(fileURLWithPath: executablePath)
                child.arguments = [DiarizationHelperCommand.flag, manifestRelativePath]
                child.standardOutput = FileHandle.nullDevice
                child.standardError = FileHandle.nullDevice
                try launch(child)
                defer { clear(child) }
                try await Self.waitForExit(child)
                guard child.terminationStatus == 0 else {
                    throw SpeakerDiarizationWorkerError.helperFailed
                }
                let resultURL = try ManagedAssetVerifier.containedURL(
                    root: dataRoot,
                    relativePath: manifest.resultRelativePath
                )
                guard let size = try? resultURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size > 0,
                      size <= DiarizationHelperCommand.maximumResultBytes,
                      let data = try? Data(contentsOf: resultURL),
                      let decoded = try? JSONDecoder().decode(DiarizationHelperResult.self, from: data)
                else { throw SpeakerDiarizationWorkerError.invalidHelperResult }
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
                throw SpeakerDiarizationWorkerError.helperFailed
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
                throw SpeakerDiarizationWorkerError.helperFailed
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
