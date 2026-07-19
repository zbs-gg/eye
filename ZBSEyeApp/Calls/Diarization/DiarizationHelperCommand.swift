import Darwin
import FluidAudio
import Foundation

struct DiarizationHelperAudioRange: Codable, Equatable, Sendable {
    let source: CallAudioSource
    let relativePath: String
    let offsetBytes: Int64
    let lengthBytes: Int64
    let sampleRate: Int
    let startSample: Int64
}

struct DiarizationHelperJobManifest: Codable, Equatable, Sendable {
    let formatVersion: Int
    let jobID: String
    let callID: Int64
    let callGeneration: Int
    let modelsRelativePath: String
    let resultRelativePath: String
    let clusteringThreshold: Double
    let audioRanges: [DiarizationHelperAudioRange]
}

struct DiarizationHelperResultSegment: Codable, Equatable, Sendable {
    let source: CallAudioSource
    let clusterKey: String
    let startSeconds: Double
    let endSeconds: Double
    let quality: Double
}

struct DiarizationHelperResult: Codable, Equatable, Sendable {
    let formatVersion: Int
    let jobID: String
    let callID: Int64
    let callGeneration: Int
    let packageVersion: String
    let modelRevision: String
    let segments: [DiarizationHelperResultSegment]
}

enum DiarizationHelperCommandError: Error, Equatable, Sendable {
    case missingManifestArgument
    case invalidManifestPath
    case invalidManifest
    case invalidJobIdentity
    case invalidModelIdentity
    case invalidResultPath
    case invalidAudioRange
    case inputTooLarge
    case resultTooLarge
    case outputExists
    case shortRead
    case processingFailed
}

/// Random-access Int16 PCM view over finalized spool chunks. FluidAudio may read concurrently;
/// `pread` keeps every read independent and the virtual gaps are explicitly zero-filled.
final class DiarizationPCMSampleSource: AudioSampleSource, @unchecked Sendable {
    private struct OpenRange: Sendable {
        let descriptor: Int32
        let fileOffsetBytes: Int64
        let startSample: Int
        let sampleCount: Int
    }

    let sampleCount: Int
    private let ranges: [OpenRange]

    init(
        root: URL,
        ranges manifests: [DiarizationHelperAudioRange]
    ) throws {
        guard !manifests.isEmpty else { throw DiarizationHelperCommandError.invalidAudioRange }
        var opened: [OpenRange] = []
        var maximumEnd = 0
        do {
            for manifest in manifests.sorted(by: { $0.startSample < $1.startSample }) {
                guard manifest.sampleRate == 16_000,
                      manifest.offsetBytes >= 0,
                      manifest.lengthBytes > 0,
                      manifest.lengthBytes.isMultiple(of: 2),
                      manifest.startSample >= 0,
                      ManagedAssetVerifier.isSafeRelativePath(manifest.relativePath),
                      manifest.startSample <= Int64(Int.max),
                      manifest.lengthBytes / 2 <= Int64(Int.max)
                else { throw DiarizationHelperCommandError.invalidAudioRange }

                let start = Int(manifest.startSample)
                let count = Int(manifest.lengthBytes / 2)
                let end = try Self.checkedEnd(start: start, count: count)
                guard start >= maximumEnd else {
                    throw DiarizationHelperCommandError.invalidAudioRange
                }
                let url = try ManagedAssetVerifier.containedURL(
                    root: root,
                    relativePath: manifest.relativePath
                )
                let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
                guard descriptor >= 0 else {
                    throw DiarizationHelperCommandError.invalidAudioRange
                }
                var info = stat()
                guard fstat(descriptor, &info) == 0,
                      (info.st_mode & S_IFMT) == S_IFREG,
                      manifest.offsetBytes <= Int64(info.st_size),
                      manifest.lengthBytes <= Int64(info.st_size) - manifest.offsetBytes
                else {
                    close(descriptor)
                    throw DiarizationHelperCommandError.invalidAudioRange
                }
                opened.append(OpenRange(
                    descriptor: descriptor,
                    fileOffsetBytes: manifest.offsetBytes,
                    startSample: start,
                    sampleCount: count
                ))
                maximumEnd = end
            }
            guard maximumEnd <= 8 * 60 * 60 * 16_000 else {
                throw DiarizationHelperCommandError.inputTooLarge
            }
        } catch {
            opened.forEach { close($0.descriptor) }
            throw error
        }
        ranges = opened
        sampleCount = maximumEnd
    }

