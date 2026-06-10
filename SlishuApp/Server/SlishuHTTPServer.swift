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
    private var runTask: Task<Void, Never>?
    private(set) var activePort: Int?

    init(deps: Deps) { self.deps = deps }

    // MARK: lifecycle

    func start(preferredPorts: [UInt16] = [8731, 8732, 11435, 8088]) async -> Int? {
        for port in preferredPorts {
            // КРИТИЧНО: bind на 127.0.0.1 (loopback), а НЕ HTTPServer(port:) — он биндит INADDR_ANY (0.0.0.0)
            // и открыл бы историю экрана всей локальной сети.
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
        guard let data = line.data(using: .utf8),
              let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
                .appendingPathComponent("Slishu", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("server.log")
        // Ротация: > 5MB → server.log.1 (одно поколение). 24/7-аптайм не должен растить лог бесконечно.
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
        await server?.stop()        // корректная остановка FlyingFox (не только cancel)
        runTask?.cancel()
        runTask = nil
        server = nil
        activePort = nil
        Self.removePortFile()       // не оставлять stale port-файл (MCP мог бы пойти на чужой порт)
    }

    private static func removePortFile() {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: false) else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("Slishu/port"))
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
        await srv.appendRoute("GET /v1/transcript") { [self] req in
            guard await authorized(req) else { return Self.unauthorized() }
            return await handleTranscript(req)
        }
        await srv.appendRoute("GET /v1/audio/file") { [self] req in
            guard await authorized(req) else { return Self.unauthorized() }
            return await handleAudioFile(req)
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
        // Присутствующий, но нераспарсенный from/to — это 400, а НЕ молчаливый сброс фильтра:
        // иначе «что я делал вчера» вернуло бы всю историю под видом «вчера» (ложь агенту).
        var from: Date? = nil
        if let s = p["from"] {
            guard let d = Self.parseTimeParam(s) else { return Self.badRequest("from: epoch-ms или ISO8601") }
            from = d
        }
        var to: Date? = nil
        if let s = p["to"] {
            guard let d = Self.parseTimeParam(s) else { return Self.badRequest("to: epoch-ms или ISO8601") }
            to = d
        }
        let filters = SearchFilters(
            from: from, to: to,
            app: p["app"],
            kind: kind,
            limit: p["limit"].flatMap { Int($0) } ?? 60,
            offset: p["offset"].flatMap { Int($0) } ?? 0)
        do {
            // честная ошибка вместо 200-пустышки: LAM обязан отличать «не нашлось» от «БД сломана»
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

    /// from/to: epoch-ms (целое) или ISO8601 (с/без долей секунды — JS Date.toISOString() даёт доли;
    /// один ISO8601DateFormatter оба варианта не парсит) или просто дата.
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

    /// Транскрипт аудио-сегмента (для LAM: «что обсуждали на звонке»).
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

    /// m4a-файл сегмента (тот же traversal-hardening, что и у кадров).
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
