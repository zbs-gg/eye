import AVFoundation
import CryptoKit
import Foundation

struct CallVideoPostprocessLease: Sendable, Equatable {
    fileprivate let generation: UInt64
}

/// Call audio invalidates this lease synchronously and never waits for video
/// convenience work to drain. The postprocessor cooperatively abandons its
/// replaceable AAC/MP4 generation while the authoritative PCM writers continue.
final class CallVideoPostprocessAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var suspended = false

    func suspend() {
        lock.lock()
        generation &+= 1
        suspended = true
        lock.unlock()
    }

    func resume() {
        lock.lock()
        generation &+= 1
        suspended = false
        lock.unlock()
    }

    func acquire() -> CallVideoPostprocessLease? {
        lock.lock()
        defer { lock.unlock() }
        guard !suspended else { return nil }
        return CallVideoPostprocessLease(generation: generation)
    }

    func permits(_ lease: CallVideoPostprocessLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !suspended && generation == lease.generation
    }
}

private final class SendableCallVideoExporter: @unchecked Sendable {
    let value: AVAssetExportSession

    init(_ value: AVAssetExportSession) {
        self.value = value
    }
}

/// Adds a convenient mixed AAC track after authoritative PCM has closed.
/// It never runs on the capture path and never replaces the separate source
/// tracks as evidence.
actor CallVideoPostProcessor {
    private let repository: CallRepository
    private let mediaRoot: URL
    private let admissionGate: CallVideoPostprocessAdmissionGate
    private var processingCallIDs: Set<Int64> = []
    private var rerunCallIDs: Set<Int64> = []

    init(
        repository: CallRepository,
        mediaRoot: URL,
        admissionGate: CallVideoPostprocessAdmissionGate
    ) {
        self.repository = repository
        self.mediaRoot = mediaRoot
        self.admissionGate = admissionGate
    }

    func process(callID: Int64) async {
        if processingCallIDs.contains(callID) {
            rerunCallIDs.insert(callID)
            return
        }
        processingCallIDs.insert(callID)
        defer {
            processingCallIDs.remove(callID)
            rerunCallIDs.remove(callID)
        }
        repeat {
            guard let lease = admissionGate.acquire() else { return }
            await processOnce(callID: callID, lease: lease)
        } while rerunCallIDs.remove(callID) != nil
    }

    private func processOnce(
        callID: Int64,
        lease: CallVideoPostprocessLease
    ) async {
        guard let snapshot = try? await repository.videoPostprocessSnapshot(callID: callID),
              snapshot.call.state != .recording,
              !snapshot.videoSegments.isEmpty else { return }
        for segment in snapshot.videoSegments where !Task.isCancelled && !segment.audioMuxed {
            do {
                try checkAdmission(lease)
                try await mux(segment: segment, snapshot: snapshot, lease: lease)
            } catch is CancellationError {
                return
            } catch {
                Log.audio.error(
                    "call_video_audio_mux_failed: \(error.localizedDescription, privacy: .private)"
                )
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
        snapshot: CallVideoPostprocessSnapshot,
        lease: CallVideoPostprocessLease
    ) async throws {
        try checkAdmission(lease)
        guard let segmentID = segment.id else { return }
        let samples = try mixedPCM(segment: segment, snapshot: snapshot, lease: lease)
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
        try writeAAC(samples, to: audioURL, lease: lease)
        try checkAdmission(lease)

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
        let sendableExporter = SendableCallVideoExporter(exporter)
        let cancellationWatcher = Task.detached(priority: .userInitiated) { [admissionGate] in
            while admissionGate.permits(lease), !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !admissionGate.permits(lease) else { return }
            sendableExporter.value.cancelExport()
        }
        defer { cancellationWatcher.cancel() }
        do {
            try await exporter.export(to: muxedURL, as: .mp4)
        } catch {
            try checkAdmission(lease)
            throw error
        }
        try checkAdmission(lease)
        let muxedAsset = AVURLAsset(url: muxedURL)
        guard !(try await muxedAsset.loadTracks(withMediaType: .video)).isEmpty,
              !(try await muxedAsset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        do {
            try checkAdmission(lease)
            _ = try fileManager.replaceItemAt(
                original,
                withItemAt: muxedURL,
                backupItemName: backupName,
                options: []
            )
            try checkAdmission(lease)
            let data = try Data(contentsOf: original, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try checkAdmission(lease)
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
        snapshot: CallVideoPostprocessSnapshot,
        lease: CallVideoPostprocessLease
    ) throws -> [Int16] {
        try checkAdmission(lease)
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
            try checkAdmission(lease)
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
            try data.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for index in 0..<min(count, sampleCount - outputStart) {
                    if index.isMultiple(of: 4_096) {
                        try checkAdmission(lease)
                    }
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
        var mixed = [Int16](repeating: 0, count: sampleCount)
        for index in mixed.indices {
            if index.isMultiple(of: 4_096) { try checkAdmission(lease) }
            if hasMicrophone && hasSystem {
                mixed[index] = Int16(
                    clamping: (Int32(microphone[index]) + Int32(system[index])) / 2
                )
            } else {
                mixed[index] = hasMicrophone ? microphone[index] : system[index]
            }
        }
        return mixed
    }

    private func writeAAC(
        _ samples: [Int16],
        to url: URL,
        lease: CallVideoPostprocessLease
    ) throws {
        try checkAdmission(lease)
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
            ],
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        try file.write(from: buffer)
        try checkAdmission(lease)
    }

    private nonisolated func checkAdmission(_ lease: CallVideoPostprocessLease) throws {
        guard admissionGate.permits(lease), !Task.isCancelled else {
            throw CancellationError()
        }
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
