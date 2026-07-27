import Darwin
import Foundation

/// Executes Handy's documented local headless transcription command against Eye's immutable PCM
/// ranges. The model stays in Handy's shared cache; Eye creates only one owner-only minute WAV
/// at a time and removes it before returning. No shell, network, transcript log, or model copy is
/// involved.
///
/// `@unchecked Sendable` is limited to Foundation's `Process`: the child reference and cancellation
/// flag are both owned behind `lock`, while all transcription inputs and outputs remain Sendable values.
final class HandyWhisperHelperProcessRunner: @unchecked Sendable {
    static let maximumRuntime: Duration = .seconds(20 * 60)
    static let maximumOutputBytes = 4 * 1_024 * 1_024
    static let maximumBatchBytes: Int64 = 60 * 16_000 * 2

    struct InputBatch: Sendable, Equatable {
        let source: CallAudioSource
        let sampleRate: Int
        let startSample: Int64
        let ranges: [WhisperHelperAudioRange]

        var lengthBytes: Int64 { ranges.reduce(0) { $0 + $1.lengthBytes } }
    }

    private struct CLIResult: Decodable {
        let text: String
    }

    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false

    init(executablePath _: String) {}

    func run(
        manifest: WhisperHelperJobManifest,
        manifestRelativePath: String,
        dataRoot: URL
    ) async throws -> WhisperHelperResult {
        prepareRun()
        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority: .utility) { [self] in
                try await execute(
                    manifest: manifest,
                    manifestRelativePath: manifestRelativePath,
                    dataRoot: dataRoot
                )
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

    private func execute(
        manifest: WhisperHelperJobManifest,
        manifestRelativePath: String,
        dataRoot: URL,
        fileManager: FileManager = .default
    ) async throws -> WhisperHelperResult {
        guard manifest.formatVersion == 1,
              UUID(uuidString: manifest.jobID)?.uuidString.lowercased() == manifest.jobID,
              manifest.callID > 0,
              manifest.callGeneration >= 0,
              manifestRelativePath == "call-helper/jobs/\(manifest.jobID)/manifest.json",
              manifest.modelRelativePath == "external/handy",
              let backend = manifest.handyBackend,
              backend.identitySHA256 == manifest.modelSHA256,
              backend.identitySHA256.count == 64,
              !backend.modelID.isEmpty,
              !backend.runtimeRelease.isEmpty,
              manifest.resultRelativePath == "call-helper/jobs/\(manifest.jobID)/result.json",
              !manifest.audioRanges.isEmpty,
              manifest.audioRanges.count <= 4_096,
              let handyExecutable = HandySpeechModelProbe.executableURL(fileManager: fileManager)
        else { throw CallTranscriptWorkerError.invalidEvidence }

        let jobRoot = "call-helper/jobs/\(manifest.jobID)"
        let jobDirectory: URL
        do {
            jobDirectory = try ManagedAssetVerifier.containedURL(
                root: dataRoot,
                relativePath: jobRoot
            )
        } catch {
            throw CallTranscriptWorkerError.invalidEvidence
        }

        var segments: [WhisperHelperResultSegment] = []
        let batches = try Self.plannedBatches(manifest.audioRanges)
        segments.reserveCapacity(batches.count)
        for (index, batch) in batches.enumerated() {
            if let segment = try await transcribeBatch(
                batch,
                index: index,
                backend: backend,
                handyExecutable: handyExecutable,
                jobDirectory: jobDirectory,
                dataRoot: dataRoot,
                fileManager: fileManager
            ) {
                segments.append(segment)
            }
        }

        return WhisperHelperResult(
            formatVersion: 1,
            jobID: manifest.jobID,
            callID: manifest.callID,
            callGeneration: manifest.callGeneration,
            modelSHA256: backend.identitySHA256,
            runtimeRelease: backend.runtimeRelease,
            segments: segments
        )
    }

    /// Keeps temporary media bounded to one contiguous one-minute batch. The `defer` runs after
    /// every Handy invocation instead of retaining WAV files until the whole call finishes.
    private func transcribeBatch(
        _ batch: InputBatch,
        index: Int,
        backend: HandySpeechBackendReference,
        handyExecutable: URL,
        jobDirectory: URL,
        dataRoot: URL,
        fileManager: FileManager
    ) async throws -> WhisperHelperResultSegment? {
        try Task.checkCancellation()
        var pcm = Data()
        pcm.reserveCapacity(Int(batch.lengthBytes))
        for range in batch.ranges {
            try Task.checkCancellation()
            pcm.append(try Self.readPCM(range: range, dataRoot: dataRoot))
        }
        let wavURL = jobDirectory.appendingPathComponent("handy-input-\(index).wav")
        let outputURL = jobDirectory.appendingPathComponent("handy-output-\(index).json")
        defer {
            try? fileManager.removeItem(at: wavURL)
            try? fileManager.removeItem(at: outputURL)
        }
        do {
            try Self.wavData(pcm: pcm, sampleRate: batch.sampleRate)
                .write(to: wavURL, options: .withoutOverwriting)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: wavURL.path
            )
        } catch {
            throw CallTranscriptWorkerError.invalidEvidence
        }

        let decoded = try await runHandy(
            executable: handyExecutable,
            modelID: backend.modelID,
            wavURL: wavURL,
            outputURL: outputURL,
            fileManager: fileManager
        )
        guard let text = Self.normalizedTranscript(decoded.text) else {
            if decoded.text.utf8.count > 1_000_000 {
                throw CallTranscriptWorkerError.invalidHelperResult
            }
            return nil
        }
        guard text.utf8.count <= 1_000_000 else {
            throw CallTranscriptWorkerError.invalidHelperResult
        }
        let start = Double(batch.startSample) / Double(batch.sampleRate)
        let duration = Double(batch.lengthBytes / 2) / Double(batch.sampleRate)
        return WhisperHelperResultSegment(
            source: batch.source,
            startSeconds: start,
            endSeconds: start + duration,
            text: text
        )
    }

