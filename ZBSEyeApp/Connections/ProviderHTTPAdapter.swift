import Foundation

struct ProviderHTTPAuthorizationState: Sendable, Equatable {
    let selection: ProviderSelectionSnapshot?
    let consentGrant: ScopedAIConsentGrant?
}

protocol ProviderHTTPAuthorizationProviding: Sendable {
    func currentAuthorization(
        for consumer: AIConsumer
    ) async -> ProviderHTTPAuthorizationState
}

protocol ProviderHTTPCredentialProviding: Sendable {
    func credential(for provider: AIProvider) async throws -> String?
}

struct ProviderHTTPTransportRequest: Sendable, Equatable {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data?
    let timeout: Duration
    let maximumResponseBytes: Int
    let maximumErrorBytes: Int
}

struct ProviderHTTPTransportResponse: Sendable, Equatable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

protocol ProviderHTTPTransport: Sendable {
    func send(_ request: ProviderHTTPTransportRequest) async throws
        -> ProviderHTTPTransportResponse
}

enum ProviderHTTPTransportError: Error, Sendable, Equatable {
    case timedOut
    case responseTooLarge
    case redirectRejected
    case cancelled
    case networkFailure
}

enum ProviderHTTPAdapterError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedProvider
    case invalidRequest
    case invalidEndpoint
    case authorizationChanged
    case notAuthorized
    case credentialUnavailable
    case requestTooLarge
    case responseTooLarge
    case redirectRejected
    case authenticationRejected
    case rateLimited
    case serviceUnavailable
    case requestRejected
    case timedOut
    case malformedResponse
    case transportFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider: return "This provider does not use the HTTP adapter."
        case .invalidRequest: return "The AI request is invalid."
        case .invalidEndpoint: return "The provider endpoint is not allowed."
        case .authorizationChanged: return "The selected provider authorization changed."
        case .notAuthorized: return "This request is not authorized for the selected provider."
        case .credentialUnavailable: return "The provider credential is unavailable."
        case .requestTooLarge: return "The AI request exceeds the local size limit."
        case .responseTooLarge: return "The provider response exceeds the local size limit."
        case .redirectRejected: return "The provider attempted an unapproved redirect."
        case .authenticationRejected: return "The provider rejected authentication."
        case .rateLimited: return "The provider is temporarily rate limited."
        case .serviceUnavailable: return "The provider is temporarily unavailable."
        case .requestRejected: return "The provider rejected the request."
        case .timedOut: return "The provider request timed out."
        case .malformedResponse: return "The provider returned an unusable response."
        case .transportFailed: return "The provider request failed."
        }
    }

    fileprivate var isRetryable: Bool {
        switch self {
        case .rateLimited, .serviceUnavailable, .timedOut, .transportFailed:
            return true
        default:
            return false
        }
    }
}

/// A direct HTTP adapter with three separately injected trust boundaries:
/// current authorization, credential retrieval, and network dispatch. The
/// endpoint and authorization are checked again after retrieving a credential,
/// so stale work cannot attach a secret or leave the Mac.
struct ProviderHTTPAdapter: LLMAdapter, Sendable {
    struct Limits: Sendable, Equatable {
        let maximumPromptBytes: Int
        let maximumRequestBytes: Int
        let maximumResponseBytes: Int
        let maximumErrorBytes: Int

        static let `default` = Limits(
            maximumPromptBytes: 256 * 1024,
            maximumRequestBytes: 320 * 1024,
            maximumResponseBytes: 2 * 1024 * 1024,
            maximumErrorBytes: 32 * 1024
        )

        fileprivate var isValid: Bool {
            maximumPromptBytes > 0
                && maximumRequestBytes > 0
                && maximumResponseBytes > 0
                && maximumErrorBytes > 0
                && maximumErrorBytes <= maximumResponseBytes
        }
    }

    private enum GenerationDialect: Sendable {
        case openAIClassic
        case openAICompletionTokens
        case anthropicMessages
    }

    private let provider: AIProvider
    private let baseURL: URL
    private let transport: any ProviderHTTPTransport
    private let credentials: any ProviderHTTPCredentialProviding
    private let authorization: any ProviderHTTPAuthorizationProviding
    private let limits: Limits
    private let now: @Sendable () -> Date

    init(
        provider: AIProvider,
        baseURL: URL,
        transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport(),
        credentials: any ProviderHTTPCredentialProviding,
        authorization: any ProviderHTTPAuthorizationProviding,
        limits: Limits = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = provider
        self.baseURL = baseURL
        self.transport = transport
        self.credentials = credentials
        self.authorization = authorization
        self.limits = limits
        self.now = now
    }

