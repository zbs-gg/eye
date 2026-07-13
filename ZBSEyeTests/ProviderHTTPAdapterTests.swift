import Foundation
import XCTest

final class ProviderHTTPAdapterTests: XCTestCase {
    private let promptCanary = "PROMPT-CANARY-7f48"
    private let secretCanary = "SECRET-CANARY-a913"
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    func testOpenAIClassicUsesPinnedURLBearerAndClassicTokenDialect() async throws {
        let fixture = makeFixture(provider: .openai, model: "gpt-4.1-mini")

        let response = try await fixture.adapter.generate(
            request: request(),
            selection: fixture.selection
        )

        let sentRequests = await fixture.transport.requests()
        let sent = try XCTUnwrap(sentRequests.only)
        XCTAssertEqual(sent.url.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer \(secretCanary)")
        XCTAssertEqual(sent.headers["Content-Type"], "application/json")
        XCTAssertEqual(sent.headers["Accept"], "application/json")
        XCTAssertEqual(sent.headers["Accept-Encoding"], "identity")
        XCTAssertNil(sent.headers["x-api-key"])

        let body = try jsonObject(sent.body)
        XCTAssertEqual(body["model"] as? String, "gpt-4.1-mini")
        XCTAssertEqual(body["max_tokens"] as? Int, 321)
        XCTAssertEqual(body["temperature"] as? Double, 0.2)
        XCTAssertNil(body["max_completion_tokens"])
        XCTAssertEqual(body["stream"] as? Bool, false)
        try assertMessages(body)

        XCTAssertEqual(response.content, "fixture answer")
        XCTAssertEqual(response.provenance.providerID, AIProvider.openai.rawValue)
        XCTAssertEqual(response.provenance.modelID, "gpt-4.1-mini")
        XCTAssertFalse(response.provenance.executedLocally)
        XCTAssertEqual(response.provenance.generatedAt, fixedDate)
        XCTAssertNil(response.provenance.brokerUpstream)
    }

    func testOpenAIReasoningUsesCompletionTokenDialectWithoutTemperature() async throws {
        let fixture = makeFixture(provider: .openai, model: "o3-mini")

        _ = try await fixture.adapter.generate(request: request(), selection: fixture.selection)

        let sentRequests = await fixture.transport.requests()
        let sent = try XCTUnwrap(sentRequests.only)
        let body = try jsonObject(sent.body)
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 321)
        XCTAssertNil(body["max_tokens"])
        XCTAssertNil(body["temperature"])
    }

    func testAnthropicUsesNativeMessagesDialectAndAPIKeyHeaders() async throws {
        let fixture = makeFixture(provider: .anthropic, model: "claude-haiku-4-5-20251001")
        await fixture.transport.replaceOutcomes([
            .response(.json(
                statusCode: 200,
                body: #"{"content":[{"type":"text","text":"native answer"}],"stop_reason":"max_tokens"}"#
            )),
        ])

        let response = try await fixture.adapter.generate(
            request: request(),
            selection: fixture.selection
        )

        let sentRequests = await fixture.transport.requests()
        let sent = try XCTUnwrap(sentRequests.only)
        XCTAssertEqual(sent.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(sent.headers["x-api-key"], secretCanary)
        XCTAssertEqual(sent.headers["anthropic-version"], "2023-06-01")
        XCTAssertNil(sent.headers["Authorization"])
        let body = try jsonObject(sent.body)
        XCTAssertEqual(body["model"] as? String, "claude-haiku-4-5-20251001")
        XCTAssertEqual(body["max_tokens"] as? Int, 321)
        XCTAssertEqual(body["temperature"] as? Double, 0.2)
        XCTAssertEqual(body["system"] as? String, "system \(promptCanary)")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "user \(promptCanary)")
        XCTAssertEqual(response.content, "native answer")
        XCTAssertTrue(response.truncated)
    }

