import Foundation
import GRDB

/// FTS5-поиск по экрану и аудио (без vector — это шаг 7). Дедуп кадров `GROUP BY` (фикс декартова).
/// Ранжирование bm25. Гибрид FTS+semantic добавится после benchmark'а vector (план).
actor SearchService {
    private let db: SlishuDatabase
    init(db: SlishuDatabase) { self.db = db }

    func search(query: String, limit: Int = 60) async throws -> [SearchResult] {
        let match = Self.ftsQuery(query)
        guard !match.isEmpty else { return [] }
        return try await db.pool.read { db in
            var out: [SearchResult] = []

            let screenSQL = """
            SELECT c.id AS id, c.ts AS ts, a.bundleId AS bundleId, a.name AS appName,
                   c.windowTitle AS windowTitle, c.browserUrl AS browserUrl, c.relativePath AS relativePath,
                   snippet(text_fts, 0, '⟦', '⟧', '…', 12) AS snip, bm25(text_fts) AS rank
            FROM text_fts
            JOIN text_blocks tb ON tb.id = text_fts.rowid
            JOIN screen_captures c ON c.id = tb.captureId
            LEFT JOIN apps a ON a.id = c.appId
            WHERE text_fts MATCH ?
            GROUP BY c.id
            ORDER BY rank
            LIMIT ?
            """
            for row in try Row.fetchAll(db, sql: screenSQL, arguments: [match, limit]) {
                out.append(SearchResult(
                    id: row["id"], kind: .screen, ts: dateFromMs(row["ts"]),
                    bundleId: row["bundleId"], appName: row["appName"],
                    windowTitle: row["windowTitle"], browserURL: row["browserUrl"],
                    snippet: row["snip"] ?? "", relativePath: row["relativePath"]))
            }

            let audioSQL = """
            SELECT ac.id AS id, ac.ts AS ts, ac.relativePath AS relativePath,
                   snippet(transcription_fts, 0, '⟦', '⟧', '…', 12) AS snip, bm25(transcription_fts) AS rank
            FROM transcription_fts
            JOIN transcriptions tr ON tr.id = transcription_fts.rowid
            JOIN audio_captures ac ON ac.id = tr.audioId
            WHERE transcription_fts MATCH ?
            GROUP BY ac.id
            ORDER BY rank
            LIMIT ?
            """
            for row in try Row.fetchAll(db, sql: audioSQL, arguments: [match, limit]) {
                out.append(SearchResult(
                    id: row["id"], kind: .audio, ts: dateFromMs(row["ts"]),
                    bundleId: nil, appName: "Аудио", windowTitle: nil, browserURL: nil,
                    snippet: row["snip"] ?? "", relativePath: row["relativePath"]))
            }

            // объединённая сортировка по времени (свежее сверху)
            return out.sorted { $0.ts > $1.ts }
        }
    }

    /// Пользовательский ввод → безопасный FTS5 prefix-MATCH (токены в кавычках + `*`, неявный AND).
    static func ftsQuery(_ q: String) -> String {
        let tokens = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " ")
    }
}