    func generate(
        request: LLMRequest,
        selection: ProviderSelectionSnapshot
    ) async throws -> LLMResponse {
        guard limits.isValid,
              selection.providerID == provider.rawValue,
              !selection.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.maximumOutputTokens > 0,
              request.timeout > .zero else {
            throw ProviderHTTPAdapterError.invalidRequest
        }
        guard Self.supportsHTTP(provider) else {
            throw ProviderHTTPAdapterError.unsupportedProvider
        }

        let promptBytes = request.systemPrompt.utf8.count + request.userPrompt.utf8.count
        guard promptBytes <= limits.maximumPromptBytes else {
            throw ProviderHTTPAdapterError.requestTooLarge
        }

        let dialect = Self.generationDialect(provider: provider, modelID: selection.modelID)
        let body = try Self.requestBody(
            request: request,
            modelID: selection.modelID,
            dialect: dialect
        )
        guard body.count <= limits.maximumRequestBytes else {
            throw ProviderHTTPAdapterError.requestTooLarge
        }

        let maximumAttempts = request.consumer.isAutomatic ? 2 : 1
        for attempt in 0..<maximumAttempts {
            do {
                return try await performAttempt(
                    request: request,
                    selection: selection,
                    dialect: dialect,
                    body: body
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ProviderHTTPAdapterError {
                if attempt + 1 < maximumAttempts, error.isRetryable {
                    try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
                    continue
                }
                throw error
            } catch {
                if attempt + 1 < maximumAttempts {
                    try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
                    continue
                }
                throw ProviderHTTPAdapterError.transportFailed
            }
        }
        throw ProviderHTTPAdapterError.transportFailed
    }

    private func performAttempt(
        request: LLMRequest,
        selection: ProviderSelectionSnapshot,
        dialect: GenerationDialect,
        body: Data
    ) async throws -> LLMResponse {
        let endpoint = try ProviderHTTPRoute.generationURL(
            provider: provider,
            baseURL: baseURL
        )
        try await revalidateAuthorization(selection: selection, consumer: request.consumer)

        let credential: String?
        if provider.isCloud {
            do {
                credential = try await credentials.credential(for: provider)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ProviderHTTPAdapterError.credentialUnavailable
            }
            guard let credential,
                  !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  credential.utf8.count <= 16 * 1024,
                  credential.unicodeScalars.allSatisfy({
                      $0.value >= 0x21 && $0.value <= 0x7E
                  }) else {
                throw ProviderHTTPAdapterError.credentialUnavailable
            }
        } else {
            credential = nil
        }

        // Both checks deliberately happen again after the async credential
        // boundary and immediately before the credential is attached.
        let revalidatedEndpoint = try ProviderHTTPRoute.generationURL(
            provider: provider,
            baseURL: baseURL
        )
        guard revalidatedEndpoint == endpoint else {
            throw ProviderHTTPAdapterError.invalidEndpoint
        }
        try await revalidateAuthorization(selection: selection, consumer: request.consumer)

        var headers = [
            "Accept": "application/json",
            "Accept-Encoding": "identity",
            "Content-Type": "application/json",
        ]
        if let credential {
            switch dialect {
            case .anthropicMessages:
                headers["x-api-key"] = credential
                headers["anthropic-version"] = ProviderHTTPMetadata.anthropicVersion
            case .openAIClassic, .openAICompletionTokens:
                headers["Authorization"] = "Bearer \(credential)"
            }
        }

        let transportRequest = ProviderHTTPTransportRequest(
            url: revalidatedEndpoint,
            method: "POST",
            headers: headers,
            body: body,
            timeout: request.timeout,
            maximumResponseBytes: limits.maximumResponseBytes,
            maximumErrorBytes: limits.maximumErrorBytes
        )

        let response: ProviderHTTPTransportResponse
        do {
            response = try await transport.send(transportRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProviderHTTPTransportError {
            switch error {
            case .timedOut: throw ProviderHTTPAdapterError.timedOut
            case .responseTooLarge: throw ProviderHTTPAdapterError.responseTooLarge
            case .redirectRejected: throw ProviderHTTPAdapterError.redirectRejected
            case .cancelled: throw CancellationError()
            case .networkFailure: throw ProviderHTTPAdapterError.transportFailed
            }
        } catch let error as URLError where error.code == .timedOut {
            throw ProviderHTTPAdapterError.timedOut
        } catch {
            throw ProviderHTTPAdapterError.transportFailed
        }

        return try decode(
            response: response,
            selection: selection,
            dialect: dialect
        )
    }

    private func revalidateAuthorization(
        selection: ProviderSelectionSnapshot,
        consumer: AIConsumer
    ) async throws {
        let current = await authorization.currentAuthorization(for: consumer)
        guard current.selection == selection else {
            throw ProviderHTTPAdapterError.authorizationChanged
        }
        guard provider.isCloud else { return }
        guard let grant = current.consentGrant,
              grant.providerID == provider.rawValue,
              grant.recipientDisclosure == provider.egressDestination(
                  for: baseURL.absoluteString
              ),
              [ScopedAIConsentGrant.legacyPolicyRevision,
               ScopedAIConsentGrant.currentPolicyRevision].contains(grant.policyRevision),
              grant.consumers.contains(consumer) else {
            throw ProviderHTTPAdapterError.notAuthorized
        }
    }

    private func decode(
        response: ProviderHTTPTransportResponse,
        selection: ProviderSelectionSnapshot,
        dialect: GenerationDialect
    ) throws -> LLMResponse {
        let bodyLimit = (200...299).contains(response.statusCode)
            ? limits.maximumResponseBytes
            : limits.maximumErrorBytes
        guard response.body.count <= bodyLimit else {
            throw ProviderHTTPAdapterError.responseTooLarge
        }

        switch response.statusCode {
        case 200...299:
            break
        case 300...399:
            throw ProviderHTTPAdapterError.redirectRejected
        case 401, 403:
            throw ProviderHTTPAdapterError.authenticationRejected
        case 429:
            throw ProviderHTTPAdapterError.rateLimited
        case 500...599:
            throw ProviderHTTPAdapterError.serviceUnavailable
        default:
            throw ProviderHTTPAdapterError.requestRejected
        }

        let parsed: (content: String, truncated: Bool)
        do {
            switch dialect {
            case .openAIClassic, .openAICompletionTokens:
                let envelope = try JSONDecoder().decode(
                    OpenAIResponseEnvelope.self,
                    from: response.body
                )
                guard let choice = envelope.choices.first,
                      !choice.message.content.isEmpty else {
                    throw ProviderHTTPAdapterError.malformedResponse
                }
                parsed = (choice.message.content, choice.finishReason == "length")
            case .anthropicMessages:
                let envelope = try JSONDecoder().decode(
                    AnthropicResponseEnvelope.self,
                    from: response.body
                )
                let text = envelope.content
                    .filter { $0.type == "text" }
                    .map(\.text)
                    .joined()
                guard !text.isEmpty else {
                    throw ProviderHTTPAdapterError.malformedResponse
                }
                parsed = (text, envelope.stopReason == "max_tokens")
            }
        } catch let error as ProviderHTTPAdapterError {
            throw error
        } catch {
            throw ProviderHTTPAdapterError.malformedResponse
        }

        return LLMResponse(
            content: parsed.content,
            truncated: parsed.truncated,
            provenance: AIExecutionProvenance(
                providerID: provider.rawValue,
                modelID: selection.modelID,
                executedLocally: !provider.isCloud,
                generatedAt: now(),
                brokerUpstream: provider == .openrouter
                    ? Self.safeUpstreamHeader(response.headers)
                    : nil
            )
        )
    }

    private static func supportsHTTP(_ provider: AIProvider) -> Bool {
        switch provider {
        case .openrouter, .anthropic, .moonshot, .zai, .xiaomi, .openai,
                .ollama, .lmstudio, .custom, .customAPI:
            return true
        case .zbsEyeLocal, .codex, .claudeCode:
            return false
        }
    }

    private static func generationDialect(
        provider: AIProvider,
        modelID: String
    ) -> GenerationDialect {
        if provider == .anthropic { return .anthropicMessages }
        if provider == .openai,
           ProviderHTTPMetadata.openAICompletionTokenPrefixes.contains(where: {
               modelID.lowercased().hasPrefix($0)
           }) {
            return .openAICompletionTokens
        }
        return .openAIClassic
    }

    private static func requestBody(
        request: LLMRequest,
        modelID: String,
        dialect: GenerationDialect
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            switch dialect {
            case .openAIClassic:
                return try encoder.encode(OpenAIRequestBody(
                    model: modelID,
                    messages: [
                        .init(role: "system", content: request.systemPrompt),
                        .init(role: "user", content: request.userPrompt),
                    ],
                    maxTokens: request.maximumOutputTokens,
                    maxCompletionTokens: nil,
                    temperature: ProviderHTTPMetadata.temperature,
                    stream: false
                ))
            case .openAICompletionTokens:
                return try encoder.encode(OpenAIRequestBody(
                    model: modelID,
                    messages: [
                        .init(role: "system", content: request.systemPrompt),
                        .init(role: "user", content: request.userPrompt),
                    ],
                    maxTokens: nil,
                    maxCompletionTokens: request.maximumOutputTokens,
                    temperature: nil,
                    stream: false
                ))
            case .anthropicMessages:
                return try encoder.encode(AnthropicRequestBody(
                    model: modelID,
                    maximumTokens: request.maximumOutputTokens,
                    system: request.systemPrompt,
                    messages: [.init(role: "user", content: request.userPrompt)],
                    temperature: ProviderHTTPMetadata.temperature
                ))
            }
        } catch {
            throw ProviderHTTPAdapterError.invalidRequest
        }
    }

    private static func safeUpstreamHeader(_ headers: [String: String]) -> String? {
        guard let raw = headers.first(where: {
            $0.key.caseInsensitiveCompare("X-OpenRouter-Provider") == .orderedSame
        })?.value else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }) else {
            return nil
        }
        return value
    }
}

private enum ProviderHTTPMetadata {
    static let anthropicVersion = "2023-06-01"
    static let temperature = 0.2
    static let openAICompletionTokenPrefixes = ["o1", "o3", "o4", "gpt-5"]
}

private struct OpenAIMessage: Codable, Sendable {
    let role: String
    let content: String
}

private struct OpenAIRequestBody: Encodable, Sendable {
    let model: String
    let messages: [OpenAIMessage]
    let maxTokens: Int?
    let maxCompletionTokens: Int?
    let temperature: Double?
    let stream: Bool

