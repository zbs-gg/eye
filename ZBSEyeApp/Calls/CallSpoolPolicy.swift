import Foundation

struct CallSpoolPolicy: Sendable, Equatable {
    let sampleRate: Int
    let maxSamplesPerChunk: Int64

    init(sampleRate: Int = 16_000, maxSamplesPerChunk: Int = 160_000) {
        self.sampleRate = sampleRate
        self.maxSamplesPerChunk = Int64(maxSamplesPerChunk)
    }
}

struct CallSpoolEpochDescriptor: Codable, Sendable, Equatable {
    let epoch: Int
    let captureSampleRate: Int
    let startSample: Int64
    let startHostTimeNs: Int64
    let startedAtMs: Int64
}

struct CallSpoolChunk: Codable, Sendable, Equatable {
    let epoch: Int
    let sequence: Int
    let startSample: Int64
    var endSample: Int64
    let relativePath: String
    var committedBytes: Int64
    var finalized: Bool
}

struct CallSpoolWatermark: Codable, Sendable, Equatable {
    let ingressSequence: Int64
    let endSample: Int64
    let normalizedHostTimeNs: Int64
    let committedBytes: Int64
}

struct CallSpoolSnapshot: Codable, Sendable, Equatable {
    let callID: Int64
    let source: CallAudioSource
    let sampleRate: Int
    let epochs: [CallSpoolEpochDescriptor]
    let gaps: [AudioIngressGap]
    let chunks: [CallSpoolChunk]
    let watermark: CallSpoolWatermark?

    var activeChunk: CallSpoolChunk? {
        chunks.last(where: { !$0.finalized })
    }
}

enum CallSpoolError: LocalizedError, Sendable, Equatable {
    case invalidPolicy
    case noActiveEpoch
    case invalidEpoch
    case invalidPCM
    case unsafePath
    case fileAlreadyExists
    case shortRead

    var errorDescription: String? {
        switch self {
        case .invalidPolicy: "Invalid call spool policy."
        case .noActiveEpoch: "The call source has no active epoch."
        case .invalidEpoch: "The call source epoch is not monotonic."
        case .invalidPCM: "The call spool received malformed PCM16LE bytes."
        case .unsafePath: "The call spool path is outside its managed root."
        case .fileAlreadyExists: "The call spool file already exists."
        case .shortRead: "The call spool contains fewer committed bytes than expected."
        }
    }
}