    deinit {
        ranges.forEach { close($0.descriptor) }
    }

    func copySamples(
        into destination: UnsafeMutablePointer<Float>,
        offset: Int,
        count: Int
    ) throws {
        guard offset >= 0, count >= 0 else {
            throw DiarizationHelperCommandError.invalidAudioRange
        }
        guard count > 0 else { return }
        destination.initialize(repeating: 0, count: count)
        guard offset < sampleCount else { return }
        let requestedEnd = min(sampleCount, try Self.checkedEnd(start: offset, count: count))

        for range in ranges {
            let rangeEnd = range.startSample + range.sampleCount
            let overlapStart = max(offset, range.startSample)
            let overlapEnd = min(requestedEnd, rangeEnd)
            guard overlapStart < overlapEnd else { continue }

            let samplesToRead = overlapEnd - overlapStart
            let rangeSampleOffset = overlapStart - range.startSample
            var pcm = [Int16](repeating: 0, count: samplesToRead)
            let bytesToRead = samplesToRead * MemoryLayout<Int16>.size
            let fileOffset = range.fileOffsetBytes
                + Int64(rangeSampleOffset * MemoryLayout<Int16>.size)
            let bytesRead = pcm.withUnsafeMutableBytes { buffer in
                pread(range.descriptor, buffer.baseAddress, bytesToRead, off_t(fileOffset))
            }
            guard bytesRead == bytesToRead else {
                throw DiarizationHelperCommandError.shortRead
            }
            let outputOffset = overlapStart - offset
            for index in 0..<samplesToRead {
                destination[outputOffset + index] = Float(pcm[index]) / 32_768
            }
        }
    }

    private static func checkedEnd(start: Int, count: Int) throws -> Int {
        let (end, overflow) = start.addingReportingOverflow(count)
        guard !overflow else { throw DiarizationHelperCommandError.inputTooLarge }
        return end
    }
}

/// Same-signed, short-lived helper: bounded JSON in/out, read-only PCM, no SQLite and no network.
struct DiarizationHelperCommand {
    static let flag = "--diarization-job"
    /// FluidAudio resolves its `.diarizer` repo below the supplied directory.
    /// Keep that upstream layout exact so offline loading cannot silently fall
    /// back to a downloader.
    static let modelsRelativePath = "ai/speech/v1/diarization"
    static let modelRepositoryDirectory = "speaker-diarization"
    static let maximumManifestBytes = 1 * 1_024 * 1_024
    static let maximumInputBytes: Int64 = 16 * 1_024 * 1_024 * 1_024
    static let maximumResultBytes = 32 * 1_024 * 1_024

    let manifest: DiarizationHelperJobManifest
    let dataRoot: URL
    let modelsURL: URL
    let resultURL: URL

