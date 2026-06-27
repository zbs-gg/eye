import Foundation

/// Client for a local LLM over an OpenAI-compatible API (`/chat/completions`, `/models`). Actor —
/// network calls are isolated, only Sendable types (String/[String]) cross the boundary. Non-streaming: for the
/// daily summary we need one whole answer, not a token stream.
actor LocalLLMClient {

    struct Message: Codable, Sendable {
        let role: String
        let content: String
    }

    /// Outcome of a connection probe. Custom enum, because Result.Failure must be an Error, and we need a String.
    enum ProbeResult: Sendable, Equatable {
        case ok([String])
        case failed(String)
    }

    /// Generation result + a flag for truncation by the token limit (finish_reason="length").
    struct ChatOutput: Sendable {
        let content: String
        let truncated: Bool
    }

    // MARK: connection check

    /// `GET {base}/models` — list of available models. A lightweight "is the server alive" probe.
    func listModels(_ cfg: LLMConfig) async -> ProbeResult {
        guard cfg.isLocalOnly else {
            return .failed("endpoint is not local (only 127.0.0.1/localhost in v1)")
        }
        guard let url = Self.endpoint(cfg.normalizedBaseURL, "models") else {
            return .failed("invalid baseURL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await Self.session(timeout: 10).data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failed("no HTTP response") }
            guard (200..<300).contains(http.statusCode) else {
                return .failed("HTTP \(http.statusCode): \(Self.snippet(data))")
            }
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return .ok(decoded.data.map(\.id))
        } catch {
            return .failed(Self.humanError(error))
        }
    }

    // MARK: generation

    /// `POST {base}/chat/completions` without streaming. maxTokens caps the output (AutomationSafety).
    func chat(_ cfg: LLMConfig, system: String, user: String,
              maxTokens: Int, timeout: TimeInterval) async throws -> ChatOutput {
        guard cfg.isLocalOnly else { throw AutomationError.nonLocalLLM(URL(string: cfg.normalizedBaseURL)?.host ?? cfg.baseURL) }
        guard let url = Self.endpoint(cfg.normalizedBaseURL, "chat/completions") else {
            throw AutomationError.llm("invalid baseURL")
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
            guard let http = resp as? HTTPURLResponse else { throw AutomationError.llm("no HTTP response") }
            guard (200..<300).contains(http.statusCode) else {
                throw AutomationError.llm("HTTP \(http.statusCode): \(Self.snippet(data))")
            }
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let choice = decoded.choices.first,
                  !choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AutomationError.llm("empty model response")
            }
            return ChatOutput(content: choice.message.content, truncated: choice.finish_reason == "length")
        } catch let e as AutomationError {
            throw e
        } catch {
            throw AutomationError.llm(Self.humanError(error))
        }
    }

    // MARK: internals

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

    /// Joins baseURL + path. Forgives a trailing `/` and a missing `/v1` (we add it if there's neither v1 nor any other
    /// suffix). `endpoint("http://127.0.0.1:11434/v1", "models")` → `.../v1/models`.
    static func endpoint(_ base: String, _ path: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespaces)
        while b.hasSuffix("/") { b.removeLast() }
        guard !b.isEmpty else { return nil }
        // If base has no version segment — we allow a "bare" host and append /v1 ourselves.
        if let u = URL(string: b), (u.path.isEmpty || u.path == "") { b += "/v1" }
        return URL(string: b + "/" + path)
    }

    private static func session(timeout: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        // stream:false → the server stays silent until the whole response is ready, so the idle timeout (timeoutIntervalForRequest)
        // is de facto = the time of full generation. Resource — a generous overall ceiling, so that a cold load of
        // the local model isn't killed prematurely. (The proper long-term fix is stream:true.)
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
                return "server not responding — is Ollama / LM Studio / mlx_lm.server running?"
            case NSURLErrorTimedOut:
                return "timeout — the model is slow to respond or isn't loaded"
            default: break
            }
        }
        return error.localizedDescription
    }
}
