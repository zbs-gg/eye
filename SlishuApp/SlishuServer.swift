import Foundation
import FlyingFox
import GRDB

public final class SlishuServer {
    public static let shared = SlishuServer()
    
    private var server: HTTPServer?
    private var activePort: UInt16 = 8080
    private let queue = DispatchQueue(label: "com.slishu.server.queue", qos: .userInitiated)
    
    public var currentPort: UInt16 {
        queue.sync { activePort }
    }
    
    private init() {}
    
    public func start() {
        queue.async { [weak self] in
            guard let self = self, self.server == nil else { return }
            self.startServerSearchingPorts(startingFrom: 8080)
        }
    }
    
    private func startServerSearchingPorts(startingFrom startPort: UInt16) {
        var currentAttemptPort = startPort
        let maxPort: UInt16 = 8100
        
        func tryNextPort() {
            guard currentAttemptPort <= maxPort else {
                print("❌ Не удалось запустить HTTP сервер ни на одном порту в диапазоне \(startPort)-\(maxPort).")
                return
            }
            
            let portToTry = currentAttemptPort
            let server = HTTPServer(port: portToTry)
            
            Task {
                do {
                    // Настройка обработчиков маршрутов (Routing) с использованием замыканий
                    await server.appendRoute("GET /status") { request in
                        try await self.handleStatus(request)
                    }
                    await server.appendRoute("POST /settings/storage") { request in
                        try await self.handleSetStorage(request)
                    }
                    await server.appendRoute("GET /search") { request in
                        try await self.handleSearch(request)
                    }
                    await server.appendRoute("GET /media/*") { request in
                        try await self.handleMedia(request)
                    }
                    await server.appendRoute("POST /capture/toggle") { request in
                        try await self.handleToggleCapture(request)
                    }
                    await server.appendRoute("POST /mcp") { request in
                        try await self.handleMCPRPC(request)
                    }
                    
                    // Попытка запуска. Если порт занят, FlyingFox выбросит ошибку бинда сразу же
                    self.queue.async {
                        self.server = server
                        self.activePort = portToTry
                    }
                    
                    print("🚀 Попытка запуска Локального REST API Slishu на http://localhost:\(portToTry)")
                    try await server.start()
                } catch {
                    print("⚠️ Ошибка запуска сервера на порту \(portToTry): \(error)")
                    
                    // Сбрасываем ссылку на сервер, чтобы предотвратить некорректное состояние
                    self.queue.async {
                        if self.activePort == portToTry {
                            self.server = nil
                        }
                    }
                    
                    // Пробуем следующий порт
                    currentAttemptPort += 1
                    tryNextPort()
                }
            }
        }
        
        tryNextPort()
    }
    
    public func stop() {
        queue.async { [weak self] in
            guard let self = self, self.server != nil else { return }
            self.server = nil
            print("🚀 REST API Slishu остановлен")
        }
    }
    
    // MARK: - Обработчики API эндпоинтов (REST API Handlers)
    
