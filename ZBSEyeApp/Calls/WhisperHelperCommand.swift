import Foundation
import ZBSEyeWhisper

struct WhisperHelperAudioRange: Codable, Sendable, Equatable {
    let source: CallAudioSource
    let relativePath: String
    let offsetBytes: Int64
    let lengthBytes: Int64
    let sampleRate: Int
    let startSample: Int64
}

struct WhisperHelperJobManifest: Codable, Sendable, Equatable {
    let formatVersion: Int
    let jobID: String
    let callID: Int64
    let callGeneration: Int
    let modelRelativePath: String
    let modelSHA256: String
    let handyBackend: HandySpeechBackendReference?
    let resultRelativePath: String
    let audioRanges: [WhisperHelperAudioRange]

    init(
        formatVersion: Int,
        jobID: String,
        callID: Int64,
        callGeneration: Int,
        modelRelativePath: String,
        modelSHA256: String,
        handyBackend: HandySpeechBackendReference? = nil,
        resultRelativePath: String,
        audioRanges: [WhisperHelperAudioRange]
    ) {
        self.formatVersion = formatVersion
        self.jobID = jobID
        self.callID = callID
        self.callGeneration = callGeneration
        self.modelRelativePath = modelRelativePath
        self.modelSHA256 = modelSHA256
        self.handyBackend = handyBackend
        self.resultRelativePath = resultRelativePath
        self.audioRanges = audioRanges
    }
}

struct WhisperHelperPreparedInput: Sendable, Equatable {
    let source: CallAudioSource
    let sampleRate: Int
    let startSample: Int64
    let samples: [Float]
}

struct WhisperHelperResultSegment: Codable, Sendable, Equatable {
    let source: CallAudioSource
    let startSeconds: Double
    let endSeconds: Double
    let text: String
}

struct WhisperHelperResult: Codable, Sendable, Equatable {
    let formatVersion: Int
    let jobID: String
    let callID: Int64
    let callGeneration: Int
    let modelSHA256: String
    let runtimeRelease: String
    let segments: [WhisperHelperResultSegment]
}

/// The helper process invokes this synchronous closure serially. Native
/// whisper state never crosses a task or escapes the short-lived process.
struct WhisperHelperRuntimeSession: @unchecked Sendable {
    let runBatch: ([WhisperHelperPreparedInput]) throws -> [WhisperHelperResultSegment]
}

/// Test/runtime dependency container used synchronously by `execute()`.
struct WhisperHelperRuntime: @unchecked Sendable {
    let makeSession: (URL) throws -> WhisperHelperRuntimeSession

    init(
        _ run: @escaping (
            _ modelURL: URL,
            _ inputs: [WhisperHelperPreparedInput]
        ) throws -> [WhisperHelperResultSegment]
    ) {
        makeSession = { modelURL in
            WhisperHelperRuntimeSession { inputs in try run(modelURL, inputs) }
        }
    }

    init(
        makeSession: @escaping (URL) throws -> WhisperHelperRuntimeSession
    ) {
        self.makeSession = makeSession
    }

    static let native = WhisperHelperRuntime(makeSession: { modelURL in
        let session = try WhisperSession(modelURL: modelURL)
        return WhisperHelperRuntimeSession { inputs in
            try inputs.flatMap { input in
                let base = Double(input.startSample) / Double(input.sampleRate)
                return try session.transcribe(samples: input.samples).map { segment in
                    WhisperHelperResultSegment(
                        source: input.source,
                        startSeconds: base + segment.startSeconds,
                        endSeconds: base + segment.endSeconds,
                        text: segment.text
                    )
                }
            }
        }
    })
}

enum WhisperHelperCommandError: Error, Sendable, Equatable {
    case missingManifestArgument
    case invalidManifestPath
    case invalidManifest
    case invalidJobIdentity
    case invalidModelIdentity
    case invalidResultPath
    case invalidAudioRange
    case inputTooLarge
    case resultTooLarge
    case shortRead
    case outputExists
    case writeFailed
}

struct WhisperModelSmokeCommand {
    static let flag = "--whisper-smoke-model"
    static let expectedRelativePath = "ai/speech/v1/staging/model.partial"

    let modelURL: URL

