import Foundation
import GRDB

/// The live retrieval seam for Ask. Search ranking stays in SearchService;
/// this actor only expands the ranked rows into citation-ready excerpts.
actor AskDatabaseRetrieval: AskRetrievalProviding {
    private let search: SearchService
    private let db: ZBSEyeDatabase

    init(search: SearchService, db: ZBSEyeDatabase) {
        self.search = search
        self.db = db
    }

    func retrieve(question: String, limit: Int) async throws -> [AskRetrievedEvidence] {
        let hits = try await search.search(
            query: question,
            filters: SearchFilters(limit: limit)
        )
        guard !hits.isEmpty else { return [] }

        return try await db.pool.read { dbc in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = "d MMM, HH:mm"

            return hits.map { result in
                let when = formatter.string(from: result.ts)
                let label: String
                let raw: String
                switch result.kind {
                case .screen:
                    let app = result.appName ?? result.bundleId ?? "screen"
                    label = [app, result.windowTitle]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " — ")
                    raw = (try? String.fetchOne(
                        dbc,
                        sql: "SELECT group_concat(text, ' ') FROM text_blocks WHERE captureId = ?",
                        arguments: [result.id]
                    )) ?? result.snippet
                case .audio:
                    label = result.appName ?? "Audio"
                    raw = (try? String.fetchOne(
                        dbc,
                        sql: "SELECT group_concat(text, ' ') FROM transcriptions WHERE audioId = ?",
                        arguments: [result.id]
                    )) ?? result.snippet
                }
                let source = label.isEmpty ? "—" : label
                return AskRetrievedEvidence(
                    source: result,
                    text: "\(when) · \(source) — \(raw)"
                )
            }
        }
    }
}