    private enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
    }
}

private struct AnthropicRequestBody: Encodable, Sendable {
    let model: String
    let maximumTokens: Int
    let system: String
    let messages: [OpenAIMessage]
    let temperature: Double

    private enum CodingKeys: String, CodingKey {
        case model, system, messages, temperature
        case maximumTokens = "max_tokens"
    }
}

private struct OpenAIResponseEnvelope: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
        let finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    let choices: [Choice]
}

private struct AnthropicResponseEnvelope: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String
    }

    let content: [ContentBlock]
    let stopReason: String?

    private enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }
}

private enum ProviderHTTPRoute {
    static func generationURL(provider: AIProvider, baseURL: URL) throws -> URL {
        let validated = try validatedBaseURL(provider: provider, baseURL: baseURL)
        switch provider {
        case .anthropic:
            return validated.appending(path: "messages", directoryHint: .notDirectory)
        case .openrouter, .moonshot, .zai, .xiaomi, .openai,
                .ollama, .lmstudio, .custom, .customAPI:
            return validated.appending(path: "chat/completions", directoryHint: .notDirectory)
        case .zbsEyeLocal, .codex, .claudeCode:
            throw ProviderHTTPAdapterError.unsupportedProvider
        }
    }

    static func catalogURL(
        provider: AIProvider,
        baseURL: URL,
        cursor: String?
    ) throws -> URL {
        let validated = try validatedBaseURL(provider: provider, baseURL: baseURL)
        var url = validated.appending(path: "models", directoryHint: .notDirectory)
        if provider == .anthropic {
            var components = try requiredComponents(url)
            var queryItems = [URLQueryItem(name: "limit", value: "100")]
            if let cursor {
                let clean = cursor.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, clean.utf8.count <= 256,
                      !clean.contains("\r"), !clean.contains("\n") else {
                    throw ProviderHTTPAdapterError.invalidRequest
                }
                queryItems.append(URLQueryItem(name: "after_id", value: clean))
            }
            components.queryItems = queryItems
            guard let rebuilt = components.url else {
                throw ProviderHTTPAdapterError.invalidEndpoint
            }
            url = rebuilt
        } else if cursor != nil {
            throw ProviderHTTPAdapterError.invalidRequest
        }
        return url
    }