    func testEveryDirectCloudProviderUsesItsExactPinnedRouteAndBearerDialect() async throws {
        let cases: [(AIProvider, String)] = [
            (.openrouter, "https://openrouter.ai/api/v1/chat/completions"),
            (.moonshot, "https://api.moonshot.ai/v1/chat/completions"),
            (.zai, "https://api.z.ai/api/paas/v4/chat/completions"),
            (.xiaomi, "https://api.xiaomimimo.com/v1/chat/completions"),
        ]

        for (provider, expectedURL) in cases {
            let fixture = makeFixture(provider: provider, model: "provider-model")
            _ = try await fixture.adapter.generate(
                request: request(),
                selection: fixture.selection
            )
            let sentRequests = await fixture.transport.requests()
            let sent = try XCTUnwrap(sentRequests.only)
            XCTAssertEqual(sent.url.absoluteString, expectedURL, provider.rawValue)
            XCTAssertEqual(sent.headers["Authorization"], "Bearer \(secretCanary)")
            XCTAssertNil(sent.headers["x-api-key"])
            let body = try jsonObject(sent.body)
            XCTAssertEqual(body["max_tokens"] as? Int, 321)
            XCTAssertEqual(body["temperature"] as? Double, 0.2)
        }
    }

    func testLocalProvidersRequireLoopbackAndNeverRequestOrAttachCredential() async throws {
        let cases: [(AIProvider, String)] = [
            (.ollama, "http://127.0.0.1:11434/v1"),
            (.lmstudio, "http://127.0.0.1:1234/v1"),
            (.custom, "http://127.0.0.1:9800/v1"),
        ]

        for (provider, endpoint) in cases {
            let fixture = makeFixture(
                provider: provider,
                model: "local-model",
                baseURL: URL(string: endpoint)!
            )
            let response = try await fixture.adapter.generate(
                request: request(),
                selection: fixture.selection
            )
            let sentRequests = await fixture.transport.requests()
            let sent = try XCTUnwrap(sentRequests.only)
            XCTAssertEqual(sent.url.host, "127.0.0.1")
            XCTAssertNil(sent.headers["Authorization"])
            XCTAssertNil(sent.headers["x-api-key"])
            let credentialReads = await fixture.credentials.readCount()
            XCTAssertEqual(credentialReads, 0)
            XCTAssertTrue(response.provenance.executedLocally)
        }

        let remote = makeFixture(
            provider: .custom,
            model: "local-model",
            baseURL: URL(string: "https://example.com/v1")!
        )
        await assertThrows(.invalidEndpoint) {
            _ = try await remote.adapter.generate(request: self.request(), selection: remote.selection)
        }
        let remoteCredentialReads = await remote.credentials.readCount()
        let remoteRequests = await remote.transport.requests()
        XCTAssertEqual(remoteCredentialReads, 0)
        XCTAssertEqual(remoteRequests.count, 0)

        let namedLoopback = makeFixture(
            provider: .custom,
            model: "local-model",
            baseURL: URL(string: "http://localhost:9800/v1")!
        )
        await assertThrows(.invalidEndpoint) {
            _ = try await namedLoopback.adapter.generate(
                request: self.request(),
                selection: namedLoopback.selection
            )
        }
        let namedLoopbackReads = await namedLoopback.credentials.readCount()
        let namedLoopbackRequests = await namedLoopback.transport.requests()
        XCTAssertEqual(namedLoopbackReads, 0)
        XCTAssertEqual(namedLoopbackRequests.count, 0)
    }

