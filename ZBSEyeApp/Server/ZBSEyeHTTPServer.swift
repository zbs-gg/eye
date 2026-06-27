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
                do { try await srv.run() } catch { Self.log("run error on \(port): \(error)") }
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
        await srv.appendRoute("GET /health") { [self] _ in
            let cap = await deps.isCapturing()
            return Self.json(APIDTO.Health(status: "ok", version: deps.version, capturing: cap))
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
        guard let host = headerValue(req, "Host"), Self.isLocalHost(host) else { return false }
        guard let auth = headerValue(req, "Authorization"), auth == "Bearer \(deps.token)" else { return false }
        return true
    }

    private func headerValue(_ req: HTTPRequest, _ name: String) -> String? {
        for (k, v) in req.headers where k.rawValue.caseInsensitiveCompare(name) == .orderedSame { return v }
        return nil
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let h = host.split(separator: ":").first.map(String.init) ?? host
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "[::1]"
    }

    // MARK: handlers

    private func handleSearch(_ req: HTTPRequest) async -> HTTPResponse {
        let p = Self.query(req)
        let q = p["q"] ?? ""
        guard !q.isEmpty else { return Self.badRequest("missing q") }
        var kind: SearchKind? = nil
        if let k = p["kind"] {
            guard let parsed = SearchKind(rawValue: k) else { return Self.badRequest("kind: screen|audio") }
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
            let results = try await deps.search.search(query: q, filters: filters)
            let hits = results.map { r in
                APIDTO.SearchHit(
                    id: r.id, kind: r.kind.rawValue, ts: msFromDate(r.ts), tsISO: isoFromMs(msFromDate(r.ts)),
                    app: .init(bundleId: r.bundleId, name: r.appName),
                    windowTitle: r.windowTitle, browserUrl: r.browserURL, snippet: r.snippet,
                    media: .init(
                        frameUrl: r.kind == .screen ? "/v1/frame/image?id=\(r.id)" : nil,
                        audioUrl: r.kind == .audio ? "/v1/audio/file?id=\(r.id)" : nil,
                        transcriptUrl: r.kind == .audio ? "/v1/transcript?audio_id=\(r.id)" : nil))
            }
            return Self.json(APIDTO.SearchResponse(query: q, total: hits.count,
                                                   limit: filters.limit, offset: filters.offset,
                                                   results: hits))
        } catch {
            Self.log("search error: \(error)")
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
            Self.log("transcript error: \(error)")
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
            Self.log("timeline error: \(error)")
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
            let oldest = try? Int64.fetchOne(db, sql: "SELECT MIN(ts) FROM screen_captures")
            let newest = try? Int64.fetchOne(db, sql: "SELECT MAX(ts) FROM screen_captures")
            return APIDTO.Stats(frames: c("screen_captures"), textBlocks: c("text_blocks"),
                                audioChunks: c("audio_captures"), transcriptions: c("transcriptions"),
                                apps: c("apps"), oldestTs: oldest ?? nil, newestTs: newest ?? nil,
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
    {"openapi":"3.0.3","info":{"title":"ZBS Eye Local API","version":"0.2.0",
     "description":"Local screen/audio memory. Auth: Bearer token on everything except /health. Time: epoch-ms or ISO8601."},
     "paths":{
      "/health":{"get":{"summary":"Status without auth","responses":{"200":{"description":"ok"}}}},
      "/v1/search":{"get":{"summary":"Hybrid search (FTS+semantic, ru/en cross-lingual)",
        "parameters":[{"name":"q","in":"query","required":true,"schema":{"type":"string"}},
          {"name":"from","in":"query","schema":{"type":"string"},"description":"epoch-ms | ISO8601"},
          {"name":"to","in":"query","schema":{"type":"string"}},
          {"name":"app","in":"query","schema":{"type":"string"},"description":"substring of bundleId/name (screen)"},
          {"name":"kind","in":"query","schema":{"type":"string","enum":["screen","audio"]}},
          {"name":"limit","in":"query","schema":{"type":"integer","maximum":200}},
          {"name":"offset","in":"query","schema":{"type":"integer"}}],
        "responses":{"200":{"description":"hits: id, kind, ts, app, snippet, media{frameUrl,audioUrl,transcriptUrl}"},
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
      "/v1/timeline":{"get":{"summary":"Activity density by buckets","parameters":[
          {"name":"from","in":"query","required":true,"schema":{"type":"integer"}},
          {"name":"to","in":"query","required":true,"schema":{"type":"integer"}},
          {"name":"bucket","in":"query","schema":{"type":"integer"},"description":"ms, default 60000"}],
        "responses":{"200":{"description":"buckets[{ts,count}]"}}}},
      "/v1/stats":{"get":{"summary":"Counters and history range","responses":{"200":{"description":"frames, audioChunks, mediaBytes…"}}}},
      "/v1/capture/toggle":{"post":{"summary":"Toggle recording on/off","parameters":[
          {"name":"enable","in":"query","schema":{"type":"boolean"}}],"responses":{"200":{"description":"capturing"}}}}}}
    """#

    private static func unauthorized() -> HTTPResponse { error(.unauthorized, "Bearer token required, localhost-only access", code: "unauthorized") }
    private static func badRequest(_ m: String) -> HTTPResponse { error(.badRequest, m, code: "bad_request") }
    private static func notFound(_ m: String) -> HTTPResponse { error(.notFound, "not found: \(m)", code: "not_found") }
}
