import AVFoundation
import CryptoKit
import Foundation
import VideoToolbox

enum CallRedactionPlanError: Error, Sendable, Equatable {
    case invalidRange
    case invalidChunk
    case stagedFileMismatch
}

struct CallRedactionChunkManifest: Codable, Sendable, Equatable {
    var sourceSpanID: Int64
    var source: CallAudioSource
    var epoch: Int
    var sequence: Int
    var startSample: Int64
    var endSample: Int64
    var startMs: Int64
    var endMs: Int64
    var sourceRelativePath: String
    var sourceOffsetBytes: Int64
    var relativePath: String
    var bytes: Int64
    var sha256: String
}

struct CallRedactionGapManifest: Codable, Sendable, Equatable {
    var source: CallAudioSource
    var startMs: Int64
    var endMs: Int64
}

struct CallRedactionVideoGapManifest: Codable, Sendable, Equatable {
    var startMs: Int64
    var endMs: Int64
}

struct CallRedactionVideoFragmentManifest: Codable, Sendable, Equatable {
    var videoSpanID: Int64
    var epoch: Int
    var sequence: Int
    var startMs: Int64
    var endMs: Int64
    var sourceStartMs: Int64
    var sourceEndMs: Int64
    var sourceRelativePath: String
    var sourceSha256: String? = nil
    var relativePath: String
    var bytes: Int64?
    var sha256: String?
    var width: Int
    var height: Int
    var fps: Int
    var codec: CallVideoCodec
    var audioMuxed: Bool
}

struct CallRedactionManifestV1: Codable, Sendable, Equatable {
    static let formatVersion = 1

    var formatVersion: Int
    var callID: Int64
    var fromGeneration: Int
    var toGeneration: Int
    var fromMs: Int64
    var toMs: Int64
    var bytesRemoved: Int64
    var obsoleteRelativePaths: [String]
    var redactedGaps: [CallRedactionGapManifest]
    var survivors: [CallRedactionChunkManifest]
    /// Optional for crash-forward compatibility with manifests written before
    /// Call video existed.
    var videoRedactedGaps: [CallRedactionVideoGapManifest]? = nil
    var videoSurvivors: [CallRedactionVideoFragmentManifest]? = nil

