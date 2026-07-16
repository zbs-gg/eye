import Foundation
import whisper

public enum WhisperRunnerError: Error, Sendable, Equatable {
    case modelLoadFailed
    case inferenceFailed(Int32)
    case sampleCountOverflow
}

public struct WhisperSegment: Codable, Sendable, Equatable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String

    public init(startSeconds: Double, endSeconds: Double, text: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
    }
}

/// Synchronous by design: ZBS Eye runs this only inside a one-job helper
/// process, so native model state never crosses an actor or remains resident in
/// the GUI after the helper exits.
public final class WhisperSession {
    private let context: OpaquePointer

    public init(modelURL: URL) throws {
        var parameters = whisper_context_default_params()
        parameters.use_gpu = true
        let loaded: OpaquePointer? = modelURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            return whisper_init_from_file_with_params(path, parameters)
        }
        guard let loaded else {
            throw WhisperRunnerError.modelLoadFailed
        }
        context = loaded
    }

    deinit {
        whisper_free(context)
    }

    public func transcribe(samples: [Float]) throws -> [WhisperSegment] {
        guard samples.count <= Int(Int32.max) else {
            throw WhisperRunnerError.sampleCountOverflow
        }
        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        parameters.translate = false
        parameters.no_context = true
        parameters.no_timestamps = false
        parameters.print_special = false
        parameters.print_progress = false
        parameters.print_realtime = false
        parameters.print_timestamps = false

        let status = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, parameters, buffer.baseAddress, Int32(buffer.count))
        }
        guard status == 0 else { throw WhisperRunnerError.inferenceFailed(status) }

        let count = whisper_full_n_segments(context)
        return (0..<count).compactMap { index in
            guard let pointer = whisper_full_get_segment_text(context, index) else { return nil }
            return WhisperSegment(
                startSeconds: Double(whisper_full_get_segment_t0(context, index)) / 100,
                endSeconds: Double(whisper_full_get_segment_t1(context, index)) / 100,
                text: String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

public enum WhisperRuntimeIdentity {
    public static let release = "v1.9.1"
    public static let archiveSHA256 = "8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c"
}
