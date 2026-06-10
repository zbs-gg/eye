import Foundation
import GRDB

/// Гибридный поиск: FTS5 (точные слова, bm25) + semantic (vec0, по смыслу, экран И транскрипты) →
/// слияние Reciprocal Rank Fusion (RRF, k=60, без калибровки шкал). Дедуп кадров ROW_NUMBER.
/// Фильтры (время/приложение/тип) применяются в SQL где дёшево и пост-фильтром для semantic-ног;
/// пагинация — поверх итогового ранжирования (offset/limit).
actor SearchService {
    private let db: SlishuDatabase
    private let embedder: EmbeddingService
    private let rrfK = 60.0

    init(db: SlishuDatabase, embedder: EmbeddingService) {
        self.db = db
        self.embedder = embedder
    }

    /// Совместимость со старыми вызовами (UI/MCP без фильтров).
    func search(query: String, limit: Int = 60) async throws -> [SearchResult] {
        try await search(query: query, filters: SearchFilters(limit: limit))
    }

    func search(query: String, filters: SearchFilters) async throws -> [SearchResult] {
        // окно кандидатов: с запасом над offset+limit; app-фильтр режется ПОСТ-фильтром (Unicode),
        // поэтому при нём окно шире — иначе редкое приложение утонет в чужих кандидатах
        var window = min(filters.offset + filters.limit + 40, 400)
        if filters.app != nil { window = min(window * 3, 600) }

        // FTS и эмбеддинг запроса — параллельно (не зависят друг от друга). query-префикс для e5.
        async let ftsTask = ftsSearch(query, filters: filters, limit: window)
        async let qvecTask = embedder.embed(query: query)
        let fts = try await ftsTask

        var byKey: [String: SearchResult] = [:]
        var score: [String: Double] = [:]
        func key(_ r: SearchResult) -> String { "\(r.kind.rawValue):\(r.id)" }

        // screen-FTS и audio-FTS — НЕЗАВИСИМЫЕ RRF-ноги (как и semantic-пара): bm25 разных FTS-таблиц
        // несравним, конкатенация занижала бы лучший аудио-хит на размер всей screen-выдачи.
        for (i, r) in fts.screen.enumerated() {
            let k = key(r)
            score[k, default: 0] += 1.0 / (rrfK + Double(i + 1))
            byKey[k] = r
        }
        for (i, r) in fts.audio.enumerated() {
            let k = key(r)
            score[k, default: 0] += 1.0 / (rrfK + Double(i + 1))
            byKey[k] = r
        }

        if let qvec = await qvecTask {
            // Две semantic-ноги параллельно: экран и транскрипты (cross-lingual и для звонков).
            // kind-фильтр гасит ненужную ногу целиком.
            async let semScreenTask = filters.kind == .audio ? [] : semanticSearch(qvec, filters: filters, limit: window)
            async let semAudioTask = filters.kind == .screen ? [] : semanticTranscripts(qvec, filters: filters, limit: min(window, 80))
            let semIds = (try? await semScreenTask) ?? []
            let semAudio = (try? await semAudioTask) ?? []

            for (rank, captureId) in semIds.enumerated() {
                let k = "screen:\(captureId)"
                score[k, default: 0] += 1.0 / (rrfK + Double(rank + 1))
                if byKey[k] == nil, let r = try? await fetchScreenResult(captureId) {
                    byKey[k] = r
                }
            }
            for (rank, audioId) in semAudio.enumerated() {
                let k = "audio:\(audioId)"
                score[k, default: 0] += 1.0 / (rrfK + Double(rank + 1))
                if byKey[k] == nil, let r = try? await fetchAudioResult(audioId) {
                    byKey[k] = r
                }
            }
        }

        // Пост-фильтр закрывает semantic-ноги (vec-партиции месячные, app в vec нет вовсе)
        // И app-фильтр целиком (Unicode-корректный, в отличие от SQLite lower()).
        let filtered = byKey.values.filter { matches($0, filters) }
        // tiebreaker (ts↓, kind, id↓): равные RRF-score встречаются постоянно — без него пагинация
        // не стыкуется между страницами (нестабильная сортировка)
        let ranked = filtered.sorted { a, b in
            let sa = score[key(a)] ?? 0, sb = score[key(b)] ?? 0
            if sa != sb { return sa > sb }
            if a.ts != b.ts { return a.ts > b.ts }
            if a.kind != b.kind { return a.kind == .screen }
            return a.id > b.id
        }
        return Array(ranked.dropFirst(filters.offset).prefix(filters.limit))
    }

    /// Точная проверка результата против фильтров (semantic-ноги фильтруются только грубо в SQL).
    private func matches(_ r: SearchResult, _ f: SearchFilters) -> Bool {
        if let k = f.kind, r.kind != k { return false }
        if let from = f.from, r.ts < from { return false }
        if let to = f.to, r.ts > to { return false }
        if let app = f.app, !app.isEmpty {
            guard r.kind == .screen else { return false }   // app-фильтр осмыслен только для экрана
            let needle = app.lowercased()
            let hay = [(r.bundleId ?? ""), (r.appName ?? "")].map { $0.lowercased() }
            if !hay.contains(where: { $0.contains(needle) }) { return false }
        }
        return true
    }

    // MARK: legs

    private func semanticSearch(_ qvec: [Float], filters: SearchFilters, limit: Int) async throws -> [Int64] {
        let blob = floatBlob(qvec)
        // temporal shard: месячные партиции vec0 режут KNN-скан при заданном времени
        let (b0, b1) = Self.bucketRange(filters)
        return try await db.pool.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT capture_id FROM vec_screen
                WHERE bucket_month BETWEEN ? AND ? AND embedding MATCH ? AND k = ? ORDER BY distance
                """, arguments: [b0, b1, blob, limit])
        }
    }

    /// Semantic по транскриптам: vec_transcripts → transcription_id → audioId (ключ RRF — audio,
    /// как у FTS-ноги: дедуп по аудио-сегменту, не по строке транскрипта).
    private func semanticTranscripts(_ qvec: [Float], filters: SearchFilters, limit: Int) async throws -> [Int64] {
        let blob = floatBlob(qvec)
        let (b0, b1) = Self.bucketRange(filters)
        return try await db.pool.read { db in
            let tids = try Int64.fetchAll(db, sql: """
                SELECT transcription_id FROM vec_transcripts
                WHERE bucket_month BETWEEN ? AND ? AND embedding MATCH ? AND k = ? ORDER BY distance
                """, arguments: [b0, b1, blob, limit])
            guard !tids.isEmpty else { return [] }
            // сохранить порядок ранжирования: маппим по одному (короткий список)
            var audioIds: [Int64] = []
            var seen = Set<Int64>()
            for tid in tids {
                if let aid = try Int64.fetchOne(db, sql:
                    "SELECT audioId FROM transcriptions WHERE id = ?", arguments: [tid]),
                   !seen.contains(aid) {
                    audioIds.append(aid); seen.insert(aid)
                }
            }
            return audioIds
        }
    }

    /// Диапазон месячных бакетов для vec-партиций (без фильтра — вся история).
    private static func bucketRange(_ f: SearchFilters) -> (Int, Int) {
        let lo = f.from.map(monthBucket) ?? 0
        let hi = f.to.map(monthBucket) ?? 999_912
        return (lo, hi)
    }

    /// Две независимые FTS-ноги. app-фильтра в SQL НЕТ намеренно: SQLite lower() — ASCII-only,
    /// кириллические имена («Заметки») молча теряли все точные матчи; фильтрует Swift-пост-фильтр.
    private func ftsSearch(_ query: String, filters: SearchFilters,
                           limit: Int) async throws -> (screen: [SearchResult], audio: [SearchResult]) {
        let match = Self.ftsQuery(query)
        guard !match.isEmpty else { return ([], []) }
        let fromMs = filters.from.map(msFromDate) ?? 0
        let toMs = filters.to.map(msFromDate) ?? Int64.max
        let wantScreen = filters.kind != .audio
        let wantAudio = filters.kind != .screen
        return try await db.pool.read { db in
            var screen: [SearchResult] = []
            var audio: [SearchResult] = []
            if wantScreen {
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
                    WHERE text_fts MATCH ? AND c.ts BETWEEN ? AND ?
                )
                SELECT id, ts, bundleId, appName, windowTitle, browserUrl, relativePath, snip, rank
                FROM ranked WHERE rn = 1 ORDER BY rank LIMIT ?
                """
                for row in try Row.fetchAll(db, sql: screenSQL,
                                            arguments: [match, fromMs, toMs, limit]) {
                    screen.append(SearchResult(
                        id: row["id"], kind: .screen, ts: dateFromMs(row["ts"]),
                        bundleId: row["bundleId"], appName: row["appName"],
                        windowTitle: row["windowTitle"], browserURL: row["browserUrl"],
                        snippet: row["snip"] ?? "", relativePath: row["relativePath"]))
                }
            }
            if wantAudio {
                let audioSQL = """
                WITH ranked AS (
                    SELECT ac.id AS id, ac.ts AS ts, ac.relativePath AS relativePath, ac.channel AS channel,
                           snippet(transcription_fts, 0, '⟦', '⟧', '…', 12) AS snip, bm25(transcription_fts) AS rank,
                           ROW_NUMBER() OVER (PARTITION BY ac.id ORDER BY bm25(transcription_fts)) AS rn
                    FROM transcription_fts
                    JOIN transcriptions tr ON tr.id = transcription_fts.rowid
                    JOIN audio_captures ac ON ac.id = tr.audioId
                    WHERE transcription_fts MATCH ? AND ac.ts BETWEEN ? AND ?
                )
                SELECT id, ts, relativePath, channel, snip, rank FROM ranked WHERE rn = 1 ORDER BY rank LIMIT ?
                """
                for row in try Row.fetchAll(db, sql: audioSQL, arguments: [match, fromMs, toMs, limit]) {
                    audio.append(SearchResult(
                        id: row["id"], kind: .audio, ts: dateFromMs(row["ts"]),
                        bundleId: nil, appName: Self.audioLabel(row["channel"]),
                        windowTitle: nil, browserURL: nil,
                        snippet: row["snip"] ?? "", relativePath: row["relativePath"]))
                }
            }
            return (screen, audio)
        }
    }

    /// «Кто говорит» вместо безликого «Аудио»: канал записи = дешёвый прокси спикера.
    static func audioLabel(_ channel: String?) -> String {
        switch channel {
        case "mic":    return "Микрофон (я)"
        case "system": return "Системный звук (собеседник)"
        default:       return "Аудио"
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

    /// Для semantic-only аудио-хита — собрать SearchResult из БД (как fetchScreenResult для экрана).
    private func fetchAudioResult(_ audioId: Int64) async throws -> SearchResult? {
        try await db.pool.read { db in
            guard let row = try Row.fetchOne(db, sql:
                "SELECT id, ts, relativePath, channel FROM audio_captures WHERE id = ?", arguments: [audioId])
            else { return nil }
            let snip = try String.fetchOne(db, sql:
                "SELECT substr(text, 1, 140) FROM transcriptions WHERE audioId = ? ORDER BY id DESC LIMIT 1",
                arguments: [audioId]) ?? ""
            return SearchResult(
                id: row["id"], kind: .audio, ts: dateFromMs(row["ts"]),
                bundleId: nil, appName: Self.audioLabel(row["channel"]),
                windowTitle: nil, browserURL: nil,
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