    func testCustomAPIRequiresHTTPSAndAttachesItsOwnCredentialWithoutRedirectFallback() async throws {
        let httpsURL = URL(string: "https://inference.example/v1")!
        let secure = makeFixture(
            provider: .customAPI,
            model: "custom-model",
            baseURL: httpsURL
        )

        let response = try await secure.adapter.generate(
            request: request(),
            selection: secure.selection
        )

        let sentRequests = await secure.transport.requests()
        let sent = try XCTUnwrap(sentRequests.only)
        XCTAssertEqual(sent.url.absoluteString, "https://inference.example/v1/chat/completions")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer \(secretCanary)")
        XCTAssertFalse(response.provenance.executedLocally)

        let insecure = makeFixture(
            provider: .customAPI,
            model: "custom-model",
            baseURL: URL(string: "http://inference.example/v1")!
        )
        await assertThrows(.invalidEndpoint) {
            _ = try await insecure.adapter.generate(
                request: self.request(),
                selection: insecure.selection
            )
        }
        let insecureReads = await insecure.credentials.readCount()
        let insecureRequests = await insecure.transport.requests()
        XCTAssertEqual(insecureReads, 0)
        XCTAssertEqual(insecureRequests.count, 0)
    }

    func testStaleSelectionRevokedConsentAndUnpinnedURLRejectBeforeSecretOrDispatch() async throws {
        let stale = makeFixture(provider: .openrouter, model: "anthropic/claude-haiku")
        await stale.authorization.setState(.init(
            selection: ProviderSelectionSnapshot(
                providerID: AIProvider.openrouter.rawValue,
                modelID: "anthropic/claude-haiku",
                selectionRevision: SelectionRevision(rawValue: 8),
                authorizationEpoch: AuthorizationEpoch(rawValue: 11)
            ),
            consentGrant: grant(for: .openrouter, consumers: [.ask])
        ))
        await assertThrows(.authorizationChanged) {
            _ = try await stale.adapter.generate(request: self.request(), selection: stale.selection)
        }
        let staleCredentialReads = await stale.credentials.readCount()
        let staleRequests = await stale.transport.requests()
        XCTAssertEqual(staleCredentialReads, 0)
        XCTAssertEqual(staleRequests.count, 0)

        let expiredEpoch = makeFixture(
            provider: .openrouter,
            model: "anthropic/claude-haiku"
        )
        await expiredEpoch.authorization.setState(.init(
            selection: ProviderSelectionSnapshot(
                providerID: AIProvider.openrouter.rawValue,
                modelID: "anthropic/claude-haiku",
                selectionRevision: SelectionRevision(rawValue: 7),
                authorizationEpoch: AuthorizationEpoch(rawValue: 12)
            ),
            consentGrant: grant(for: .openrouter, consumers: [.ask])
        ))
        await assertThrows(.authorizationChanged) {
            _ = try await expiredEpoch.adapter.generate(
                request: self.request(),
                selection: expiredEpoch.selection
            )
        }
        let expiredEpochReads = await expiredEpoch.credentials.readCount()
        let expiredEpochRequests = await expiredEpoch.transport.requests()
        XCTAssertEqual(expiredEpochReads, 0)
        XCTAssertEqual(expiredEpochRequests.count, 0)

        let revoked = makeFixture(provider: .openrouter, model: "anthropic/claude-haiku")
        await revoked.authorization.setState(.init(selection: revoked.selection, consentGrant: nil))
        await assertThrows(.notAuthorized) {
            _ = try await revoked.adapter.generate(request: self.request(), selection: revoked.selection)
        }
        let revokedCredentialReads = await revoked.credentials.readCount()
        let revokedRequests = await revoked.transport.requests()
        XCTAssertEqual(revokedCredentialReads, 0)
        XCTAssertEqual(revokedRequests.count, 0)

        let unpinned = makeFixture(
            provider: .openrouter,
            model: "anthropic/claude-haiku",
            baseURL: URL(string: "https://localhost/api/v1")!
        )
        await assertThrows(.invalidEndpoint) {
            _ = try await unpinned.adapter.generate(request: self.request(), selection: unpinned.selection)
        }
        let unpinnedCredentialReads = await unpinned.credentials.readCount()
        let unpinnedRequests = await unpinned.transport.requests()
        XCTAssertEqual(unpinnedCredentialReads, 0)
        XCTAssertEqual(unpinnedRequests.count, 0)
    }

