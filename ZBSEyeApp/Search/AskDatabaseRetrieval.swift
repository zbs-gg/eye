import Foundation
import GRDB

/// Narrow search seam keeps Ask's database-bound behavior testable without
/// loading the semantic model. SearchService is the production conformer.
protocol AskSearchProviding: Sendable {
    func search(
        query: String,
        filters: SearchFilters
    ) async throws -> [SearchResult]
}

/// The live retrieval seam for Ask. Search ranking stays in SearchService;
/// this actor expands ranked rows into citation-ready excerpts and verifies
/// that every source still exists inside the frozen request scope.
actor AskDatabaseRetrieval: AskRetrievalProviding {
    private let search: any AskSearchProviding
    private let db: ZBSEyeDatabase

    init(search: any AskSearchProviding, db: ZBSEyeDatabase) {
        self.search = search
        self.db = db
    }

    /// Compatibility for legacy/evaluation callers remains explicit all-history.
    func retrieve(question: String, limit: Int) async throws -> [AskRetrievedEvidence] {
        try await retrieve(
            question: question,
            scope: .allHistory,
            limit: limit
        )
    }

    func retrieve(
        question: String,
        scope: AskScopeSnapshot,
        limit: Int
    ) async throws -> [AskRetrievedEvidence] {
        let filters = scope.searchFilters(limit: limit)
        let hits = try await search.search(query: question, filters: filters)
        guard !hits.isEmpty else { return [] }

        // Ranked search and expansion are separate reads. Retention may remove
        // a hit between them, so expansion re-reads the parent, timestamp, and
        // current text. A cached search snippet is never evidence fallback.
        return try await db.pool.read { dbc in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = "d MMM, HH:mm"

            return try hits.compactMap { hit in
                switch hit.kind {
                case .screen:
                    guard let row = try Row.fetchOne(
                        dbc,
                        sql: """
                        SELECT c.id, c.ts, c.windowTitle, c.browserUrl,
                               c.relativePath, a.bundleId, a.name AS appName
                        FROM screen_captures c
                        LEFT JOIN apps a ON a.id = c.appId
                        WHERE c.id = ?
                        """,
                        arguments: [hit.id]
                    ) else { return nil }
                    let timestamp = dateFromMs(row["ts"] as Int64)
                    guard filters.includes(timestamp: timestamp),
                          let raw = try String.fetchOne(
                            dbc,
                            sql: """
                            SELECT group_concat(text, ' ')
                            FROM (
                                SELECT text FROM text_blocks
                                WHERE captureId = ? ORDER BY id
                            )
                            """,
                            arguments: [hit.id]
                          ),
                          !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { return nil }

                    let bundleID: String? = row["bundleId"]
                    let appName: String? = row["appName"]
                    let windowTitle: String? = row["windowTitle"]
                    let label = [appName ?? bundleID ?? "screen", windowTitle]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " — ")
                    let current = SearchResult(
                        id: row["id"],
                        kind: .screen,
                        ts: timestamp,
                        bundleId: bundleID,
                        appName: appName,
                        windowTitle: windowTitle,
                        browserURL: row["browserUrl"],
                        snippet: Self.snippet(raw),
                        relativePath: row["relativePath"]
                    )
                    return AskRetrievedEvidence(
                        source: current,
                        text: Self.evidenceText(
                            timestamp: timestamp,
                            label: label,
                            raw: raw,
                            formatter: formatter
                        )
                    )

                case .audio:
                    guard let row = try Row.fetchOne(
                        dbc,
                        sql: """
                        SELECT id, ts, relativePath, channel
                        FROM audio_captures WHERE id = ?
                        """,
                        arguments: [hit.id]
                    ) else { return nil }
                    let timestamp = dateFromMs(row["ts"] as Int64)
                    guard filters.includes(timestamp: timestamp),
                          let raw = try String.fetchOne(
                            dbc,
                            sql: """
                            SELECT group_concat(text, ' ')
                            FROM (
                                SELECT text FROM transcriptions
                                WHERE audioId = ? ORDER BY id
                            )
                            """,
                            arguments: [hit.id]
                          ),
                          !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { return nil }

                    let label = Self.audioLabel(row["channel"])
                    let current = SearchResult(
                        id: row["id"],
                        kind: .audio,
                        ts: timestamp,
                        bundleId: nil,
                        appName: label,
                        windowTitle: nil,
                        browserURL: nil,
                        snippet: Self.snippet(raw),
                        relativePath: row["relativePath"]
                    )
                    return AskRetrievedEvidence(
                        source: current,
                        text: Self.evidenceText(
                            timestamp: timestamp,
                            label: label,
                            raw: raw,
                            formatter: formatter
                        )
                    )
                }
            }
        }
    }

    private static func evidenceText(
        timestamp: Date,
        label: String,
        raw: String,
        formatter: DateFormatter
    ) -> String {
        let source = label.isEmpty ? "—" : label
        return "\(formatter.string(from: timestamp)) · \(source) — \(raw)"
    }

    private static func snippet(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 240 else { return normalized }
        return String(normalized.prefix(240)) + "…"
    }

    private static func audioLabel(_ channel: String?) -> String {
        switch channel {
        case "mic": return "Microphone (me)"
        case "system": return "System audio (other party)"
        default: return "Audio"
        }
    }
}
