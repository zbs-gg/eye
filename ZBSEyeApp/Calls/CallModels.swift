import Foundation
import GRDB

enum CallLifecycleState: String, Codable, DatabaseValueConvertible, Sendable {
    case recording
    case finalizing
    case interrupted
    case ready
    case failed
}

enum CallAudioSource: String, Codable, DatabaseValueConvertible, Sendable {
    case me
    case system
}

enum CallSourceAvailability: String, Codable, DatabaseValueConvertible, Sendable {
    case available
    case unavailable
    case gap
}

enum CallBookmarkState: String, Codable, DatabaseValueConvertible, Sendable {
    case preparing
    case pending
    case deferredCapacity = "deferred_capacity"
    case ready
    case readyDegraded = "ready_degraded"
    case failed
    case satisfiedByFinal = "satisfied_by_final"
}

enum CallTranscriptJobKind: String, Codable, DatabaseValueConvertible, Sendable {
    case checkpoint
    case final
}

enum CallTranscriptJobState: String, Codable, DatabaseValueConvertible, Sendable {
    case preparing
    case deferredCapacity = "deferred_capacity"
    case pending
    case running
    case satisfiedByFinal = "satisfied_by_final"
    case ready
    case readyDegraded = "ready_degraded"
    case failed
    case cancelled
}

enum CallTranscriptRevisionKind: String, Codable, DatabaseValueConvertible, Sendable {
    case interval
    case projection
    case final
}

enum CallTranscriptRevisionState: String, Codable, DatabaseValueConvertible, Sendable {
    case writing
    case ready
    case failed
}

enum CallMediaMutationKind: String, Codable, DatabaseValueConvertible, Sendable {
    case redaction
    case erase
}

enum CallMediaMutationState: String, Codable, DatabaseValueConvertible, Sendable {
    case staged
    case referenceSwapped = "reference_swapped"
    case cleanupPending = "cleanup_pending"
    case completed
    case rolledBack = "rolled_back"
    case failed
}

struct CallRow: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    static let databaseTableName = "calls"

    var id: Int64?
    var startIdempotencyKey: String
    var endIdempotencyKey: String?
    var startTs: Int64
    var endTs: Int64?
    var state: CallLifecycleState
    var interrupted: Bool
    var degradationReason: String?
    var mediaGeneration: Int
    var preferredRevisionId: Int64?
    var createdAtMs: Int64
    var updatedAtMs: Int64

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct CallSourceSpanRow: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    static let databaseTableName = "call_source_spans"

    var id: Int64?
    var callId: Int64
    var source: CallAudioSource
    var epoch: Int
    var sampleRate: Int
    var startedAtMs: Int64
    var endedAtMs: Int64?
    var startSample: Int64
    var endSample: Int64?
    var startHostTimeNs: Int64
    var endHostTimeNs: Int64?
    var availability: CallSourceAvailability
    var gapReason: String?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct CallAudioChunkRow: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    static let databaseTableName = "call_audio_chunks"

    var id: Int64?
    var callId: Int64
    var sourceSpanId: Int64
    var source: CallAudioSource
    var epoch: Int
    var sequence: Int
    var mediaGeneration: Int
    var startSample: Int64
    var endSample: Int64
    var startMs: Int64
    var endMs: Int64
    var relativePath: String
    var bytes: Int64
    var sha256: String?
    var finalized: Bool

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct CallBookmarkRow: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    static let databaseTableName = "call_bookmarks"

    var id: Int64?
    var callId: Int64
    var idempotencyKey: String
    var ordinal: Int
    var acceptedAtMs: Int64
    var meIngressTarget: Int64?
    var systemIngressTarget: Int64?
    var logicalStartMs: Int64
    var logicalEndMs: Int64
    var contextStartMs: Int64
    var state: CallBookmarkState
    var mediaGeneration: Int

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct CallTranscriptJobRow: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    static let databaseTableName = "call_transcript_jobs"

    var id: Int64?
    var identity: String
    var callId: Int64
    var bookmarkId: Int64?
    var kind: CallTranscriptJobKind
    var mediaGeneration: Int
    var state: CallTranscriptJobState
    var priority: Int
    var logicalStartMs: Int64
    var logicalEndMs: Int64
    var contextStartMs: Int64
    var meEndSample: Int64?
    var systemEndSample: Int64?
    var coverageFrozen: Bool
    var attempts: Int
    var errorCode: String?
    var createdAtMs: Int64
    var updatedAtMs: Int64

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct CallTranscriptRevisionRow: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    static let databaseTableName = "call_transcript_revisions"

    var id: Int64?
    var callId: Int64
    var jobId: Int64?
    var projectionKey: String?
    var kind: CallTranscriptRevisionKind
    var mediaGeneration: Int
    var state: CallTranscriptRevisionState
    var text: String
    var language: String
    var engine: String
    var modelRevision: String
    var logicalStartMs: Int64
    var logicalEndMs: Int64
    var createdAtMs: Int64

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct CallTranscriptSegmentRow: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    static let databaseTableName = "call_transcript_segments"

    var id: Int64?
    var revisionId: Int64
    var ordinal: Int
    var source: CallAudioSource
    var startMs: Int64
    var endMs: Int64
    var text: String

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct CallMediaMutationRow: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    static let databaseTableName = "call_media_mutations"

    var id: Int64?
    var identity: String
    var callId: Int64
    var kind: CallMediaMutationKind
    var state: CallMediaMutationState
    var fromGeneration: Int
    var toGeneration: Int
    var oldRelativePathsJSON: String
    var newRelativePathsJSON: String
    var createdAtMs: Int64
    var updatedAtMs: Int64
    var errorCode: String?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct CallSourceSpanDraft: Sendable, Equatable {
    var callId: Int64
    var source: CallAudioSource
    var epoch: Int
    var sampleRate: Int
    var startedAtMs: Int64
    var startSample: Int64
    var startHostTimeNs: Int64
    var availability: CallSourceAvailability
    var gapReason: String?

    init(
        callId: Int64,
        source: CallAudioSource,
        epoch: Int,
        sampleRate: Int,
        startedAtMs: Int64,
        startSample: Int64,
        startHostTimeNs: Int64,
        availability: CallSourceAvailability,
        gapReason: String? = nil
    ) {
        self.callId = callId
        self.source = source
        self.epoch = epoch
        self.sampleRate = sampleRate
        self.startedAtMs = startedAtMs
        self.startSample = startSample
        self.startHostTimeNs = startHostTimeNs
        self.availability = availability
        self.gapReason = gapReason
    }
}

struct CallAudioChunkDraft: Sendable, Equatable {
    var callId: Int64
    var sourceSpanId: Int64
    var source: CallAudioSource
    var epoch: Int
    var sequence: Int
    var mediaGeneration: Int
    var startSample: Int64
    var endSample: Int64
    var startMs: Int64
    var endMs: Int64
    var relativePath: String
    var bytes: Int64
    var sha256: String?
    var finalized: Bool
}

struct CallBookmarkCreation: Sendable, Equatable {
    var bookmark: CallBookmarkRow
    var job: CallTranscriptJobRow
}

struct CallRecoveryDatabaseReport: Sendable, Equatable {
    var callsInterrupted: Int
    var jobsReset: Int
    var finalJobsCreated: Int
}

struct CallRecoveryReport: Sendable, Equatable {
    var callsInterrupted: Int
    var jobsReset: Int
    var finalJobsCreated: Int
    var chunksFinalized: Int
    var chunksDiscarded: Int
    var mutationsCompleted: Int
    var mutationsRolledBack: Int
}
