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

enum CallCaptureOwner: String, Codable, DatabaseValueConvertible, Sendable {
    case manual
    case automatic
    case claimed
}

enum CallCaptureDisposition: String, Codable, DatabaseValueConvertible, Sendable {
    case active
    case confirmed
    case rejected
}

enum CallSpeakerRevisionState: String, Codable, DatabaseValueConvertible, Sendable {
    case writing
    case ready
    case failed
}

enum CallSpeakerNamingProvenance: String, Codable, DatabaseValueConvertible, Sendable {
    case anonymous
    case currentCall = "current_call"
    case manual
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
    var preferredSpeakerRevisionId: Int64? = nil
    var createdAtMs: Int64
    var updatedAtMs: Int64

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct CallContextRow: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "call_context"

    var callId: Int64
    var captureOwner: CallCaptureOwner
    var disposition: CallCaptureDisposition
    var detectorFingerprintHash: String?
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var trustedOriginHost: String?
    var title: String?
    var participantsJSON: String
    var createdAtMs: Int64
    var updatedAtMs: Int64
}

struct CallSpeakerRevisionRow: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    static let databaseTableName = "call_speaker_revisions"

    var id: Int64?
    var callId: Int64
    var mediaGeneration: Int
    var previousRevisionId: Int64?
    var state: CallSpeakerRevisionState
    var engine: String
    var modelRevision: String
    var createdAtMs: Int64

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct CallSpeakerClusterRow: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    static let databaseTableName = "call_speaker_clusters"

    var id: Int64?
    var revisionId: Int64
    var ordinal: Int
    var clusterKey: String
    var displayName: String?
    var namingProvenance: CallSpeakerNamingProvenance

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct CallSpeakerIntervalRow: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    static let databaseTableName = "call_speaker_intervals"

    var id: Int64?
    var revisionId: Int64
    var clusterId: Int64
    var ordinal: Int
    var source: CallAudioSource
    var startMs: Int64
    var endMs: Int64

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct CallSpeakerIntervalDraft: Sendable, Equatable {
    let source: CallAudioSource
    let startMs: Int64
    let endMs: Int64
}

struct CallSpeakerClusterDraft: Sendable, Equatable {
    let clusterKey: String
    let displayName: String?
    let namingProvenance: CallSpeakerNamingProvenance
    let intervals: [CallSpeakerIntervalDraft]
}

struct CallTranscriptSpeakerAlignment: Sendable, Equatable {
    let segment: CallTranscriptSegmentDraft
    let speakerClusterKey: String?
}

/// Assigns transcript segments only when one same-source speaker has a unique
/// maximum amount of overlap. Ties remain anonymous instead of inventing a
/// speaker identity.
enum CallTranscriptSpeakerAligner {
    static func align(
        _ segments: [CallTranscriptSegmentDraft],
        to clusters: [CallSpeakerClusterDraft]
    ) -> [CallTranscriptSpeakerAlignment] {
        segments.map { segment in
            var overlapByCluster: [String: Int64] = [:]
            for cluster in clusters {
                let overlap = cluster.intervals.reduce(into: Int64(0)) { total, interval in
                    guard interval.source == segment.source else { return }
                    total += max(
                        0,
                        min(segment.endMs, interval.endMs) - max(segment.startMs, interval.startMs)
                    )
                }
                if overlap > 0 {
                    overlapByCluster[cluster.clusterKey, default: 0] += overlap
                }
            }

            let maximum = overlapByCluster.values.max()
            let winners = maximum.map { maximum in
                overlapByCluster.compactMap { key, overlap in
                    overlap == maximum ? key : nil
                }
            } ?? []
            return CallTranscriptSpeakerAlignment(
                segment: segment,
                speakerClusterKey: winners.count == 1 ? winners[0] : nil
            )
        }
    }
}

struct CallSpeakerIntervalSelection: Sendable, Equatable {
    let source: CallAudioSource
    let startMs: Int64
    let endMs: Int64
}

enum CallSpeakerCorrectionTarget: Sendable, Equatable {
    case existingCluster(clusterKey: String)
    case newNamedSpeaker(String)
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

struct CallSourceGapRow: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    static let databaseTableName = "call_source_gaps"

    var id: Int64?
    var callId: Int64
    var mediaGeneration: Int
    var source: CallAudioSource
    var startMs: Int64
    var endMs: Int64
    var reason: String
    var createdAtMs: Int64

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

struct CallTranscriptProjectionGapRow: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "call_transcript_projection_gaps"

    var revisionId: Int64
    var bookmarkId: Int64
    var ordinal: Int
    var state: CallBookmarkState
    var logicalStartMs: Int64
    var logicalEndMs: Int64
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

struct CallRedactionSourceSnapshot: Sendable, Equatable {
    let call: CallRow
    let spans: [CallSourceSpanRow]
    let chunks: [CallAudioChunkRow]
}

struct CallRedactionReport: Sendable, Equatable {
    let callID: Int64
    let fromGeneration: Int
    let toGeneration: Int
    let bytesRemoved: Int64
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

struct CallTranscriptJobEvidence: Sendable, Equatable {
    let call: CallRow
    let job: CallTranscriptJobRow
    let bookmark: CallBookmarkRow?
    let chunks: [CallAudioChunkRow]
}

struct CallTranscriptCommitResult: Sendable, Equatable {
    let intervalOrFinalRevisionID: Int64
    let preferredRevisionID: Int64
    let final: Bool
}

/// Immutable inputs for one speaker pass. The preferred final transcript and
/// media generation are captured together so a later privacy edit cannot be
/// promoted as if it described the new evidence.
struct CallSpeakerDiarizationEvidence: Sendable, Equatable {
    let call: CallRow
    let transcriptRevision: CallTranscriptRevisionRow
    let transcriptSegments: [CallTranscriptSegmentRow]
    let chunks: [CallAudioChunkRow]

    var identity: String {
        "\(call.id ?? 0):\(call.mediaGeneration):\(transcriptRevision.id ?? 0)"
    }
}
