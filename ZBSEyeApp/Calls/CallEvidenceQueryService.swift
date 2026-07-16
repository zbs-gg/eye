import Foundation
import GRDB

struct CallTranscriptRevisionSummary: Sendable, Equatable, FetchableRecord, Decodable {
    let id: Int64
    let kind: CallTranscriptRevisionKind
    let state: CallTranscriptRevisionState
}

struct CallEvidencePage: Sendable, Equatable {
    let call: CallRow
    let sourceSpans: [CallSourceSpanRow]
    let sourceSpansTruncated: Bool
    let bookmarks: [CallBookmarkRow]
    let bookmarksTruncated: Bool
    let finalJob: CallTranscriptJobRow?
    let preferredRevision: CallTranscriptRevisionSummary?
    let projectionGaps: [CallTranscriptProjectionGapRow]
    let projectionGapsTruncated: Bool
    let segments: [CallTranscriptSegmentRow]
    let segmentOffset: Int
    let hasMoreSegments: Bool
}

/// Bounded, read-only projection used by the compact call strip and Call
/// Detail. Search/Timeline/REST/MCP extend this same evidence vocabulary in
/// later units instead of teaching each surface its own call semantics.
actor CallEvidenceQueryService {
    static let maximumSegmentPage = 200
    static let maximumSourceSpans = 512
    static let maximumBookmarks = 1_000
    static let maximumProjectionGaps = 1_000

    private let database: ZBSEyeDatabase

    init(database: ZBSEyeDatabase) {
        self.database = database
    }

    func latestCall(
        segmentOffset: Int = 0,
        segmentLimit: Int = 80
    ) async throws -> CallEvidencePage? {
        let callID = try await database.pool.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT id FROM calls ORDER BY startTs DESC, id DESC LIMIT 1"
            )
        }
        guard let callID else { return nil }
        return try await call(
            id: callID,
            segmentOffset: segmentOffset,
            segmentLimit: segmentLimit
        )
    }

    func call(
        id callID: Int64,
        segmentOffset: Int = 0,
        segmentLimit: Int = 80
    ) async throws -> CallEvidencePage? {
        let offset = max(0, segmentOffset)
        let limit = min(Self.maximumSegmentPage, max(1, segmentLimit))
        return try await database.pool.read { db in
            guard let call = try CallRow.fetchOne(db, key: callID) else { return nil }
            let sourceRows = try CallSourceSpanRow.fetchAll(
                db,
                sql: """
                    SELECT * FROM call_source_spans
                    WHERE callId = ?
                    ORDER BY
                      CASE WHEN availability = ? OR gapReason IS NOT NULL THEN 0 ELSE 1 END,
                      source, epoch DESC, id DESC
                    LIMIT ?
                    """,
                arguments: [
                    callID,
                    CallSourceAvailability.gap.rawValue,
                    Self.maximumSourceSpans + 1,
                ]
            )
            let bookmarkRows = try CallBookmarkRow.fetchAll(
                db,
                sql: """
                    SELECT * FROM call_bookmarks
                    WHERE callId = ? ORDER BY ordinal, id LIMIT ?
                    """,
                arguments: [callID, Self.maximumBookmarks + 1]
            )
            let sourceSpans = Array(sourceRows.prefix(Self.maximumSourceSpans))
            let bookmarks = Array(bookmarkRows.prefix(Self.maximumBookmarks))
            let finalJob = try CallTranscriptJobRow.fetchOne(
                db,
                sql: """
                    SELECT * FROM call_transcript_jobs
                    WHERE callId = ? AND mediaGeneration = ? AND kind = ?
                    ORDER BY id DESC LIMIT 1
                    """,
                arguments: [
                    callID,
                    call.mediaGeneration,
                    CallTranscriptJobKind.final.rawValue,
                ]
            )
            let revision = try call.preferredRevisionId.flatMap { revisionID in
                try CallTranscriptRevisionSummary.fetchOne(
                    db,
                    sql: """
                        SELECT id, kind, state
                        FROM call_transcript_revisions WHERE id = ?
                        """,
                    arguments: [revisionID]
                )
            }
            let gapRows: [CallTranscriptProjectionGapRow]
            let segmentRows: [CallTranscriptSegmentRow]
            if let revisionID = revision?.id {
                gapRows = try CallTranscriptProjectionGapRow.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM call_transcript_projection_gaps
                        WHERE revisionId = ? ORDER BY ordinal, bookmarkId
                        LIMIT ?
                        """,
                    arguments: [revisionID, Self.maximumProjectionGaps + 1]
                )
                segmentRows = try CallTranscriptSegmentRow.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM call_transcript_segments
                        WHERE revisionId = ?
                        ORDER BY ordinal, id
                        LIMIT ? OFFSET ?
                        """,
                    arguments: [revisionID, limit + 1, offset]
                )
            } else {
                gapRows = []
                segmentRows = []
            }
            return CallEvidencePage(
                call: call,
                sourceSpans: sourceSpans,
                sourceSpansTruncated: sourceRows.count > Self.maximumSourceSpans,
                bookmarks: bookmarks,
                bookmarksTruncated: bookmarkRows.count > Self.maximumBookmarks,
                finalJob: finalJob,
                preferredRevision: revision,
                projectionGaps: Array(gapRows.prefix(Self.maximumProjectionGaps)),
                projectionGapsTruncated: gapRows.count > Self.maximumProjectionGaps,
                segments: Array(segmentRows.prefix(limit)),
                segmentOffset: offset,
                hasMoreSegments: segmentRows.count > limit
            )
        }
    }
}
