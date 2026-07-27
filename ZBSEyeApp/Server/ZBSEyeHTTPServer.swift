import Foundation
import FlyingFox
import FlyingSocks
import GRDB
import CoreImage
import CoreGraphics

/// Local REST `/v1` (FlyingFox). Binds ONLY 127.0.0.1 (loopback, not INADDR_ANY!), dynamic port,
/// **auth on EVERYTHING except /health** (Bearer token from Keychain), Host check, path-traversal hardening.
actor ZBSEyeHTTPServer {
    struct Deps: Sendable {
        let search: SearchService
        let timeline: TimelineService
        let calls: CallEvidenceQueryService
        let db: ZBSEyeDatabase
        let mediaDir: URL
        let token: String
        let version: String
        let isCapturing: @Sendable () async -> Bool
        let toggleCapture: @Sendable (Bool?) async -> Bool
        let mediaBytes: @Sendable () async -> Int64
    }

    private let deps: Deps
    private var server: HTTPServer?
    private var runTask: Task<Void, Never>?
    private(set) var activePort: Int?

    init(deps: Deps) { self.deps = deps }

    // MARK: lifecycle

    func start(preferredPorts: [UInt16] = [8731, 8732, 11435, 8088]) async -> Int? {
        for port in preferredPorts {
            // CRITICAL: bind to 127.0.0.1 (loopback), and NOT HTTPServer(port:) — it binds INADDR_ANY (0.0.0.0)
            // and would expose the screen history to the whole local network.
            guard let address = try? sockaddr_in.inet(ip4: "127.0.0.1", port: port) else { Self.log("bad addr \(port)"); continue }
            let srv = HTTPServer(address: address)
            await registerRoutes(srv)
            let task = Task {
                do { try await srv.run() } catch { Self.log("run_failed port=\(port)") }
            }
            let ok = await Self.raceListening(srv)
            Self.log("port \(port): listened=\(ok)")
            if ok {
                server = srv
                runTask = task
                activePort = Int(port)
                Self.writePortFile(Int(port))
                return Int(port)
            } else {
                task.cancel()
            }
        }
        Self.log("server: all ports failed")
        return nil
    }

    static func log(_ s: String) {
        Log.server.info("\(s, privacy: .public)")
        let line = "[\(Date())] \(s)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = StorageLocation.serverLogURL()       // accounts for relocate
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Rotation: > 5MB → server.log.1 (one generation). 24/7 uptime mustn't grow the log forever.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 5_000_000 {
            let rotated = dir.appendingPathComponent("server.log.1")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: url, to: rotated)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    func stop() async {
        await server?.stop()        // proper FlyingFox shutdown (not just cancel)
        runTask?.cancel()
        runTask = nil
        server = nil
        activePort = nil
        Self.removePortFile()       // don't leave a stale port file (MCP could hit the wrong port)
    }

    private static func removePortFile() {
        try? FileManager.default.removeItem(at: StorageLocation.portURL())
    }

    private static func raceListening(_ srv: HTTPServer) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do { try await srv.waitUntilListening(); return true } catch { return false }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2)); return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private static func writePortFile(_ port: Int) {
        let url = StorageLocation.portURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(port)".write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: routes

    private func registerRoutes(_ srv: HTTPServer) async {
        await srv.appendRoute("GET /health") { [self] req in
            let cap = await deps.isCapturing()
            let challenge = Self.query(req)["challenge"]
            let listeningPort = await self.activePort
            let proof = challenge.flatMap { challenge in
                listeningPort.flatMap {
                    LocalPeerAuthenticator.proof(
                        token: deps.token,
                        challenge: challenge,
                        listeningPort: $0
                    )
                }
            }
            return Self.json(
                APIDTO.Health(
                    status: "ok",
                    version: deps.version,
                    capturing: cap,
                    proof: proof
                )
            )
        }
        await srv.appendRoute("GET /v1/search") { [self] req in
            guard await authorized(req) else { return Self.unauthorized() }
            return await handleSearch(req)
        }
        await srv.appendRoute("GET /v1/timeline") { [self] req in
            guard await authorized(req) else { return Self.unauthorized() }
            return await handleTimeline(req)
        }
        await srv.appendRoute("GET /v1/frame") { [self] req in
            guard await authorized(req) else { return Self.unauthorized() }
            return await handleFrame(req)
        }
        await srv.appendRoute("GET /v1/frame/image") { [self] req in
            guard await authorized(req) else { return Self.unauthorized() }
            return await handleImage(req)
        }
        await srv.appendRoute("GET /v1/transcript") { [self] req in
            guard await authorized(req) else { return Self.unauthorized() }
            return await handleTranscript(req)
        }
        await srv.appendRoute("GET /v1/audio/file") { [self] req in
            guard await authorized(req) else { return Self.unauthorized() }
            return await handleAudioFile(req)
        }
        await srv.appendRoute("GET /v1/calls") { [self] req in
            guard await authorized(req) else { return Self.unauthorized() }
            return await handleCalls(req)
        }
        await srv.appendRoute("GET /v1/call") { [self] req in
            guard await authorized(req) else { return Self.unauthorized() }
            return await handleCallEnvelope(req)
        }
        await srv.appendRoute("GET /v1/call/bookmarks") { [self] req in
            guard await authorized(req) else { return Self.unauthorized() }
            return await handleCallBookmarks(req)
        }
        await srv.appendRoute("GET /v1/call/transcript") { [self] req in
            guard await authorized(req) else { return Self.unauthorized() }
            return await handleCallTranscript(req)
        }
        await srv.appendRoute("GET /v1/call/evidence") { [self] req in
            guard await authorized(req) else { return Self.unauthorized() }
            return await handleCallEvidence(req)
        }
        await srv.appendRoute("GET /v1/openapi.json") { [self] req in
            guard await authorized(req) else { return Self.unauthorized() }
            return HTTPResponse(statusCode: .ok,
                                headers: [HTTPHeader.contentType: "application/json; charset=utf-8"],
                                body: Data(Self.openAPISpec.utf8))
        }
        await srv.appendRoute("GET /v1/stats") { [self] req in
            guard await authorized(req) else { return Self.unauthorized() }
            return await handleStats()
        }
        await srv.appendRoute("POST /v1/capture/toggle") { [self] req in
            guard await authorized(req) else { return Self.unauthorized() }
            let enable = Self.query(req)["enable"].flatMap { Bool($0) }
            let now = await deps.toggleCapture(enable)
            return Self.json(["capturing": now])
        }
    }

    // MARK: auth

    private func authorized(_ req: HTTPRequest) -> Bool {
        APILocalAuthorization.allows(
            hostHeader: headerValue(req, "Host"),
            authorizationHeader: headerValue(req, "Authorization"),
            token: deps.token
        )
    }

    private func headerValue(_ req: HTTPRequest, _ name: String) -> String? {
        for (k, v) in req.headers where k.rawValue.caseInsensitiveCompare(name) == .orderedSame { return v }
        return nil
    }

    // MARK: handlers

    private func handleSearch(_ req: HTTPRequest) async -> HTTPResponse {
        let p = Self.query(req)
        let q = p["q"] ?? ""
        guard !q.isEmpty else { return Self.badRequest("missing q") }
        var kind: SearchKind? = nil
        if let k = p["kind"] {
            guard let parsed = SearchKind(rawValue: k) else { return Self.badRequest("kind: screen|audio|call") }
            kind = parsed
        }
        // A present but unparsed from/to is a 400, NOT a silent filter reset:
        // otherwise "what did I do yesterday" would return the whole history disguised as "yesterday" (a lie to the agent).
        var from: Date? = nil
        if let s = p["from"] {
            guard let d = Self.parseTimeParam(s) else { return Self.badRequest("from: epoch-ms or ISO8601") }
            from = d
        }
        var to: Date? = nil
        if let s = p["to"] {
            guard let d = Self.parseTimeParam(s) else { return Self.badRequest("to: epoch-ms or ISO8601") }
            to = d
        }
        let filters = SearchFilters(
            from: from, to: to,
            app: p["app"],
            kind: kind,
            limit: p["limit"].flatMap { Int($0) } ?? 60,
            offset: p["offset"].flatMap { Int($0) } ?? 0)
        do {
            // an honest error instead of an empty 200: the LAM must distinguish "not found" from "DB is broken"
            let execution = try await deps.search.searchWithMetadata(query: q, filters: filters)
            let hits = execution.results.map { r in
                APIDTO.SearchHit(
                    id: r.id, kind: r.kind.rawValue, ts: msFromDate(r.ts),
                    endTs: r.endTs.map(msFromDate), tsISO: isoFromMs(msFromDate(r.ts)),
                    app: .init(bundleId: r.bundleId, name: r.appName),
                    windowTitle: r.windowTitle, browserUrl: r.browserURL, snippet: r.snippet,
                    media: .init(
                        frameUrl: r.kind == .screen ? "/v1/frame/image?id=\(r.id)" : nil,
                        audioUrl: r.kind == .audio ? "/v1/audio/file?id=\(r.id)" : nil,
                        transcriptUrl: r.kind == .audio ? "/v1/transcript?audio_id=\(r.id)" : nil,
                        callUrl: r.kind == .call ? "/v1/call?call_id=call:\(r.id)" : nil))
            }
            let mode: String
            let fallbackReason: String?
            switch execution.semanticMode {
            case .hybrid:
                mode = "hybrid"
                fallbackReason = nil
            case .embeddingUnavailable:
                mode = "embeddingUnavailable"
                fallbackReason = nil
            case .ftsOnly(let reason):
                mode = "ftsOnly"
                fallbackReason = reason.rawValue
            }
            return Self.json(APIDTO.SearchResponse(query: q, total: hits.count,
                                                   limit: filters.limit, offset: filters.offset,
                                                   semanticMode: mode,
                                                   semanticFallbackReason: fallbackReason,
                                                   results: hits))
        } catch {
            Self.log("search_failed")
            return Self.error(.internalServerError, "search failed", code: "search_failed")
        }
    }

    /// from/to: epoch-ms (integer) or ISO8601 (with/without fractional seconds — JS Date.toISOString() gives fractions;
    /// a single ISO8601DateFormatter doesn't parse both variants) or just a date.
    static func parseTimeParam(_ s: String) -> Date? {
        if let ms = Int64(s) { return dateFromMs(ms) }
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        return dateOnly.date(from: s)
    }

    /// Transcript of an audio segment (for the LAM: "what was discussed on the call").
    private func handleTranscript(_ req: HTTPRequest) async -> HTTPResponse {
        guard let id = Self.query(req)["audio_id"].flatMap({ Int64($0) }) else {
            return Self.badRequest("audio_id required")
        }
        do {
            guard let d = try await deps.timeline.audioDetail(id: id) else { return Self.notFound("audio") }
            return Self.json(APIDTO.Transcript(
                audioId: d.id, ts: msFromDate(d.ts), tsISO: isoFromMs(msFromDate(d.ts)),
                durationSec: d.durationSec, channel: d.channel, speaker: d.speaker,
                language: d.language, text: d.transcript,
                audioUrl: "/v1/audio/file?id=\(d.id)"))
        } catch {
            Self.log("transcript_failed")
            return Self.error(.internalServerError, "transcript failed", code: "transcript_failed")
        }
    }

    /// The segment's m4a file (the same traversal hardening as for frames).
    private func handleAudioFile(_ req: HTTPRequest) async -> HTTPResponse {
        guard let id = Self.query(req)["id"].flatMap({ Int64($0) }),
              let d = try? await deps.timeline.audioDetail(id: id) else { return Self.notFound("audio") }
        let rel = d.relativePath
        guard !rel.contains(".."), !rel.hasPrefix("/") else { return Self.notFound("audio") }
        let base = deps.mediaDir.standardizedFileURL.resolvingSymlinksInPath()
        let target = base.appendingPathComponent(rel).standardizedFileURL.resolvingSymlinksInPath()
        guard Array(target.pathComponents.prefix(base.pathComponents.count)) == base.pathComponents,
              let data = try? Data(contentsOf: target) else { return Self.notFound("audio") }
        return HTTPResponse(statusCode: .ok, headers: [HTTPHeader.contentType: "audio/mp4"], body: data)
    }

    private func handleCalls(_ req: HTTPRequest) async -> HTTPResponse {
        let p = Self.query(req)
        guard let pagination = Self.pagination(p, defaultLimit: 25) else {
            return Self.badRequest("limit must be 1...100 and offset must be >= 0")
        }
        var fromMs: Int64?
        if let raw = p["from"] {
            guard let date = Self.parseTimeParam(raw) else { return Self.badRequest("from: epoch-ms or ISO8601") }
            fromMs = msFromDate(date)
        }
        var toMs: Int64?
        if let raw = p["to"] {
            guard let date = Self.parseTimeParam(raw) else { return Self.badRequest("to: epoch-ms or ISO8601") }
            toMs = msFromDate(date)
        }
        do {
            return Self.json(try await deps.calls.listCalls(
                query: p["q"],
                fromMs: fromMs,
                toMs: toMs,
                limit: pagination.limit,
                offset: pagination.offset
            ))
        } catch let error as CallEvidenceRequestError {
            return Self.callRequestError(error)
        } catch {
            Self.log("call list failed")
            return Self.error(.internalServerError, "call evidence unavailable", code: "call_evidence_failed")
        }
    }

    private func handleCallEnvelope(_ req: HTTPRequest) async -> HTTPResponse {
        guard let raw = Self.query(req)["call_id"],
              let callID = CallEvidenceIdentifier.parseCall(raw) else {
            return Self.badRequest("typed call_id required, for example call:42")
        }
        do {
            guard let envelope = try await deps.calls.envelope(callID: callID) else { return Self.notFound("call") }
            return Self.json(envelope)
        } catch {
            Self.log("call envelope failed")
            return Self.error(.internalServerError, "call evidence unavailable", code: "call_evidence_failed")
        }
    }

    private func handleCallBookmarks(_ req: HTTPRequest) async -> HTTPResponse {
        let p = Self.query(req)
        guard let raw = p["call_id"], let callID = CallEvidenceIdentifier.parseCall(raw) else {
            return Self.badRequest("typed call_id required, for example call:42")
        }
        guard let pagination = Self.pagination(p, defaultLimit: 50) else {
            return Self.badRequest("limit must be 1...100 and offset must be >= 0")
        }
        do {
            return Self.json(try await deps.calls.bookmarks(
                callID: callID,
                limit: pagination.limit,
                offset: pagination.offset
            ))
        } catch let error as CallEvidenceRequestError {
            return Self.callRequestError(error)
        } catch {
            Self.log("call bookmarks failed")
            return Self.error(.internalServerError, "call evidence unavailable", code: "call_evidence_failed")
        }
    }

    private func handleCallTranscript(_ req: HTTPRequest) async -> HTTPResponse {
        let p = Self.query(req)
        guard let raw = p["call_id"], let callID = CallEvidenceIdentifier.parseCall(raw) else {
            return Self.badRequest("typed call_id required, for example call:42")
        }
        guard let selector = CallTranscriptSelector(rawValue: p["selector"] ?? "preferred") else {
            return Self.badRequest("selector must be preferred or bookmark")
        }
        let bookmarkID: Int64?
        if let rawBookmark = p["bookmark_id"] {
            guard let parsed = CallEvidenceIdentifier.parseBookmark(rawBookmark) else {
                return Self.badRequest("typed bookmark_id required, for example bookmark:7")
            }
            bookmarkID = parsed
        } else {
            bookmarkID = nil
        }
        guard let pagination = Self.pagination(p, defaultLimit: 80) else {
            return Self.badRequest("limit must be 1...100 and offset must be >= 0")
        }
        do {
            return Self.json(try await deps.calls.transcript(
                callID: callID,
                selector: selector,
                bookmarkID: bookmarkID,
                limit: pagination.limit,
                offset: pagination.offset
            ))
        } catch let error as CallEvidenceRequestError {
            return Self.callRequestError(error)
        } catch {
            Self.log("call transcript failed")
            return Self.error(.internalServerError, "call evidence unavailable", code: "call_evidence_failed")
        }
    }

    private func handleCallEvidence(_ req: HTTPRequest) async -> HTTPResponse {
        guard let reference = Self.query(req)["evidence_id"] else {
            return Self.badRequest("typed evidence_id required")
        }
        do {
            guard let evidence = try await deps.calls.audioEvidence(reference: reference),
                  let url = ManagedMediaResolver.url(
                    relativePath: evidence.relativePath,
                    mediaRoot: deps.mediaDir
                  ),
                  let data = try? Data(contentsOf: url) else { return Self.notFound("call evidence") }
            return HTTPResponse(
                statusCode: .ok,
                headers: [HTTPHeader.contentType: "application/octet-stream"],
                body: data
            )
        } catch let error as CallEvidenceRequestError {
            return Self.callRequestError(error)
        } catch {
            Self.log("call media failed")
            return Self.error(.internalServerError, "call evidence unavailable", code: "call_evidence_failed")
        }
    }

    private func handleTimeline(_ req: HTTPRequest) async -> HTTPResponse {
        let p = Self.query(req)
        guard let from = p["from"].flatMap({ Int64($0) }), let to = p["to"].flatMap({ Int64($0) }) else {
            return Self.badRequest("from/to required (epoch ms)")
        }
        let bucket = p["bucket"].flatMap { Int64($0) } ?? 60_000
        do {
            let buckets = try await deps.timeline.density(from: dateFromMs(from), to: dateFromMs(to), bucketMs: bucket)
            let dto = buckets.map { APIDTO.DensityBucketDTO(ts: msFromDate($0.ts), count: $0.count) }
            return Self.json(APIDTO.TimelineResponse(from: from, to: to, bucketMs: bucket, buckets: dto))
        } catch {
            Self.log("timeline_failed")
            return Self.error(.internalServerError, "timeline failed", code: "timeline_failed")
        }
    }

    private func handleFrame(_ req: HTTPRequest) async -> HTTPResponse {
        let p = Self.query(req)
        let detail: FrameDetail?
        if let id = p["id"].flatMap({ Int64($0) }) {
            detail = try? await deps.timeline.frameDetail(id: id)
        } else if let at = p["at"].flatMap({ Int64($0) }) {
            detail = try? await deps.timeline.frameAt(dateFromMs(at))
        } else {
            return Self.badRequest("id or at required")
        }
        guard let d = detail else { return Self.notFound("frame") }
        return Self.json(APIDTO.Frame(
            id: d.id, ts: msFromDate(d.ts), tsISO: isoFromMs(msFromDate(d.ts)),
            app: .init(bundleId: d.bundleId, name: d.appName), windowTitle: d.windowTitle,
            browserUrl: d.browserURL, axQuality: d.axQuality, text: d.text,
            media: .init(frameUrl: "/v1/frame/image?id=\(d.id)")))
    }

    private func handleImage(_ req: HTTPRequest) async -> HTTPResponse {
        guard let id = Self.query(req)["id"].flatMap({ Int64($0) }),
              let d = try? await deps.timeline.frameDetail(id: id),
              let rel = d.relativePath else { return Self.notFound("image") }
        // path-traversal hardening: name from the DB (not the URL) + explicit reject of ".." / absolute + mediaDir bounds
        guard !rel.contains(".."), !rel.hasPrefix("/") else { return Self.notFound("image") }
        let base = deps.mediaDir.standardizedFileURL.resolvingSymlinksInPath()
        let target = base.appendingPathComponent(rel).standardizedFileURL.resolvingSymlinksInPath()
        guard Array(target.pathComponents.prefix(base.pathComponents.count)) == base.pathComponents,
              let data = try? Data(contentsOf: target) else { return Self.notFound("image") }
        // ?format=jpeg — for browsers/LLM viewers (they don't decode HEIC)
        if Self.query(req)["format"] == "jpeg", let jpeg = Self.heicToJPEG(data) {
            return HTTPResponse(statusCode: .ok, headers: [HTTPHeader.contentType: "image/jpeg"], body: jpeg)
        }
        return HTTPResponse(statusCode: .ok, headers: [HTTPHeader.contentType: "image/heic"], body: data)
    }

    /// HEIC→JPEG downscaled to 1280px (like MCP's loadFrameJPEG): without it a full-size Retina/5K
    /// frame yields a 5-15MB response and ~100MB of uncompressed bitmap in RAM on EVERY request — an agent in a loop builds
    /// up memory pressure on the GUI process.
    private static func heicToJPEG(_ heic: Data, maxDim: CGFloat = 1280) -> Data? {
        guard let ci = CIImage(data: heic) else { return nil }
        let ext = ci.extent
        let longest = max(ext.width, ext.height)
        let scale = longest > maxDim ? maxDim / longest : 1.0
        let scaled = scale < 1.0 ? ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ci
        return CIContext().jpegRepresentation(of: scaled, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:])
    }

    private func handleStats() async -> HTTPResponse {
        let counts = (try? await deps.db.pool.read { db -> APIDTO.Stats in
            func c(_ t: String) -> Int { (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(t)")) ?? 0 }
            let screen = try SystemAppFilter.visibleScreenCaptureStats(in: db)
            return APIDTO.Stats(frames: screen.frames, textBlocks: screen.textBlocks,
                                audioChunks: c("audio_captures"), transcriptions: c("transcriptions"),
                                apps: screen.apps, oldestTs: screen.oldestMs, newestTs: screen.newestMs,
                                mediaBytes: 0)
        })
        guard var stats = counts else { return Self.error(.internalServerError, "db") }
        stats = APIDTO.Stats(frames: stats.frames, textBlocks: stats.textBlocks, audioChunks: stats.audioChunks,
                             transcriptions: stats.transcriptions, apps: stats.apps, oldestTs: stats.oldestTs,
                             newestTs: stats.newestTs, mediaBytes: await deps.mediaBytes())
        return Self.json(stats)
    }

    // MARK: helpers

    private static func query(_ req: HTTPRequest) -> [String: String] {
        var out: [String: String] = [:]
        for item in req.query { out[item.name] = item.value }
        return out
    }

    private static func pagination(
        _ parameters: [String: String],
        defaultLimit: Int
    ) -> CallEvidencePageRequest? {
        let limit: Int
        if let raw = parameters["limit"] {
            guard let parsed = Int(raw) else { return nil }
            limit = parsed
        } else {
            limit = defaultLimit
        }
        let offset: Int
        if let raw = parameters["offset"] {
            guard let parsed = Int(raw) else { return nil }
            offset = parsed
        } else {
            offset = 0
        }
        return try? CallEvidencePageRequest(limit: limit, offset: offset)
    }

    private static func callRequestError(_ error: CallEvidenceRequestError) -> HTTPResponse {
        switch error {
        case .bookmarkDoesNotBelongToCall:
            return notFound("bookmark")
        case .notFound:
            return notFound("call")
        case .invalidIdentifier, .invalidPagination, .invalidSelector, .bookmarkRequired:
            return badRequest("invalid call evidence request")
        }
    }

    private static func json<T: Encodable>(_ value: T, status: HTTPStatusCode = .ok) -> HTTPResponse {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? enc.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(statusCode: status, headers: [HTTPHeader.contentType: "application/json; charset=utf-8"], body: data)
    }
    private static func error(_ status: HTTPStatusCode, _ msg: String, code: String = "error") -> HTTPResponse {
        json(APIDTO.ErrorResponse(error: .init(code: code, message: msg)), status: status)
    }
    /// Compact OpenAPI spec (a machine contract for the LAM; the contract used to live only in code).
    static let openAPISpec = #"""
    {"openapi":"3.0.3","info":{"title":"ZBS Eye Local API","version":"0.5.2",
     "description":"Local screen/audio memory. Auth: Bearer token on everything except /health. Time: epoch-ms or ISO8601."},
     "paths":{
      "/health":{"get":{"summary":"Status without auth","responses":{"200":{"description":"ok"}}}},
      "/v1/search":{"get":{"summary":"Hybrid search (FTS+semantic, ru/en cross-lingual)",
        "parameters":[{"name":"q","in":"query","required":true,"schema":{"type":"string"}},
          {"name":"from","in":"query","schema":{"type":"string"},"description":"epoch-ms | ISO8601"},
          {"name":"to","in":"query","schema":{"type":"string"}},
          {"name":"app","in":"query","schema":{"type":"string"},"description":"substring of bundleId/name (screen)"},
          {"name":"kind","in":"query","schema":{"type":"string","enum":["screen","audio","call"]}},
          {"name":"limit","in":"query","schema":{"type":"integer","maximum":200}},
          {"name":"offset","in":"query","schema":{"type":"integer"}}],
        "responses":{"200":{"description":"hits: id, kind, ts, app, snippet, media{frameUrl,audioUrl,transcriptUrl,callUrl}"},
                     "400":{"description":"invalid parameter (unparsed time, etc.)"},"500":{"description":"failure"}}}},
      "/v1/frame":{"get":{"summary":"Frame by id or nearest to a moment (at)","parameters":[
          {"name":"id","in":"query","schema":{"type":"integer"}},{"name":"at","in":"query","schema":{"type":"integer"},"description":"epoch-ms"}],
        "responses":{"200":{"description":"app, windowTitle, browserUrl, text, media.frameUrl"}}}},
      "/v1/frame/image":{"get":{"summary":"Frame image","parameters":[
          {"name":"id","in":"query","required":true,"schema":{"type":"integer"}},
          {"name":"format","in":"query","schema":{"type":"string","enum":["jpeg"]},"description":"for LLM viewers"}],
        "responses":{"200":{"description":"image/heic | image/jpeg"}}}},
      "/v1/transcript":{"get":{"summary":"Transcript of an audio segment","parameters":[
          {"name":"audio_id","in":"query","required":true,"schema":{"type":"integer"}}],
        "responses":{"200":{"description":"text, speaker(me|other), language, audioUrl"}}}},
      "/v1/audio/file":{"get":{"summary":"Segment m4a","parameters":[
          {"name":"id","in":"query","required":true,"schema":{"type":"integer"}}],
        "responses":{"200":{"description":"audio/mp4"}}}},
      "/v1/calls":{"get":{"summary":"List or search Call Envelopes","parameters":[
          {"name":"q","in":"query","schema":{"type":"string"}},
          {"name":"from","in":"query","schema":{"type":"string"}},
          {"name":"to","in":"query","schema":{"type":"string"}},
          {"name":"limit","in":"query","schema":{"type":"integer","maximum":100}},
          {"name":"offset","in":"query","schema":{"type":"integer"}}],
        "responses":{"200":{"description":"typed call summaries","content":{"application/json":{"schema":{"$ref":"#/components/schemas/CallListPage"}}}},
          "400":{"$ref":"#/components/responses/BadRequest"},"500":{"$ref":"#/components/responses/Failure"}}}},
      "/v1/call":{"get":{"summary":"Read one Call Envelope by typed call_id","parameters":[
          {"$ref":"#/components/parameters/CallId"}],
        "responses":{"200":{"description":"source health, coverage, revision status, evidence refs","content":{"application/json":{"schema":{"$ref":"#/components/schemas/CallEnvelope"}}}},
          "400":{"$ref":"#/components/responses/BadRequest"},"404":{"$ref":"#/components/responses/NotFound"},"500":{"$ref":"#/components/responses/Failure"}}}},
      "/v1/call/bookmarks":{"get":{"summary":"Paginate bookmarks by typed call_id","parameters":[
          {"$ref":"#/components/parameters/CallId"},{"$ref":"#/components/parameters/Limit"},{"$ref":"#/components/parameters/Offset"}],
        "responses":{"200":{"description":"typed bookmark evidence","content":{"application/json":{"schema":{"$ref":"#/components/schemas/BookmarkPage"}}}},
          "400":{"$ref":"#/components/responses/BadRequest"},"404":{"$ref":"#/components/responses/NotFound"},"500":{"$ref":"#/components/responses/Failure"}}}},
      "/v1/call/transcript":{"get":{"summary":"Paginate preferred or bookmark transcript segments","parameters":[
          {"$ref":"#/components/parameters/CallId"},
          {"name":"selector","in":"query","schema":{"type":"string","enum":["preferred","bookmark"],"default":"preferred"}},
          {"name":"bookmark_id","in":"query","description":"required when selector=bookmark","schema":{"type":"string","pattern":"^bookmark:[1-9][0-9]*$"}},
          {"$ref":"#/components/parameters/Limit"},{"$ref":"#/components/parameters/Offset"}],
        "responses":{"200":{"description":"timed source-labelled segments","content":{"application/json":{"schema":{"$ref":"#/components/schemas/TranscriptPage"}}}},
          "400":{"$ref":"#/components/responses/BadRequest"},"404":{"$ref":"#/components/responses/NotFound"},"500":{"$ref":"#/components/responses/Failure"}}}},
      "/v1/call/evidence":{"get":{"summary":"Resolve one typed managed audio evidence ref","parameters":[
          {"$ref":"#/components/parameters/EvidenceId"}],
        "responses":{"200":{"description":"bounded local PCM evidence","content":{"application/octet-stream":{"schema":{"type":"string","format":"binary"}}}},
          "400":{"$ref":"#/components/responses/BadRequest"},"404":{"$ref":"#/components/responses/NotFound"},"500":{"$ref":"#/components/responses/Failure"}}}},
      "/v1/timeline":{"get":{"summary":"Activity density by buckets","parameters":[
          {"name":"from","in":"query","required":true,"schema":{"type":"integer"}},
          {"name":"to","in":"query","required":true,"schema":{"type":"integer"}},
          {"name":"bucket","in":"query","schema":{"type":"integer"},"description":"ms, default 60000"}],
        "responses":{"200":{"description":"buckets[{ts,count}]"}}}},
      "/v1/stats":{"get":{"summary":"Counters and history range","responses":{"200":{"description":"frames, audioChunks, mediaBytes…"}}}},
      "/v1/capture/toggle":{"post":{"summary":"Toggle recording on/off","parameters":[
          {"name":"enable","in":"query","schema":{"type":"boolean"}}],"responses":{"200":{"description":"capturing"}}}}},
     "components":{
      "parameters":{
       "CallId":{"name":"call_id","in":"query","required":true,"schema":{"type":"string","pattern":"^call:[1-9][0-9]*$"}},
       "EvidenceId":{"name":"evidence_id","in":"query","required":true,"schema":{"type":"string","pattern":"^call-audio-chunk:[1-9][0-9]*$"}},
       "Limit":{"name":"limit","in":"query","schema":{"type":"integer","minimum":1,"maximum":100}},
       "Offset":{"name":"offset","in":"query","schema":{"type":"integer","minimum":0,"maximum":1000000}}},
      "responses":{
       "BadRequest":{"description":"invalid typed identifier, selector, time, or pagination","content":{"application/json":{"schema":{"$ref":"#/components/schemas/ErrorResponse"}}}},
       "NotFound":{"description":"typed resource not found","content":{"application/json":{"schema":{"$ref":"#/components/schemas/ErrorResponse"}}}},
       "Failure":{"description":"local evidence unavailable","content":{"application/json":{"schema":{"$ref":"#/components/schemas/ErrorResponse"}}}}},
      "schemas":{
       "ErrorResponse":{"type":"object","required":["error"],"properties":{"error":{"type":"object","required":["code","message"],"properties":{"code":{"type":"string"},"message":{"type":"string"}}}}},
       "CallSummary":{"type":"object","required":["callId","startTs","state","status","retryable","participants","bookmarkCount","speakerStatus"],"properties":{"callId":{"type":"string"},"startTs":{"type":"integer","format":"int64"},"endTs":{"type":"integer","format":"int64","nullable":true},"state":{"type":"string"},"status":{"type":"string","enum":["recording","processing","retryable","ready","degraded"]},"retryable":{"type":"boolean"},"preferredRevisionKind":{"type":"string","nullable":true},"title":{"type":"string","nullable":true},"participants":{"type":"array","items":{"type":"string"}},"sourceApp":{"type":"string","nullable":true},"bookmarkCount":{"type":"integer","minimum":0},"speakerStatus":{"type":"string","enum":["unavailable","processing","ready","degraded"]}}},
       "CallListPage":{"type":"object","required":["limit","offset","hasMore","calls"],"properties":{"query":{"type":"string","nullable":true},"limit":{"type":"integer"},"offset":{"type":"integer"},"hasMore":{"type":"boolean"},"nextOffset":{"type":"integer","nullable":true},"calls":{"type":"array","items":{"$ref":"#/components/schemas/CallSummary"}}}},
       "CallCoverage":{"type":"object","required":["logicalStartMs","complete","hasExplicitGaps"],"properties":{"logicalStartMs":{"type":"integer","format":"int64"},"logicalEndMs":{"type":"integer","format":"int64","nullable":true},"complete":{"type":"boolean"},"hasExplicitGaps":{"type":"boolean"}}},
       "CallSource":{"type":"object","required":["source","health","spanCount","gapCount"],"properties":{"source":{"type":"string","enum":["me","system"]},"health":{"type":"string","enum":["available","gapped","missing"]},"spanCount":{"type":"integer"},"gapCount":{"type":"integer"},"coveredFromMs":{"type":"integer","format":"int64","nullable":true},"coveredToMs":{"type":"integer","format":"int64","nullable":true}}},
       "CallRevision":{"type":"object","required":["revisionId","kind","state","language","engine","modelRevision","logicalStartMs","logicalEndMs"],"properties":{"revisionId":{"type":"string"},"kind":{"type":"string"},"state":{"type":"string"},"language":{"type":"string"},"engine":{"type":"string"},"modelRevision":{"type":"string"},"logicalStartMs":{"type":"integer","format":"int64"},"logicalEndMs":{"type":"integer","format":"int64"}}},
       "CallContext":{"type":"object","required":["captureOwner","disposition","participants"],"properties":{"captureOwner":{"type":"string","enum":["manual","automatic","claimed"]},"disposition":{"type":"string","enum":["active","confirmed","rejected"]},"title":{"type":"string","nullable":true},"participants":{"type":"array","items":{"type":"string"}},"sourceApp":{"type":"string","nullable":true}}},
       "SpeakerInterval":{"type":"object","required":["source","startMs","endMs"],"properties":{"source":{"type":"string","enum":["me","system"]},"startMs":{"type":"integer","format":"int64"},"endMs":{"type":"integer","format":"int64"}}},
       "Speaker":{"type":"object","required":["clusterKey","label","namingProvenance","intervals"],"properties":{"clusterKey":{"type":"string"},"label":{"type":"string"},"namingProvenance":{"type":"string","enum":["anonymous","accessibility","manual"]},"intervals":{"type":"array","items":{"$ref":"#/components/schemas/SpeakerInterval"}}}},
       "SpeakerRevision":{"type":"object","required":["revisionId","state","engine","modelRevision","speakers","intervalsTruncated"],"properties":{"revisionId":{"type":"string"},"state":{"type":"string"},"engine":{"type":"string"},"modelRevision":{"type":"string"},"speakers":{"type":"array","items":{"$ref":"#/components/schemas/Speaker"}},"intervalsTruncated":{"type":"boolean"}}},
       "EvidenceReference":{"type":"object","required":["evidenceId","source","startMs","endMs","bytes"],"properties":{"evidenceId":{"type":"string"},"source":{"type":"string","enum":["me","system"]},"startMs":{"type":"integer","format":"int64"},"endMs":{"type":"integer","format":"int64"},"bytes":{"type":"integer","format":"int64"}}},
       "CallEnvelope":{"type":"object","required":["callId","startTs","state","status","retryable","coverage","sources","speakerStatus","bookmarkCount","evidence","evidenceTruncated"],"properties":{"callId":{"type":"string"},"startTs":{"type":"integer","format":"int64"},"endTs":{"type":"integer","format":"int64","nullable":true},"state":{"type":"string"},"status":{"type":"string"},"retryable":{"type":"boolean"},"degradationCode":{"type":"string","nullable":true},"coverage":{"$ref":"#/components/schemas/CallCoverage"},"sources":{"type":"array","items":{"$ref":"#/components/schemas/CallSource"}},"context":{"allOf":[{"$ref":"#/components/schemas/CallContext"}],"nullable":true},"preferredRevision":{"allOf":[{"$ref":"#/components/schemas/CallRevision"}],"nullable":true},"preferredSpeakerRevision":{"allOf":[{"$ref":"#/components/schemas/SpeakerRevision"}],"nullable":true},"speakerStatus":{"type":"string","enum":["unavailable","processing","ready","degraded"]},"bookmarkCount":{"type":"integer"},"evidence":{"type":"array","items":{"$ref":"#/components/schemas/EvidenceReference"}},"evidenceTruncated":{"type":"boolean"}}},
       "Bookmark":{"type":"object","required":["bookmarkId","callId","ordinal","acceptedAtMs","logicalStartMs","logicalEndMs","state","retryable"],"properties":{"bookmarkId":{"type":"string"},"callId":{"type":"string"},"ordinal":{"type":"integer"},"acceptedAtMs":{"type":"integer","format":"int64"},"logicalStartMs":{"type":"integer","format":"int64"},"logicalEndMs":{"type":"integer","format":"int64"},"state":{"type":"string"},"retryable":{"type":"boolean"}}},
       "BookmarkPage":{"type":"object","required":["callId","limit","offset","hasMore","bookmarks"],"properties":{"callId":{"type":"string"},"limit":{"type":"integer"},"offset":{"type":"integer"},"hasMore":{"type":"boolean"},"nextOffset":{"type":"integer","nullable":true},"bookmarks":{"type":"array","items":{"$ref":"#/components/schemas/Bookmark"}}}},
       "TranscriptSegment":{"type":"object","required":["segmentId","ordinal","source","startMs","endMs","text"],"properties":{"segmentId":{"type":"string"},"ordinal":{"type":"integer"},"source":{"type":"string","enum":["me","system"]},"startMs":{"type":"integer","format":"int64"},"endMs":{"type":"integer","format":"int64"},"text":{"type":"string"}}},
       "TranscriptPage":{"type":"object","required":["callId","selector","limit","offset","hasMore","segments"],"properties":{"callId":{"type":"string"},"selector":{"type":"string","enum":["preferred","bookmark"]},"bookmarkId":{"type":"string","nullable":true},"revision":{"allOf":[{"$ref":"#/components/schemas/CallRevision"}],"nullable":true},"limit":{"type":"integer"},"offset":{"type":"integer"},"hasMore":{"type":"boolean"},"nextOffset":{"type":"integer","nullable":true},"segments":{"type":"array","items":{"$ref":"#/components/schemas/TranscriptSegment"}}}}
      }}}
    """#

    private static func unauthorized() -> HTTPResponse { error(.unauthorized, "Bearer token required, localhost-only access", code: "unauthorized") }
    private static func badRequest(_ m: String) -> HTTPResponse { error(.badRequest, m, code: "bad_request") }
    private static func notFound(_ m: String) -> HTTPResponse { error(.notFound, "not found: \(m)", code: "not_found") }
}