    static func validatedBaseURL(provider: AIProvider, baseURL: URL) throws -> URL {
        switch provider {
        case .openrouter, .anthropic, .moonshot, .zai, .xiaomi, .openai:
            guard let expectedHost = provider.apiHost,
                  let expected = URL(string: provider.defaultBaseURL),
                  baseURL.absoluteString == expected.absoluteString else {
                throw ProviderHTTPAdapterError.invalidEndpoint
            }
            let components = try requiredComponents(baseURL)
            guard components.scheme?.lowercased() == "https",
                  components.host?.lowercased() == expectedHost,
                  components.port == nil,
                  components.user == nil,
                  components.password == nil,
                  components.query == nil,
                  components.fragment == nil else {
                throw ProviderHTTPAdapterError.invalidEndpoint
            }
            return baseURL

        case .ollama, .lmstudio:
            var components = try requiredComponents(baseURL)
            guard let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let rawHost = components.host?.lowercased(),
                  ["127.0.0.1", "localhost", "::1", "[::1]"].contains(rawHost),
                  components.user == nil,
                  components.password == nil,
                  components.query == nil,
                  components.fragment == nil,
                  !components.percentEncodedPath.lowercased().contains("%2e") else {
                throw ProviderHTTPAdapterError.invalidEndpoint
            }
            // Do not let a mutable hosts file or resolver turn the special
            // name `localhost` into a non-loopback peer. URLSession gets a
            // numeric destination, so the connected address is loopback by
            // construction. Numeric 127.0.0.1/::1 inputs are already exact.
            if rawHost == "localhost" { components.host = "127.0.0.1" }
            guard let normalized = components.url else {
                throw ProviderHTTPAdapterError.invalidEndpoint
            }
            return normalized

        case .custom:
            let components = try requiredComponents(baseURL)
            guard let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let rawHost = components.host?.lowercased(),
                  ["127.0.0.1", "::1", "[::1]"].contains(rawHost),
                  components.user == nil,
                  components.password == nil,
                  components.query == nil,
                  components.fragment == nil,
                  !components.percentEncodedPath.lowercased().contains("%2e") else {
                throw ProviderHTTPAdapterError.invalidEndpoint
            }
            return baseURL

        case .customAPI:
            let components = try requiredComponents(baseURL)
            guard components.scheme?.lowercased() == "https",
                  let host = components.host,
                  !host.isEmpty,
                  components.user == nil,
                  components.password == nil,
                  components.query == nil,
                  components.fragment == nil,
                  !components.percentEncodedPath.lowercased().contains("%2e") else {
                throw ProviderHTTPAdapterError.invalidEndpoint
            }
            return baseURL

        case .zbsEyeLocal, .codex, .claudeCode:
            throw ProviderHTTPAdapterError.unsupportedProvider
        }
    }

