import Foundation
import GRDB

/// Hybrid search: FTS5 (exact words, bm25) + semantic (vec0, by meaning, screen AND transcripts) →
/// Reciprocal Rank Fusion merge (RRF, k=60, no scale calibration). Frame dedup via ROW_NUMBER.
/// Filters (time/app/kind) are applied in SQL where cheap and as a post-filter for the semantic legs;
/// pagination sits on top of the final ranking (offset/limit).
actor SearchService {
    private let db: ZBSEyeDatabase
    private let embedder: EmbeddingService
    private let rrfK = 60.0

    init(db: ZBSEyeDatabase, embedder: EmbeddingService) {
        self.db = db
        self.embedder = embedder
    }

    /// Compatibility with old call sites (UI/MCP without filters).
    func search(query: String, limit: Int = 60) async throws -> [SearchResult] {
        try await search(query: query, filters: SearchFilters(limit: limit))
    }

    func search(query: String, filters: SearchFilters) async throws -> [SearchResult] {
        // candidate window: with headroom over offset+limit; the app filter is cut by a POST-filter (Unicode),
        // so the window is wider when it's set — otherwise a rare app would drown among other candidates
        let baseWindow = min(filters.offset + filters.limit + 40, 400)
        let window = filters.app != nil ? min(baseWindow * 3, 600) : baseWindow

        // FTS and the query embedding — in parallel (they don't depend on each other). query prefix for e5.
        async let ftsTask = ftsSearch(query, filters: filters, limit: window)
        async let qvecTask = embedder.embed(query: query)
        let fts = try await ftsTask

        var byKey: [String: SearchResult] = [:]
        var score: [String: Double] = [:]
        func key(_ r: SearchResult) -> String { "\(r.kind.rawValue):\(r.id)" }

        // screen-FTS and audio-FTS are INDEPENDENT RRF legs (as is the semantic pair): bm25 of different FTS
        // tables is incomparable, concatenation would underrate the best audio hit by the size of the whole screen set.
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
            // Two semantic legs IN PARALLEL (async let → DB reads overlap via the pool): screen and
            // transcripts (cross-lingual, for calls). The kind filter AND app filter mute the unneeded leg
            // entirely (audio has no appId — under an app filter it's dropped in matches() anyway, no KNN burned).
            // Recency-first: with no time filter KNN starts on hot shards — on large history 37 vs 370ms.
            let appFiltered = !(filters.app?.isEmpty ?? true)
            async let semIdsTask: [Int64] = filters.kind == .audio ? [] :
                recencyFirst(window) { try await self.semanticSearch(qvec, filters: filters, limit: window, buckets: $0) }
            async let semAudioTask: [Int64] = (filters.kind == .screen || appFiltered) ? [] :
                recencyFirst(min(window, 80)) { try await self.semanticTranscripts(qvec, filters: filters, limit: min(window, 80), buckets: $0) }
            let semIds = await semIdsTask
            let semAudio = await semAudioTask

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

        // The post-filter closes the semantic legs (vec partitions are monthly, app isn't in vec at all)
        // AND the app filter entirely (Unicode-correct, unlike SQLite's lower()).
        let filtered = byKey.values.filter { matches($0, filters) }
        // tiebreaker (ts↓, kind, id↓): equal RRF scores show up constantly — without it pagination
        // doesn't line up between pages (unstable sort)
        let ranked = filtered.sorted { a, b in
            let sa = score[key(a)] ?? 0, sb = score[key(b)] ?? 0
            if sa != sb { return sa > sb }
            if a.ts != b.ts { return a.ts > b.ts }
            if a.kind != b.kind { return a.kind == .screen }
            return a.id > b.id
        }
        return Array(ranked.dropFirst(filters.offset).prefix(filters.limit))
    }

    /// Exact check of a result against the filters (the semantic legs are only filtered coarsely in SQL).
    private func matches(_ r: SearchResult, _ f: SearchFilters) -> Bool {
        if let k = f.kind, r.kind != k { return false }
        if let from = f.from, r.ts < from { return false }
        if let to = f.to, r.ts > to { return false }
        if let app = f.app, !app.isEmpty {
            guard r.kind == .screen else { return false }   // the app filter only makes sense for screen
            let needle = app.lowercased()
            let hay = [(r.bundleId ?? ""), (r.appName ?? "")].map { $0.lowercased() }
            if !hay.contains(where: { $0.contains(needle) }) { return false }
        }
        return true
    }

    // MARK: legs

    private func semanticSearch(_ qvec: [Float], filters: SearchFilters, limit: Int,
                                buckets: (Int, Int)? = nil) async throws -> [Int64] {
        let blob = floatBlob(qvec)
        // temporal shard: monthly vec0 partitions cut the KNN scan. An explicit time filter wins over the recency window.
        let (b0, b1) = (filters.from != nil || filters.to != nil) ? Self.bucketRange(filters)
                       : (buckets ?? Self.bucketRange(filters))
        return try await db.pool.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT capture_id FROM vec_screen
                WHERE bucket_month BETWEEN ? AND ? AND embedding MATCH ? AND k = ? ORDER BY distance
                """, arguments: [b0, b1, blob, limit])
        }
    }

    /// Semantic over transcripts: vec_transcripts → transcription_id → audioId (the RRF key is audio,
    /// like the FTS leg: dedup by audio segment, not by transcript line).
    private func semanticTranscripts(_ qvec: [Float], filters: SearchFilters, limit: Int,
                                     buckets: (Int, Int)? = nil) async throws -> [Int64] {
        let blob = floatBlob(qvec)
        let (b0, b1) = (filters.from != nil || filters.to != nil) ? Self.bucketRange(filters)
                       : (buckets ?? Self.bucketRange(filters))
        return try await db.pool.read { db in
            let tids = try Int64.fetchAll(db, sql: """
                SELECT transcription_id FROM vec_transcripts
                WHERE bucket_month BETWEEN ? AND ? AND embedding MATCH ? AND k = ? ORDER BY distance
                """, arguments: [b0, b1, blob, limit])
            guard !tids.isEmpty else { return [] }
            // preserve the ranking order: map one by one (short list)
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

    /// Range of monthly buckets for the vec partitions (no filter — the whole history).
    private static func bucketRange(_ f: SearchFilters) -> (Int, Int) {
        let lo = f.from.map(monthBucket) ?? 0
        let hi = f.to.map(monthBucket) ?? 999_912
        return (lo, hi)
    }

    /// Recency-first: run the leg over the last ~2 months; too few candidates → top up over the whole history
    /// (fresh ids come first — recency boost via the RRF ranking order).
    private func recencyFirst(_ want: Int, _ leg: ((Int, Int)?) async throws -> [Int64]) async -> [Int64] {
        let recentLo = monthBucket(Date().addingTimeInterval(-60 * 86_400))
        let recent = (try? await leg((recentLo, 999_912))) ?? []
        if recent.count >= max(10, want / 3) { return recent }
        let full = (try? await leg(nil)) ?? []
        var seen = Set(recent)
        return recent + full.filter { seen.insert($0).inserted }
    }

    /// Two independent FTS legs. app filter: the needle resolves to an appId list IN SWIFT (Unicode-correct;
    /// SQLite lower() is ASCII-only and broke Cyrillic) and goes into SQL as `appId IN (…)` — lossless
    /// (a post-filter over topN lost rare apps that drowned behind frequent words).
    private func ftsSearch(_ query: String, filters: SearchFilters,
                           limit: Int) async throws -> (screen: [SearchResult], audio: [SearchResult]) {
        let match = Self.ftsQuery(query)
        guard !match.isEmpty else { return ([], []) }
        let fromMs = filters.from.map(msFromDate) ?? 0
        let toMs = filters.to.map(msFromDate) ?? Int64.max
        let wantScreen = filters.kind != .audio
        // audio has no appId → under an app filter the audio leg is guaranteed empty, skip the extra FTS scan
        let wantAudio = filters.kind != .screen && (filters.app?.isEmpty ?? true)
        // app needle → ids (the apps table is small; contains over Unicode-lowercased)
        let appIdsClause: String
        if let app = filters.app?.lowercased(), !app.isEmpty {
            let ids: [Int64] = try await db.pool.read { db in
                try Row.fetchAll(db, sql: "SELECT id, bundleId, name FROM apps").compactMap { row in
                    let b = ((row["bundleId"] as String?) ?? "").lowercased()
                    let n = ((row["name"] as String?) ?? "").lowercased()
                    return (b.contains(app) || n.contains(app)) ? row["id"] : nil
                }
            }
            guard !ids.isEmpty else { return ([], []) }   // no such app — an honest zero
            appIdsClause = "AND c.appId IN (\(ids.map(String.init).joined(separator: ",")))"
        } else {
            appIdsClause = ""
        }
        return try await db.pool.read { db in
            var screen: [SearchResult] = []
            var audio: [SearchResult] = []
            if wantScreen {
                // snippet()/bm25() are computed in the subquery PURELY over the FTS table (hits): extra conditions on
                // joined tables (ts BETWEEN) change the plan and SQLite loses the FTS context —
                // "unable to use function snippet" (caught by a live run on 50k imported blocks).
                let screenSQL = """
                WITH hits AS (
                    SELECT rowid AS tbid, snippet(text_fts, 0, '⟦', '⟧', '…', 12) AS snip,
                           bm25(text_fts) AS rank
                    FROM text_fts WHERE text_fts MATCH ?
                    ORDER BY rank LIMIT 5000
                ),
                ranked AS (
                    SELECT c.id AS id, c.ts AS ts, a.bundleId AS bundleId, a.name AS appName,
                           c.windowTitle AS windowTitle, c.browserUrl AS browserUrl, c.relativePath AS relativePath,
                           h.snip AS snip, h.rank AS rank,
                           ROW_NUMBER() OVER (PARTITION BY c.id ORDER BY h.rank) AS rn
                    FROM hits h
                    JOIN text_blocks tb ON tb.id = h.tbid
                    JOIN screen_captures c ON c.id = tb.captureId
                    LEFT JOIN apps a ON a.id = c.appId
                    WHERE c.ts BETWEEN ? AND ? \(appIdsClause)
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
                // same hits scheme as for screen (see the comment above)
                let audioSQL = """
                WITH hits AS (
                    SELECT rowid AS trid, snippet(transcription_fts, 0, '⟦', '⟧', '…', 12) AS snip,
                           bm25(transcription_fts) AS rank
                    FROM transcription_fts WHERE transcription_fts MATCH ?
                    ORDER BY rank LIMIT 5000
                ),
                ranked AS (
                    SELECT ac.id AS id, ac.ts AS ts, ac.relativePath AS relativePath, ac.channel AS channel,
                           h.snip AS snip, h.rank AS rank,
                           ROW_NUMBER() OVER (PARTITION BY ac.id ORDER BY h.rank) AS rn
                    FROM hits h
                    JOIN transcriptions tr ON tr.id = h.trid
                    JOIN audio_captures ac ON ac.id = tr.audioId
                    WHERE ac.ts BETWEEN ? AND ?
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

    /// "Who's speaking" instead of a faceless "Audio": the recording channel = a cheap speaker proxy.
    static func audioLabel(_ channel: String?) -> String {
        switch channel {
        case "mic":    return "Microphone (me)"
        case "system": return "System audio (other party)"
        default:       return "Audio"
        }
    }

    /// For a semantic-only hit (found by meaning, without exact words) — assemble a SearchResult from the DB.
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

    /// For a semantic-only audio hit — assemble a SearchResult from the DB (like fetchScreenResult for screen).
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

    /// User input → safe FTS5 prefix MATCH (quoted tokens + `*`, implicit AND).
    static func ftsQuery(_ q: String) -> String {
        let tokens = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " ")
    }
}
