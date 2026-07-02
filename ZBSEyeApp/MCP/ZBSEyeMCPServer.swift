import Foundation
import MCP
import GRDB
import CoreImage

/// MCP stdio server (`ZBS Eye --mcp`). Tools on top of the existing services: search/timeline read the DB
/// directly (WAL allows concurrent reads alongside the writing GUI instance); toggle/status are proxied
/// to the running GUI instance over local REST (port from the port file, token from Keychain).
enum ZBSEyeMCPServer {

    /// Short timeout for localhost calls to the GUI instance (otherwise URLSession.shared waits 7 days).
    private static let localSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 5
        return URLSession(configuration: cfg)
    }()

    static func runStdio() async {
        // DB for READING, WITHOUT migrations (the GUI owns the schema; we don't take a write lock).
        let search: SearchService?
        let timeline: TimelineService?
        let db: ZBSEyeDatabase?
        do {
            let d = try ZBSEyeDatabase(path: ZBSEyeDatabase.defaultURL().path, runMigrations: false)
            db = d; search = SearchService(db: d, embedder: EmbeddingService()); timeline = TimelineService(db: d)
        } catch {
            FileHandle.standardError.write("[mcp] db open failed: \(error)\n".data(using: .utf8)!)
            db = nil; search = nil; timeline = nil
        }

        let server = Server(
            name: "zbseye",
            version: "0.1.0",
            capabilities: .init(tools: .init(listChanged: false)))

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: Self.toolList())
        }

        await server.withMethodHandler(CallTool.self) { params in
            let args = params.arguments ?? [:]
            switch params.name {
            case "search_history":
                let q = args["query"]?.stringValue ?? ""
                guard let search, !q.isEmpty else {
                    return .init(content: [.text("No query or the DB is unavailable.")], isError: true)
                }
                var kind: SearchKind? = nil
                if let k = args["kind"]?.stringValue {
                    guard let parsed = SearchKind(rawValue: k) else {
                        return .init(content: [.text("kind: screen | audio")], isError: true)
                    }
                    kind = parsed
                }
                // A present-but-unparsed from/to is an honest error, not a silent filter reset
                var from: Date? = nil
                if let s = args["from"], let str = Self.timeString(s) {
                    guard let d = Self.parseTime(str) else {
                        return .init(content: [.text("from failed to parse: needs ISO8601 or epoch-ms")], isError: true)
                    }
                    from = d
                }
                var to: Date? = nil
                if let s = args["to"], let str = Self.timeString(s) {
                    guard let d = Self.parseTime(str) else {
                        return .init(content: [.text("to failed to parse: needs ISO8601 or epoch-ms")], isError: true)
                    }
                    to = d
                }
                let limit = args["limit"]?.intValue
                    ?? args["limit"]?.stringValue.flatMap { Int($0) }   // limit as a string — a common agent case
                let filters = SearchFilters(
                    from: from, to: to,
                    app: args["app"]?.stringValue,
                    kind: kind,
                    limit: limit ?? 25)
                do {
                    let results = try await search.search(query: q, filters: filters)
                    return .init(content: [.text(Self.formatResults(q, results))])
                } catch {
                    // honest error: the agent must distinguish "nothing found" from "DB broken"
                    return .init(content: [.text("Search failed: \(error)")], isError: true)
                }

            case "get_transcript":
                guard let timeline else {
                    return .init(content: [.text("The DB is unavailable.")], isError: true)
                }
                guard let id = args["audio_id"]?.intValue
                        ?? args["audio_id"]?.stringValue.flatMap({ Int($0) }) else {
                    return .init(content: [.text("audio_id required (from the search results).")], isError: true)
                }
                let detail: AudioDetail?
                do { detail = try await timeline.audioDetail(id: Int64(id)) }
                catch {
                    return .init(content: [.text("DB read failed: \(error)")], isError: true)
                }
                guard let d = detail else {
                    return .init(content: [.text("Audio segment #\(id) not found.")], isError: true)
                }
                var out = "Audio #\(d.id) [\(d.ts.formatted(date: .abbreviated, time: .standard))] "
                out += "\(d.speaker ?? (d.channel == "mic" ? "me" : "other party")) · \(Int(d.durationSec))s"
                out += "\n\n" + (d.transcript ?? "(no transcript — audio recorded, text not recognized)")
                return .init(content: [.text(out)])

            case "get_context_at":
                let timeStr = args["time"]?.stringValue ?? ""
                guard let timeline, let date = Self.parseTime(timeStr) else {
                    return .init(content: [.text("time parameter required (ISO8601 or epoch-ms).")], isError: true)
                }
                let frame = try? await timeline.frameAt(date)
                return .init(content: [.text(Self.formatFrame(frame))])

            case "get_timeline":
                guard let timeline,
                      let from = Self.parseTime(args["from"]?.stringValue ?? ""),
                      let to = Self.parseTime(args["to"]?.stringValue ?? "") else {
                    return .init(content: [.text("from and to required (ISO8601 or epoch-ms).")], isError: true)
                }
                let buckets = (try? await timeline.density(from: from, to: to, bucketMs: 300_000)) ?? []
                return .init(content: [.text(Self.formatTimeline(from, to, buckets))])

            case "get_frame_image":
                guard let timeline else {
                    return .init(content: [.text("The DB is unavailable.")], isError: true)
                }
                guard let id = args["frame_id"]?.intValue
                        ?? args["frame_id"]?.stringValue.flatMap({ Int($0) }) else {
                    return .init(content: [.text("frame_id required (from the search results).")], isError: true)
                }
                guard let d = try? await timeline.frameDetail(id: Int64(id)), let rel = d.relativePath else {
                    return .init(content: [.text("Frame #\(id) not found or has no image (context-only).")], isError: true)
                }
                guard let jpeg = Self.loadFrameJPEG(relativePath: rel) else {
                    return .init(content: [.text("Frame file #\(id) is not readable (may have been removed by retention).")], isError: true)
                }
                return .init(content: [
                    .text("Frame #\(d.id) [\(d.ts.formatted(date: .abbreviated, time: .standard))] \(d.appName ?? "—")\(d.windowTitle.map { " · \($0)" } ?? "")"),
                    .image(data: jpeg.base64EncodedString(), mimeType: "image/jpeg", metadata: nil),
                ])

            case "get_status":
                return .init(content: [.text(await Self.formatStatus(db: db))])

            case "get_diagnostics":
                return .init(content: [.text(await Self.formatDiagnostics(db: db))])

            case "toggle_recording":
                let enable = args["enable"]?.boolValue
                if let now = await Self.proxyToggle(enable: enable) {
                    return .init(content: [.text("Recording \(now ? "on" : "off").")])
                }
                return .init(content: [.text("The ZBS Eye GUI instance isn't running — nothing to control recording.")], isError: true)

            default:
                return .init(content: [.text("Unknown tool: \(params.name)")], isError: true)
            }
        }

        let transport = StdioTransport()
        do {
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
            await server.stop()
            try? await Task.sleep(for: .milliseconds(50))   // let the in-flight toggle POST land
        } catch {
            FileHandle.standardError.write("[mcp] start error: \(error)\n".data(using: .utf8)!)
        }
    }

    // MARK: tools

    private static func toolList() -> [Tool] {
        func strProp(_ desc: String) -> Value {
            .object(["type": .string("string"), "description": .string(desc)])
        }
        return [
            Tool(name: "search_history",
                 description: "Hybrid search (exact words + by meaning, ru/en) over the user's screen and audio history.",
                 inputSchema: .object(["type": .string("object"),
                                       "properties": .object([
                                           "query": strProp("search query"),
                                           "from": strProp("optional: range start, ISO8601 or epoch-ms"),
                                           "to": strProp("optional: range end, ISO8601 or epoch-ms"),
                                           "app": strProp("optional: substring of bundleId/app name (screen only)"),
                                           "kind": strProp("optional: screen | audio"),
                                           "limit": .object(["type": .string("integer"),
                                                             "description": .string("max results (default 25)")]),
                                       ]),
                                       "required": .array([.string("query")])])),
            Tool(name: "get_transcript",
                 description: "Transcript of an audio segment by audio_id from the search results (what was said on the call).",
                 inputSchema: .object(["type": .string("object"),
                                       "properties": .object(["audio_id": .object([
                                           "type": .string("integer"),
                                           "description": .string("id of an audio search result")])]),
                                       "required": .array([.string("audio_id")])])),
            Tool(name: "get_context_at",
                 description: "What was on screen at the given moment: app, window, URL, text.",
                 inputSchema: .object(["type": .string("object"),
                                       "properties": .object(["time": strProp("ISO8601 or epoch-ms")]),
                                       "required": .array([.string("time")])])),
            Tool(name: "get_timeline",
                 description: "Activity over time in a range (how many frames per bucket) — what the user was doing in that time window.",
                 inputSchema: .object(["type": .string("object"),
                                       "properties": .object(["from": strProp("start ISO8601/epoch-ms"),
                                                              "to": strProp("end ISO8601/epoch-ms")]),
                                       "required": .array([.string("from"), .string("to")])])),
            Tool(name: "get_frame_image",
                 description: "Screenshot of a frame by frame_id from the search results (see the screen through the user's eyes).",
                 inputSchema: .object(["type": .string("object"),
                                       "properties": .object(["frame_id": .object([
                                           "type": .string("integer"),
                                           "description": .string("id of a screen search result")])]),
                                       "required": .array([.string("frame_id")])])),
            Tool(name: "get_status",
                 description: "ZBS Eye status: number of frames/texts/audio, history range, whether recording is on.",
                 inputSchema: .object(["type": .string("object"), "properties": .object([:])])),
            Tool(name: "get_diagnostics",
                 description: "Diagnostics for self-repair: app version, macOS, DB migrations + table counts, recording state. Read github.com/zbs-gg/eye with this context to debug/fix ZBS Eye.",
                 inputSchema: .object(["type": .string("object"), "properties": .object([:])])),
            Tool(name: "toggle_recording",
                 description: "Turn recording on/off in the running ZBS Eye GUI instance.",
                 inputSchema: .object(["type": .string("object"),
                                       "properties": .object(["enable": .object(["type": .string("boolean")])])])),
        ]
    }

    // MARK: formatting

    private static func formatResults(_ q: String, _ results: [SearchResult]) -> String {
        guard !results.isEmpty else { return "Nothing found for \"\(q)\"." }
        var out = "Found \(results.count) for \"\(q)\":\n"
        for r in results {
            let app = r.appName ?? r.bundleId ?? "—"
            let when = r.ts.formatted(date: .abbreviated, time: .shortened)
            let snip = r.snippet.replacingOccurrences(of: "\n", with: " ")
            // id in the response: the agent can reference a specific frame/audio in a follow-up
            let ref = r.kind == .audio ? "audio_id=\(r.id)" : "frame_id=\(r.id)"
            out += "\n• [\(when)] \(app)\(r.windowTitle.map { " · \($0)" } ?? "") (\(ref)): \(snip)"
        }
        if !results.isEmpty {
            out += "\n\nFor audio: get_transcript(audio_id). For a screen moment: get_context_at(time)."
        }
        return out
    }

    private static func formatFrame(_ f: FrameDetail?) -> String {
        guard let f else { return "There is no frame for this moment." }
        let app = f.appName ?? f.bundleId ?? "—"
        var out = "At \(f.ts.formatted(date: .abbreviated, time: .standard)) — \(app)"
        if let w = f.windowTitle { out += " · \(w)" }
        if let u = f.browserURL { out += "\nURL: \(u)" }
        out += "\n\n\(f.text.isEmpty ? "(text not extracted)" : f.text)"
        return out
    }

    private static func formatTimeline(_ from: Date, _ to: Date, _ buckets: [DensityBucket]) -> String {
        let total = buckets.reduce(0) { $0 + $1.count }
        guard total > 0 else { return "No activity recorded from \(from.formatted()) to \(to.formatted())." }
        let peak = buckets.max { $0.count < $1.count }
        var out = "From \(from.formatted(date: .abbreviated, time: .shortened)) to \(to.formatted(date: .abbreviated, time: .shortened)): \(total) frames across \(buckets.count) intervals."
        if let peak { out += "\nActivity peak around \(peak.ts.formatted(date: .omitted, time: .shortened)) (\(peak.count))." }
        return out
    }

    private static func formatStatus(db: ZBSEyeDatabase?) async -> String {
        guard let db else { return "The DB is unavailable." }
        let counts = try? await db.pool.read { db -> (Int, Int, Int, Int64?, Int64?) in
            func c(_ t: String) -> Int { (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(t)")) ?? 0 }
            let oldest = try? Int64.fetchOne(db, sql: "SELECT MIN(ts) FROM screen_captures")
            let newest = try? Int64.fetchOne(db, sql: "SELECT MAX(ts) FROM screen_captures")
            return (c("screen_captures"), c("text_blocks"), c("audio_captures"), oldest ?? nil, newest ?? nil)
        }
        let cap = await mainInstanceCapturing()
        guard let (frames, texts, audio, oldest, newest) = counts else { return "DB read error." }
        var out = "ZBS Eye: \(frames) frames, \(texts) text blocks, \(audio) audio."
        if let o = oldest, let n = newest {
            out += "\nHistory: \(dateFromMs(o).formatted()) — \(dateFromMs(n).formatted())."
        }
        out += "\nRecording: \(cap.map { $0 ? "on" : "paused" } ?? "GUI not running")."
        return out
    }

    // MARK: proxying to the GUI instance

    private static func readPort() -> Int? {
        guard let s = try? String(contentsOf: StorageLocation.portURL(), encoding: .utf8) else { return nil }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Verifies it's really ZBS Eye on the port (not someone else's reused port from a stale port file).
    private static func healthOK(port: Int) async -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health"),
              let (data, _) = try? await localSession.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["status"] as? String == "ok" else { return nil }
        return obj
    }

    private static func mainInstanceCapturing() async -> Bool? {
        guard let port = readPort(), let obj = await healthOK(port: port) else { return nil }
        return obj["capturing"] as? Bool
    }

    /// Diagnostics for the self-repair flow — an agent connected over MCP calls this to get live state,
    /// then reads the public source and fixes the app. Nothing egresses; it's the machine's own state.
    private static func formatDiagnostics(db: ZBSEyeDatabase?) async -> String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        var out = "ZBS Eye \(v) · \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        out += "Source: https://github.com/zbs-gg/eye — read README.md / AGENTS.md / BUILD.md, reproduce, "
        out += "fix (local-first, Swift 6 strict concurrency), rebuild with scripts/build-notarized.sh.\n"
        if let db {
            let info = try? await db.pool.read { d -> (String, Int, Int, Int, Int, Int) in
                func c(_ t: String) -> Int { (try? Int.fetchOne(d, sql: "SELECT COUNT(*) FROM \(t)")) ?? 0 }
                // ORDER BY rowid = application order (ORDER BY identifier sorts v10 before v2 once two-digit
                // migrations exist, misreporting the schema sequence to an agent).
                let migs = (try? String.fetchAll(d, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")) ?? []
                return (migs.joined(separator: ", "), c("screen_captures"), c("text_blocks"),
                        c("audio_captures"), c("transcriptions"), c("browser_visits"))
            }
            if let (migs, frames, texts, audio, tr, bv) = info {
                out += "DB migrations: \(migs)\n"
                out += "Counts: frames=\(frames) text=\(texts) audio=\(audio) transcripts=\(tr) browser_visits=\(bv)\n"
            } else { out += "DB read error.\n" }
        } else { out += "DB unavailable (run the GUI to initialize it).\n" }
        let cap = await mainInstanceCapturing()
        out += "Recording: \(cap.map { $0 ? "on" : "paused" } ?? "GUI not running")."
        return out
    }

    private static func proxyToggle(enable: Bool?) async -> Bool? {
        // Verify identity (this is ZBS Eye) BEFORE sending the token — protection from a stale/reused port.
        guard let port = readPort(), await healthOK(port: port) != nil else { return nil }
        var comps = URLComponents(string: "http://127.0.0.1:\(port)/v1/capture/toggle")!
        if let enable { comps.queryItems = [URLQueryItem(name: "enable", value: enable ? "true" : "false")] }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(KeychainStore.apiToken())", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await localSession.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["capturing"] as? Bool
    }

    private static func parseTime(_ s: String) -> Date? {
        ZBSEyeHTTPServer.parseTimeParam(s)
    }

    /// Frame HEIC → downscale ≤1280px → JPEG (vision LLMs don't decode HEIC; full Retina is a token hog).
    /// Traversal-safe: path from DB + explicit checks, media-directory boundary.
    private static func loadFrameJPEG(relativePath rel: String, maxDim: CGFloat = 1280) -> Data? {
        guard !rel.contains(".."), !rel.hasPrefix("/") else { return nil }
        let base = StorageLocation.mediaDirectory()       // accounts for relocate
            .standardizedFileURL.resolvingSymlinksInPath()
        let target = base.appendingPathComponent(rel).standardizedFileURL.resolvingSymlinksInPath()
        guard Array(target.pathComponents.prefix(base.pathComponents.count)) == base.pathComponents,
              let data = try? Data(contentsOf: target),
              let ci = CIImage(data: data) else { return nil }
        let scale = min(1.0, maxDim / max(ci.extent.width, ci.extent.height))
        let scaled = scale < 1 ? ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ci
        return CIContext().jpegRepresentation(of: scaled, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                              options: [:])
    }

    /// MCP time Value: a string or a number (epoch-ms) — agents send both.
    private static func timeString(_ v: Value) -> String? {
        if let s = v.stringValue { return s }
        if let i = v.intValue { return String(i) }
        if let d = v.doubleValue { return String(Int64(d)) }
        return nil
    }
}