    init(
        arguments: [String],
        dataRoot: URL,
        expectedModel: WhisperModelManifest = .largeV3Turbo
    ) throws {
        guard let flagIndex = arguments.firstIndex(of: Self.flag),
              arguments.indices.contains(flagIndex + 1),
              arguments[flagIndex + 1] == Self.expectedRelativePath else {
            throw WhisperHelperCommandError.invalidModelIdentity
        }
        do {
            _ = try ManagedAssetVerifier.verifyFile(
                root: dataRoot,
                relativePath: Self.expectedRelativePath,
                expectedBytes: expectedModel.expectedBytes,
                sha256: expectedModel.sha256
            )
            modelURL = try ManagedAssetVerifier.containedURL(
                root: dataRoot,
                relativePath: Self.expectedRelativePath
            )
        } catch {
            throw WhisperHelperCommandError.invalidModelIdentity
        }
    }

    func execute() throws {
        _ = try WhisperSession(modelURL: modelURL)
    }
}

/// One immutable manifest in, one bounded result artifact out. This command
/// never opens SQLite and the owning process exits immediately afterwards.
struct WhisperHelperCommand {
    static let flag = "--whisper-job"
    static let maximumManifestBytes = 1 * 1_024 * 1_024
    static let maximumInputBytes = 64 * 1_024 * 1_024
    static let maximumResultBytes = 32 * 1_024 * 1_024

    let manifest: WhisperHelperJobManifest
    let dataRoot: URL
    let manifestURL: URL
    let modelURL: URL
    let resultURL: URL

    init(
        arguments: [String],
        dataRoot: URL,
        expectedModel: WhisperModelManifest = .largeV3Turbo,
        fileManager: FileManager = .default
    ) throws {
        guard let flagIndex = arguments.firstIndex(of: Self.flag),
              arguments.indices.contains(flagIndex + 1) else {
            throw WhisperHelperCommandError.missingManifestArgument
        }
        let root = dataRoot.standardizedFileURL
        let suppliedPath = arguments[flagIndex + 1]
        guard ManagedAssetVerifier.isSafeRelativePath(suppliedPath) else {
            throw WhisperHelperCommandError.invalidManifestPath
        }
        let resolvedManifest: URL
        do {
            resolvedManifest = try ManagedAssetVerifier.containedURL(
                root: root,
                relativePath: suppliedPath
            )
        } catch {
            throw WhisperHelperCommandError.invalidManifestPath
        }
        guard let values = try? resolvedManifest.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= Self.maximumManifestBytes,
              let data = try? Data(contentsOf: resolvedManifest),
              let decoded = try? JSONDecoder().decode(WhisperHelperJobManifest.self, from: data)
        else { throw WhisperHelperCommandError.invalidManifest }

        guard decoded.formatVersion == 1,
              let canonicalJobID = UUID(uuidString: decoded.jobID)?.uuidString.lowercased(),
              decoded.jobID == canonicalJobID,
              decoded.callID > 0,
              decoded.callGeneration >= 0 else {
            throw WhisperHelperCommandError.invalidJobIdentity
        }
        let jobRoot = "call-helper/jobs/\(decoded.jobID.lowercased())"
        guard suppliedPath == "\(jobRoot)/manifest.json" else {
            throw WhisperHelperCommandError.invalidManifestPath
        }

        let expectedModelPath = "ai/speech/v1/\(expectedModel.relativePath)"
        guard decoded.modelRelativePath == expectedModelPath,
              decoded.modelSHA256 == expectedModel.sha256,
              decoded.handyBackend == nil else {
            throw WhisperHelperCommandError.invalidModelIdentity
        }
        let resolvedModel: URL
        do {
            resolvedModel = try ManagedAssetVerifier.containedURL(
                root: root,
                relativePath: decoded.modelRelativePath
            )
        } catch {
            throw WhisperHelperCommandError.invalidModelIdentity
        }
        guard let modelSize = try? resolvedModel.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(modelSize) == expectedModel.expectedBytes else {
            throw WhisperHelperCommandError.invalidModelIdentity
        }
        do {
            _ = try ManagedAssetVerifier.verifyFile(
                root: root,
                relativePath: decoded.modelRelativePath,
                expectedBytes: expectedModel.expectedBytes,
                sha256: expectedModel.sha256
            )
        } catch {
            throw WhisperHelperCommandError.invalidModelIdentity
        }
        let installationURL = root.appendingPathComponent(
            "ai/speech/v1/installation.json",
            isDirectory: false
        )
        guard let installationData = try? Data(contentsOf: installationURL),
              let installation = try? JSONDecoder().decode(
                  WhisperModelInstallation.self,
                  from: installationData
              ),
              installation.manifestID == expectedModel.id,
              installation.revision == expectedModel.revision,
              installation.sha256 == expectedModel.sha256,
              installation.expectedBytes == expectedModel.expectedBytes,
              installation.runtimeRelease == expectedModel.runtimeRelease else {
            throw WhisperHelperCommandError.invalidModelIdentity
        }

        guard decoded.resultRelativePath == "\(jobRoot)/result.json" else {
            throw WhisperHelperCommandError.invalidResultPath
        }
        let resolvedResult: URL
        do {
            resolvedResult = try ManagedAssetVerifier.containedURL(
                root: root,
                relativePath: decoded.resultRelativePath
            )
        } catch {
            throw WhisperHelperCommandError.invalidResultPath
        }
        guard !fileManager.fileExists(atPath: resolvedResult.path) else {
            throw WhisperHelperCommandError.outputExists
        }

        guard !decoded.audioRanges.isEmpty, decoded.audioRanges.count <= 4_096 else {
            throw WhisperHelperCommandError.invalidAudioRange
        }
        for range in decoded.audioRanges {
            guard range.relativePath.hasPrefix("media/calls/"),
                  ManagedAssetVerifier.isSafeRelativePath(range.relativePath),
                  range.offsetBytes >= 0,
                  range.lengthBytes > 0,
                  range.lengthBytes.isMultiple(of: 2),
                  range.sampleRate == 16_000,
                  range.startSample >= 0,
                  range.lengthBytes <= Int64(Self.maximumInputBytes) else {
                throw WhisperHelperCommandError.invalidAudioRange
            }
        }

        manifest = decoded
        self.dataRoot = root
        manifestURL = resolvedManifest
        modelURL = resolvedModel
        resultURL = resolvedResult
    }