    // 1. GET /status - Текущее состояние и статистика
    private func handleStatus(_ request: HTTPRequest) async throws -> HTTPResponse {
        let db = SlishuDatabase.shared
        let dbPool = db.getDatabasePool()
        
        let (screenCount, audioCount, appsCount) = await (try? dbPool.read { dbReader in
            let sCount = try SlishuScreenCapture.fetchCount(dbReader)
            let aCount = try SlishuAudioCapture.fetchCount(dbReader)
            let apCount = try SlishuAppModel.fetchCount(dbReader)
            return (sCount, aCount, apCount)
        }) ?? (0, 0, 0)
        
        let customPath = UserDefaults.standard.string(forKey: "SlishuCustomStoragePath") ?? "default"
        
        let bodyObj: [String: Any] = [
            "status": "online",
            "isCapturing": SlishuCapture.shared.isCapturing,
            "storageMode": customPath == "default" ? "default" : "custom",
            "mediaDirectory": db.mediaDirectory.path,
            "stats": [
                "screenFrames": screenCount,
                "audioChunks": audioCount,
                "recordedApps": appsCount
            ]
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: bodyObj, options: [.prettyPrinted, .sortedKeys]) else {
            return HTTPResponse(statusCode: .internalServerError)
        }
        
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "application/json"],
            body: jsonData
        )
    }
    
    // 2. POST /settings/storage - Изменение директории хранения
    private func handleSetStorage(_ request: HTTPRequest) async throws -> HTTPResponse {
        let bodyData = try await request.bodyData
        guard let requestBody = try? JSONSerialization.jsonObject(with: bodyData) as? [String: String],
              let newPath = requestBody["path"] else {
            let errorBody = "{\"error\": \"Не передан обязательный параметр 'path'\"}".data(using: .utf8)!
            return HTTPResponse(statusCode: .badRequest, headers: [.contentType: "application/json"], body: errorBody)
        }
        
        do {
            try SlishuDatabase.shared.setCustomStorageDirectory(path: newPath)
            let successBody = "{\"status\": \"success\", \"message\": \"Директория успешно изменена на \(newPath)\"}".data(using: .utf8)!
            return HTTPResponse(statusCode: .ok, headers: [.contentType: "application/json"], body: successBody)
        } catch {
            let errorBody = "{\"error\": \"\(error.localizedDescription)\"}".data(using: .utf8)!
            return HTTPResponse(statusCode: .internalServerError, headers: [.contentType: "application/json"], body: errorBody)
        }
    }
    
    // 3. GET /search - Полнотекстовый поиск по экрану и аудио (FTS5 без дубликатов)
    private func handleSearch(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let queryComponents = URLComponents(string: request.path),
              let queryItem = queryComponents.queryItems?.first(where: { $0.name == "q" }),
              let query = queryItem.value, !query.isEmpty else {
            let errorBody = "{\"error\": \"Отсутствует поисковый запрос в параметре 'q'\"}".data(using: .utf8)!
            return HTTPResponse(statusCode: .badRequest, headers: [.contentType: "application/json"], body: errorBody)
        }
        
        let dbPool = SlishuDatabase.shared.getDatabasePool()
        
        let searchResults: [[String: Any]] = await (try? dbPool.read { dbReader in
            var results: [[String: Any]] = []
            
            // А. Поиск по тексту экрана через ocr_fts (прямая выборка без лишних JOIN оставляет ровно 1 ряд на кадр)
            let screenMatches = try Row.fetchAll(dbReader, sql: """
                SELECT c.id, c.timestamp, c.relativePath, a.name as appName, a.bundleIdentifier, f.text
                FROM ocr_fts f
                JOIN screen_captures c ON c.id = f.captureId
                JOIN apps a ON a.id = c.appId
                WHERE ocr_fts MATCH ?
                ORDER BY c.timestamp DESC LIMIT 50
            """, arguments: [query])
            
            for row in screenMatches {
                results.append([
                    "type": "screen",
                    "id": row["id"] ?? 0,
                    "timestamp": row["timestamp"] ?? "",
                    "appName": row["appName"] ?? "",
                    "bundleId": row["bundleIdentifier"] ?? "",
                    "mediaPath": row["relativePath"] ?? "",
                    "snippet": row["text"] ?? ""
                ])
            }
            
            // Б. Поиск по аудиозаписям через audio_fts
            let audioMatches = try Row.fetchAll(dbReader, sql: """
                SELECT ac.id, ac.timestamp, ac.relativePath, ac.durationSeconds, af.text
                FROM audio_fts af
                JOIN audio_captures ac ON ac.id = af.audioCaptureId
                WHERE audio_fts MATCH ?
                ORDER BY ac.timestamp DESC LIMIT 50
            """, arguments: [query])
            
            for row in audioMatches {
                results.append([
                    "type": "audio",
                    "id": row["id"] ?? 0,
                    "timestamp": row["timestamp"] ?? "",
                    "duration": row["durationSeconds"] ?? 0.0,
                    "mediaPath": row["relativePath"] ?? "",
                    "snippet": row["text"] ?? ""
                ])
            }
            
            return results
        }) ?? []
        
        // Сортируем общие результаты по времени
        let sortedResults = searchResults.sorted { a, b in
            let dateA = (a["timestamp"] as? String) ?? ""
            let dateB = (b["timestamp"] as? String) ?? ""
            return dateA > dateB
        }
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: sortedResults, options: [.prettyPrinted]) else {
            return HTTPResponse(statusCode: .internalServerError)
        }
        
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "application/json"],
            body: jsonData
        )
    }
    
    // 4. GET /media/* - Отдача картинок экрана и аудиофайлов с защитой от Directory Traversal
    private func handleMedia(_ request: HTTPRequest) async throws -> HTTPResponse {
        let pathComponents = request.path.components(separatedBy: "/")
        guard let filename = pathComponents.last, !filename.isEmpty else {
            return HTTPResponse(statusCode: .notFound)
        }
        
        let mediaDir = SlishuDatabase.shared.mediaDirectory.standardizedFileURL
        let targetUrl = mediaDir.appendingPathComponent(filename).standardizedFileURL
        
        // Защита от Directory Traversal: запрашиваемый путь должен находиться строго в медиа папке
        guard targetUrl.path.hasPrefix(mediaDir.path) else {
            print("⚠️ Попытка несанкционированного доступа к файлу: \(targetUrl.path)")
            return HTTPResponse(statusCode: .forbidden)
        }
        
        do {
            let data = try Data(contentsOf: targetUrl)
            
            var mimeType = "application/octet-stream"
            if filename.hasSuffix(".heic") {
                mimeType = "image/heic"
            } else if filename.hasSuffix(".caf") {
                mimeType = "audio/x-caf"
            } else if filename.hasSuffix(".m4a") {
                mimeType = "audio/mp4"
            }
            
            return HTTPResponse(
                statusCode: .ok,
                headers: [.contentType: mimeType, HTTPHeader(rawValue: "Cache-Control"): "max-age=3600"],
                body: data
            )
        } catch {
            return HTTPResponse(statusCode: .notFound)
        }
    }
    
    // 5. POST /capture/toggle - Управление запуском/остановкой записи из API
    private func handleToggleCapture(_ request: HTTPRequest) async throws -> HTTPResponse {
        let isCapturing = SlishuCapture.shared.isCapturing
        
        if isCapturing {
            SlishuCapture.shared.stopCapture()
        } else {
            SlishuCapture.shared.startCapture()
        }
        
        // Ждем 100мс для применения изменений
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        let newState = SlishuCapture.shared.isCapturing
        let bodyString = "{\"status\": \"success\", \"isCapturing\": \(newState)}"
        
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "application/json"],
            body: bodyString.data(using: .utf8)!
        )
    }
    
    // 6. POST /mcp - Обработка JSON-RPC запросов протокола MCP
    private func handleMCPRPC(_ request: HTTPRequest) async throws -> HTTPResponse {
        let bodyData = try await request.bodyData
        let responseData = SlishuMCP.shared.handleJSONRPCRequest(bodyData)
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "application/json"],
            body: responseData
        )
    }
}