    func encodedJSON() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    static func decode(_ json: String) -> Self? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct CallRedactionPlanner: Sendable {
    private let secureRoot: SecureCallSpoolRoot

    init(mediaRoot: URL) throws {
        secureRoot = try SecureCallSpoolRoot(root: mediaRoot)
    }

    func makeManifest(
        snapshot: CallRedactionSourceSnapshot,
        fromMs requestedFromMs: Int64,
        toMs requestedToMs: Int64
    ) throws -> CallRedactionManifestV1 {
        guard let callID = snapshot.call.id,
              snapshot.call.state != .recording,
              let callEnd = snapshot.call.endTs,
              requestedFromMs < requestedToMs else {
            throw CallRedactionPlanError.invalidRange
        }
        let fromMs = max(snapshot.call.startTs, requestedFromMs)
        let toMs = min(callEnd, requestedToMs)
        guard fromMs < toMs else { throw CallRedactionPlanError.invalidRange }
        let nextGenerationResult = snapshot.call.mediaGeneration.addingReportingOverflow(1)
        guard !nextGenerationResult.overflow else { throw CallRedactionPlanError.invalidRange }
        let nextGeneration = nextGenerationResult.partialValue
        let spans = Dictionary(
            uniqueKeysWithValues: snapshot.spans.compactMap { span in
                span.id.map { ($0, span) }
            }
        )

        var survivors: [CallRedactionChunkManifest] = []
        var obsoletePaths: [String] = []
        var redactedGapsBySource: [String: CallRedactionGapManifest] = [:]
        var bytesRemoved: Int64 = 0
        for chunk in snapshot.chunks.sorted(by: Self.chunkOrder) {
            let sampleCount = chunk.endSample.subtractingReportingOverflow(chunk.startSample)
            let expectedBytes = sampleCount.partialValue.multipliedReportingOverflow(by: 2)
            guard chunk.finalized,
                  chunk.bytes > 0,
                  chunk.bytes <= Int64(Int.max),
                  chunk.bytes.isMultiple(of: 2),
                  chunk.mediaGeneration == snapshot.call.mediaGeneration,
                  !sampleCount.overflow,
                  sampleCount.partialValue > 0,
                  !expectedBytes.overflow,
                  chunk.bytes == expectedBytes.partialValue,
                  let span = spans[chunk.sourceSpanId],
                  span.sampleRate > 0 else {
                throw CallRedactionPlanError.invalidChunk
            }
            let original = try secureRoot.readRange(
                relativePath: chunk.relativePath,
                offset: 0,
                byteCount: Int(chunk.bytes)
            )
            guard original.count == Int(chunk.bytes) else {
                throw CallRedactionPlanError.invalidChunk
            }
            let originalHash = Self.digest(original)
            if let expected = chunk.sha256, !expected.isEmpty, expected != originalHash {
                throw CallRedactionPlanError.invalidChunk
            }

            let cutStart = max(
                chunk.startSample,
                Self.sampleFloor(atMs: fromMs, span: span)
            )
            let cutEnd = min(
                chunk.endSample,
                Self.sampleCeil(atMs: toMs, span: span)
            )
            guard cutStart < cutEnd,
                  chunk.endMs > fromMs,
                  chunk.startMs < toMs else {
                survivors.append(
                    Self.fragment(
                        chunk: chunk,
                        startSample: chunk.startSample,
                        endSample: chunk.endSample,
                        startMs: chunk.startMs,
                        endMs: chunk.endMs,
                        sourceOffsetBytes: 0,
                        relativePath: chunk.relativePath,
                        bytes: chunk.bytes,
                        sha256: originalHash
                    )
                )
                continue
            }

            obsoletePaths.append(chunk.relativePath)
            let actualGapStart = max(chunk.startMs, Self.timeMs(for: cutStart, span: span))
            let actualGapEnd = min(chunk.endMs, Self.timeMs(for: cutEnd, span: span))
            if let previous = redactedGapsBySource[chunk.source.rawValue] {
                redactedGapsBySource[chunk.source.rawValue] = CallRedactionGapManifest(
                    source: chunk.source,
                    startMs: min(previous.startMs, actualGapStart),
                    endMs: max(previous.endMs, actualGapEnd)
                )
            } else {
                redactedGapsBySource[chunk.source.rawValue] = CallRedactionGapManifest(
                    source: chunk.source,
                    startMs: actualGapStart,
                    endMs: actualGapEnd
                )
            }
            let removedBytes = (cutEnd - cutStart) * 2
            let removedTotal = bytesRemoved.addingReportingOverflow(removedBytes)
            bytesRemoved = removedTotal.overflow ? Int64.max : removedTotal.partialValue

            if cutStart > chunk.startSample {
                let length = (cutStart - chunk.startSample) * 2
                let data = original.prefix(Int(length))
                survivors.append(
                    Self.fragment(
                        chunk: chunk,
                        startSample: chunk.startSample,
                        endSample: cutStart,
                        startMs: chunk.startMs,
                        endMs: min(chunk.endMs, Self.timeMs(for: cutStart, span: span)),
                        sourceOffsetBytes: 0,
                        relativePath: Self.replacementPath(
                            chunk: chunk,
                            generation: nextGeneration,
                            suffix: "prefix"
                        ),
                        bytes: length,
                        sha256: Self.digest(Data(data))
                    )
                )
            }
            if cutEnd < chunk.endSample {
                let offset = (cutEnd - chunk.startSample) * 2
                let length = (chunk.endSample - cutEnd) * 2
                let range = Int(offset)..<Int(offset + length)
                survivors.append(
                    Self.fragment(
                        chunk: chunk,
                        startSample: cutEnd,
                        endSample: chunk.endSample,
                        startMs: max(chunk.startMs, Self.timeMs(for: cutEnd, span: span)),
                        endMs: chunk.endMs,
                        sourceOffsetBytes: offset,
                        relativePath: Self.replacementPath(
                            chunk: chunk,
                            generation: nextGeneration,
                            suffix: "suffix"
                        ),
                        bytes: length,
                        sha256: Self.digest(original.subdata(in: range))
                    )
                )
            }
        }

        survivors.sort {
            ($0.source.rawValue, $0.epoch, $0.startSample, $0.relativePath)
                < ($1.source.rawValue, $1.epoch, $1.startSample, $1.relativePath)
        }
        var nextSequence: [String: Int] = [:]
        for index in survivors.indices {
            let key = "\(survivors[index].source.rawValue):\(survivors[index].epoch)"
            survivors[index].sequence = nextSequence[key, default: 0]
            nextSequence[key, default: 0] += 1
        }

        let redactedGaps = redactedGapsBySource.values.sorted {
            ($0.source.rawValue, $0.startMs, $0.endMs)
                < ($1.source.rawValue, $1.startMs, $1.endMs)
        }
        var videoRedactedGaps: [CallRedactionVideoGapManifest] = []
        var videoSurvivors: [CallRedactionVideoFragmentManifest] = []
        for segment in snapshot.videoSegments.sorted(by: {
            ($0.epoch, $0.startMs, $0.sequence) < ($1.epoch, $1.startMs, $1.sequence)
        }) {
            guard segment.finalized, segment.endMs > segment.startMs else {
                throw CallRedactionPlanError.invalidChunk
            }
            let videoSpanID = segment.videoSpanId
            guard segment.endMs > fromMs && segment.startMs < toMs else {
                videoSurvivors.append(Self.videoFragment(
                    segment: segment,
                    videoSpanID: videoSpanID,
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    relativePath: segment.relativePath,
                    bytes: segment.bytes,
                    sha256: segment.sha256
                ))
                continue
            }
            obsoletePaths.append(segment.relativePath)
            videoRedactedGaps.append(CallRedactionVideoGapManifest(
                startMs: max(segment.startMs, fromMs),
                endMs: min(segment.endMs, toMs)
            ))
            if segment.startMs < fromMs {
                videoSurvivors.append(Self.videoFragment(
                    segment: segment,
                    videoSpanID: videoSpanID,
                    startMs: segment.startMs,
                    endMs: min(fromMs, segment.endMs),
                    relativePath: Self.videoReplacementPath(
                        segment: segment,
                        generation: nextGeneration,
                        suffix: "prefix"
                    ),
                    bytes: nil,
                    sha256: nil
                ))
            }
            if segment.endMs > toMs {
                videoSurvivors.append(Self.videoFragment(
                    segment: segment,
                    videoSpanID: videoSpanID,
                    startMs: max(toMs, segment.startMs),
                    endMs: segment.endMs,
                    relativePath: Self.videoReplacementPath(
                        segment: segment,
                        generation: nextGeneration,
                        suffix: "suffix"
                    ),
                    bytes: nil,
                    sha256: nil
                ))
            }
        }
        var nextVideoSequence: [Int: Int] = [:]
        for index in videoSurvivors.indices {
            videoSurvivors[index].sequence = nextVideoSequence[videoSurvivors[index].epoch, default: 0]
            nextVideoSequence[videoSurvivors[index].epoch, default: 0] += 1
        }
        return CallRedactionManifestV1(
            formatVersion: Self.formatVersion,
            callID: callID,
            fromGeneration: snapshot.call.mediaGeneration,
            toGeneration: nextGeneration,
            fromMs: fromMs,
            toMs: toMs,
            bytesRemoved: bytesRemoved,
            obsoleteRelativePaths: Array(Set(obsoletePaths)).sorted(),
            redactedGaps: redactedGaps,
            survivors: survivors,
            videoRedactedGaps: videoRedactedGaps,
            videoSurvivors: videoSurvivors
        )
    }

    private static let formatVersion = CallRedactionManifestV1.formatVersion

    private static func chunkOrder(_ lhs: CallAudioChunkRow, _ rhs: CallAudioChunkRow) -> Bool {
        (lhs.source.rawValue, lhs.epoch, lhs.sequence, lhs.id ?? 0)
            < (rhs.source.rawValue, rhs.epoch, rhs.sequence, rhs.id ?? 0)
    }

    private static func fragment(
        chunk: CallAudioChunkRow,
        startSample: Int64,
        endSample: Int64,
        startMs: Int64,
        endMs: Int64,
        sourceOffsetBytes: Int64,
        relativePath: String,
        bytes: Int64,
        sha256: String
    ) -> CallRedactionChunkManifest {
        CallRedactionChunkManifest(
            sourceSpanID: chunk.sourceSpanId,
            source: chunk.source,
            epoch: chunk.epoch,
            sequence: 0,
            startSample: startSample,
            endSample: endSample,
            startMs: startMs,
            endMs: endMs,
            sourceRelativePath: chunk.relativePath,
            sourceOffsetBytes: sourceOffsetBytes,
            relativePath: relativePath,
            bytes: bytes,
            sha256: sha256
        )
    }

    private static func replacementPath(
        chunk: CallAudioChunkRow,
        generation: Int,
        suffix: String
    ) -> String {
        "calls/\(chunk.callId)/\(chunk.source.rawValue)/epoch-\(String(format: "%04d", chunk.epoch))/redacted-g\(String(format: "%04d", generation))-c\(String(format: "%06d", chunk.sequence))-\(suffix).pcm"
    }

    private static func videoFragment(
        segment: CallVideoSegmentRow,
        videoSpanID: Int64,
        startMs: Int64,
        endMs: Int64,
        relativePath: String,
        bytes: Int64?,
        sha256: String?
    ) -> CallRedactionVideoFragmentManifest {
        CallRedactionVideoFragmentManifest(
            videoSpanID: videoSpanID,
            epoch: segment.epoch,
            sequence: 0,
            startMs: startMs,
            endMs: endMs,
            sourceStartMs: segment.startMs,
            sourceEndMs: segment.endMs,
            sourceRelativePath: segment.relativePath,
            sourceSha256: segment.sha256,
            relativePath: relativePath,
            bytes: bytes,
            sha256: sha256,
            width: segment.width,
            height: segment.height,
            fps: segment.fps,
            codec: segment.codec,
            audioMuxed: segment.audioMuxed
        )
    }

    private static func videoReplacementPath(
        segment: CallVideoSegmentRow,
        generation: Int,
        suffix: String
    ) -> String {
        "calls/\(segment.callId)/video/epoch-\(String(format: "%04d", segment.epoch))/redacted-g\(String(format: "%04d", generation))-s\(String(format: "%06d", segment.sequence))-\(suffix).mp4"
    }

    private static func sampleFloor(atMs timeMs: Int64, span: CallSourceSpanRow) -> Int64 {
        guard timeMs > span.startedAtMs else { return span.startSample }
        let delta = timeMs - span.startedAtMs
        let scaled = delta.multipliedReportingOverflow(by: Int64(span.sampleRate))
        guard !scaled.overflow else { return Int64.max }
        let result = span.startSample.addingReportingOverflow(scaled.partialValue / 1_000)
        return result.overflow ? Int64.max : result.partialValue
    }

    private static func sampleCeil(atMs timeMs: Int64, span: CallSourceSpanRow) -> Int64 {
        guard timeMs > span.startedAtMs else { return span.startSample }
        let delta = timeMs - span.startedAtMs
        let scaled = delta.multipliedReportingOverflow(by: Int64(span.sampleRate))
        guard !scaled.overflow else { return Int64.max }
        let rounded = scaled.partialValue.addingReportingOverflow(999)
        guard !rounded.overflow else { return Int64.max }
        let result = span.startSample.addingReportingOverflow(rounded.partialValue / 1_000)
        return result.overflow ? Int64.max : result.partialValue
    }

    private static func timeMs(for sample: Int64, span: CallSourceSpanRow) -> Int64 {
        let delta = max(0, sample - span.startSample)
        let scaled = delta.multipliedReportingOverflow(by: 1_000)
        guard !scaled.overflow else { return Int64.max }
        let result = span.startedAtMs.addingReportingOverflow(
            scaled.partialValue / Int64(span.sampleRate)
        )
        return result.overflow ? Int64.max : result.partialValue
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct CallRedactionFileStore {
    private let secureRoot: SecureCallSpoolRoot
    private let mediaRoot: URL

    init(mediaRoot: URL) throws {
        self.mediaRoot = mediaRoot.standardizedFileURL
        secureRoot = try SecureCallSpoolRoot(root: mediaRoot)
    }

    func stageAndVerify(_ manifest: CallRedactionManifestV1) throws {
        guard manifest.formatVersion == CallRedactionManifestV1.formatVersion else {
            throw CallRedactionPlanError.stagedFileMismatch
        }
        for survivor in manifest.survivors {
            let data = try secureRoot.readRange(
                relativePath: survivor.sourceRelativePath,
                offset: survivor.sourceOffsetBytes,
                byteCount: Int(survivor.bytes)
            )
            guard data.count == Int(survivor.bytes), Self.digest(data) == survivor.sha256 else {
                throw CallRedactionPlanError.stagedFileMismatch
            }
            if survivor.relativePath == survivor.sourceRelativePath { continue }
            try writeVerified(data, survivor: survivor)
        }
    }

    func removeObsolete(_ manifest: CallRedactionManifestV1) throws -> Int {
        var live = Set(manifest.survivors.map(\.relativePath))
        live.formUnion((manifest.videoSurvivors ?? []).map(\.relativePath))
        var removed = 0
        for path in manifest.obsoleteRelativePaths where !live.contains(path) {
            if try secureRoot.removeFile(relativePath: path) {
                removed += 1
            }
        }
        return removed
    }

    func stageVideoAndVerify(
        _ input: CallRedactionManifestV1
    ) async throws -> CallRedactionManifestV1 {
        var manifest = input
        var fragments = manifest.videoSurvivors ?? []
        var retainedVideoBytes: Int64 = 0
        var originalVideoBytes: Int64 = 0
        let obsolete = Set(manifest.obsoleteRelativePaths)
        var countedOriginalVideoPaths: Set<String> = []
        for index in fragments.indices {
            var fragment = fragments[index]
            let source = try containedURL(fragment.sourceRelativePath)
            if let expectedSourceHash = fragment.sourceSha256, !expectedSourceHash.isEmpty {
                let sourceData = try Data(contentsOf: source, options: .mappedIfSafe)
                guard Self.digest(sourceData) == expectedSourceHash else {
                    throw CallRedactionPlanError.stagedFileMismatch
                }
            }
            if obsolete.contains(fragment.sourceRelativePath),
               countedOriginalVideoPaths.insert(fragment.sourceRelativePath).inserted {
                let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
                originalVideoBytes = Self.saturatingAdd(
                    originalVideoBytes,
                    (attributes[.size] as? NSNumber)?.int64Value ?? 0
                )
            }
            let data: Data
            if fragment.relativePath == fragment.sourceRelativePath {
                data = try Data(contentsOf: source, options: .mappedIfSafe)
            } else {
                let destination = try containedURL(fragment.relativePath)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let partial = destination.deletingPathExtension()
                        .appendingPathExtension("partial.mp4")
                    try? FileManager.default.removeItem(at: partial)
                    fragment.codec = try await transcodeVideoFragment(
                        source: source,
                        destination: partial,
                        fragment: fragment
                    )
                    let outputAsset = AVURLAsset(url: partial)
                    guard !(try await outputAsset.loadTracks(withMediaType: .video)).isEmpty else {
                        throw CallRedactionPlanError.stagedFileMismatch
                    }
                    try FileManager.default.moveItem(at: partial, to: destination)
                }
                data = try Data(contentsOf: destination, options: .mappedIfSafe)
            }
            guard !data.isEmpty else { throw CallRedactionPlanError.stagedFileMismatch }
            fragment.codec = try await detectedVideoCodec(at: try containedURL(fragment.relativePath))
            fragment.bytes = Int64(data.count)
            fragment.sha256 = Self.digest(data)
            if obsolete.contains(fragment.sourceRelativePath) {
                retainedVideoBytes = Self.saturatingAdd(retainedVideoBytes, Int64(data.count))
            }
            fragments[index] = fragment
        }
        manifest.videoSurvivors = fragments
        let removedVideoBytes = max(0, originalVideoBytes - retainedVideoBytes)
        manifest.bytesRemoved = Self.saturatingAdd(manifest.bytesRemoved, removedVideoBytes)
        return manifest
    }

    private func detectedVideoCodec(at url: URL) async throws -> CallVideoCodec {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let description = try await track.load(.formatDescriptions).first else {
            throw CallRedactionPlanError.stagedFileMismatch
        }
        switch CMFormatDescriptionGetMediaSubType(description) {
        case kCMVideoCodecType_HEVC:
            return .hevc
        case kCMVideoCodecType_H264:
            return .h264
        default:
            throw CallRedactionPlanError.stagedFileMismatch
        }
    }

    private func transcodeVideoFragment(
        source: URL,
        destination: URL,
        fragment: CallRedactionVideoFragmentManifest
    ) async throws -> CallVideoCodec {
        for codec in [CallVideoCodec.hevc, .h264] {
            try? FileManager.default.removeItem(at: destination)
            do {
                try await transcodeVideoFragment(
                    source: source,
                    destination: destination,
                    fragment: fragment,
                    codec: codec
                )
                return codec
            } catch {
                try? FileManager.default.removeItem(at: destination)
                if codec == .h264 { throw error }
            }
        }
        throw CallRedactionPlanError.stagedFileMismatch
    }

    private func transcodeVideoFragment(
        source: URL,
        destination: URL,
        fragment: CallRedactionVideoFragmentManifest,
        codec: CallVideoCodec
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CallRedactionPlanError.stagedFileMismatch
        }
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw CallRedactionPlanError.stagedFileMismatch
        }
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let codecType: AVVideoCodecType = codec == .hevc ? .hevc : .h264
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: fragment.width,
            AVVideoHeightKey: fragment.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_000_000,
                AVVideoExpectedSourceFrameRateKey: fragment.fps,
                AVVideoMaxKeyFrameIntervalKey: max(1, fragment.fps * 2),
                AVVideoAllowFrameReorderingKey: false,
            ],
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
            ],
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw CallRedactionPlanError.stagedFileMismatch
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        guard writer.canAdd(videoInput) else {
            throw CallRedactionPlanError.stagedFileMismatch
        }
        writer.add(videoInput)

        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let audioDescription = try await audioTrack.load(.formatDescriptions).first
            let basicDescription = audioDescription.flatMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
            }
            let sampleRate = basicDescription?.mSampleRate ?? 16_000
            let channelCount = max(1, Int(basicDescription?.mChannelsPerFrame ?? 1))
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channelCount,
                    AVEncoderBitRateKey: channelCount == 1 ? 64_000 : 128_000,
                ]
            )
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                audioOutput = output
                audioInput = input
            }
        }

        let offset = CMTime(
            seconds: Double(fragment.startMs - fragment.sourceStartMs) / 1_000,
            preferredTimescale: 600
        )
        let duration = CMTime(
            seconds: Double(fragment.endMs - fragment.startMs) / 1_000,
            preferredTimescale: 600
        )
        guard duration > .zero else { throw CallRedactionPlanError.stagedFileMismatch }
        reader.timeRange = CMTimeRange(start: offset, duration: duration)
        guard writer.startWriting(), reader.startReading() else {
            throw writer.error ?? reader.error ?? CallRedactionPlanError.stagedFileMismatch
        }
        writer.startSession(atSourceTime: offset)

        var videoFinished = false
        var audioFinished = audioOutput == nil
        while !videoFinished || !audioFinished {
            var progressed = false
            if !videoFinished, videoInput.isReadyForMoreMediaData {
                if let sample = videoOutput.copyNextSampleBuffer() {
                    guard videoInput.append(sample) else {
                        reader.cancelReading()
                        writer.cancelWriting()
                        throw writer.error ?? CallRedactionPlanError.stagedFileMismatch
                    }
                } else {
                    videoInput.markAsFinished()
                    videoFinished = true
                }
                progressed = true
            }
            if !audioFinished,
               let audioOutput,
               let audioInput,
               audioInput.isReadyForMoreMediaData {
                if let sample = audioOutput.copyNextSampleBuffer() {
                    guard audioInput.append(sample) else {
                        reader.cancelReading()
                        writer.cancelWriting()
                        throw writer.error ?? CallRedactionPlanError.stagedFileMismatch
                    }
                } else {
                    audioInput.markAsFinished()
                    audioFinished = true
                }
                progressed = true
            }
            if !progressed { try await Task.sleep(for: .milliseconds(2)) }
            guard reader.status != .failed, writer.status != .failed else {
                reader.cancelReading()
                writer.cancelWriting()
                throw writer.error ?? reader.error ?? CallRedactionPlanError.stagedFileMismatch
            }
        }
        guard reader.status == .completed else {
            writer.cancelWriting()
            throw reader.error ?? CallRedactionPlanError.stagedFileMismatch
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CallRedactionPlanError.stagedFileMismatch
        }
    }

    private func writeVerified(_ data: Data, survivor: CallRedactionChunkManifest) throws {
        do {
            let existing = try secureRoot.readRange(
                relativePath: survivor.relativePath,
                offset: 0,
                byteCount: Int(survivor.bytes)
            )
            if existing.count == Int(survivor.bytes), Self.digest(existing) == survivor.sha256 {
                return
            }
            _ = try secureRoot.removeFile(relativePath: survivor.relativePath)
        } catch let error as POSIXError where error.code == .ENOENT {
            // Expected on the first attempt.
        }
        let (_, handle) = try secureRoot.createWritableFile(relativePath: survivor.relativePath)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try secureRoot.synchronizeParent(relativePath: survivor.relativePath)
        } catch {
            try? handle.close()
            throw error
        }
        let written = try secureRoot.readRange(
            relativePath: survivor.relativePath,
            offset: 0,
            byteCount: Int(survivor.bytes)
        )
        guard written.count == Int(survivor.bytes), Self.digest(written) == survivor.sha256 else {
            throw CallRedactionPlanError.stagedFileMismatch
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func containedURL(_ relativePath: String) throws -> URL {
        guard CapturedMediaReconciler.isSafeRelativePath(relativePath) else {
            throw CallRedactionPlanError.invalidChunk
        }
        let url = mediaRoot.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(mediaRoot.path + "/") else {
            throw CallRedactionPlanError.invalidChunk
        }
        return url
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }
}

