import AVFoundation
import Foundation
import Observation

struct CallPlaybackChunk: Sendable, Equatable {
    let relativePath: String
    let startSample: Int64
    let endSample: Int64
    let bytes: Int64
}

/// Streams one ten-second PCM spool chunk at a time. Playback never builds a
/// whole-call Float array or a second retained media file, so a two-hour call
/// remains bounded and stopping playback releases private bytes immediately.
@MainActor
@Observable
final class CallPlaybackStore {
    private(set) var isPlaying = false
    private(set) var source: CallAudioSource?
    private(set) var errorMessage: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private var items: [Item] = []
    @ObservationIgnored private var itemIndex = 0
    @ObservationIgnored private var spoolRoot: SecureCallSpoolRoot?

    private enum Item {
        case silence(Int)
        case chunk(CallPlaybackChunk)
    }

    func toggle(
        callID: Int64,
        source requestedSource: CallAudioSource,
        service: CallEvidenceQueryService,
        mediaRoot: URL
    ) {
        if source == requestedSource, !items.isEmpty {
            if isPlaying {
                player.pause()
                isPlaying = false
            } else {
                player.play()
                isPlaying = true
            }
            return
        }
        stop()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let chunks = try await service.playbackChunks(callID: callID, source: requestedSource)
                guard !chunks.isEmpty else {
                    self.errorMessage = "This source has no playable audio."
                    return
                }
                self.spoolRoot = try SecureCallSpoolRoot(root: mediaRoot)
                self.source = requestedSource
                self.items = Self.makeItems(chunks)
                try self.startEngine()
                self.scheduleNext()
                self.player.play()
                self.isPlaying = true
            } catch {
                self.stop()
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        engine.reset()
        items.removeAll(keepingCapacity: false)
        itemIndex = 0
        spoolRoot = nil
        source = nil
        isPlaying = false
    }

    private func startEngine() throws {
        if !engine.attachedNodes.contains(player) { engine.attach(player) }
        let format = try Self.format()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
    }

    private func scheduleNext() {
        guard itemIndex < items.count else {
            isPlaying = false
            return
        }
        do {
            let buffer = try buffer(for: items[itemIndex])
            itemIndex += 1
            player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                Task { @MainActor in self?.scheduleNext() }
            }
        } catch {
            errorMessage = error.localizedDescription
            stop()
        }
    }

    private func buffer(for item: Item) throws -> AVAudioPCMBuffer {
        let sampleCount: Int
        let data: Data?
        switch item {
        case let .silence(count):
            sampleCount = count
            data = nil
        case let .chunk(chunk):
            guard let spoolRoot,
                  chunk.bytes > 0,
                  chunk.bytes <= 2 * 160_000,
                  chunk.bytes.isMultiple(of: 2) else {
                throw CallPlaybackError.unsafePath
            }
            let loaded = try spoolRoot.readRange(
                relativePath: chunk.relativePath,
                offset: 0,
                byteCount: Int(chunk.bytes)
            )
            guard loaded.count == Int(chunk.bytes) else { throw CallPlaybackError.shortRead }
            sampleCount = loaded.count / 2
            data = loaded
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: try Self.format(),
            frameCapacity: AVAudioFrameCount(sampleCount)
        ), let channel = buffer.int16ChannelData?.pointee else {
            throw CallPlaybackError.invalidFormat
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        if let data {
            data.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { memcpy(channel, base, data.count) }
            }
        } else {
            memset(channel, 0, sampleCount * MemoryLayout<Int16>.size)
        }
        return buffer
    }

    private static func makeItems(_ chunks: [CallPlaybackChunk]) -> [Item] {
        let ordered = chunks.sorted {
            ($0.startSample, $0.endSample, $0.relativePath)
                < ($1.startSample, $1.endSample, $1.relativePath)
        }
        guard let first = ordered.first else { return [] }
        var cursor = first.startSample
        var result: [Item] = []
        for chunk in ordered where chunk.endSample > chunk.startSample {
            var gap = max(0, chunk.startSample - cursor)
            while gap > 0 {
                let count = Int(min(gap, 160_000))
                result.append(.silence(count))
                gap -= Int64(count)
            }
            result.append(.chunk(chunk))
            cursor = max(cursor, chunk.endSample)
        }
        return result
    }

    private static func format() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { throw CallPlaybackError.invalidFormat }
        return format
    }
}

private enum CallPlaybackError: LocalizedError {
    case unsafePath
    case shortRead
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .unsafePath: "The call audio path is outside Eye's managed storage."
        case .shortRead: "The call audio chunk is incomplete."
        case .invalidFormat: "The call audio format is unavailable."
        }
    }
}
