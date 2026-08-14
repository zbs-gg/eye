import AVFoundation
import CryptoKit
import Foundation

/// Adds a convenient mixed AAC track after authoritative PCM has closed.
/// It never runs on the capture path and never replaces the separate source
/// tracks as evidence.
actor CallVideoPostProcessor {
    private let repository: CallRepository
    private let mediaRoot: URL

    init(repository: CallRepository, mediaRoot: URL) {
        self.repository = repository
        self.mediaRoot = mediaRoot
    }

    func process(callID: Int64) async {
        guard let snapshot = try? await repository.videoPostprocessSnapshot(callID: callID),
              snapshot.call.state != .recording,
              !snapshot.videoSegments.isEmpty else { return }
        for segment in snapshot.videoSegments where !Task.isCancelled {
            do {
                try await mux(segment: segment, snapshot: snapshot)
            } catch {
                try? await repository.markCallDegraded(
                    callID: callID,
                    reason: "video_audio_mux_unavailable",
                    nowMs: Int64(Date().timeIntervalSince1970 * 1_000)
                )
            }
        }
    }

    private func mux(
        segment: CallVideoSegmentRow,
        snapshot: CallVideoPostprocessSnapshot
    ) async throws {
        guard let segmentID = segment.id else { return }
        let samples = try mixedPCM(segment: segment, snapshot: snapshot)
        guard !samples.isEmpty else { return }
        let original = try containedURL(segment.relativePath)
        let audioURL = original.appendingPathExtension("mix.m4a")
        let muxedURL = original.appendingPathExtension("muxed.partial")
        let backupName = original.lastPathComponent + ".silent-backup"
        let backupURL = original.deletingLastPathComponent().appendingPathComponent(backupName)
        let fileManager = FileManager.default
        defer {
            try? fileManager.removeItem(at: audioURL)
            try? fileManager.removeItem(at: muxedURL)
        }
        try? fileManager.removeItem(at: audioURL)
        try? fileManager.removeItem(at: muxedURL)
        try? fileManager.removeItem(at: backupURL)
        try writeAAC(samples, to: audioURL)

        let videoAsset = AVURLAsset(url: original)
        let audioAsset = AVURLAsset(url: audioURL)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let compositionAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw CocoaError(.fileWriteUnknown) }
        try compositionVideo.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: videoTrack,
            at: .zero
        )
        try compositionAudio.insertTimeRange(
            CMTimeRange(start: .zero, duration: min(videoDuration, audioDuration)),
            of: audioTrack,
            at: .zero
        )
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else { throw CocoaError(.featureUnsupported) }
        try await exporter.export(to: muxedURL, as: .mp4)
        let muxedAsset = AVURLAsset(url: muxedURL)
        guard !(try await muxedAsset.loadTracks(withMediaType: .video)).isEmpty,
              !(try await muxedAsset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        _ = try fileManager.replaceItemAt(
            original,
            withItemAt: muxedURL,
            backupItemName: backupName,
            options: []
        )
        let data = try Data(contentsOf: original, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        do {
            try await repository.markVideoSegmentAudioMuxed(
                id: segmentID,
                mediaGeneration: segment.mediaGeneration,
                bytes: Int64(data.count),
                sha256: digest
            )
            try? fileManager.removeItem(at: backupURL)
        } catch {
            if fileManager.fileExists(atPath: backupURL.path) {
                _ = try? fileManager.replaceItemAt(original, withItemAt: backupURL)
            }
            throw error
        }
    }

    private func mixedPCM(
        segment: CallVideoSegmentRow,
        snapshot: CallVideoPostprocessSnapshot
    ) throws -> [Int16] {
        let sampleCount = max(1, Int((segment.endMs - segment.startMs) * 16))
        var microphone = [Int16](repeating: 0, count: sampleCount)
        var system = [Int16](repeating: 0, count: sampleCount)
        var hasMicrophone = false
        var hasSystem = false
        let spans = Dictionary(
            uniqueKeysWithValues: snapshot.audioSpans.compactMap { span in span.id.map { ($0, span) } }
        )
        let root = try SecureCallSpoolRoot(root: mediaRoot)
        for chunk in snapshot.audioChunks {
            guard let span = spans[chunk.sourceSpanId], span.sampleRate == 16_000 else { continue }
            let lowerMs = max(segment.startMs, chunk.startMs)
            let upperMs = min(segment.endMs, chunk.endMs)
            guard lowerMs < upperMs else { continue }
            let lowerSample = max(
                chunk.startSample,
                span.startSample + (lowerMs - span.startedAtMs) * 16
            )
            let upperSample = min(
                chunk.endSample,
                span.startSample + (upperMs - span.startedAtMs) * 16
            )
            guard lowerSample < upperSample else { continue }
            let count = Int(upperSample - lowerSample)
            let data = try root.readRange(
                relativePath: chunk.relativePath,
                offset: (lowerSample - chunk.startSample) * 2,
                byteCount: count * 2
            )
            guard data.count == count * 2 else { throw CocoaError(.fileReadCorruptFile) }
            let outputStart = max(0, Int((lowerMs - segment.startMs) * 16))
            data.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for index in 0..<min(count, sampleCount - outputStart) {
                    let bits = UInt16(bytes[index * 2]) | (UInt16(bytes[index * 2 + 1]) << 8)
                    if chunk.source == .me {
                        microphone[outputStart + index] = Int16(bitPattern: bits)
                    } else {
                        system[outputStart + index] = Int16(bitPattern: bits)
                    }
                }
            }
            if chunk.source == .me { hasMicrophone = true } else { hasSystem = true }
        }
        guard hasMicrophone || hasSystem else { return [] }
        return microphone.indices.map { index in
            if hasMicrophone && hasSystem {
                return Int16(clamping: (Int32(microphone[index]) + Int32(system[index])) / 2)
            }
            return hasMicrophone ? microphone[index] : system[index]
        }
    }

    private func writeAAC(_ samples: [Int16], to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.int16ChannelData?.pointee else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { memcpy(channel, base, bytes.count) }
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ],
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private func containedURL(_ relativePath: String) throws -> URL {
        guard CapturedMediaReconciler.isSafeRelativePath(relativePath) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let root = mediaRoot.standardizedFileURL
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadNoPermission) }
        return url
    }
}