    func execute(
        runtime: WhisperHelperRuntime = .native,
        fileManager: FileManager = .default
    ) throws {
        let session = try runtime.makeSession(modelURL)
        var segments: [WhisperHelperResultSegment] = []
        for ranges in Self.batches(manifest.audioRanges) {
            let inputs = try ranges.map(loadRange)
            segments.append(contentsOf: try session.runBatch(inputs))
        }
        let result = WhisperHelperResult(
            formatVersion: 1,
            jobID: manifest.jobID,
            callID: manifest.callID,
            callGeneration: manifest.callGeneration,
            modelSHA256: manifest.modelSHA256,
            runtimeRelease: WhisperRuntimeIdentity.release,
            segments: segments
        )
        let encoded = try JSONEncoder().encode(result)
        guard encoded.count <= Self.maximumResultBytes else {
            throw WhisperHelperCommandError.resultTooLarge
        }
        let jobDirectory = resultURL.deletingLastPathComponent()
        let temporary = jobDirectory.appendingPathComponent("result.tmp-\(UUID().uuidString)")
        do {
            try encoded.write(to: temporary, options: .withoutOverwriting)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporary.path
            )
            try fileManager.moveItem(at: temporary, to: resultURL)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw WhisperHelperCommandError.writeFailed
        }
    }

    private static func batches(
        _ ranges: [WhisperHelperAudioRange]
    ) -> [[WhisperHelperAudioRange]] {
        var result: [[WhisperHelperAudioRange]] = []
        var current: [WhisperHelperAudioRange] = []
        var bytes: Int64 = 0
        for range in ranges {
            if !current.isEmpty,
               current.count == 64 || bytes + range.lengthBytes > Int64(maximumInputBytes) {
                result.append(current)
                current = []
                bytes = 0
            }
            current.append(range)
            bytes += range.lengthBytes
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func loadRange(_ range: WhisperHelperAudioRange) throws -> WhisperHelperPreparedInput {
        let url: URL
        do {
            url = try ManagedAssetVerifier.containedURL(
                root: dataRoot,
                relativePath: range.relativePath
            )
        } catch {
            throw WhisperHelperCommandError.invalidAudioRange
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: UInt64(range.offsetBytes))
        } catch {
            throw WhisperHelperCommandError.invalidAudioRange
        }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: Int(range.lengthBytes)),
              bytes.count == Int(range.lengthBytes) else {
            throw WhisperHelperCommandError.shortRead
        }
        var samples = [Float]()
        samples.reserveCapacity(bytes.count / 2)
        bytes.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: raw.count, by: 2) {
                let bits = UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
                samples.append(Float(Int16(bitPattern: bits)) / 32_768)
            }
        }
        return WhisperHelperPreparedInput(
            source: range.source,
            sampleRate: range.sampleRate,
            startSample: range.startSample,
            samples: samples
        )
    }
}