    private static func requiredComponents(_ url: URL) throws -> URLComponents {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil else {
            throw ProviderHTTPAdapterError.invalidEndpoint
        }
        return components
    }
}

enum ProviderHTTPCatalogAuthentication: Sendable, Equatable {
    case none
    case bearer
    case anthropicAPIKey
}

struct ProviderHTTPCatalogRequest: Sendable, Equatable {
    let url: URL
    let headers: [String: String]
    let authentication: ProviderHTTPCatalogAuthentication
}

struct ProviderHTTPCatalogModel: Sendable, Equatable {
    let id: String
    let displayName: String?
}

struct ProviderHTTPCatalogPage: Sendable, Equatable {
    let models: [ProviderHTTPCatalogModel]
    let nextCursor: String?
}

struct ProviderHTTPCatalogPlan: Sendable, Equatable {
    let liveRequest: ProviderHTTPCatalogRequest?
    let documentedSuggestions: [String]
}

/// Pure catalog request/parse helpers. They describe authentication but never
/// fetch or attach a credential. Z.AI and MiMo deliberately remain documented
/// suggestions until those providers expose a trustworthy live catalog.
enum ProviderHTTPCatalog {
    static func plan(
        provider: AIProvider,
        baseURL: URL,
        cursor: String? = nil
    ) throws -> ProviderHTTPCatalogPlan {
        switch provider {
        case .zai, .xiaomi:
            guard cursor == nil else { throw ProviderHTTPAdapterError.invalidRequest }
            _ = try ProviderHTTPRoute.validatedBaseURL(provider: provider, baseURL: baseURL)
            return ProviderHTTPCatalogPlan(
                liveRequest: nil,
                documentedSuggestions: provider.documentedSuggestedModels
            )

        case .openrouter, .moonshot, .openai, .ollama, .lmstudio, .custom, .customAPI:
            let url = try ProviderHTTPRoute.catalogURL(
                provider: provider,
                baseURL: baseURL,
                cursor: cursor
            )
            return ProviderHTTPCatalogPlan(
                liveRequest: ProviderHTTPCatalogRequest(
                    url: url,
                    headers: [
                        "Accept": "application/json",
                        "Accept-Encoding": "identity",
                    ],
                    authentication: provider.isCloud ? .bearer : .none
                ),
                documentedSuggestions: []
            )

        case .anthropic:
            let url = try ProviderHTTPRoute.catalogURL(
                provider: provider,
                baseURL: baseURL,
                cursor: cursor
            )
            return ProviderHTTPCatalogPlan(
                liveRequest: ProviderHTTPCatalogRequest(
                    url: url,
                    headers: [
                        "Accept": "application/json",
                        "Accept-Encoding": "identity",
                        "anthropic-version": ProviderHTTPMetadata.anthropicVersion,
                    ],
                    authentication: .anthropicAPIKey
                ),
                documentedSuggestions: []
            )

        case .zbsEyeLocal, .codex, .claudeCode:
            guard cursor == nil else { throw ProviderHTTPAdapterError.invalidRequest }
            return ProviderHTTPCatalogPlan(liveRequest: nil, documentedSuggestions: [])
        }
    }

