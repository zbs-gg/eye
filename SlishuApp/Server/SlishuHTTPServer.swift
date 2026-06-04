import Foundation
import FlyingFox
import FlyingSocks
import GRDB
import CoreImage
import CoreGraphics

/// Локальный REST `/v1` (FlyingFox). Bind ТОЛЬКО 127.0.0.1 (loopback, не INADDR_ANY!), динамический порт,
/// **auth на ВСЁ кроме /health** (Bearer-токен из Keychain), Host-check, path-traversal hardening.
actor SlishuHTTPServer {
    struct Deps: Sendable {
        let search: SearchService
        let timeline: TimelineService
        let db: SlishuDatabase
        let mediaDir: URL
        let token: String
        let version: String
        let isCapturing: @Sendable () async -> Bool
        let toggleCapture: @Sendable (Bool?) async -> Bool
        let mediaBytes: @Sendable () async -> Int64
    }

    private let deps: Deps
    private var server: HTTPServer?
    private var runTask: Task<Void, Error>?
    private(set) var activePort: Int?

    init(deps: Deps) { self.deps = deps }

    // MARK: lifecycle

    func start(preferredPorts: [UInt16] = [8731, 8732, 11435, 8088]) async -> Int? {
        for port in preferredPorts {
            // КРИТИЧНО: bind на 127.0.0.1 (loopback), а НЕ HTTPServer(port:) — он биндит INADDR_ANY (0.0.0.0)
            // и открыл бы историю экрана всей локальной сети.
            guard let address = try? sockaddr_in.inet(ip4: "127.0.0.1", port: port) else { continue }
            let srv = HTTPServer(address: address)
            await registerRoutes(srv)
            let task = Task { try await srv.run() }
            if await Self.raceListening(srv) {
                server = srv
                runTask = task
                activePort = Int(port)
                Self.writePortFile(Int(port))
                return Int(port)
            } else {
                task.cancel()
            }
        }
        return nil
    }

    func stop() async {
        await server?.stop()        // корректная остановка FlyingFox (не только cancel)
        runTask?.cancel()
        runTask = nil
        server = nil
        activePort = nil
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
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            .appendingPathComponent("Slishu", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "\(port)".write(to: dir.appendingPathComponent("port"), atomically: true, encoding: .utf8)
    }

    // MARK: routes

    private func registerRoutes(_ srv: HTTPServer) async {
        await srv.appendRoute("GET /health") { [self] _ in
            let cap = await deps.isCapturing()
            let port = await activePort ?? 0
            return Self.json(APIDTO.Health(status: "ok", version: deps.version,
                                           capturing: cap, port: port))
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
        let q = Self.query(req)["q"] ?? ""
        guard !q.isEmpty else { return Self.badRequest("missing q") }
        let results = (try? await deps.search.search(query: q)) ?? []
        let hits = results.map { r in
            APIDTO.SearchHit(
                id: r.id, kind: r.kind.rawValue, ts: msFromDate(r.ts), tsISO: isoFromMs(msFromDate(r.ts)),
                app: .init(bundleId: r.bundleId, name: r.appName),
                windowTitle: r.windowTitle, browserUrl: r.browserURL, snippet: r.snippet,
                media: .init(frameUrl: r.kind == .screen ? "/v1/frame/image?id=\(r.id)" : nil))
        }
        return Self.json(APIDTO.SearchResponse(query: q, total: hits.count, results: hits))
    }

    private func handleTimeline(_ req: HTTPRequest) async -> HTTPResponse {
        let p = Self.query(req)
        guard let from = p["from"].flatMap({ Int64($0) }), let to = p["to"].flatMap({ Int64($0) }) else {
            return Self.badRequest("from/to required (epoch ms)")
        }
        let bucket = p["bucket"].flatMap { Int64($0) } ?? 60_000
        let buckets = (try? await deps.timeline.density(from: dateFromMs(from), to: dateFromMs(to), bucketMs: bucket)) ?? []
        let dto = buckets.map { APIDTO.DensityBucketDTO(ts: msFromDate($0.ts), count: $0.count) }
        return Self.json(APIDTO.TimelineResponse(from: from, to: to, bucketMs: bucket, buckets: dto))
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
        // path-traversal hardening: имя из БД (не из URL) + явный reject ".." / абсолютных + границы mediaDir
        guard !rel.contains(".."), !rel.hasPrefix("/") else { return Self.notFound("image") }
        let base = deps.mediaDir.standardizedFileURL.resolvingSymlinksInPath()
        let target = base.appendingPathComponent(rel).standardizedFileURL.resolvingSymlinksInPath()
        guard Array(target.pathComponents.prefix(base.pathComponents.count)) == base.pathComponents,
              let data = try? Data(contentsOf: target) else { return Self.notFound("image") }
        // ?format=jpeg — для браузеров/LLM-вьюеров (HEIC они не декодируют)
        if Self.query(req)["format"] == "jpeg", let jpeg = Self.heicToJPEG(data) {
            return HTTPResponse(statusCode: .ok, headers: [HTTPHeader.contentType: "image/jpeg"], body: jpeg)
        }
        return HTTPResponse(statusCode: .ok, headers: [HTTPHeader.contentType: "image/heic"], body: data)
    }

    private static func heicToJPEG(_ heic: Data) -> Data? {
        guard let ci = CIImage(data: heic) else { return nil }
        return CIContext().jpegRepresentation(of: ci, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:])
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
    private static func unauthorized() -> HTTPResponse { error(.unauthorized, "Требуется Bearer-токен, доступ только с localhost", code: "unauthorized") }
    private static func badRequest(_ m: String) -> HTTPResponse { error(.badRequest, m, code: "bad_request") }
    private static func notFound(_ m: String) -> HTTPResponse { error(.notFound, "not found: \(m)", code: "not_found") }
}
