import Foundation

/// Read-only MCP adapter over the exact same allowlisted projection used by
/// REST. It deliberately accepts typed IDs only and has no database/root,
/// mutation, recording, retry, delete, or model-install argument.
struct MCPCallEvidenceCoordinator: Sendable {
    let service: CallEvidenceQueryService

    func listCalls(
        query: String? = nil,
        fromMs: Int64? = nil,
        toMs: Int64? = nil,
        limit: Int = 25,
        offset: Int = 0
    ) async throws -> CallEvidenceListPage {
        try await service.listCalls(
            query: query,
            fromMs: fromMs,
            toMs: toMs,
            limit: limit,
            offset: offset
        )
    }

    func envelope(callID: String) async throws -> CallEvidenceEnvelope? {
        guard let id = CallEvidenceIdentifier.parseCall(callID) else {
            throw CallEvidenceRequestError.invalidIdentifier
        }
        return try await service.envelope(callID: id)
    }

    func bookmarks(
        callID: String,
        limit: Int = 50,
        offset: Int = 0
    ) async throws -> CallEvidenceBookmarkPage {
        guard let id = CallEvidenceIdentifier.parseCall(callID) else {
            throw CallEvidenceRequestError.invalidIdentifier
        }
        return try await service.bookmarks(callID: id, limit: limit, offset: offset)
    }

    func transcript(
        callID: String,
        selector: String,
        bookmarkID: String?,
        limit: Int = 80,
        offset: Int = 0
    ) async throws -> CallEvidenceTranscriptPage {
        guard let id = CallEvidenceIdentifier.parseCall(callID) else {
            throw CallEvidenceRequestError.invalidIdentifier
        }
        guard let parsedSelector = CallTranscriptSelector(rawValue: selector) else {
            throw CallEvidenceRequestError.invalidSelector
        }
        let parsedBookmark: Int64?
        if let bookmarkID {
            guard let id = CallEvidenceIdentifier.parseBookmark(bookmarkID) else {
                throw CallEvidenceRequestError.invalidIdentifier
            }
            parsedBookmark = id
        } else {
            parsedBookmark = nil
        }
        return try await service.transcript(
            callID: id,
            selector: parsedSelector,
            bookmarkID: parsedBookmark,
            limit: limit,
            offset: offset
        )
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CallEvidenceRequestError.invalidIdentifier
        }
        return string
    }

    static func requestsAlternateStorage(argumentKeys: Set<String>) -> Bool {
        !argumentKeys.isDisjoint(with: ["root", "database", "database_path", "data_root"])
    }
}
