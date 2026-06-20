import Foundation

/// Клиент локальной LLM по OpenAI-совместимому API (`/chat/completions`, `/models`). Actor —
/// сетевые вызовы изолированы, наружу только Sendable (String/[String]). Non-streaming: для daily-summary
/// нам нужен один цельный ответ, не поток токенов.
actor LocalLLMClient {

    struct Message: Codable, Sendable {
        let role: String
        let content: String
    }

    /// Итог пробы подключения. Своя enum, т.к. Result.Failure обязан быть Error, а нам нужен String.
    enum ProbeResult: Sendable, Equatable {
        case ok([String])
        case failed(String)
    }

    /// Ответ генерации + флаг обрезки по лимиту токенов (finish_reason="length").
    struct ChatOutput: Sendable {
        let content: String
        let truncated: Bool
    }

    // MARK: проверка подключения

    /// `GET {base}/models` — список доступных моделей. Лёгкая проба «жив ли сервер».
    func listModels(_ cfg: LLMConfig) async -> ProbeResult {
        guard cfg.isLocalOnly else {
            return .failed("endpoint не локальный (только 127.0.0.1/localhost в v1)")
        }
        guard let url = Self.endpoint(cfg.normalizedBaseURL, "models") else {
            return .failed("некорректный baseURL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await Self.session(timeout: 10).data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failed("нет HTTP-ответа") }
            guard (200..<300).contains(http.statusCode) else {
                return .failed("HTTP \(http.statusCode): \(Self.snippet(data))")
            }
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return .ok(decoded.data.map(\.id))
        } catch {
            return .failed(Self.humanError(error))
        }
    }

    // MARK: генерация

    /// `POST {base}/chat/completions` без стрима. maxTokens cap'ает выход (PipeSafety).
    func chat(_ cfg: LLMConfig, system: String, user: String,
              maxTokens: Int, timeout: TimeInterval) async throws -> ChatOutput {
        guard cfg.isLocalOnly else { throw PipeError.nonLocalLLM(URL(string: cfg.normalizedBaseURL)?.host ?? cfg.baseURL) }
        guard let url = Self.endpoint(cfg.normalizedBaseURL, "chat/completions") else {
            throw PipeError.llm("некорректный baseURL")
        }
        let body = ChatRequest(
            model: cfg.model,
            messages: [Message(role: "system", content: system), Message(role: "user", content: user)],
            max_tokens: maxTokens, temperature: 0.3, stream: false)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        do {
            let (data, resp) = try await Self.session(timeout: timeout).data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw PipeError.llm("нет HTTP-ответа") }
            guard (200..<300).contains(http.statusCode) else {
                throw PipeError.llm("HTTP \(http.statusCode): \(Self.snippet(data))")
            }
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let choice = decoded.choices.first,
                  !choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PipeError.llm("пустой ответ модели")
            }
            return ChatOutput(content: choice.message.content, truncated: choice.finish_reason == "length")
        } catch let e as PipeError {
            throw e
        } catch {
            throw PipeError.llm(Self.humanError(error))
        }
    }

    // MARK: внутреннее

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let max_tokens: Int
        let temperature: Double
        let stream: Bool
    }
    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Msg: Decodable { let content: String }
            let message: Msg
            let finish_reason: String?
        }
        let choices: [Choice]
    }
    private struct ModelsResponse: Decodable {
        struct M: Decodable { let id: String }
        let data: [M]
    }

    /// Склейка baseURL + path. Прощаем хвостовой `/` и отсутствие `/v1` (добавим, если нет ни v1, ни иного
    /// суффикса). `endpoint("http://127.0.0.1:11434/v1", "models")` → `.../v1/models`.
    static func endpoint(_ base: String, _ path: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespaces)
        while b.hasSuffix("/") { b.removeLast() }
        guard !b.isEmpty else { return nil }
        // Если в base нет сегмента версии — допускаем «голый» хост и сами дописываем /v1.
        if let u = URL(string: b), (u.path.isEmpty || u.path == "") { b += "/v1" }
        return URL(string: b + "/" + path)
    }

    private static func session(timeout: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        // stream:false → сервер молчит до готовности всего ответа, поэтому idle-таймаут (timeoutIntervalForRequest)
        // де-факто = времени полной генерации. Resource — щедрый общий потолок, чтобы холодная загрузка
        // локальной модели не убивалась раньше времени. (Правильный долгосрочный фикс — stream:true.)
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = max(timeout, 600)
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }

    private static func snippet(_ data: Data) -> String {
        let s = String(data: data, encoding: .utf8) ?? ""
        return String(s.prefix(200))
    }

    private static func humanError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return "сервер не отвечает — запущен ли Ollama / LM Studio / mlx_lm.server?"
            case NSURLErrorTimedOut:
                return "таймаут — модель долго отвечает или не загружена"
            default: break
            }
        }
        return error.localizedDescription
    }
}