    func testAuthorizationIsRecheckedAfterCredentialReadBeforeDispatch() async throws {
        let provider = AIProvider.openrouter
        let selection = snapshot(provider: provider, model: "model")
        let transport = StubProviderHTTPTransport()
        let authorization = StubProviderHTTPAuthorization(
            state: .init(selection: selection, consentGrant: grant(for: provider, consumers: [.ask]))
        )
        let credentials = StubProviderHTTPCredentials(secret: secretCanary) {
            await authorization.setState(.init(selection: selection, consentGrant: nil))
        }
        let date = fixedDate
        let adapter = ProviderHTTPAdapter(
            provider: provider,
            baseURL: URL(string: provider.defaultBaseURL)!,
            transport: transport,
            credentials: credentials,
            authorization: authorization,
            now: { date }
        )

        await assertThrows(.notAuthorized) {
            _ = try await adapter.generate(request: self.request(), selection: selection)
        }
        let credentialReads = await credentials.readCount()
        let sentRequests = await transport.requests()
        XCTAssertEqual(credentialReads, 1)
        XCTAssertEqual(sentRequests.count, 0)
    }

    func testInvalidCredentialIsRejectedWithoutHeaderInjectionOrDispatch() async throws {
        let provider = AIProvider.openai
        let selection = snapshot(provider: provider, model: "gpt-4.1-mini")
        let transport = StubProviderHTTPTransport()
        let authorization = StubProviderHTTPAuthorization(
            state: .init(
                selection: selection,
                consentGrant: grant(for: provider, consumers: [.ask])
            )
        )
        let credentials = StubProviderHTTPCredentials(
            secret: "\(secretCanary)\r\nX-Injected: yes"
        )
        let adapter = ProviderHTTPAdapter(
            provider: provider,
            baseURL: URL(string: provider.defaultBaseURL)!,
            transport: transport,
            credentials: credentials,
            authorization: authorization
        )

        await assertThrows(.credentialUnavailable) {
            _ = try await adapter.generate(request: self.request(), selection: selection)
        }
        let sentRequests = await transport.requests()
        XCTAssertEqual(sentRequests.count, 0)
        XCTAssertFalse(
            ProviderHTTPAdapterError.credentialUnavailable.localizedDescription
                .contains(secretCanary)
        )
    }

    func testRedirectStatusesAndFailuresAreNormalizedWithoutPromptSecretOrBody() async throws {
        let cases: [(StubProviderHTTPTransport.Outcome, ProviderHTTPAdapterError)] = [
            (.response(.json(statusCode: 302, body: "redirect \(promptCanary) \(secretCanary)")), .redirectRejected),
            (.response(.json(statusCode: 401, body: "unauthorized \(promptCanary) \(secretCanary)")), .authenticationRejected),
            (.response(.json(statusCode: 403, body: "forbidden \(promptCanary) \(secretCanary)")), .authenticationRejected),
            (.response(.json(statusCode: 429, body: "rate \(promptCanary) \(secretCanary)")), .rateLimited),
            (.response(.json(statusCode: 500, body: "server \(promptCanary) \(secretCanary)")), .serviceUnavailable),
            (.response(.json(statusCode: 200, body: "{malformed \(promptCanary) \(secretCanary)")), .malformedResponse),
            (.failure(.timedOut), .timedOut),
            (.rawFailure, .transportFailed),
        ]

        for (outcome, expected) in cases {
            let fixture = makeFixture(provider: .openai, model: "gpt-4.1-mini")
            await fixture.transport.replaceOutcomes([outcome])
            do {
                _ = try await fixture.adapter.generate(
                    request: request(),
                    selection: fixture.selection
                )
                XCTFail("Expected \(expected)")
            } catch let error as ProviderHTTPAdapterError {
                XCTAssertEqual(error, expected)
                let rendered = String(describing: error) + error.localizedDescription
                XCTAssertFalse(rendered.contains(promptCanary))
                XCTAssertFalse(rendered.contains(secretCanary))
                XCTAssertFalse(rendered.contains("server"))
            } catch {
                XCTFail("Unexpected error type: \(type(of: error))")
            }
        }
    }