enum CallHelperScratchError: Error, LocalizedError, Sendable, Equatable {
    case unsafeEntry
    case globalLimitExceeded

    var errorDescription: String? {
        switch self {
        case .unsafeEntry:
            "Call transcription scratch contained an unsafe filesystem entry."
        case .globalLimitExceeded:
            "Call transcription scratch exceeded its 64 MB safety limit."
        }
    }
}

struct CallHelperScratchInventory: Sendable, Equatable {
    let jobDirectories: Int
    let bytes: Int64
}

/// Ephemeral helper results live outside retained evidence. The worker is
/// serial, so every directory except the currently launching helper is an
/// abandoned crash artifact and can be reclaimed deterministically.
struct CallHelperScratchStore: @unchecked Sendable {
    static let maximumResultBytes: Int64 = 32 * 1_024 * 1_024
    static let maximumGlobalBytes: Int64 = 64 * 1_024 * 1_024

    let dataRoot: URL
    private let fileManager: FileManager

    init(dataRoot: URL, fileManager: FileManager = .default) {
        self.dataRoot = dataRoot.standardizedFileURL
        self.fileManager = fileManager
    }

    var jobsRoot: URL {
        StorageLocation.callHelperRoot(under: dataRoot)
            .appendingPathComponent("jobs", isDirectory: true)
    }

