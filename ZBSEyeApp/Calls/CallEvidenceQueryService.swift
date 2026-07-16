import Foundation
import GRDB

enum CallTranscriptSelector: String, Codable, Sendable {
    case preferred
    case bookmark
}

enum CallEvidenceStatus: String, Codable, Sendable {
    case recording
    case processing
    case retryable
    case ready
    case degraded
}

enum CallEvidenceSourceHealth: String, Codable, Sendable {
    case available
    case gapped
    case missing
}

enum CallEvidenceRequestError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidPagination
    case invalidSelector
    case bookmarkRequired
    case bookmarkDoesNotBelongToCall
    case notFound
}

enum CallEvidenceContract {
    static let maximumPage = 100
    static let maximumOffset = 1_000_000
    static let maximumEvidenceReferences = 200
}

struct CallEvidencePageRequest: Sendable, Equatable {
    let limit: Int
    let offset: Int

    init(limit: Int, offset: Int) throws {
        guard (1...CallEvidenceContract.maximumPage).contains(limit),
              offset >= 0,
              offset <= CallEvidenceContract.maximumOffset,
              offset <= Int.max - limit else {
            throw CallEvidenceRequestError.invalidPagination
        }
        self.limit = limit
        self.offset = offset
    }
}

enum CallEvidenceIdentifier {
    static func call(_ id: Int64) -> String { "call:\(id)" }
    static func bookmark(_ id: Int64) -> String { "bookmark:\(id)" }
    static func revision(_ id: Int64) -> String { "call-transcript-revision:\(id)" }
    static func segment(_ id: Int64) -> String { "call-transcript-segment:\(id)" }
    static func audioChunk(_ id: Int64) -> String { "call-audio-chunk:\(id)" }

    static func parseCall(_ value: String) -> Int64? { parse(value, prefix: "call:") }
    static func parseBookmark(_ value: String) -> Int64? { parse(value, prefix: "bookmark:") }
    static func parseAudioChunk(_ value: String) -> Int64? { parse(value, prefix: "call-audio-chunk:") }

    private static func parse(_ value: String, prefix: String) -> Int64? {
        guard value.hasPrefix(prefix),
              let id = Int64(value.dropFirst(prefix.count)),
              id > 0 else { return nil }
        return id
    }
}

struct CallEvidenceSummary: Codable, Sendable, Equatable {
    let callId: String
    let startTs: Int64
    let endTs: Int64?
    let state: CallLifecycleState
    let status: CallEvidenceStatus
    let retryable: Bool
    let preferredRevisionKind: CallTranscriptRevisionKind?
}

struct CallEvidenceListPage: Codable, Sendable, Equatable {
    let query: String?
    let limit: Int
    let offset: Int
    let hasMore: Bool
    let nextOffset: Int?
    let calls: [CallEvidenceSummary]
}

struct CallEvidenceSource: Codable, Sendable, Equatable {
    let source: CallAudioSource
    let health: CallEvidenceSourceHealth
    let spanCount: Int
    let gapCount: Int
    let coveredFromMs: Int64?
    let coveredToMs: Int64?
}

struct CallEvidenceCoverage: Codable, Sendable, Equatable {
    let logicalStartMs: Int64
    let logicalEndMs: Int64?
    let complete: Bool
    let hasExplicitGaps: Bool
}

struct CallEvidenceRevision: Codable, Sendable, Equatable {
    let revisionId: String
    let kind: CallTranscriptRevisionKind
    let state: CallTranscriptRevisionState
    let language: String
    let engine: String
    let modelRevision: String
    let logicalStartMs: Int64
    let logicalEndMs: Int64
}

struct CallEvidenceReference: Codable, Sendable, Equatable {
    let evidenceId: String
    let source: CallAudioSource
    let startMs: Int64
    let endMs: Int64
    let bytes: Int64
}

struct CallEvidenceEnvelope: Codable, Sendable, Equatable {
    let callId: String
    let startTs: Int64
    let endTs: Int64?
    let state: CallLifecycleState
    let status: CallEvidenceStatus
    let retryable: Bool
    let degradationCode: String?
    let coverage: CallEvidenceCoverage
    let sources: [CallEvidenceSource]
    let preferredRevision: CallEvidenceRevision?
    let bookmarkCount: Int
    let evidence: [CallEvidenceReference]
    let evidenceTruncated: Bool
}