    init(
        arguments: [String],
        dataRoot: URL,
        expectedModel: SpeakerDiarizationModelManifest = .fluidAudio0155,
        fileManager: FileManager = .default
    ) throws {
        guard let flagIndex = arguments.firstIndex(of: Self.flag),
              arguments.indices.contains(flagIndex + 1) else {
            throw DiarizationHelperCommandError.missingManifestArgument
        }
        let root = dataRoot.standardizedFileURL
        let manifestPath = arguments[flagIndex + 1]
        guard ManagedAssetVerifier.isSafeRelativePath(manifestPath),
              let manifestURL = try? ManagedAssetVerifier.containedURL(
                  root: root,
                  relativePath: manifestPath
              ),
              let values = try? manifestURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0,
              size <= Self.maximumManifestBytes,
              let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode(DiarizationHelperJobManifest.self, from: data)
        else { throw DiarizationHelperCommandError.invalidManifest }

        guard decoded.formatVersion == 1,
              let jobID = UUID(uuidString: decoded.jobID)?.uuidString.lowercased(),
              jobID == decoded.jobID,
              decoded.callID > 0,
              decoded.callGeneration >= 0,
              (0.5...0.9).contains(decoded.clusteringThreshold)
        else { throw DiarizationHelperCommandError.invalidJobIdentity }
        let jobRoot = "call-helper/diarization/\(jobID)"
        guard manifestPath == "\(jobRoot)/manifest.json" else {
            throw DiarizationHelperCommandError.invalidManifestPath
        }
        guard decoded.modelsRelativePath == Self.modelsRelativePath,
              let resolvedModelsRoot = try? ManagedAssetVerifier.containedURL(
                  root: root,
                  relativePath: decoded.modelsRelativePath
              ),
              let resolvedModels = try? ManagedAssetVerifier.containedURL(
                  root: resolvedModelsRoot,
                  relativePath: Self.modelRepositoryDirectory
              ),
              (try? SpeakerDiarizationModelVerifier.verify(
                  directory: resolvedModels,
                  manifest: expectedModel,
                  fileManager: fileManager
              )) == expectedModel.expectedBytes
        else { throw DiarizationHelperCommandError.invalidModelIdentity }
        guard decoded.resultRelativePath == "\(jobRoot)/result.json",
              let resolvedResult = try? ManagedAssetVerifier.containedURL(
                  root: root,
                  relativePath: decoded.resultRelativePath
              )
        else { throw DiarizationHelperCommandError.invalidResultPath }
        guard !fileManager.fileExists(atPath: resolvedResult.path) else {
            throw DiarizationHelperCommandError.outputExists
        }

        var totalInputBytes: Int64 = 0
        for range in decoded.audioRanges {
            let (next, overflow) = totalInputBytes.addingReportingOverflow(range.lengthBytes)
            guard !overflow, range.lengthBytes > 0, next <= Self.maximumInputBytes else {
                throw DiarizationHelperCommandError.inputTooLarge
            }
            totalInputBytes = next
        }
        guard !decoded.audioRanges.isEmpty else {
            throw DiarizationHelperCommandError.invalidAudioRange
        }

        manifest = decoded
        self.dataRoot = root
        modelsURL = resolvedModelsRoot
        resultURL = resolvedResult
    }

    func execute() async throws {
        ModelHub.offlineMode = true
        let models = try await OfflineDiarizerModels.load(from: modelsURL)
        var output: [DiarizationHelperResultSegment] = []

        for source in [CallAudioSource.me, .system] {
            let ranges = manifest.audioRanges.filter { $0.source == source }
            guard !ranges.isEmpty else { continue }
            let samples = try DiarizationPCMSampleSource(root: dataRoot, ranges: ranges)
            var config = OfflineDiarizerConfig(clusteringThreshold: manifest.clusteringThreshold)
            config.exposeChunkEmbeddings = false
            config.export = .none
            let manager = OfflineDiarizerManager(config: config)
            manager.initialize(models: models)
            let result = try await manager.process(
                audioSource: samples,
                audioLoadingSeconds: 0
            )
            for segment in result.segments {
                let start = Double(segment.startTimeSeconds)
                let end = Double(segment.endTimeSeconds)
                let quality = Double(segment.qualityScore)
                guard start.isFinite, end.isFinite, quality.isFinite,
                      start >= 0, end > start,
                      output.count < 1_000_000 else {
                    throw DiarizationHelperCommandError.processingFailed
                }
                output.append(DiarizationHelperResultSegment(
                    source: source,
                    clusterKey: "\(source.rawValue):\(segment.speakerId)",
                    startSeconds: start,
                    endSeconds: end,
                    quality: quality
                ))
            }
        }

        let pinned = SpeakerDiarizationModelManifest.fluidAudio0155
        let result = DiarizationHelperResult(
            formatVersion: 1,
            jobID: manifest.jobID,
            callID: manifest.callID,
            callGeneration: manifest.callGeneration,
            packageVersion: pinned.packageVersion,
            modelRevision: pinned.modelRevision,
            segments: output.sorted {
                ($0.startSeconds, $0.source.rawValue, $0.clusterKey)
                    < ($1.startSeconds, $1.source.rawValue, $1.clusterKey)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        guard data.count <= Self.maximumResultBytes else {
            throw DiarizationHelperCommandError.resultTooLarge
        }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: resultURL, options: .withoutOverwriting)
        } catch {
            throw DiarizationHelperCommandError.outputExists
        }
    }
}