    static func parse(provider: AIProvider, data: Data) throws -> ProviderHTTPCatalogPage {
        do {
            switch provider {
            case .anthropic:
                let envelope = try JSONDecoder().decode(AnthropicCatalogEnvelope.self, from: data)
                let models = try validatedModels(envelope.data.map {
                    ProviderHTTPCatalogModel(id: $0.id, displayName: $0.displayName)
                })
                if envelope.hasMore {
                    guard let cursor = envelope.lastID?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !cursor.isEmpty, cursor.utf8.count <= 256 else {
                        throw ProviderHTTPAdapterError.malformedResponse
                    }
                    return ProviderHTTPCatalogPage(models: models, nextCursor: cursor)
                }
                return ProviderHTTPCatalogPage(models: models, nextCursor: nil)

            case .openrouter:
                let envelope = try JSONDecoder().decode(OpenRouterCatalogEnvelope.self, from: data)
                return ProviderHTTPCatalogPage(
                    models: try validatedModels(envelope.data.map {
                        ProviderHTTPCatalogModel(id: $0.id, displayName: $0.name)
                    }),
                    nextCursor: nil
                )

            case .moonshot, .openai, .ollama, .lmstudio, .custom, .customAPI:
                let envelope = try JSONDecoder().decode(OpenAICatalogEnvelope.self, from: data)
                return ProviderHTTPCatalogPage(
                    models: try validatedModels(envelope.data.map {
                        ProviderHTTPCatalogModel(id: $0.id, displayName: nil)
                    }),
                    nextCursor: nil
                )

            case .zai, .xiaomi, .zbsEyeLocal, .codex, .claudeCode:
                throw ProviderHTTPAdapterError.unsupportedProvider
            }
        } catch let error as ProviderHTTPAdapterError {
            throw error
        } catch {
            throw ProviderHTTPAdapterError.malformedResponse
        }
    }

    private static func validatedModels(
        _ rawModels: [ProviderHTTPCatalogModel]
    ) throws -> [ProviderHTTPCatalogModel] {
        var seen = Set<String>()
        var models: [ProviderHTTPCatalogModel] = []
        models.reserveCapacity(rawModels.count)
        for raw in rawModels {
            let id = raw.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.utf8.count <= 512 else {
                throw ProviderHTTPAdapterError.malformedResponse
            }
            guard seen.insert(id).inserted else { continue }
            let displayName = raw.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let displayName, displayName.utf8.count > 512 {
                throw ProviderHTTPAdapterError.malformedResponse
            }
            models.append(ProviderHTTPCatalogModel(
                id: id,
                displayName: displayName?.isEmpty == false ? displayName : nil
            ))
        }
        return models
    }
}