    func testRequestResponseAndErrorBodiesAreBounded() async throws {
        let limits = ProviderHTTPAdapter.Limits(
            maximumPromptBytes: 64,
            maximumRequestBytes: 512,
            maximumResponseBytes: 128,
            maximumErrorBytes: 32
        )
        let fixture = makeFixture(provider: .openai, model: "gpt-4.1-mini", limits: limits)

        let hugeRequest = LLMRequest(
            id: UUID(), consumer: .ask, priority: .ask,
            systemPrompt: String(repeating: "s", count: 80), userPrompt: "u",
            maximumOutputTokens: 10, timeout: .seconds(3)
        )
        await assertThrows(.requestTooLarge) {
            _ = try await fixture.adapter.generate(request: hugeRequest, selection: fixture.selection)
        }
        let oversizedRequestDispatches = await fixture.transport.requests()
        XCTAssertEqual(oversizedRequestDispatches.count, 0)

        await fixture.transport.replaceOutcomes([
            .response(.json(statusCode: 200, body: String(repeating: "x", count: 129))),
        ])
        await assertThrows(.responseTooLarge) {
            _ = try await fixture.adapter.generate(request: self.request(), selection: fixture.selection)
        }
        let boundedRequests = await fixture.transport.requests()
        let sent = try XCTUnwrap(boundedRequests.only)
        XCTAssertEqual(sent.maximumResponseBytes, 128)
        XCTAssertEqual(sent.maximumErrorBytes, 32)
    }

    func testRetriesTransientFailureOnceOnlyForAutomaticConsumers() async throws {
        let manual = makeFixture(provider: .openai, model: "gpt-4.1-mini")
        await manual.transport.replaceOutcomes([
            .response(.json(statusCode: 500, body: "no")),
            .response(.openAISuccess),
        ])
        await assertThrows(.serviceUnavailable) {
            _ = try await manual.adapter.generate(request: self.request(), selection: manual.selection)
        }
        let manualRequests = await manual.transport.requests()
        XCTAssertEqual(manualRequests.count, 1)

        let automatic = makeFixture(provider: .openai, model: "gpt-4.1-mini")
        await automatic.transport.replaceOutcomes([
            .failure(.timedOut),
            .response(.openAISuccess),
            .response(.openAISuccess),
        ])
        let automaticRequest = LLMRequest(
            id: UUID(), consumer: .scheduledSummary, priority: .scheduledSummary,
            systemPrompt: "system", userPrompt: "user", maximumOutputTokens: 40,
            timeout: .seconds(3)
        )
        let answer = try await automatic.adapter.generate(
            request: automaticRequest,
            selection: automatic.selection
        )
        XCTAssertEqual(answer.content, "fixture answer")
        let automaticRequests = await automatic.transport.requests()
        XCTAssertEqual(automaticRequests.count, 2)
    }

    func testOpenRouterProvenanceUsesBoundedUpstreamHeaderOnly() async throws {
        let fixture = makeFixture(provider: .openrouter, model: "anthropic/claude-haiku")
        await fixture.transport.replaceOutcomes([
            .response(.json(
                statusCode: 200,
                headers: ["X-OpenRouter-Provider": "  Anthropic  "],
                body: ProviderHTTPTransportResponse.openAISuccessBody
            )),
        ])

        let response = try await fixture.adapter.generate(
            request: request(),
            selection: fixture.selection
        )
        XCTAssertEqual(response.provenance.brokerUpstream, "Anthropic")

        let unsafe = makeFixture(provider: .openrouter, model: "model")
        await unsafe.transport.replaceOutcomes([
            .response(.json(
                statusCode: 200,
                headers: ["x-openrouter-provider": "bad\n\(secretCanary)"],
                body: ProviderHTTPTransportResponse.openAISuccessBody
            )),
        ])
        let unsafeResponse = try await unsafe.adapter.generate(
            request: request(),
            selection: unsafe.selection
        )
        XCTAssertNil(unsafeResponse.provenance.brokerUpstream)
    }

