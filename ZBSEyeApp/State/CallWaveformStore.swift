import Foundation
import Observation

struct CallWaveformSnapshot: Sendable, Equatable {
    let microphone: [Double]
    let system: [Double]

    static let empty = CallWaveformSnapshot(microphone: [], system: [])
}

/// Reads one tiny PCM window per visual bin. A long call never becomes a retained waveform file
/// or a whole-call in-memory buffer; rebuilding a 320-bin preview reads at most ~1.3 MB per source.
@MainActor
@Observable
final class CallWaveformStore {
    private(set) var snapshot = CallWaveformSnapshot.empty
    private(set) var loading = false
    private(set) var errorMessage: String?

    func load(
        callID: Int64,
        durationSeconds: Double,
        service: CallEvidenceQueryService,
        mediaRoot: URL,
        binCount: Int = 320
    ) async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            async let microphoneChunks = service.playbackChunks(callID: callID, source: .me)
            async let systemChunks = service.playbackChunks(callID: callID, source: .system)
            let root = try SecureCallSpoolRoot(root: mediaRoot)
            let (microphone, system) = try await (microphoneChunks, systemChunks)
            snapshot = try await Task.detached(priority: .utility) {
                CallWaveformSnapshot(
                    microphone: try Self.samples(
                        chunks: microphone,
                        durationSeconds: durationSeconds,
                        binCount: binCount,
                        root: root
                    ),
                    system: try Self.samples(
                        chunks: system,
                        durationSeconds: durationSeconds,
                        binCount: binCount,
                        root: root
                    )
                )
            }.value
        } catch {
            snapshot = .empty
            errorMessage = error.localizedDescription
        }
    }

    nonisolated static func samples(
        chunks: [CallPlaybackChunk],
        durationSeconds: Double,
        binCount: Int,
        root: SecureCallSpoolRoot
    ) throws -> [Double] {
        guard durationSeconds > 0, (32...1_024).contains(binCount) else { return [] }
        let ordered = chunks.sorted { $0.startSample < $1.startSample }
        guard !ordered.isEmpty else { return [] }
        let totalSamples = max(1, Int64(durationSeconds * 16_000))
        let probeSamples: Int64 = 2_048
        var result = Array(repeating: 0.0, count: binCount)
        var chunkIndex = 0

        for bin in 0..<binCount {
            let center = min(
                totalSamples - 1,
                Int64((Double(bin) + 0.5) / Double(binCount) * Double(totalSamples))
            )
            while chunkIndex + 1 < ordered.count, ordered[chunkIndex].endSample <= center {
                chunkIndex += 1
            }
            let chunk = ordered[chunkIndex]
            guard center >= chunk.startSample, center < chunk.endSample else { continue }
            let start = min(
                max(chunk.startSample, center - probeSamples / 2),
                max(chunk.startSample, chunk.endSample - 1)
            )
            let count = Int(min(probeSamples, chunk.endSample - start))
            guard count > 0 else { continue }
            let data = try root.readRange(
                relativePath: chunk.relativePath,
                offset: (start - chunk.startSample) * 2,
                byteCount: count * 2
            )
            guard data.count == count * 2 else { throw CallWaveformError.shortRead }
            var peak: Int32 = 0
            data.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                var index = 0
                while index + 1 < bytes.count {
                    let bits = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                    let sample = Int32(abs(Int(Int16(bitPattern: bits))))
                    peak = max(peak, sample)
                    index += 2
                }
            }
            // Square-root emphasis keeps quiet speech visible without claiming exact loudness.
            result[bin] = sqrt(min(1, Double(peak) / 32_768))
        }
        return result
    }
}

private enum CallWaveformError: LocalizedError {
    case shortRead

    var errorDescription: String? {
        String(localized: "A call waveform sample could not be read safely.")
    }
}