/// Authenticated model discovery. It shares the same bounded, no-redirect
/// transport as generation but never receives history excerpts and never
/// mutates provider selection. A successful empty payload is authoritative;
/// malformed/partial pagination fails closed.
actor ProviderHTTPCatalogClient {
    private let transport: any ProviderHTTPTransport
    private let credentials: any ProviderHTTPCredentialProviding
    private let maximumPages: Int
    private let maximumModels: Int

    init(
        transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport(),
        credentials: any ProviderHTTPCredentialProviding,
        maximumPages: Int = 10,
        maximumModels: Int = 2_000
    ) {
        self.transport = transport
        self.credentials = credentials
        self.maximumPages = max(1, maximumPages)
        self.maximumModels = max(1, maximumModels)
    }

    func load(
        provider: AIProvider,
        baseURL: URL,
        timeout: Duration = .seconds(10)
    ) async throws -> ProviderCatalogState {
        guard timeout > .zero else { throw ProviderHTTPAdapterError.invalidRequest }
        if provider.catalogDialect == .documentedSuggestions {
            _ = try ProviderHTTPCatalog.plan(provider: provider, baseURL: baseURL)
            return .notLoaded
        }

        var credential: String?
        if provider.usesAPIKey {
            do {
                credential = try await credentials.credential(for: provider)
            } catch {
                throw ProviderHTTPAdapterError.credentialUnavailable
            }
            guard let credential,
                  !credential.isEmpty,
                  credential.utf8.count <= 16 * 1_024,
                  credential.unicodeScalars.allSatisfy({
                      $0.value >= 0x21 && $0.value <= 0x7E
                  }) else {
                throw ProviderHTTPAdapterError.credentialUnavailable
            }
        }

        var cursor: String?
        var models: [ProviderHTTPCatalogModel] = []
        var seen = Set<String>()
        for pageIndex in 0..<maximumPages {
            let plan = try ProviderHTTPCatalog.plan(
                provider: provider,
                baseURL: baseURL,
                cursor: cursor
            )
            guard let live = plan.liveRequest else {
                return .unsupported
            }

            // Rebuild the route after the asynchronous Keychain boundary and
            // compare it byte-for-byte before attaching a secret.
            let revalidated = try ProviderHTTPCatalog.plan(
                provider: provider,
                baseURL: baseURL,
                cursor: cursor
            )
            guard revalidated.liveRequest?.url == live.url else {
                throw ProviderHTTPAdapterError.invalidEndpoint
            }

            var headers = live.headers
            switch live.authentication {
            case .none:
                break
            case .bearer:
                guard let credential else {
                    throw ProviderHTTPAdapterError.credentialUnavailable
                }
                headers["Authorization"] = "Bearer \(credential)"
            case .anthropicAPIKey:
                guard let credential else {
                    throw ProviderHTTPAdapterError.credentialUnavailable
                }
                headers["x-api-key"] = credential
            }
            let response: ProviderHTTPTransportResponse
            do {
                response = try await transport.send(ProviderHTTPTransportRequest(
                    url: live.url,
                    method: "GET",
                    headers: headers,
                    body: nil,
                    timeout: timeout,
                    maximumResponseBytes: 2 * 1_024 * 1_024,
                    maximumErrorBytes: 32 * 1_024
                ))
            } catch let error as ProviderHTTPTransportError {
                switch error {
                case .timedOut: throw ProviderHTTPAdapterError.timedOut
                case .responseTooLarge: throw ProviderHTTPAdapterError.responseTooLarge
                case .redirectRejected: throw ProviderHTTPAdapterError.redirectRejected
                case .cancelled: throw CancellationError()
                case .networkFailure: throw ProviderHTTPAdapterError.transportFailed
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ProviderHTTPAdapterError.transportFailed
            }
            guard response.body.count <= 2 * 1_024 * 1_024 else {
                throw ProviderHTTPAdapterError.responseTooLarge
            }
            switch response.statusCode {
            case 200...299:
                break
            case 300...399:
                throw ProviderHTTPAdapterError.redirectRejected
            case 401, 403:
                throw ProviderHTTPAdapterError.authenticationRejected
            case 429:
                throw ProviderHTTPAdapterError.rateLimited
            case 500...599:
                throw ProviderHTTPAdapterError.serviceUnavailable
            default:
                throw ProviderHTTPAdapterError.requestRejected
            }

            let page = try ProviderHTTPCatalog.parse(provider: provider, data: response.body)
            for model in page.models where seen.insert(model.id).inserted {
                models.append(model)
                guard models.count <= maximumModels else {
                    throw ProviderHTTPAdapterError.responseTooLarge
                }
            }
            guard let next = page.nextCursor else {
                var ids = models.map(\.id)
                if provider == .openai {
                    ids = ids.filter(AIProvider.isChatCapableOpenAIModel)
                }
                return ProviderCatalogState.validatingSuccessfulPayload(ids)
            }
            guard provider == .anthropic,
                  pageIndex + 1 < maximumPages,
                  next != cursor else {
                throw ProviderHTTPAdapterError.malformedResponse
            }
            cursor = next
        }
        throw ProviderHTTPAdapterError.malformedResponse
    }
}

private struct OpenAICatalogEnvelope: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
}

private struct OpenRouterCatalogEnvelope: Decodable {
    struct Model: Decodable {
        let id: String
        let name: String?
    }
    let data: [Model]
}

private struct AnthropicCatalogEnvelope: Decodable {
    struct Model: Decodable {
        let id: String
        let displayName: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }
    }

    let data: [Model]
    let hasMore: Bool
    let lastID: String?

    private enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case lastID = "last_id"
    }
}

/// Streaming, bounded production transport. Each request gets an ephemeral
/// session with no cookie jar, URL cache, credential storage, or redirect
/// following. Response bytes are rejected before appending the first byte over
/// the status-specific limit.
struct URLSessionProviderHTTPTransport: ProviderHTTPTransport, Sendable {
    private let disablesSystemProxy: Bool

    init(disablesSystemProxy: Bool = false) {
        self.disablesSystemProxy = disablesSystemProxy
    }

    static func makeConfiguration(
        disablesSystemProxy: Bool = false
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        if disablesSystemProxy {
            configuration.connectionProxyDictionary = [:]
        }
        return configuration
    }

    func send(
        _ request: ProviderHTTPTransportRequest
    ) async throws -> ProviderHTTPTransportResponse {
        guard request.maximumResponseBytes > 0,
              request.maximumErrorBytes > 0,
              request.maximumErrorBytes <= request.maximumResponseBytes else {
            throw ProviderHTTPTransportError.networkFailure
        }

        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: request.timeout.providerHTTPSeconds
        )
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let state = ProviderHTTPURLSessionState(
            maximumResponseBytes: request.maximumResponseBytes,
            maximumErrorBytes: request.maximumErrorBytes
        )
        let delegate = ProviderHTTPURLSessionDelegate(state: state)
        let session = URLSession(
            configuration: Self.makeConfiguration(disablesSystemProxy: disablesSystemProxy),
            delegate: delegate,
            delegateQueue: nil
        )
        let task = session.dataTask(with: urlRequest)
        return try await state.start(session: session, task: task)
    }
}