struct CallEvidenceBookmark: Codable, Sendable, Equatable {
    let bookmarkId: String
    let callId: String
    let ordinal: Int
    let acceptedAtMs: Int64
    let logicalStartMs: Int64
    let logicalEndMs: Int64
    let state: CallBookmarkState
    let retryable: Bool
}

struct CallEvidenceBookmarkPage: Codable, Sendable, Equatable {
    let callId: String
    let limit: Int
    let offset: Int
    let hasMore: Bool
    let nextOffset: Int?
    let bookmarks: [CallEvidenceBookmark]
}

struct CallEvidenceTranscriptSegment: Codable, Sendable, Equatable {
    let segmentId: String
    let ordinal: Int
    let source: CallAudioSource
    let startMs: Int64
    let endMs: Int64
    let text: String
}

struct CallEvidenceTranscriptPage: Codable, Sendable, Equatable {
    let callId: String
    let selector: CallTranscriptSelector
    let bookmarkId: String?
    let revision: CallEvidenceRevision?
    let limit: Int
    let offset: Int
    let hasMore: Bool
    let nextOffset: Int?
    let segments: [CallEvidenceTranscriptSegment]
}

struct CallAudioEvidenceFile: Sendable, Equatable {
    let reference: CallEvidenceReference
    let relativePath: String
}

struct CallTranscriptRevisionSummary: Sendable, Equatable, FetchableRecord, Decodable {
    let id: Int64
    let kind: CallTranscriptRevisionKind
    let state: CallTranscriptRevisionState
}

struct CallEvidencePage: Sendable, Equatable {
    let call: CallRow
    let sourceSpans: [CallSourceSpanRow]
    let sourceSpansTruncated: Bool
    let sourceGaps: [CallSourceGapRow]
    let sourceGapsTruncated: Bool
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
    static let maximumSourceGaps = 1_000
    static let maximumBookmarks = 1_000
    static let maximumProjectionGaps = 1_000

    private let database: ZBSEyeDatabase

    init(database: ZBSEyeDatabase) {
        self.database = database
    }

    func listCalls(
        query: String? = nil,
        fromMs: Int64? = nil,
        toMs: Int64? = nil,
        limit: Int = 25,
        offset: Int = 0
    ) async throws -> CallEvidenceListPage {
        let page = try CallEvidencePageRequest(limit: limit, offset: offset)
        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let from = fromMs ?? 0
        let to = toMs ?? Int64.max
        guard from <= to else { throw CallEvidenceRequestError.invalidPagination }
        let match = normalizedQuery.map(SearchService.ftsQuery) ?? ""
        let rows = try database.pool.read { db -> [Row] in
            let commonProjection = """
                SELECT c.*,
                       r.kind AS revisionKind,
                       r.state AS revisionState,
                       (SELECT j.state FROM call_transcript_jobs j
                        WHERE j.callId = c.id AND j.mediaGeneration = c.mediaGeneration AND j.kind = 'final'
                        ORDER BY j.id DESC LIMIT 1) AS finalJobState
                """
            if let normalizedQuery, !normalizedQuery.isEmpty {
                guard !match.isEmpty else { return [] }
                return try Row.fetchAll(
                    db,
                    sql: """
                        WITH hits AS (
                            SELECT DISTINCT call_id
                            FROM call_transcript_fts
                            WHERE call_transcript_fts MATCH ?
                            LIMIT 5000
                        )
                        \(commonProjection)
                        FROM hits h
                        JOIN calls c ON c.id = h.call_id
                        LEFT JOIN call_transcript_revisions r ON r.id = c.preferredRevisionId
                        WHERE c.startTs <= ? AND COALESCE(c.endTs, c.startTs) >= ?
                        ORDER BY c.startTs DESC, c.id DESC
                        LIMIT ? OFFSET ?
                        """,
                    arguments: [match, to, from, page.limit + 1, page.offset]
                )
            }
            return try Row.fetchAll(
                db,
                sql: """
                    \(commonProjection)
                    FROM calls c
                    LEFT JOIN call_transcript_revisions r ON r.id = c.preferredRevisionId
                    WHERE c.startTs <= ? AND COALESCE(c.endTs, c.startTs) >= ?
                    ORDER BY c.startTs DESC, c.id DESC
                    LIMIT ? OFFSET ?
                    """,
                arguments: [to, from, page.limit + 1, page.offset]
            )
        }
        let hasMore = rows.count > page.limit
        let calls = try rows.prefix(page.limit).map(Self.summary)
        return CallEvidenceListPage(
            query: normalizedQuery?.isEmpty == false ? normalizedQuery : nil,
            limit: page.limit,
            offset: page.offset,
            hasMore: hasMore,
            nextOffset: hasMore ? page.offset + calls.count : nil,
            calls: calls
        )
    }