    func testCatalogPlansAndStrictParsersKeepSuggestionsSeparateFromLiveAuthority() throws {
        let openAI = try ProviderHTTPCatalog.plan(
            provider: .openai,
            baseURL: URL(string: AIProvider.openai.defaultBaseURL)!
        )
        XCTAssertEqual(openAI.liveRequest?.url.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(openAI.liveRequest?.authentication, .bearer)

        let openRouter = try ProviderHTTPCatalog.plan(
            provider: .openrouter,
            baseURL: URL(string: AIProvider.openrouter.defaultBaseURL)!
        )
        let openRouterPage = try ProviderHTTPCatalog.parse(
            provider: .openrouter,
            data: Data(#"{"data":[{"id":"a/model","name":"A Model"}]}"#.utf8)
        )
        XCTAssertEqual(openRouter.liveRequest?.url.absoluteString, "https://openrouter.ai/api/v1/models")
        XCTAssertEqual(openRouterPage.models, [.init(id: "a/model", displayName: "A Model")])
        XCTAssertNil(openRouterPage.nextCursor)

        let kimi = try ProviderHTTPCatalog.plan(
            provider: .moonshot,
            baseURL: URL(string: AIProvider.moonshot.defaultBaseURL)!
        )
        XCTAssertEqual(kimi.liveRequest?.url.absoluteString, "https://api.moonshot.ai/v1/models")
        XCTAssertEqual(
            try ProviderHTTPCatalog.parse(
                provider: .moonshot,
                data: Data(#"{"data":[{"id":"kimi-k2.5"}]}"#.utf8)
            ).models,
            [.init(id: "kimi-k2.5", displayName: nil)]
        )

        let anthropic = try ProviderHTTPCatalog.plan(
            provider: .anthropic,
            baseURL: URL(string: AIProvider.anthropic.defaultBaseURL)!
        )
        XCTAssertEqual(anthropic.liveRequest?.url.absoluteString, "https://api.anthropic.com/v1/models?limit=100")
        XCTAssertEqual(anthropic.liveRequest?.authentication, .anthropicAPIKey)
        XCTAssertEqual(anthropic.liveRequest?.headers["anthropic-version"], "2023-06-01")
        let anthropicPage = try ProviderHTTPCatalog.parse(
            provider: .anthropic,
            data: Data(#"{"data":[{"id":"claude-haiku","display_name":"Claude Haiku"}],"has_more":true,"last_id":"claude-haiku"}"#.utf8)
        )
        XCTAssertEqual(
            anthropicPage.models,
            [.init(id: "claude-haiku", displayName: "Claude Haiku")]
        )
        XCTAssertEqual(anthropicPage.nextCursor, "claude-haiku")
        let next = try ProviderHTTPCatalog.plan(
            provider: .anthropic,
            baseURL: URL(string: AIProvider.anthropic.defaultBaseURL)!,
            cursor: anthropicPage.nextCursor
        )
        XCTAssertEqual(
            next.liveRequest?.url.absoluteString,
            "https://api.anthropic.com/v1/models?limit=100&after_id=claude-haiku"
        )

        let zai = try ProviderHTTPCatalog.plan(
            provider: .zai,
            baseURL: URL(string: AIProvider.zai.defaultBaseURL)!
        )
        let mimo = try ProviderHTTPCatalog.plan(
            provider: .xiaomi,
            baseURL: URL(string: AIProvider.xiaomi.defaultBaseURL)!
        )
        XCTAssertNil(zai.liveRequest)
        XCTAssertNil(mimo.liveRequest)
        XCTAssertEqual(zai.documentedSuggestions, AIProvider.zai.documentedSuggestedModels)
        XCTAssertEqual(mimo.documentedSuggestions, AIProvider.xiaomi.documentedSuggestedModels)
        XCTAssertThrowsError(
            try ProviderHTTPCatalog.parse(
                provider: .openai,
                data: Data(#"{"models":[]}"#.utf8)
            )
        )
    }

    func testCatalogClientPaginatesAnthropicAndKeepsSuggestionsOffline() async throws {
        let transport = StubProviderHTTPTransport()
        await transport.replaceOutcomes([
            .response(.json(
                statusCode: 200,
                body: #"{"data":[{"id":"claude-haiku","display_name":"Haiku"}],"has_more":true,"last_id":"claude-haiku"}"#
            )),
            .response(.json(
                statusCode: 200,
                body: #"{"data":[{"id":"claude-sonnet","display_name":"Sonnet"}],"has_more":false}"#
            )),
        ])
        let credentials = StubProviderHTTPCredentials(secret: secretCanary)
        let client = ProviderHTTPCatalogClient(
            transport: transport,
            credentials: credentials
        )

        let state = try await client.load(
            provider: .anthropic,
            baseURL: URL(string: AIProvider.anthropic.defaultBaseURL)!
        )

        XCTAssertEqual(state, .authoritative(["claude-haiku", "claude-sonnet"]))
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests[1].url.absoluteString,
            "https://api.anthropic.com/v1/models?limit=100&after_id=claude-haiku"
        )
        XCTAssertEqual(requests[0].headers["x-api-key"], secretCanary)
        XCTAssertEqual(requests[0].headers["anthropic-version"], "2023-06-01")
        let readsAfterAnthropic = await credentials.readCount()
        XCTAssertEqual(readsAfterAnthropic, 1)

        let suggestions = try await client.load(
            provider: .zai,
            baseURL: URL(string: AIProvider.zai.defaultBaseURL)!
        )
        XCTAssertEqual(suggestions, .notLoaded)
        let readsAfterSuggestions = await credentials.readCount()
        let requestsAfterSuggestions = await transport.requests()
        XCTAssertEqual(readsAfterSuggestions, 1)
        XCTAssertEqual(requestsAfterSuggestions.count, 2)
    }

    func testProductionTransportConfigurationHasNoAmbientState() {
        let configuration = URLSessionProviderHTTPTransport.makeConfiguration()
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
    }

    // MARK: helpers

    private struct Fixture {
        let adapter: ProviderHTTPAdapter
        let selection: ProviderSelectionSnapshot
        let transport: StubProviderHTTPTransport
        let credentials: StubProviderHTTPCredentials
        let authorization: StubProviderHTTPAuthorization
    }

    private func makeFixture(
        provider: AIProvider,
        model: String,
        baseURL: URL? = nil,
        limits: ProviderHTTPAdapter.Limits = .default
    ) -> Fixture {
        let selection = snapshot(provider: provider, model: model)
        let transport = StubProviderHTTPTransport()
        let credentials = StubProviderHTTPCredentials(secret: secretCanary)
        let consumers = Set(AIConsumer.allCases)
        let resolvedBaseURL = baseURL ?? URL(string: provider.defaultBaseURL)!
        let authorization = StubProviderHTTPAuthorization(
            state: .init(
                selection: selection,
                consentGrant: provider.isCloud
                    ? grant(
                        for: provider,
                        consumers: consumers,
                        baseURL: resolvedBaseURL
                    )
                    : nil
            )
        )
        let date = fixedDate
        return Fixture(
            adapter: ProviderHTTPAdapter(
                provider: provider,
                baseURL: resolvedBaseURL,
                transport: transport,
                credentials: credentials,
                authorization: authorization,
                limits: limits,
                now: { date }
            ),
            selection: selection,
            transport: transport,
            credentials: credentials,
            authorization: authorization
        )
    }

    private func snapshot(provider: AIProvider, model: String) -> ProviderSelectionSnapshot {
        ProviderSelectionSnapshot(
            providerID: provider.rawValue,
            modelID: model,
            selectionRevision: SelectionRevision(rawValue: 7),
            authorizationEpoch: AuthorizationEpoch(rawValue: 11)
        )
    }

    private func grant(
        for provider: AIProvider,
        consumers: Set<AIConsumer>,
        baseURL: URL? = nil
    ) -> ScopedAIConsentGrant {
        ScopedAIConsentGrant(
            providerID: provider.rawValue,
            recipientDisclosure: provider.egressDestination(
                for: baseURL?.absoluteString ?? provider.defaultBaseURL
            ),
            consumers: consumers,
            policyRevision: ScopedAIConsentGrant.currentPolicyRevision
        )
    }

    private func request() -> LLMRequest {
        LLMRequest(
            id: UUID(), consumer: .ask, priority: .ask,
            systemPrompt: "system \(promptCanary)",
            userPrompt: "user \(promptCanary)",
            maximumOutputTokens: 321,
            timeout: .seconds(3)
        )
    }

    private func jsonObject(_ data: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertMessages(_ body: [String: Any]) throws {
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "system \(promptCanary)")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "user \(promptCanary)")
    }

    private func assertThrows(
        _ expected: ProviderHTTPAdapterError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as ProviderHTTPAdapterError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))")
        }
    }
}

