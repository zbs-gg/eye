import Foundation
import GRDB

/// Гибридный поиск: FTS5 (точные слова, bm25) + semantic (vec0, по смыслу) → слияние Reciprocal Rank
/// Fusion (RRF, k=60, без калибровки шкал). Дедуп кадров ROW_NUMBER. Vector — шаг 7 плана.
actor SearchService {
    private let db: SlishuDatabase
    private let embedder: EmbeddingService
    private let rrfK = 60.0

    init(db: SlishuDatabase, embedder: EmbeddingService) {
        self.db = db
        self.embedder = embedder
    }

    func search(query: String, limit: Int = 60) async throws -> [SearchResult] {
        // FTS и эмбеддинг запроса — параллельно (не зависят друг от друга).
        async let ftsTask = ftsSearch(query, limit: 80)
        async let qvecTask = embedder.embed(query)
        let fts = try await ftsTask

        guard let qvec = await qvecTask else {
            return Array(fts.prefix(limit))
        }
        let semIds = try await semanticSearch(qvec, limit: 80)

        // RRF: ключ = "kind:id"
        var score: [String: Double] = [:]
        var byKey: [String: SearchResult] = [:]
        func key(_ r: SearchResult) -> String { "\(r.kind.rawValue):\(r.id)" }

        for (i, r) in fts.enumerated() {
            let k = key(r)
            score[k, default: 0] += 1.0 / (rrfK + Double(i + 1))
            byKey[k] = r
        }
        for (rank, captureId) in semIds.enumerated() {
            let k = "screen:\(captureId)"
            score[k, default: 0] += 1.0 / (rrfK + Double(rank + 1))
            if byKey[k] == nil, let r = try? await fetchScreenResult(captureId) {
                byKey[k] = r
            }
        }

        let ranked = byKey.values.sorted { (score[key($0)] ?? 0) > (score[key($1)] ?? 0) }
        return Array(ranked.prefix(limit))
    }

    // MARK: legs

    private func semanticSearch(_ qvec: [Float], limit: Int) async throws -> [Int64] {
        let blob = floatBlob(qvec)
        return try await db.pool.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT capture_id FROM vec_screen WHERE embedding MATCH ? AND k = ? ORDER BY distance
                """, arguments: [blob, limit])
        }
    }

    private func ftsSearch(_ query: String, limit: Int) async throws -> [SearchResult] {
        let match = Self.ftsQuery(query)
        guard !match.isEmpty else { return [] }
        return try await db.pool.read { db in
            var out: [SearchResult] = []
            let screenSQL = """
            WITH ranked AS (
                SELECT c.id AS id, c.ts AS ts, a.bundleId AS bundleId, a.name AS appName,
                       c.windowTitle AS windowTitle, c.browserUrl AS browserUrl, c.relativePath AS relativePath,
                       snippet(text_fts, 0, '⟦', '⟧', '…', 12) AS snip, bm25(text_fts) AS rank,
                       ROW_NUMBER() OVER (PARTITION BY c.id ORDER BY bm25(text_fts)) AS rn
                FROM text_fts
                JOIN text_blocks tb ON tb.id = text_fts.rowid
                JOIN screen_captures c ON c.id = tb.captureId
                LEFT JOIN apps a ON a.id = c.appId
                WHERE text_fts MATCH ?
            )
            SELECT id, ts, bundleId, appName, windowTitle, browserUrl, relativePath, snip, rank
            FROM ranked WHERE rn = 1 ORDER BY rank LIMIT ?
            """
            for row in try Row.fetchAll(db, sql: screenSQL, arguments: [match, limit]) {
                out.append(SearchResult(
                    id: row["id"], kind: .screen, ts: dateFromMs(row["ts"]),
                    bundleId: row["bundleId"], appName: row["appName"],
                    windowTitle: row["windowTitle"], browserURL: row["browserUrl"],
                    snippet: row["snip"] ?? "", relativePath: row["relativePath"]))
            }
            let audioSQL = """
            WITH ranked AS (
                SELECT ac.id AS id, ac.ts AS ts, ac.relativePath AS relativePath,
                       snippet(transcription_fts, 0, '⟦', '⟧', '…', 12) AS snip, bm25(transcription_fts) AS rank,
                       ROW_NUMBER() OVER (PARTITION BY ac.id ORDER BY bm25(transcription_fts)) AS rn
                FROM transcription_fts
                JOIN transcriptions tr ON tr.id = transcription_fts.rowid
                JOIN audio_captures ac ON ac.id = tr.audioId
                WHERE transcription_fts MATCH ?
            )
            SELECT id, ts, relativePath, snip, rank FROM ranked WHERE rn = 1 ORDER BY rank LIMIT ?
            """
            for row in try Row.fetchAll(db, sql: audioSQL, arguments: [match, limit]) {
                out.append(SearchResult(
                    id: row["id"], kind: .audio, ts: dateFromMs(row["ts"]),
                    bundleId: nil, appName: "Аудио", windowTitle: nil, browserURL: nil,
                    snippet: row["snip"] ?? "", relativePath: row["relativePath"]))
            }
            return out
        }
    }

    /// Для semantic-only хита (нашёлся по смыслу, без точных слов) — собрать SearchResult из БД.
    private func fetchScreenResult(_ captureId: Int64) async throws -> SearchResult? {
        try await db.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT c.id AS id, c.ts AS ts, a.bundleId AS bundleId, a.name AS appName,
                       c.windowTitle AS windowTitle, c.browserUrl AS browserUrl, c.relativePath AS relativePath
                FROM screen_captures c LEFT JOIN apps a ON a.id = c.appId WHERE c.id = ?
                """, arguments: [captureId]) else { return nil }
            let snip = try String.fetchOne(db, sql:
                "SELECT substr(text, 1, 140) FROM text_blocks WHERE captureId = ? ORDER BY length(text) DESC LIMIT 1",
                arguments: [captureId]) ?? ""
            return SearchResult(
                id: row["id"], kind: .screen, ts: dateFromMs(row["ts"]),
                bundleId: row["bundleId"], appName: row["appName"],
                windowTitle: row["windowTitle"], browserURL: row["browserUrl"],
                snippet: snip, relativePath: row["relativePath"])
        }
    }

    /// Пользовательский ввод → безопасный FTS5 prefix-MATCH (токены в кавычках + `*`, неявный AND).
    static func ftsQuery(_ q: String) -> String {
        let tokens = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " ")
    }
}
