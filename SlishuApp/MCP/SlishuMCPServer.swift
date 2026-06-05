import Foundation
import MCP
import GRDB

/// MCP stdio-сервер (`Slishu --mcp`). Инструменты поверх готовых сервисов: поиск/таймлайн читают БД
/// напрямую (WAL допускает параллельное чтение с пишущим GUI-инстансом); toggle/status проксируются
/// в запущенный GUI-инстанс через локальный REST (порт из port-файла, токен из Keychain).
enum SlishuMCPServer {

    static func runStdio() async {
        // БД на чтение (миграция на уже-мигрированной — no-op; WAL допускает параллель с GUI).
        let search: SearchService?
        let timeline: TimelineService?
        let db: SlishuDatabase?
        if let d = try? SlishuDatabase(path: SlishuDatabase.defaultURL().path) {
            db = d; search = SearchService(db: d); timeline = TimelineService(db: d)
        } else {
            db = nil; search = nil; timeline = nil
        }

        let server = Server(
            name: "slishu",
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
                    return .init(content: [.text("Нет запроса или БД недоступна.")], isError: true)
                }
                let results = (try? await search.search(query: q, limit: 25)) ?? []
                return .init(content: [.text(Self.formatResults(q, results))])

            case "get_context_at":
                let timeStr = args["time"]?.stringValue ?? ""
                guard let timeline, let date = Self.parseTime(timeStr) else {
                    return .init(content: [.text("Нужен параметр time (ISO8601 или epoch-ms).")], isError: true)
                }
                let frame = try? await timeline.frameAt(date)
                return .init(content: [.text(Self.formatFrame(frame))])

            case "get_status":
                return .init(content: [.text(await Self.formatStatus(db: db))])

            case "toggle_recording":
                let enable = args["enable"]?.boolValue
                if let now = await Self.proxyToggle(enable: enable) {
                    return .init(content: [.text("Запись \(now ? "включена" : "выключена").")])
                }
                return .init(content: [.text("GUI-инстанс Slishu не запущен — нечем управлять записью.")], isError: true)

            default:
                return .init(content: [.text("Неизвестный инструмент: \(params.name)")], isError: true)
            }
        }

        let transport = StdioTransport()
        do {
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
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
                 description: "Полнотекстовый поиск по истории экрана и аудио пользователя (что он видел/делал).",
                 inputSchema: .object(["type": .string("object"),
                                       "properties": .object(["query": strProp("поисковый запрос")]),
                                       "required": .array([.string("query")])])),
            Tool(name: "get_context_at",
                 description: "Что было на экране в указанный момент: приложение, окно, URL, текст.",
                 inputSchema: .object(["type": .string("object"),
                                       "properties": .object(["time": strProp("ISO8601 или epoch-ms")]),
                                       "required": .array([.string("time")])])),
            Tool(name: "get_status",
                 description: "Статус Slishu: число кадров/текстов/аудио, диапазон истории, идёт ли запись.",
                 inputSchema: .object(["type": .string("object"), "properties": .object([:])])),
            Tool(name: "toggle_recording",
                 description: "Включить/выключить запись в запущенном GUI-инстансе Slishu.",
                 inputSchema: .object(["type": .string("object"),
                                       "properties": .object(["enable": .object(["type": .string("boolean")])])])),
        ]
    }

    // MARK: форматирование

    private static func formatResults(_ q: String, _ results: [SearchResult]) -> String {
        guard !results.isEmpty else { return "По запросу «\(q)» ничего не найдено." }
        var out = "Найдено \(results.count) по «\(q)»:\n"
        for r in results.prefix(25) {
            let app = r.appName ?? r.bundleId ?? "—"
            let when = r.ts.formatted(date: .abbreviated, time: .shortened)
            let snip = r.snippet.replacingOccurrences(of: "\n", with: " ")
            out += "\n• [\(when)] \(app)\(r.windowTitle.map { " · \($0)" } ?? ""): \(snip)"
        }
        return out
    }

    private static func formatFrame(_ f: FrameDetail?) -> String {
        guard let f else { return "Кадра на этот момент нет." }
        let app = f.appName ?? f.bundleId ?? "—"
        var out = "В \(f.ts.formatted(date: .abbreviated, time: .standard)) — \(app)"
        if let w = f.windowTitle { out += " · \(w)" }
        if let u = f.browserURL { out += "\nURL: \(u)" }
        out += "\n\n\(f.text.isEmpty ? "(текст не извлечён)" : f.text)"
        return out
    }

    private static func formatStatus(db: SlishuDatabase?) async -> String {
        guard let db else { return "БД недоступна." }
        let counts = try? await db.pool.read { db -> (Int, Int, Int, Int64?, Int64?) in
            func c(_ t: String) -> Int { (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(t)")) ?? 0 }
            let oldest = try? Int64.fetchOne(db, sql: "SELECT MIN(ts) FROM screen_captures")
            let newest = try? Int64.fetchOne(db, sql: "SELECT MAX(ts) FROM screen_captures")
            return (c("screen_captures"), c("text_blocks"), c("audio_captures"), oldest ?? nil, newest ?? nil)
        }
        let cap = await mainInstanceCapturing()
        guard let (frames, texts, audio, oldest, newest) = counts else { return "Ошибка чтения БД." }
        var out = "Slishu: кадров \(frames), текст-блоков \(texts), аудио \(audio)."
        if let o = oldest, let n = newest {
            out += "\nИстория: \(dateFromMs(o).formatted()) — \(dateFromMs(n).formatted())."
        }
        out += "\nЗапись: \(cap.map { $0 ? "идёт" : "на паузе" } ?? "GUI не запущен")."
        return out
    }

    // MARK: проксирование в GUI-инстанс

    private static func readPort() -> Int? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: false)
            .appendingPathComponent("Slishu/port"),
              let s = try? String(contentsOf: dir, encoding: .utf8) else { return nil }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func mainInstanceCapturing() async -> Bool? {
        guard let port = readPort(),
              let url = URL(string: "http://127.0.0.1:\(port)/health"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["capturing"] as? Bool
    }

    private static func proxyToggle(enable: Bool?) async -> Bool? {
        guard let port = readPort() else { return nil }
        var comps = URLComponents(string: "http://127.0.0.1:\(port)/v1/capture/toggle")!
        if let enable { comps.queryItems = [URLQueryItem(name: "enable", value: enable ? "true" : "false")] }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(KeychainStore.apiToken())", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["capturing"] as? Bool
    }

    private static func parseTime(_ s: String) -> Date? {
        if let ms = Int64(s) { return dateFromMs(ms) }
        return ISO8601DateFormatter().date(from: s)
    }
}
