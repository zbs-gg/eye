import CTranscribe
import Foundation

public enum TranscribeCppRunnerError: Error, Sendable, Equatable {
    case backendInitializationFailed(Int32)
    case modelLoadFailed(Int32)
    case inferenceFailed(Int32)
    case sampleCountOverflow
}

/// Direct, synchronous access to the same MIT-licensed transcribe.cpp runtime
/// Handy uses. Eye runs this only inside its own short-lived helper process;
/// Handy.app is never launched and the shared model is never copied.
public final class TranscribeCppSession {
    private let session: OpaquePointer

    public init(modelURL: URL) throws {
        let backendStatus = transcribe_init_backends_default()
        guard backendStatus == TRANSCRIBE_OK else {
            throw TranscribeCppRunnerError.backendInitializationFailed(
                Int32(backendStatus.rawValue)
            )
        }

        var loaded: OpaquePointer?
        let status = modelURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return TRANSCRIBE_ERR_INVALID_ARG }
            return transcribe_open(path, nil, nil, &loaded)
        }
        guard status == TRANSCRIBE_OK, let loaded else {
            throw TranscribeCppRunnerError.modelLoadFailed(Int32(status.rawValue))
        }
        session = loaded
    }

    deinit {
        transcribe_session_free(session)
    }

    public func transcribe(samples: [Float]) throws -> [WhisperSegment] {
        guard !samples.isEmpty else { return [] }
        guard samples.count <= Int(Int32.max) else {
            throw TranscribeCppRunnerError.sampleCountOverflow
        }
        let status = samples.withUnsafeBufferPointer { buffer in
            transcribe_run(session, buffer.baseAddress, Int32(buffer.count), nil)
        }
        guard status == TRANSCRIBE_OK else {
            throw TranscribeCppRunnerError.inferenceFailed(Int32(status.rawValue))
        }
        guard let pointer = transcribe_full_text(session) else { return [] }
        let text = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.rangeOfCharacter(from: .alphanumerics) != nil else { return [] }
        return [
            WhisperSegment(
                startSeconds: 0,
                endSeconds: Double(samples.count) / 16_000,
                text: text
            ),
        ]
    }
}

public enum TranscribeCppRuntimeIdentity {
    public static let release = "transcribe.cpp-v0.1.3"
    public static let archiveSHA256 = "b7a3442e2f3552cac1ee71b5e164934dd4db243f6b4b16b1e3e3ed5d1645eefd"
}
