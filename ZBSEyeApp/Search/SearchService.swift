import Foundation
import GRDB

/// Hybrid search: FTS5 (exact words, bm25) + semantic (vec0, by meaning, screen AND transcripts) →
/// Reciprocal Rank Fusion merge (RRF, k=60, no scale calibration). Frame dedup via ROW_NUMBER.
/// Filters (time/app/kind) are applied in SQL where cheap and as a post-filter for the semantic legs;
/// pagination sits on top of the final ranking (offset/limit).
actor SearchService {
    private let db: ZBSEyeDatabase
    private let semanticQuery: SearchSemanticQueryRunner
    private let rrfK = 60.0

    init(
        db: ZBSEyeDatabase,
        embedder: any SearchEmbeddingProviding,
        semanticPolicy: SearchSemanticPolicy = .uncoordinated
    ) {
        self.db = db
        self.semanticQuery = SearchSemanticQueryRunner(policy: semanticPolicy) { query in
            await embedder.embed(query: query)
        }
    }

    /// Compatibility with old call sites (UI/MCP without filters).
    func search(query: String, limit: Int = 60) async throws -> [SearchResult] {
        try await search(query: query, filters: SearchFilters(limit: limit))
    }

    func search(query: String, filters: SearchFilters) async throws -> [SearchResult] {
        try await searchWithMetadata(query: query, filters: filters).results
    }

    /// Metadata-bearing path used by helper processes that must disclose an
    /// explicit FTS-only policy rather than silently pretending hybrid search.
    func searchWithMetadata(
        query: String,
        filters: SearchFilters
    ) async throws -> SearchExecution {
        // candidate window: with headroom over offset+limit; the app filter is cut by a POST-filter (Unicode),
        // so the window is wider when it's set — otherwise a rare app would drown among other candidates
        let baseWindow = min(filters.offset + filters.limit + 40, 400)
        let window = filters.app != nil ? min(baseWindow * 3, 600) : baseWindow

        // FTS and the query embedding — in parallel (they don't depend on each other). query prefix for e5.
        async let ftsTask = ftsSearch(query, filters: filters, limit: window)
        async let semanticTask = semanticQuery.run(query: query)
        let fts = try await ftsTask

        var byKey: [String: SearchResult] = [:]
        var score: [String: Double] = [:]
        func key(_ r: SearchResult) -> String { "\(r.kind.rawValue):\(r.id)" }

        // Screen, legacy audio, and call FTS are INDEPENDENT RRF legs: bm25 of different FTS
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
        for (i, r) in fts.call.enumerated() {
            let k = key(r)
            score[k, default: 0] += 1.0 / (rrfK + Double(i + 1))
            byKey[k] = r
        }

        let semanticOutcome = await semanticTask
        if case .vector(let qvec) = semanticOutcome {
            // Three semantic legs IN PARALLEL (async let → DB reads overlap via the pool): screen,
            // legacy audio transcripts, and preferred call transcripts. The kind/app filters mute unneeded legs
            // entirely (audio has no appId — under an app filter it's dropped in matches() anyway, no KNN burned).
            // Recency-first: with no time filter KNN starts on hot shards — on large history 37 vs 370ms.
            let appFiltered = !(filters.app?.isEmpty ?? true)
            async let semIdsTask: [Int64] = (filters.kind == .audio || filters.kind == .call) ? [] :
                recencyFirst(window) { try await self.semanticSearch(qvec, filters: filters, limit: window, buckets: $0) }
            async let semAudioTask: [Int64] = (filters.kind == .screen || filters.kind == .call || appFiltered) ? [] :
                recencyFirst(min(window, 80)) { try await self.semanticTranscripts(qvec, filters: filters, limit: min(window, 80), buckets: $0) }
            async let semCallTask: [Int64] = (filters.kind == .screen || filters.kind == .audio || appFiltered) ? [] :
                recencyFirst(min(window, 80)) { try await self.semanticCalls(qvec, filters: filters, limit: min(window, 80), buckets: $0) }
            let semIds = await semIdsTask
            let semAudio = await semAudioTask
            let semCalls = await semCallTask

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
            for (rank, callID) in semCalls.enumerated() {
                let k = "call:\(callID)"
                score[k, default: 0] += 1.0 / (rrfK + Double(rank + 1))
                if byKey[k] == nil, let r = try? await fetchCallResult(callID) {
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
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            return a.id > b.id
        }
        let mode: SearchSemanticMode
        switch semanticOutcome {
        case .vector:
            mode = .hybrid
        case .embeddingUnavailable:
            mode = .embeddingUnavailable
        case .ftsOnly(let reason):
            mode = .ftsOnly(reason)
        }
        return SearchExecution(
            results: Array(ranked.dropFirst(filters.offset).prefix(filters.limit)),
            semanticMode: mode
        )
    }

    /// Exact check of a result against the filters (the semantic legs are only filtered coarsely in SQL).
    private func matches(_ r: SearchResult, _ f: SearchFilters) -> Bool {
        if r.kind == .screen,
           SystemAppFilter.isProtectedCaptureSurface(bundleId: r.bundleId, appName: r.appName) {
            return false
        }
        if let k = f.kind, r.kind != k { return false }
        if let from = f.from, (r.endTs ?? r.ts) < from { return false }
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
            // KNN's k is applied before Swift can inspect app identity. Use a
            // bounded privacy headroom rather than scaling work with an
            // arbitrarily large legacy protected corpus.
            // `searchWithMetadata` can legitimately request a 600-item window
            // for app-filtered pagination. Keep that caller-visible window
            // intact while capping only the privacy headroom above it.
            let boundedLimit = min(max(limit, 0), 600)
            let candidateLimit = min(max(boundedLimit * 4, boundedLimit + 64), 1_000)
            let candidates = try Int64.fetchAll(db, sql: """
                SELECT capture_id FROM vec_screen
                WHERE bucket_month BETWEEN ? AND ? AND embedding MATCH ? AND k = ? ORDER BY distance
                """, arguments: [b0, b1, blob, candidateLimit])
            guard !candidates.isEmpty else { return [] }

            // Classify only the bounded KNN window; never materialize the whole
            // legacy protected corpus just to reject a handful of candidates.
            let candidateIDs = candidates.map(String.init).joined(separator: ",")
            let visibleIDs = Set(try Row.fetchAll(db, sql: """
                SELECT c.id, a.bundleId, a.name
                FROM screen_captures c
                LEFT JOIN apps a ON a.id = c.appId
                WHERE c.id IN (\(candidateIDs))
                """).compactMap { row -> Int64? in
                    let bundleID: String? = row["bundleId"]
                    let appName: String? = row["name"]
                    guard !SystemAppFilter.isProtectedCaptureSurface(
                        bundleId: bundleID,
                        appName: appName
                    ) else { return nil }
                    return row["id"]
                })
            return Array(candidates.lazy.filter { visibleIDs.contains($0) }.prefix(limit))
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

    /// Preferred call revision only: vec_call_transcripts → revision → call. Superseded revisions may still
    /// be present briefly while the durable queue catches up, so the join to calls.preferredRevisionId is required.
    private func semanticCalls(_ qvec: [Float], filters: SearchFilters, limit: Int,
                               buckets: (Int, Int)? = nil) async throws -> [Int64] {
        let blob = floatBlob(qvec)
        let (b0, b1) = (filters.from != nil || filters.to != nil) ? Self.bucketRange(filters)
                       : (buckets ?? Self.bucketRange(filters))
        return try await db.pool.read { db in
            let revisionIDs = try Int64.fetchAll(db, sql: """
                SELECT revision_id FROM vec_call_transcripts
                WHERE bucket_month BETWEEN ? AND ? AND embedding MATCH ? AND k = ? ORDER BY distance
                """, arguments: [b0, b1, blob, limit])
            var callIDs: [Int64] = []
            var seen = Set<Int64>()
            for revisionID in revisionIDs {
                if let callID = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM calls WHERE preferredRevisionId = ? AND state != 'erased'",
                    arguments: [revisionID]
                ), seen.insert(callID).inserted {
                    callIDs.append(callID)
                }
            }
            return callIDs
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

    /// Three independent FTS legs. app filter: the needle resolves to an appId list IN SWIFT (Unicode-correct;
    /// SQLite lower() is ASCII-only and broke Cyrillic) and goes into SQL as `appId IN (…)` — lossless
    /// (a post-filter over topN lost rare apps that drowned behind frequent words).
    private func ftsSearch(_ query: String, filters: SearchFilters,
                           limit: Int) async throws -> (screen: [SearchResult], audio: [SearchResult], call: [SearchResult]) {
        let match = Self.ftsQuery(query)
        guard !match.isEmpty else { return ([], [], []) }
        let fromMs = filters.from.map(msFromDate) ?? 0
        let toMs = filters.to.map(msFromDate) ?? Int64.max
        let wantScreen = filters.kind != .audio && filters.kind != .call
        // audio has no appId → under an app filter the audio leg is guaranteed empty, skip the extra FTS scan
        let wantAudio = filters.kind != .screen && filters.kind != .call && (filters.app?.isEmpty ?? true)
        let wantCall = filters.kind != .screen && filters.kind != .audio && (filters.app?.isEmpty ?? true)
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
            guard !ids.isEmpty else { return ([], [], []) }   // no such app — an honest zero
            appIdsClause = "AND c.appId IN (\(ids.map(String.init).joined(separator: ",")))"
        } else {
            appIdsClause = ""
        }
        return try await db.pool.read { db in
            var screen: [SearchResult] = []
            var audio: [SearchResult] = []
            var call: [SearchResult] = []
            if wantScreen {
                let protectedIDs = try SystemAppFilter.protectedAppIDs(in: db)
                let protectedTextBlocksClause: String
                if protectedIDs.isEmpty {
                    protectedTextBlocksClause = ""
                } else {
                    let ids = protectedIDs.map(String.init).joined(separator: ",")
                    protectedTextBlocksClause = """
                    AND NOT EXISTS (
                        SELECT 1
                        FROM text_blocks protected_tb
                        JOIN screen_captures protected_c ON protected_c.id = protected_tb.captureId
                        WHERE protected_tb.id = text_fts.rowid
                          AND protected_c.appId IN (\(ids))
                    )
                    """
                }
                let visible = SystemAppFilter.visibleCapturePredicate(
                    .c,
                    protectedAppIDs: protectedIDs
                )
                // snippet()/bm25() stay in a SELECT whose only FROM source is text_fts. The correlated
                // rowid check rejects legacy protected blocks before LIMIT 5000 without joining
                // another table into the FTS cursor (which loses snippet()/bm25() context).
                let screenSQL = """
                WITH hits AS (
                    SELECT rowid AS tbid, snippet(text_fts, 0, '⟦', '⟧', '…', 12) AS snip,
                           bm25(text_fts) AS rank
                    FROM text_fts
                    WHERE text_fts MATCH ?
                    \(protectedTextBlocksClause)
                    ORDER BY rank LIMIT ?
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
                    WHERE c.ts BETWEEN ? AND ? AND \(visible) \(appIdsClause)
                )
                SELECT id, ts, bundleId, appName, windowTitle, browserUrl, relativePath, snip, rank
                FROM ranked WHERE rn = 1 ORDER BY rank LIMIT ?
                """
                for row in try Row.fetchAll(db, sql: screenSQL,
                                            arguments: [match, 5_000, fromMs, toMs, limit]) {
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
            if wantCall {
                let callSQL = """
                WITH hits AS (
                    SELECT revision_id, call_id,
                           snippet(call_transcript_fts, 2, '⟦', '⟧', '…', 12) AS snip,
                           bm25(call_transcript_fts) AS rank
                    FROM call_transcript_fts WHERE call_transcript_fts MATCH ?
                    ORDER BY rank LIMIT 5000
                )
                SELECT c.id AS id, c.startTs AS ts, c.endTs AS endTs, r.kind AS revisionKind,
                       h.snip AS snip, h.rank AS rank
                FROM hits h
                JOIN calls c ON c.id = h.call_id AND c.preferredRevisionId = h.revision_id
                JOIN call_transcript_revisions r ON r.id = h.revision_id
                WHERE c.state != 'erased' AND c.startTs <= ? AND COALESCE(c.endTs, c.startTs) >= ?
                ORDER BY h.rank LIMIT ?
                """
                for row in try Row.fetchAll(db, sql: callSQL, arguments: [match, toMs, fromMs, limit]) {
                    let revisionKind: String = row["revisionKind"]
                    call.append(SearchResult(
                        id: row["id"], kind: .call, ts: dateFromMs(row["ts"]),
                        endTs: (row["endTs"] as Int64?).map(dateFromMs),
                        bundleId: nil, appName: "Call",
                        windowTitle: revisionKind == CallTranscriptRevisionKind.final.rawValue
                            ? "Final transcript" : "Provisional transcript",
                        browserURL: nil, snippet: row["snip"] ?? "", relativePath: nil
                    ))
                }
            }
            return (screen, audio, call)
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

    private func fetchCallResult(_ callID: Int64) async throws -> SearchResult? {
        try await db.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT c.id AS id, c.startTs AS ts, c.endTs AS endTs, r.kind AS revisionKind,
                       substr(r.text, 1, 140) AS snip
                FROM calls c
                JOIN call_transcript_revisions r ON r.id = c.preferredRevisionId
                WHERE c.id = ? AND c.state != 'erased' AND r.state = 'ready'
                """, arguments: [callID]) else { return nil }
            let revisionKind: String = row["revisionKind"]
            return SearchResult(
                id: row["id"], kind: .call, ts: dateFromMs(row["ts"]),
                endTs: (row["endTs"] as Int64?).map(dateFromMs),
                bundleId: nil, appName: "Call",
                windowTitle: revisionKind == CallTranscriptRevisionKind.final.rawValue
                    ? "Final transcript" : "Provisional transcript",
                browserURL: nil, snippet: row["snip"] ?? "", relativePath: nil
            )
        }
    }

    /// User input → safe FTS5 prefix MATCH (quoted tokens + `*`, implicit AND).
    static func ftsQuery(_ q: String) -> String {
        let tokens = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " ")
    }
}

extension SearchService: AskSearchProviding {}