private final class ProviderHTTPURLSessionDelegate: NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable {
    private let state: ProviderHTTPURLSessionState

    init(state: ProviderHTTPURLSessionState) {
        self.state = state
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            state.fail(.networkFailure, cancelTask: true)
            completionHandler(.cancel)
            return
        }
        if state.receive(response: response) {
            completionHandler(.allow)
        } else {
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        state.receive(data: data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        state.complete(error: error)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        state.fail(.redirectRejected, cancelTask: true)
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod
            == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

private final class ProviderHTTPURLSessionState: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumResponseBytes: Int
    private let maximumErrorBytes: Int

    private var response: HTTPURLResponse?
    private var body = Data()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<ProviderHTTPTransportResponse, any Error>?
    private var terminal: Result<ProviderHTTPTransportResponse, any Error>?

    init(maximumResponseBytes: Int, maximumErrorBytes: Int) {
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumErrorBytes = maximumErrorBytes
    }

    func start(
        session: URLSession,
        task: URLSessionDataTask
    ) async throws -> ProviderHTTPTransportResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                begin(session: session, task: task, continuation: continuation)
            }
        } onCancel: {
            self.fail(.cancelled, cancelTask: true)
        }
    }

    private func begin(
        session: URLSession,
        task: URLSessionDataTask,
        continuation: CheckedContinuation<ProviderHTTPTransportResponse, any Error>
    ) {
        var immediate: Result<ProviderHTTPTransportResponse, any Error>?
        lock.lock()
        if let terminal {
            immediate = terminal
        } else {
            self.session = session
            self.task = task
            self.continuation = continuation
        }
        lock.unlock()

        if let immediate {
            session.invalidateAndCancel()
            continuation.resume(with: immediate)
        } else {
            task.resume()
        }
    }

    func receive(response: HTTPURLResponse) -> Bool {
        let limit = (200...299).contains(response.statusCode)
            ? maximumResponseBytes
            : maximumErrorBytes
        let expected = response.expectedContentLength
        guard expected < 0 || expected <= Int64(limit) else {
            fail(.responseTooLarge, cancelTask: true)
            return false
        }

        lock.lock()
        guard terminal == nil else {
            lock.unlock()
            return false
        }
        self.response = response
        lock.unlock()
        return true
    }

    func receive(data: Data) {
        var overflow = false
        lock.lock()
        if terminal == nil {
            let status = response?.statusCode ?? 0
            let limit = (200...299).contains(status)
                ? maximumResponseBytes
                : maximumErrorBytes
            if data.count > limit - body.count {
                overflow = true
            } else {
                body.append(data)
            }
        }
        lock.unlock()
        if overflow { fail(.responseTooLarge, cancelTask: true) }
    }

    func complete(error: (any Error)?) {
        lock.lock()
        if terminal != nil {
            lock.unlock()
            return
        }
        let response = self.response
        let body = self.body
        lock.unlock()

        if let error {
            let code = (error as? URLError)?.code
            if code == .timedOut {
                fail(.timedOut, cancelTask: false)
            } else if code == .cancelled {
                fail(.networkFailure, cancelTask: false)
            } else {
                fail(.networkFailure, cancelTask: false)
            }
            return
        }
        guard let response else {
            fail(.networkFailure, cancelTask: false)
            return
        }

        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            headers[String(describing: name)] = String(describing: value)
        }
        finish(.success(ProviderHTTPTransportResponse(
            statusCode: response.statusCode,
            headers: headers,
            body: body
        )), cancelTask: false)
    }

    func fail(_ error: ProviderHTTPTransportError, cancelTask: Bool) {
        finish(.failure(error), cancelTask: cancelTask)
    }

    private func finish(
        _ result: Result<ProviderHTTPTransportResponse, any Error>,
        cancelTask: Bool
    ) {
        var continuation: CheckedContinuation<ProviderHTTPTransportResponse, any Error>?
        var session: URLSession?
        var task: URLSessionDataTask?
        lock.lock()
        guard terminal == nil else {
            lock.unlock()
            return
        }
        terminal = result
        continuation = self.continuation
        self.continuation = nil
        session = self.session
        self.session = nil
        task = self.task
        self.task = nil
        lock.unlock()

        if cancelTask { task?.cancel() }
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}

private extension Duration {
    var providerHTTPSeconds: TimeInterval {
        let components = self.components
        let value = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return max(0.001, value)
    }
}
