import Foundation
import GRDB

public final class SlishuMCP {
    public static let shared = SlishuMCP()
    
    private let queue = DispatchQueue(label: "com.slishu.mcp.queue", qos: .userInitiated)
    
    private init() {}
    
    /// Обрабатывает JSON-RPC запрос, пришедший от MCP-клиента
    public func handleJSONRPCRequest(_ requestBody: Data) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
              let method = json["method"] as? String,
              let id = json["id"] else {
            return makeErrorResponse(id: nil, code: -32600, message: "Invalid Request")
        }
        
        switch method {
        case "initialize":
            return makeInitializeResponse(id: id)
            
        case "tools/list":
            return makeToolsListResponse(id: id)
            
        case "tools/call":
            let params = json["params"] as? [String: Any]
            return handleToolCall(id: id, params: params)
            
        default:
            return makeErrorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }
    
    // MARK: - JSON-RPC Responses
    
    private func makeInitializeResponse(id: Any) -> Data {
        let responseObj: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "protocolVersion": "2024-11-05",
                "capabilities": [
                    "tools": [:]
                ],
                "serverInfo": [
                    "name": "SlishuMCP",
                    "version": "1.0.0"
                ]
            ]
        ]
        return safeSerialize(responseObj, fallbackId: id)
    }
    
    private func makeToolsListResponse(id: Any) -> Data {
        let tools: [[String: Any]] = [
            [
                "name": "search_history",
                "description": "Ищет информацию в истории активности пользователя (снимки экрана и расшифровки разговоров) с помощью FTS5.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Поисковый запрос (ключевые слова, фразы, названия приложений или темы)"
                        ]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "get_status",
                "description": "Возвращает текущий статус записи, путь к хранилищу и статистику собранных данных.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "toggle_recording",
                "description": "Включает или выключает фоновый захват экрана и звука.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "enable": [
                            "type": "boolean",
                            "description": "true для включения записи, false для приостановки"
                        ]
                    ],
                    "required": ["enable"]
                ]
            ]
        ]
        
        let responseObj: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "tools": tools
            ]
        ]
        return safeSerialize(responseObj, fallbackId: id)
    }
    
    private func handleToolCall(id: Any, params: [String: Any]?) -> Data {
        guard let name = params?["name"] as? String else {
            return makeErrorResponse(id: id, code: -32602, message: "Invalid params: missing name")
        }
        
        let arguments = params?["arguments"] as? [String: Any] ?? [:]
        
        switch name {
        case "search_history":
            guard let query = arguments["query"] as? String, !query.isEmpty else {
                return makeErrorResponse(id: id, code: -32602, message: "Missing query parameter")
            }
            return handleSearchHistoryTool(id: id, query: query)
            
        case "get_status":
            return handleGetStatusTool(id: id)
            
        case "toggle_recording":
            guard let enable = arguments["enable"] as? Bool else {
                return makeErrorResponse(id: id, code: -32602, message: "Missing enable parameter")
            }
            return handleToggleRecordingTool(id: id, enable: enable)
            
        default:
            return makeErrorResponse(id: id, code: -32601, message: "Tool not found: \(name)")
        }
    }
    
    // MARK: - Tool Handlers
    
    private func handleSearchHistoryTool(id: Any, query: String) -> Data {
        let dbPool = SlishuDatabase.shared.getDatabasePool()
        var textResults = ""
        
        do {
            try dbPool.read { dbReader in
                // 1. Поиск по тексту экрана
                let screenMatches = try Row.fetchAll(dbReader, sql: """
                    SELECT c.timestamp, a.name as appName, f.text
                    FROM ocr_fts f
                    JOIN screen_captures c ON c.id = f.captureId
                    JOIN apps a ON a.id = c.appId
                    WHERE ocr_fts MATCH ?
                    ORDER BY c.timestamp DESC LIMIT 15
                """, arguments: [query])
                
                if !screenMatches.isEmpty {
                    textResults += "--- [Результаты поиска по экрану] ---\n"
                    for row in screenMatches {
                        let timestamp: String = row["timestamp"] ?? ""
                        let appName: String = row["appName"] ?? "Unknown"
                        let text: String = row["text"] ?? ""
                        textResults += "[\(timestamp)] Приложение: \(appName)\nТекст: \(text)\n\n"
                    }
                }
                
                // 2. Поиск по аудиозаписям
                let audioMatches = try Row.fetchAll(dbReader, sql: """
                    SELECT ac.timestamp, af.text
                    FROM audio_fts af
                    JOIN audio_captures ac ON ac.id = af.audioCaptureId
                    WHERE audio_fts MATCH ?
                    ORDER BY ac.timestamp DESC LIMIT 15
                """, arguments: [query])
                
                if !audioMatches.isEmpty {
                    textResults += "--- [Результаты поиска по аудиозаписям] ---\n"
                    for row in audioMatches {
                        let timestamp: String = row["timestamp"] ?? ""
                        let text: String = row["text"] ?? ""
                        textResults += "[\(timestamp)] Расшифровка разговора:\n\"\(text)\"\n\n"
                    }
                }
            }
        } catch {
            return makeToolCallSuccessResponse(id: id, text: "Ошибка БД при поиске: \(error.localizedDescription)")
        }
        
        if textResults.isEmpty {
            textResults = "Ничего не найдено по запросу \"\(query)\"."
        }
        
        return makeToolCallSuccessResponse(id: id, text: textResults)
    }
    
    private func handleGetStatusTool(id: Any) -> Data {
        let db = SlishuDatabase.shared
        let dbPool = db.getDatabasePool()
        
        var screenCount = 0
        var audioCount = 0
        
        try? dbPool.read { dbReader in
            screenCount = try SlishuScreenCapture.fetchCount(dbReader)
            audioCount = try SlishuAudioCapture.fetchCount(dbReader)
        }
        
        let customPath = UserDefaults.standard.string(forKey: "SlishuCustomStoragePath") ?? "default"
        
        let statusText = """
        Статус Slishu: \(SlishuCapture.shared.isCapturing ? "🔴 Активная запись" : "⚪ Запись приостановлена")
        Путь к медиа-файлам: \(db.mediaDirectory.path) (Режим: \(customPath == "default" ? "По умолчанию" : "Пользовательский"))
        Статистика локальной базы данных:
        - Захвачено кадров экрана: \(screenCount)
        - Записано аудио-сегментов: \(audioCount)
        """
        
        return makeToolCallSuccessResponse(id: id, text: statusText)
    }
    
    private func handleToggleRecordingTool(id: Any, enable: Bool) -> Data {
        let isCurrentlyCapturing = SlishuCapture.shared.isCapturing
        
        if enable && !isCurrentlyCapturing {
            SlishuCapture.shared.startCapture()
        } else if !enable && isCurrentlyCapturing {
            SlishuCapture.shared.stopCapture()
        }
        
        let statusMessage = "Запись успешно \(enable ? "запущена" : "остановлена")."
        return makeToolCallSuccessResponse(id: id, text: statusMessage)
    }
    
    // MARK: - Response Builders
    
    private func makeToolCallSuccessResponse(id: Any, text: String) -> Data {
        let responseObj: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": text
                    ]
                ]
            ]
        ]
        return safeSerialize(responseObj, fallbackId: id)
    }
    
    private func makeErrorResponse(id: Any?, code: Int, message: String) -> Data {
        var responseObj: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message
            ]
        ]
        if let id = id {
            responseObj["id"] = id
        } else {
            responseObj["id"] = NSNull()
        }
        return safeSerialize(responseObj, fallbackId: id)
    }
    
    private func safeSerialize(_ obj: [String: Any], fallbackId: Any?) -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: obj, options: [])
        } catch {
            let errObj: [String: Any] = [
                "jsonrpc": "2.0",
                "id": fallbackId ?? NSNull(),
                "error": ["code": -32603, "message": "Internal JSON Serialization error"]
            ]
            return try! JSONSerialization.data(withJSONObject: errObj, options: [])
        }
    }
}