private actor StubProviderHTTPTransport: ProviderHTTPTransport {
    enum Outcome: Sendable {
        case response(ProviderHTTPTransportResponse)
        case failure(ProviderHTTPTransportError)
        case rawFailure
    }

    private var sent: [ProviderHTTPTransportRequest] = []
    private var outcomes: [Outcome] = [.response(.openAISuccess)]

    func send(_ request: ProviderHTTPTransportRequest) async throws -> ProviderHTTPTransportResponse {
        sent.append(request)
        let outcome = outcomes.isEmpty ? .response(.openAISuccess) : outcomes.removeFirst()
        switch outcome {
        case .response(let response): return response
        case .failure(let error): throw error
        case .rawFailure: throw RawCanaryError()
        }
    }

    func requests() -> [ProviderHTTPTransportRequest] { sent }

    func replaceOutcomes(_ replacement: [Outcome]) {
        outcomes = replacement
        sent = []
    }

    private struct RawCanaryError: Error, CustomStringConvertible {
        var description: String { "PROMPT-CANARY-7f48 SECRET-CANARY-a913" }
    }
}

private actor StubProviderHTTPCredentials: ProviderHTTPCredentialProviding {
    private let secret: String?
    private let onRead: (@Sendable () async -> Void)?
    private var count = 0

    init(secret: String?, onRead: (@Sendable () async -> Void)? = nil) {
        self.secret = secret
        self.onRead = onRead
    }

    func credential(for provider: AIProvider) async throws -> String? {
        count += 1
        await onRead?()
        return secret
    }

    func readCount() -> Int { count }
}

private actor StubProviderHTTPAuthorization: ProviderHTTPAuthorizationProviding {
    private var state: ProviderHTTPAuthorizationState

    init(state: ProviderHTTPAuthorizationState) {
        self.state = state
    }

    func currentAuthorization() async -> ProviderHTTPAuthorizationState { state }
    func setState(_ newState: ProviderHTTPAuthorizationState) { state = newState }
}

private extension ProviderHTTPTransportResponse {
    static let openAISuccessBody = #"{"choices":[{"message":{"content":"fixture answer"},"finish_reason":"stop"}]}"#

    static var openAISuccess: Self {
        .json(statusCode: 200, body: openAISuccessBody)
    }

    static func json(
        statusCode: Int,
        headers: [String: String] = [:],
        body: String
    ) -> Self {
        Self(statusCode: statusCode, headers: headers, body: Data(body.utf8))
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
