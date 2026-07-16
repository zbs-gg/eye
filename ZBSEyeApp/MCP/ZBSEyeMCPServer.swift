import Foundation
import MCP
import GRDB
import CoreImage

private final class MCPLoopbackSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// MCP stdio server (`ZBS Eye --mcp`). The default profile is read-only;
/// screenshot bytes and recording control require the explicit `--mcp-full`
/// profile. The data root is pinned for the process lifetime so relocation can
/// never split one helper across old and new stores.
enum ZBSEyeMCPServer {

    /// Short timeout for localhost calls to the GUI instance (otherwise URLSession.shared waits 7 days).
    private static let localSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 5
        return URLSession(
            configuration: cfg,
            delegate: MCPLoopbackSessionDelegate(),
            delegateQueue: nil
        )
    }()

    static func runStdio(profile: MCPAccessProfile, dataRoot: URL) async {
        // DB for READING, WITHOUT migrations (the GUI owns the schema; we don't take a write lock).
        let search: SearchService?
        let timeline: TimelineService?
        let db: ZBSEyeDatabase?
        do {
            let d = try ZBSEyeDatabase(
                path: StorageLocation.databaseURL(under: dataRoot).path,
                runMigrations: false,
                access: .readOnly
            )
            db = d
            // This is a second process and cannot share the GUI's compute
            // actor. Loading another e5 here could overlap GUI MLX, so helper
            // search is explicitly FTS-only and discloses that in its result.
            search = SearchService(
                db: d,
                embedder: EmbeddingService(),
                semanticPolicy: .ftsOnly(.secondaryProcess)
            )
            timeline = TimelineService(db: d)
        } catch {
            FileHandle.standardError.write("[mcp] db_open_failed\n".data(using: .utf8)!)
            db = nil; search = nil; timeline = nil
        }

        let historySearch = MCPHistorySearchCoordinator(
            guiSearch: { query, filters in
                try await Self.proxyHistorySearch(
                    query: query,
                    filters: filters,
                    dataRoot: dataRoot
                )
            },
            fallbackSearch: { query, filters in
                guard let search else {
                    throw MCPHistorySearchRoutingError.fallbackUnavailable
                }
                return try await search.searchWithMetadata(query: query, filters: filters)
            }
        )
        let callEvidence = db.map {
            MCPCallEvidenceCoordinator(service: CallEvidenceQueryService(database: $0))
        }

        let server = Server(
            name: "zbseye",
            version: AppVersion.current,
            capabilities: .init(tools: .init(listChanged: false)))

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: Self.toolList(profile: profile))
        }

        await server.withMethodHandler(CallTool.self) { params in
            guard MCPToolPolicy.allows(params.name, profile: profile) else {
                return .init(
                    content: [.text("Tool unavailable in the current MCP access profile.")],
                    isError: true
                )
            }
            let args = params.arguments ?? [:]
            switch params.name {
            case "search_history":
                let q = args["query"]?.stringValue ?? ""
                guard !q.isEmpty else {
                    return .init(content: [.text("query is required.")], isError: true)
                }
                var kind: SearchKind? = nil
                if let k = args["kind"]?.stringValue {
                    guard let parsed = SearchKind(rawValue: k) else {
                        return .init(content: [.text("kind: screen | audio | call")], isError: true)
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
                    let resolution = try await historySearch.search(query: q, filters: filters)
                    return .init(content: [
                        .text(Self.formatResults(q, resolution.results, semanticMode: resolution.semanticMode))
                    ])
                } catch {
                    // honest error: the agent must distinguish "nothing found" from "DB broken"
                    return .init(content: [.text("Search failed (search_failed).")], isError: true)
                }

            case "list_calls":
                guard let callEvidence else {
                    return .init(content: [.text("Call evidence is unavailable.")], isError: true)
                }
                guard !MCPCallEvidenceCoordinator.requestsAlternateStorage(argumentKeys: Set(args.keys)) else {
                    return .init(content: [.text("Alternate database or storage roots are not accepted.")], isError: true)
                }
                guard let pagination = Self.callPagination(args, defaultLimit: 25) else {
                    return .init(content: [.text("limit must be 1...100 and offset must be >= 0")], isError: true)
                }
                let fromMs: Int64?
                if let value = args["from"] {
                    guard let raw = Self.timeString(value), let date = Self.parseTime(raw) else {
                        return .init(content: [.text("from failed to parse: needs ISO8601 or epoch-ms")], isError: true)
                    }
                    fromMs = msFromDate(date)
                } else {
                    fromMs = nil
                }
                let toMs: Int64?
                if let value = args["to"] {
                    guard let raw = Self.timeString(value), let date = Self.parseTime(raw) else {
                        return .init(content: [.text("to failed to parse: needs ISO8601 or epoch-ms")], isError: true)
                    }
                    toMs = msFromDate(date)
                } else {
                    toMs = nil
                }
                do {
                    let page = try await callEvidence.listCalls(
                        query: args["query"]?.stringValue,
                        fromMs: fromMs,
                        toMs: toMs,
                        limit: pagination.limit,
                        offset: pagination.offset
                    )
                    return .init(content: [.text(try MCPCallEvidenceCoordinator.json(page))])
                } catch {
                    return .init(content: [.text("Invalid or unavailable call evidence request.")], isError: true)
                }

            case "get_call":
                guard let callEvidence else {
                    return .init(content: [.text("Call evidence is unavailable.")], isError: true)
                }
                guard !MCPCallEvidenceCoordinator.requestsAlternateStorage(argumentKeys: Set(args.keys)),
                      let callID = args["call_id"]?.stringValue else {
                    return .init(content: [.text("Typed call_id required; alternate roots are not accepted.")], isError: true)
                }
                do {
                    guard let envelope = try await callEvidence.envelope(callID: callID) else {
                        return .init(content: [.text("Call not found.")], isError: true)
                    }
                    return .init(content: [.text(try MCPCallEvidenceCoordinator.json(envelope))])
                } catch {
                    return .init(content: [.text("Invalid or unavailable call evidence request.")], isError: true)
                }

            case "list_call_bookmarks":
                guard let callEvidence else {
                    return .init(content: [.text("Call evidence is unavailable.")], isError: true)
                }
                guard !MCPCallEvidenceCoordinator.requestsAlternateStorage(argumentKeys: Set(args.keys)),
                      let callID = args["call_id"]?.stringValue else {
                    return .init(content: [.text("Typed call_id required; alternate roots are not accepted.")], isError: true)
                }
                guard let pagination = Self.callPagination(args, defaultLimit: 50) else {
                    return .init(content: [.text("limit must be 1...100 and offset must be >= 0")], isError: true)
                }
                do {
                    let page = try await callEvidence.bookmarks(
                        callID: callID,
                        limit: pagination.limit,
                        offset: pagination.offset
                    )
                    return .init(content: [.text(try MCPCallEvidenceCoordinator.json(page))])
                } catch {
                    return .init(content: [.text("Invalid or unavailable call evidence request.")], isError: true)
                }

            case "read_call_transcript":
                guard let callEvidence else {
                    return .init(content: [.text("Call evidence is unavailable.")], isError: true)
                }
                guard !MCPCallEvidenceCoordinator.requestsAlternateStorage(argumentKeys: Set(args.keys)),
                      let callID = args["call_id"]?.stringValue else {
                    return .init(content: [.text("Typed call_id required; alternate roots are not accepted.")], isError: true)
                }
                guard let pagination = Self.callPagination(args, defaultLimit: 80) else {
                    return .init(content: [.text("limit must be 1...100 and offset must be >= 0")], isError: true)
                }
                do {
                    let page = try await callEvidence.transcript(
                        callID: callID,
                        selector: args["selector"]?.stringValue ?? "preferred",
                        bookmarkID: args["bookmark_id"]?.stringValue,
                        limit: pagination.limit,
                        offset: pagination.offset
                    )
                    return .init(content: [.text(try MCPCallEvidenceCoordinator.json(page))])
                } catch {
                    return .init(content: [.text("Invalid or unavailable call evidence request.")], isError: true)
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
                    return .init(content: [.text("DB read failed (db_read_failed).")], isError: true)
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
                guard let timeline else {
                    return .init(content: [.text("The DB is unavailable.")], isError: true)
                }
                guard let date = Self.parseTime(timeStr) else {
                    return .init(content: [.text("time parameter required (ISO8601 or epoch-ms).")], isError: true)
                }
                do {
                    let frame = try await timeline.frameAt(date)
                    return .init(content: [.text(Self.formatFrame(frame))])
                } catch {
                    return .init(content: [.text("DB read failed: \(error)")], isError: true)
                }

            case "get_timeline":
                guard let timeline else {
                    return .init(content: [.text("The DB is unavailable.")], isError: true)
                }
                guard let from = Self.parseTime(args["from"]?.stringValue ?? ""),
                      let to = Self.parseTime(args["to"]?.stringValue ?? "") else {
                    return .init(content: [.text("from and to required (ISO8601 or epoch-ms).")], isError: true)
                }
                do {
                    let buckets = try await timeline.density(from: from, to: to, bucketMs: 300_000)
                    return .init(content: [.text(Self.formatTimeline(from, to, buckets))])
                } catch {
                    return .init(content: [.text("DB read failed: \(error)")], isError: true)
                }

            case "get_frame_image":
                guard let timeline else {
                    return .init(content: [.text("The DB is unavailable.")], isError: true)
                }
                guard let id = args["frame_id"]?.intValue
                        ?? args["frame_id"]?.stringValue.flatMap({ Int($0) }) else {
                    return .init(content: [.text("frame_id required (from the search results).")], isError: true)
                }
                let detail: FrameDetail?
                do { detail = try await timeline.frameDetail(id: Int64(id)) }
                catch {
                    return .init(content: [.text("DB read failed: \(error)")], isError: true)
                }
                guard let d = detail, let rel = d.relativePath else {
                    return .init(content: [.text("Frame #\(id) not found or has no image (context-only).")], isError: true)
                }
                guard let jpeg = Self.loadFrameJPEG(relativePath: rel, dataRoot: dataRoot) else {
                    return .init(content: [.text("Frame file #\(id) is not readable (may have been removed by retention).")], isError: true)
                }
                return .init(content: [
                    .text("Frame #\(d.id) [\(d.ts.formatted(date: .abbreviated, time: .standard))] \(d.appName ?? "—")\(d.windowTitle.map { " · \($0)" } ?? "")"),
                    .image(data: jpeg.base64EncodedString(), mimeType: "image/jpeg", metadata: nil),
                ])

            case "get_status":
                do {
                    return .init(content: [
                        .text(try await Self.formatStatus(db: db, dataRoot: dataRoot))
                    ])
                } catch {
                    return .init(content: [.text("Status failed: \(error)")], isError: true)
                }

            case "get_diagnostics":
                do {
                    return .init(content: [
                        .text(try await Self.formatDiagnostics(db: db, dataRoot: dataRoot))
                    ])
                } catch {
                    return .init(content: [.text("Diagnostics failed: \(error)")], isError: true)
                }

            case "toggle_recording":
                let enable = args["enable"]?.boolValue
                do {
                    let now = try await Self.proxyToggle(enable: enable, dataRoot: dataRoot)
                    return .init(content: [.text("Recording \(now ? "on" : "off").")])
                } catch {
                    return .init(content: [.text("Recording control failed: \(error)")], isError: true)
                }

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
            FileHandle.standardError.write("[mcp] start_failed\n".data(using: .utf8)!)
        }
    }

    // MARK: tools

    private static func toolList(profile: MCPAccessProfile) -> [Tool] {
        func strProp(_ desc: String) -> Value {
            .object(["type": .string("string"), "description": .string(desc)])
        }
        let tools = [
            Tool(name: "search_history",
                 description: "Hybrid search over the user's screen, audio, and preferred call transcript history, including cross-language matches. Uses the running GUI's semantic search, with an exact-word FTS fallback when the GUI is absent.",
                 inputSchema: .object(["type": .string("object"),
                                       "properties": .object([
                                           "query": strProp("search query"),
                                           "from": strProp("optional: range start, ISO8601 or epoch-ms"),
                                           "to": strProp("optional: range end, ISO8601 or epoch-ms"),
                                           "app": strProp("optional: substring of bundleId/app name (screen only)"),
                                           "kind": strProp("optional: screen | audio | call"),
                                           "limit": .object(["type": .string("integer"),
                                                             "description": .string("max results (default 25)")]),
                                       ]),
                                       "required": .array([.string("query")])])),
            Tool(name: "list_calls",
                 description: "Read-only paginated list or exact-word search of Call Envelopes. Stdio access is the capability of the configured owner-launched ZBS Eye binary; no alternate database/root is accepted.",
                 inputSchema: .object(["type": .string("object"),
                                       "additionalProperties": .bool(false),
                                       "properties": .object([
                                           "query": strProp("optional transcript query"),
                                           "from": strProp("optional range start, ISO8601 or epoch-ms"),
                                           "to": strProp("optional range end, ISO8601 or epoch-ms"),
                                           "limit": .object(["type": .string("integer"), "maximum": .int(100)]),
                                           "offset": .object(["type": .string("integer"), "minimum": .int(0)]),
                                       ])])),
            Tool(name: "get_call",
                 description: "Read one Call Envelope: source health, logical coverage, transcript status, bookmarks count, and typed evidence references.",
                 inputSchema: .object(["type": .string("object"),
                                       "additionalProperties": .bool(false),
                                       "properties": .object(["call_id": strProp("typed id such as call:42")]),
                                       "required": .array([.string("call_id")])])),
            Tool(name: "list_call_bookmarks",
                 description: "Read-only paginated bookmark evidence for one Call Envelope.",
                 inputSchema: .object(["type": .string("object"),
                                       "additionalProperties": .bool(false),
                                       "properties": .object([
                                           "call_id": strProp("typed id such as call:42"),
                                           "limit": .object(["type": .string("integer"), "maximum": .int(100)]),
                                           "offset": .object(["type": .string("integer"), "minimum": .int(0)]),
                                       ]),
                                       "required": .array([.string("call_id")])])),
            Tool(name: "read_call_transcript",
                 description: "Read-only paginated timed transcript segments from the preferred call revision or one bookmark checkpoint. Source labels are mic/system evidence, not inferred speaker identity.",
                 inputSchema: .object(["type": .string("object"),
                                       "additionalProperties": .bool(false),
                                       "properties": .object([
                                           "call_id": strProp("typed id such as call:42"),
                                           "selector": strProp("preferred | bookmark"),
                                           "bookmark_id": strProp("required for selector=bookmark; typed id such as bookmark:7"),
                                           "limit": .object(["type": .string("integer"), "maximum": .int(100)]),
                                           "offset": .object(["type": .string("integer"), "minimum": .int(0)]),
                                       ]),
                                       "required": .array([.string("call_id")])])),
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
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        return MCPToolPolicy.toolNames(for: profile).compactMap { byName[$0] }
    }

    // MARK: formatting

    private static func formatResults(
        _ q: String,
        _ results: [SearchResult],
        semanticMode: SearchSemanticMode
    ) -> String {
        let disclosure = switch semanticMode {
        case .ftsOnly(.secondaryProcess):
            "FTS-only helper search (semantic search stays in the GUI process).\n"
        case .ftsOnly, .embeddingUnavailable:
            "FTS-only search.\n"
        case .hybrid:
            ""
        }
        guard !results.isEmpty else {
            return disclosure + "Nothing found for \"\(q)\"."
        }
        var out = disclosure + "Found \(results.count) for \"\(q)\":\n"
        for r in results {
            let app = r.appName ?? r.bundleId ?? "—"
            let when = r.ts.formatted(date: .abbreviated, time: .shortened)
            let snip = r.snippet.replacingOccurrences(of: "\n", with: " ")
            // id in the response: the agent can reference a specific frame/audio in a follow-up
            let ref = switch r.kind {
            case .screen: "frame_id=\(r.id)"
            case .audio: "audio_id=\(r.id)"
            case .call: "call_id=call:\(r.id)"
            }
            out += "\n• [\(when)] \(app)\(r.windowTitle.map { " · \($0)" } ?? "") (\(ref)): \(snip)"
        }
        if !results.isEmpty {
            out += "\n\nFor a call: get_call(call_id), then read_call_transcript(call_id). For audio: get_transcript(audio_id). For a screen moment: get_context_at(time)."
        }
        return out
    }

    private static func formatFrame(_ f: FrameDetail?) -> String {
        guard let f else { return "There is no frame for this moment." }
        let app = f.appName ?? f.bundleId ?? "—"
        var out = "Frame #\(f.id) at \(f.ts.formatted(date: .abbreviated, time: .standard)) — \(app)"
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

    private static func formatStatus(db: ZBSEyeDatabase?, dataRoot: URL) async throws -> String {
        guard let db else { throw MCPHistorySearchRoutingError.fallbackUnavailable }
        let counts = try await db.pool.read { db -> (Int, Int, Int, Int64?, Int64?) in
            func count(_ table: String) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            let oldest = try Int64.fetchOne(db, sql: "SELECT MIN(ts) FROM screen_captures")
            let newest = try Int64.fetchOne(db, sql: "SELECT MAX(ts) FROM screen_captures")
            return (
                try count("screen_captures"),
                try count("text_blocks"),
                try count("audio_captures"),
                oldest,
                newest
            )
        }
        let recording = await mainInstanceCaptureStatus(dataRoot: dataRoot)
        let (frames, texts, audio, oldest, newest) = counts
        var out = "ZBS Eye: \(frames) frames, \(texts) text blocks, \(audio) audio."
        if let o = oldest, let n = newest {
            out += "\nHistory: \(dateFromMs(o).formatted()) — \(dateFromMs(n).formatted())."
        }
        out += "\nRecording: \(recording.description)."
        return out
    }

    // MARK: proxying to the GUI instance

    private static func readPort(dataRoot: URL) -> Int? {
        guard let s = try? String(
            contentsOf: StorageLocation.portURL(under: dataRoot),
            encoding: .utf8
        ) else { return nil }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Proves the peer knows the Keychain token without sending that token to
    /// a port that may have been recycled after a stale port file.
    private static func authenticatedHealth(port: Int, token: String) async -> [String: Any]? {
        let challenge = LocalPeerAuthenticator.makeChallenge()
        var components = URLComponents(string: "http://127.0.0.1:\(port)/health")!
        components.queryItems = [URLQueryItem(name: "challenge", value: challenge)]
        guard let url = components.url,
              let (data, response) = try? await localSession.data(from: url),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              http.url == url,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["status"] as? String == "ok",
              let proof = obj["proof"] as? String,
              LocalPeerAuthenticator.verify(
                proof: proof,
                token: token,
                challenge: challenge,
                listeningPort: port
              ) else { return nil }
        return obj
    }

    private enum MainInstanceCaptureStatus {
        case capturing(Bool)
        case guiUnavailable
        case authenticationUnavailable

        var description: String {
            switch self {
            case .capturing(true): "on"
            case .capturing(false): "paused"
            case .guiUnavailable: "GUI not running"
            case .authenticationUnavailable:
                "unknown (local authentication unavailable)"
            }
        }
    }

    private static func mainInstanceCaptureStatus(
        dataRoot: URL
    ) async -> MainInstanceCaptureStatus {
        guard let token = KeychainStore.get("api-token"), !token.isEmpty else {
            return .authenticationUnavailable
        }
        guard let port = readPort(dataRoot: dataRoot) else { return .guiUnavailable }
        guard let object = await authenticatedHealth(port: port, token: token),
              let capturing = object["capturing"] as? Bool else {
            return .authenticationUnavailable
        }
        return .capturing(capturing)
    }

    private static func proxyHistorySearch(
        query: String,
        filters: SearchFilters,
        dataRoot: URL
    ) async throws -> SearchExecution? {
        // Verify identity before sending the bearer token. Missing local auth,
        // a missing GUI, or a stale port all keep stdio useful through the
        // read-only direct-DB fallback.
        guard let token = KeychainStore.get("api-token"),
              let port = readPort(dataRoot: dataRoot),
              await authenticatedHealth(port: port, token: token) != nil else { return nil }
        let client = MCPGUIHistorySearchClient { request in
            let (data, response) = try await localSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MCPHistorySearchRoutingError.invalidHTTPResponse
            }
            return MCPGUIHistorySearchHTTPResponse(statusCode: http.statusCode, data: data)
        }
        do {
            return try await client.search(
                port: port,
                token: token,
                query: query,
                filters: filters
            )
        } catch let error as URLError {
            guard await authenticatedHealth(port: port, token: token) == nil else {
                throw error
            }
            return nil
        }
    }

    /// Diagnostics for the self-repair flow — an agent connected over MCP calls this to get live state,
    /// then reads the public source and fixes the app. Nothing egresses; it's the machine's own state.
    private static func formatDiagnostics(db: ZBSEyeDatabase?, dataRoot: URL) async throws -> String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        var out = "ZBS Eye \(v) · \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        out += "Source: https://github.com/zbs-gg/eye — read README.md / AGENTS.md / BUILD.md, reproduce, "
        out += "fix (local-first, Swift 6 strict concurrency), rebuild with scripts/build-notarized.sh.\n"
        if let db {
            let info = try await db.pool.read { d -> (String, Int, Int, Int, Int, Int) in
                func count(_ table: String) throws -> Int {
                    try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
                }
                // ORDER BY rowid = application order (ORDER BY identifier sorts v10 before v2 once two-digit
                // migrations exist, misreporting the schema sequence to an agent).
                let migrations = try String.fetchAll(
                    d,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
                )
                return (
                    migrations.joined(separator: ", "),
                    try count("screen_captures"),
                    try count("text_blocks"),
                    try count("audio_captures"),
                    try count("transcriptions"),
                    try count("browser_visits")
                )
            }
            let (migrations, frames, texts, audio, transcriptions, browserVisits) = info
            out += "DB migrations: \(migrations)\n"
            out += "Counts: frames=\(frames) text=\(texts) audio=\(audio) transcripts=\(transcriptions) browser_visits=\(browserVisits)\n"
        } else {
            throw MCPHistorySearchRoutingError.fallbackUnavailable
        }
        let recording = await mainInstanceCaptureStatus(dataRoot: dataRoot)
        out += "Recording: \(recording.description)."
        return out
    }

    private enum RecordingControlError: LocalizedError {
        case authenticationUnavailable
        case guiUnavailable
        case peerAuthenticationFailed
        case requestFailed

        var errorDescription: String? {
            switch self {
            case .authenticationUnavailable:
                "local authentication is unavailable"
            case .guiUnavailable:
                "the ZBS Eye GUI is not running"
            case .peerAuthenticationFailed:
                "the local GUI could not be authenticated"
            case .requestFailed:
                "the local GUI rejected the request"
            }
        }
    }

    private static func proxyToggle(enable: Bool?, dataRoot: URL) async throws -> Bool {
        // Verify identity (this is ZBS Eye) BEFORE sending the token — protection from a stale/reused port.
        guard let token = KeychainStore.get("api-token"), !token.isEmpty else {
            throw RecordingControlError.authenticationUnavailable
        }
        guard let port = readPort(dataRoot: dataRoot) else {
            throw RecordingControlError.guiUnavailable
        }
        guard await authenticatedHealth(port: port, token: token) != nil else {
            throw RecordingControlError.peerAuthenticationFailed
        }
        var comps = URLComponents(string: "http://127.0.0.1:\(port)/v1/capture/toggle")!
        if let enable { comps.queryItems = [URLQueryItem(name: "enable", value: enable ? "true" : "false")] }
        guard let url = comps.url else { throw RecordingControlError.requestFailed }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await localSession.data(for: req),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let capturing = object["capturing"] as? Bool else {
            throw RecordingControlError.requestFailed
        }
        return capturing
    }

    private static func parseTime(_ s: String) -> Date? {
        ZBSEyeHTTPServer.parseTimeParam(s)
    }

    /// Frame HEIC → downscale ≤1280px → JPEG (vision LLMs don't decode HEIC; full Retina is a token hog).
    /// Traversal-safe: path from DB + explicit checks, media-directory boundary.
    private static func loadFrameJPEG(
        relativePath rel: String,
        dataRoot: URL,
        maxDim: CGFloat = 1280
    ) -> Data? {
        guard !rel.contains(".."), !rel.hasPrefix("/") else { return nil }
        let base = StorageLocation.mediaDirectory(under: dataRoot)
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

    private static func callPagination(
        _ arguments: [String: Value],
        defaultLimit: Int
    ) -> CallEvidencePageRequest? {
        let limit: Int
        if let value = arguments["limit"] {
            guard let parsed = value.intValue ?? value.stringValue.flatMap(Int.init) else { return nil }
            limit = parsed
        } else {
            limit = defaultLimit
        }
        let offset: Int
        if let value = arguments["offset"] {
            guard let parsed = value.intValue ?? value.stringValue.flatMap(Int.init) else { return nil }
            offset = parsed
        } else {
            offset = 0
        }
        return try? CallEvidencePageRequest(limit: limit, offset: offset)
    }

}