    static func normalizedTranscript(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 1_000_000,
              text.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
        return text
    }

    static func plannedBatches(_ ranges: [WhisperHelperAudioRange]) throws -> [InputBatch] {
        var result: [InputBatch] = []
        var current: InputBatch?

        func append(_ range: WhisperHelperAudioRange) {
            if let batch = current {
                let expectedStart = batch.startSample + batch.lengthBytes / 2
                let canAppend = batch.source == range.source
                    && batch.sampleRate == range.sampleRate
                    && range.startSample == expectedStart
                    && batch.lengthBytes + range.lengthBytes <= maximumBatchBytes
                if canAppend {
                    current = InputBatch(
                        source: batch.source,
                        sampleRate: batch.sampleRate,
                        startSample: batch.startSample,
                        ranges: batch.ranges + [range]
                    )
                    return
                }
                result.append(batch)
            }
            current = InputBatch(
                source: range.source,
                sampleRate: range.sampleRate,
                startSample: range.startSample,
                ranges: [range]
            )
        }

        for range in ranges {
            try validate(range)
            var consumed: Int64 = 0
            while consumed < range.lengthBytes {
                let length = min(maximumBatchBytes, range.lengthBytes - consumed)
                append(WhisperHelperAudioRange(
                    source: range.source,
                    relativePath: range.relativePath,
                    offsetBytes: range.offsetBytes + consumed,
                    lengthBytes: length,
                    sampleRate: range.sampleRate,
                    startSample: range.startSample + consumed / 2
                ))
                consumed += length
            }
        }
        if let current { result.append(current) }
        return result
    }

    private static func validate(_ range: WhisperHelperAudioRange) throws {
        guard range.relativePath.hasPrefix("media/calls/"),
              ManagedAssetVerifier.isSafeRelativePath(range.relativePath),
              range.offsetBytes >= 0,
              range.lengthBytes > 0,
              range.lengthBytes <= Int64(WhisperHelperCommand.maximumInputBytes),
              range.lengthBytes.isMultiple(of: 2),
              range.sampleRate == 16_000,
              range.startSample >= 0 else {
            throw CallTranscriptWorkerError.invalidEvidence
        }
    }

    private func runHandy(
        executable: URL,
        modelID: String,
        wavURL: URL,
        outputURL: URL,
        fileManager: FileManager
    ) async throws -> CLIResult {
        guard fileManager.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ),
        let output = try? FileHandle(forWritingTo: outputURL) else {
            throw CallTranscriptWorkerError.helperFailed
        }
        defer { try? output.close() }

        let child = Process()
        child.executableURL = executable
        child.arguments = [
            "--transcribe-file", wavURL.path,
            "--model", modelID,
            "--json",
        ]
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        try launch(child)
        defer { clear(child) }
        try await Self.waitForExit(child)
        guard child.terminationStatus == 0 else {
            throw CallTranscriptWorkerError.helperFailed
        }
        try? output.synchronize()
        guard let size = try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0,
              size <= Self.maximumOutputBytes,
              let data = try? Data(contentsOf: outputURL),
              let decoded = try? JSONDecoder().decode(CLIResult.self, from: data) else {
            throw CallTranscriptWorkerError.invalidHelperResult
        }
        return decoded
    }

    private static func readPCM(
        range: WhisperHelperAudioRange,
        dataRoot: URL
    ) throws -> Data {
        let source: URL
        do {
            source = try ManagedAssetVerifier.containedURL(
                root: dataRoot,
                relativePath: range.relativePath
            )
        } catch {
            throw CallTranscriptWorkerError.invalidEvidence
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: source)
            try handle.seek(toOffset: UInt64(range.offsetBytes))
        } catch {
            throw CallTranscriptWorkerError.invalidEvidence
        }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: Int(range.lengthBytes)),
              bytes.count == Int(range.lengthBytes) else {
            throw CallTranscriptWorkerError.invalidEvidence
        }
        return bytes
    }

    static func wavData(pcm: Data, sampleRate: Int) throws -> Data {
        guard sampleRate == 16_000,
              !pcm.isEmpty,
              pcm.count.isMultiple(of: 2),
              pcm.count <= Int(UInt32.max) - 36 else {
            throw CallTranscriptWorkerError.invalidEvidence
        }
        var data = Data()
        data.reserveCapacity(44 + pcm.count)
        data.append(Data("RIFF".utf8))
        data.appendLittleEndian(UInt32(36 + pcm.count))
        data.append(Data("WAVEfmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * 2))
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.append(Data("data".utf8))
        data.appendLittleEndian(UInt32(pcm.count))
        data.append(pcm)
        return data
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

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