    func prepareForJob(_ jobID: String) throws {
        guard UUID(uuidString: jobID)?.uuidString.lowercased() == jobID else {
            throw CallHelperScratchError.unsafeEntry
        }
        try scavenge(excluding: jobID)
        let inventory = try inventory()
        guard inventory.bytes <= Self.maximumGlobalBytes else {
            throw CallHelperScratchError.globalLimitExceeded
        }
    }

    @discardableResult
    func scavenge(excluding jobID: String? = nil) throws -> CallHelperScratchInventory {
        try fileManager.createDirectory(
            at: jobsRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: jobsRoot.path
        )
        for url in try fileManager.contentsOfDirectory(
            at: jobsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) {
            if url.lastPathComponent == jobID { continue }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                try fileManager.removeItem(at: url)
                continue
            }
            guard values.isDirectory == true else {
                try fileManager.removeItem(at: url)
                continue
            }
            try fileManager.removeItem(at: url)
        }
        return try inventory()
    }

    func inventory() throws -> CallHelperScratchInventory {
        guard fileManager.fileExists(atPath: jobsRoot.path) else {
            return CallHelperScratchInventory(jobDirectories: 0, bytes: 0)
        }
        let roots = try fileManager.contentsOfDirectory(
            at: jobsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        var bytes: Int64 = 0
        var directories = 0
        for root in roots {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CallHelperScratchError.unsafeEntry
            }
            directories += 1
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                ],
                options: []
            ) else { continue }
            for case let url as URL in enumerator {
                let item = try url.resourceValues(
                    forKeys: [
                        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                    ]
                )
                guard item.isSymbolicLink != true else {
                    throw CallHelperScratchError.unsafeEntry
                }
                if item.isRegularFile == true {
                    let size = Int64(item.fileSize ?? 0)
                    let next = bytes.addingReportingOverflow(size)
                    guard !next.overflow else {
                        throw CallHelperScratchError.globalLimitExceeded
                    }
                    bytes = next.partialValue
                } else if item.isDirectory != true {
                    throw CallHelperScratchError.unsafeEntry
                }
            }
        }
        return CallHelperScratchInventory(jobDirectories: directories, bytes: bytes)
    }
}