    func envelope(callID: Int64) async throws -> CallEvidenceEnvelope? {
        guard callID > 0, let page = try await call(id: callID, segmentLimit: 1) else { return nil }
        let extra = try await database.pool.read { db -> (CallTranscriptRevisionRow?, Int, [CallAudioChunkRow]) in
            let revision = try page.call.preferredRevisionId.flatMap { try CallTranscriptRevisionRow.fetchOne(db, key: $0) }
            let bookmarkCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM call_bookmarks WHERE callId = ?",
                arguments: [callID]
            ) ?? 0
            let chunks = try CallAudioChunkRow.fetchAll(
                db,
                sql: """
                    SELECT * FROM call_audio_chunks
                    WHERE callId = ? AND mediaGeneration = ? AND finalized = 1
                    ORDER BY startMs, source, epoch, sequence, id
                    LIMIT ?
                    """,
                arguments: [callID, page.call.mediaGeneration, CallEvidenceContract.maximumEvidenceReferences + 1]
            )
            return (revision, bookmarkCount, chunks)
        }
        let (revisionRow, bookmarkCount, chunkRows) = extra
        let sourceGaps = page.sourceGaps
        let sources = CallAudioSource.allCasesForEvidence.map { source in
            Self.sourceProjection(source: source, spans: page.sourceSpans, gaps: sourceGaps)
        }
        let hasExplicitGaps = sources.contains { $0.health != .available }
        let status = Self.status(call: page.call, finalJobState: page.finalJob?.state, preferredKind: revisionRow?.kind)
        let evidenceRows = Array(chunkRows.prefix(CallEvidenceContract.maximumEvidenceReferences))
        return CallEvidenceEnvelope(
            callId: CallEvidenceIdentifier.call(callID),
            startTs: page.call.startTs,
            endTs: page.call.endTs,
            state: page.call.state,
            status: status,
            retryable: status == .retryable,
            degradationCode: page.call.degradationReason,
            coverage: CallEvidenceCoverage(
                logicalStartMs: page.call.startTs,
                logicalEndMs: page.call.endTs,
                complete: page.call.endTs != nil && !hasExplicitGaps,
                hasExplicitGaps: hasExplicitGaps
            ),
            sources: sources,
            preferredRevision: revisionRow.map(Self.revisionProjection),
            bookmarkCount: bookmarkCount,
            evidence: evidenceRows.compactMap(Self.evidenceProjection),
            evidenceTruncated: chunkRows.count > CallEvidenceContract.maximumEvidenceReferences
        )
    }

    func bookmarks(
        callID: Int64,
        limit: Int = 50,
        offset: Int = 0
    ) async throws -> CallEvidenceBookmarkPage {
        let page = try CallEvidencePageRequest(limit: limit, offset: offset)
        guard callID > 0 else { throw CallEvidenceRequestError.invalidIdentifier }
        let rows = try await database.pool.read { db in
            guard try CallRow.fetchOne(db, key: callID) != nil else {
                throw CallEvidenceRequestError.notFound
            }
            return try CallBookmarkRow.fetchAll(
                db,
                sql: """
                    SELECT * FROM call_bookmarks WHERE callId = ?
                    ORDER BY ordinal, id LIMIT ? OFFSET ?
                    """,
                arguments: [callID, page.limit + 1, page.offset]
            )
        }
        let hasMore = rows.count > page.limit
        let items = rows.prefix(page.limit).compactMap { row -> CallEvidenceBookmark? in
            guard let id = row.id else { return nil }
            return CallEvidenceBookmark(
                bookmarkId: CallEvidenceIdentifier.bookmark(id),
                callId: CallEvidenceIdentifier.call(callID),
                ordinal: row.ordinal,
                acceptedAtMs: row.acceptedAtMs,
                logicalStartMs: row.logicalStartMs,
                logicalEndMs: row.logicalEndMs,
                state: row.state,
                retryable: row.state == .failed
            )
        }
        return CallEvidenceBookmarkPage(
            callId: CallEvidenceIdentifier.call(callID),
            limit: page.limit,
            offset: page.offset,
            hasMore: hasMore,
            nextOffset: hasMore ? page.offset + items.count : nil,
            bookmarks: items
        )
    }

    func transcript(
        callID: Int64,
        selector: CallTranscriptSelector,
        bookmarkID: Int64?,
        limit: Int = 80,
        offset: Int = 0
    ) async throws -> CallEvidenceTranscriptPage {
        let page = try CallEvidencePageRequest(limit: limit, offset: offset)
        guard callID > 0 else { throw CallEvidenceRequestError.invalidIdentifier }
        return try await database.pool.read { db in
            guard let call = try CallRow.fetchOne(db, key: callID) else {
                throw CallEvidenceRequestError.notFound
            }
            var selectedBookmark: CallBookmarkRow?
            let revisionID: Int64?
            switch selector {
            case .preferred:
                guard bookmarkID == nil else { throw CallEvidenceRequestError.invalidSelector }
                revisionID = call.preferredRevisionId
            case .bookmark:
                guard let bookmarkID else { throw CallEvidenceRequestError.bookmarkRequired }
                guard let bookmark = try CallBookmarkRow.fetchOne(db, key: bookmarkID), bookmark.callId == callID else {
                    throw CallEvidenceRequestError.bookmarkDoesNotBelongToCall
                }
                selectedBookmark = bookmark
                revisionID = try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT r.id
                        FROM call_transcript_revisions r
                        JOIN call_transcript_jobs j ON j.id = r.jobId
                        WHERE r.callId = ? AND r.mediaGeneration = ? AND r.state = 'ready'
                          AND j.bookmarkId = ?
                        ORDER BY r.createdAtMs DESC, r.id DESC LIMIT 1
                        """,
                    arguments: [callID, call.mediaGeneration, bookmarkID]
                ) ?? call.preferredRevisionId
            }
            let revision = try revisionID.flatMap { try CallTranscriptRevisionRow.fetchOne(db, key: $0) }
            guard let revision else {
                return CallEvidenceTranscriptPage(
                    callId: CallEvidenceIdentifier.call(callID),
                    selector: selector,
                    bookmarkId: bookmarkID.map(CallEvidenceIdentifier.bookmark),
                    revision: nil,
                    limit: page.limit,
                    offset: page.offset,
                    hasMore: false,
                    nextOffset: nil,
                    segments: []
                )
            }
            var arguments: StatementArguments = [revision.id ?? 0]
            var rangeClause = ""
            if let bookmark = selectedBookmark, revision.kind == .final {
                rangeClause = "AND endMs > ? AND startMs < ?"
                arguments += [bookmark.logicalStartMs, bookmark.logicalEndMs]
            }
            arguments += [page.limit + 1, page.offset]
            let rows = try CallTranscriptSegmentRow.fetchAll(
                db,
                sql: """
                    SELECT * FROM call_transcript_segments
                    WHERE revisionId = ? \(rangeClause)
                    ORDER BY ordinal, id LIMIT ? OFFSET ?
                    """,
                arguments: arguments
            )
            let hasMore = rows.count > page.limit
            let segments = rows.prefix(page.limit).compactMap { row -> CallEvidenceTranscriptSegment? in
                guard let id = row.id else { return nil }
                return CallEvidenceTranscriptSegment(
                    segmentId: CallEvidenceIdentifier.segment(id),
                    ordinal: row.ordinal,
                    source: row.source,
                    startMs: row.startMs,
                    endMs: row.endMs,
                    text: row.text
                )
            }
            return CallEvidenceTranscriptPage(
                callId: CallEvidenceIdentifier.call(callID),
                selector: selector,
                bookmarkId: bookmarkID.map(CallEvidenceIdentifier.bookmark),
                revision: Self.revisionProjection(revision),
                limit: page.limit,
                offset: page.offset,
                hasMore: hasMore,
                nextOffset: hasMore ? page.offset + segments.count : nil,
                segments: segments
            )
        }
    }

    func audioEvidence(reference: String) async throws -> CallAudioEvidenceFile? {
        guard let chunkID = CallEvidenceIdentifier.parseAudioChunk(reference) else {
            throw CallEvidenceRequestError.invalidIdentifier
        }
        return try await database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT ch.* FROM call_audio_chunks ch
                    JOIN calls c ON c.id = ch.callId AND c.mediaGeneration = ch.mediaGeneration
                    WHERE ch.id = ? AND ch.finalized = 1
                    """,
                arguments: [chunkID]
            ) else { return nil }
            let chunk = try CallAudioChunkRow(row: row)
            guard let projected = Self.evidenceProjection(chunk) else { return nil }
            return CallAudioEvidenceFile(reference: projected, relativePath: chunk.relativePath)
        }
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
            let sourceGapRows = try CallSourceGapRow.fetchAll(
                db,
                sql: """
                    SELECT * FROM call_source_gaps
                    WHERE callId = ? AND mediaGeneration = ?
                    ORDER BY startMs, source, id LIMIT ?
                    """,
                arguments: [callID, call.mediaGeneration, Self.maximumSourceGaps + 1]
            )
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
                sourceGaps: Array(sourceGapRows.prefix(Self.maximumSourceGaps)),
                sourceGapsTruncated: sourceGapRows.count > Self.maximumSourceGaps,
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

    private static func summary(_ row: Row) throws -> CallEvidenceSummary {
        let call = try CallRow(row: row)
        guard let id = call.id else { throw CallEvidenceRequestError.invalidIdentifier }
        let revisionKind = (row["revisionKind"] as String?).flatMap(CallTranscriptRevisionKind.init(rawValue:))
        let finalJobState = (row["finalJobState"] as String?).flatMap(CallTranscriptJobState.init(rawValue:))
        let status = status(call: call, finalJobState: finalJobState, preferredKind: revisionKind)
        return CallEvidenceSummary(
            callId: CallEvidenceIdentifier.call(id),
            startTs: call.startTs,
            endTs: call.endTs,
            state: call.state,
            status: status,
            retryable: status == .retryable,
            preferredRevisionKind: revisionKind
        )
    }

    private static func status(
        call: CallRow,
        finalJobState: CallTranscriptJobState?,
        preferredKind: CallTranscriptRevisionKind?
    ) -> CallEvidenceStatus {
        if call.state == .recording { return .recording }
        if call.state == .failed || finalJobState == .failed { return .retryable }
        if call.degradationReason != nil || finalJobState == .readyDegraded { return .degraded }
        if call.state == .ready && preferredKind == .final { return .ready }
        return .processing
    }

    private static func sourceProjection(
        source: CallAudioSource,
        spans: [CallSourceSpanRow],
        gaps: [CallSourceGapRow]
    ) -> CallEvidenceSource {
        let selected = spans.filter { $0.source == source }
        let available = selected.filter { $0.availability == .available }
        let gapCount = selected.filter { $0.availability != .available || $0.gapReason != nil }.count
            + gaps.filter { $0.source == source }.count
        let health: CallEvidenceSourceHealth = available.isEmpty ? .missing : (gapCount > 0 ? .gapped : .available)
        return CallEvidenceSource(
            source: source,
            health: health,
            spanCount: selected.count,
            gapCount: gapCount,
            coveredFromMs: available.map(\.startedAtMs).min(),
            coveredToMs: available.compactMap(\.endedAtMs).max()
        )
    }

    private static func revisionProjection(_ row: CallTranscriptRevisionRow) -> CallEvidenceRevision {
        CallEvidenceRevision(
            revisionId: CallEvidenceIdentifier.revision(row.id ?? 0),
            kind: row.kind,
            state: row.state,
            language: row.language,
            engine: row.engine,
            modelRevision: row.modelRevision,
            logicalStartMs: row.logicalStartMs,
            logicalEndMs: row.logicalEndMs
        )
    }

    private static func evidenceProjection(_ row: CallAudioChunkRow) -> CallEvidenceReference? {
        guard let id = row.id else { return nil }
        return CallEvidenceReference(
            evidenceId: CallEvidenceIdentifier.audioChunk(id),
            source: row.source,
            startMs: row.startMs,
            endMs: row.endMs,
            bytes: row.bytes
        )
    }
}

private extension CallAudioSource {
    static let allCasesForEvidence: [CallAudioSource] = [.me, .system]
}
