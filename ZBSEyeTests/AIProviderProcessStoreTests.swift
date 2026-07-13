import Foundation
import XCTest

@MainActor
final class AIProviderProcessStoreTests: XCTestCase {
    func testConfigureProcessProvidersDoesNotProbeActiveCodexWithoutScopedConsent() async {
        let codex = ScriptedStoreCodexProvider(updates: [])
        let (store, overlay, defaults) = makeStore(codex: codex)
        defer { clear(defaults) }
        store.settings = AIProviderSettings(
            active: AIProvider.codex.rawValue,
            activeModelID: "gpt-5.4-mini",
            models: [AIProvider.codex.rawValue: "gpt-5.4-mini"]
        )

        store.configureProcessProviders(
            codex: codex,
            claudeCode: ScriptedStoreClaudeProvider(updates: []),
            overlay: overlay
        )
        for _ in 0..<20 { await Task.yield() }

        let calls = await codex.probeCallCount()
        XCTAssertEqual(calls, 0)
    }

    func testConfigureProcessProvidersRejectsMalformedScopedConsent() async {
        let codex = ScriptedStoreCodexProvider(updates: [])
        let (store, overlay, defaults) = makeStore(codex: codex)
        defer { clear(defaults) }
        let malformed = ScopedAIConsentGrant(
            providerID: AIProvider.codex.rawValue,
            recipientDisclosure: "some other recipient",
            consumers: [.ask],
            policyRevision: ScopedAIConsentGrant.currentPolicyRevision
        )
        store.settings = AIProviderSettings(
            active: AIProvider.codex.rawValue,
            activeModelID: "gpt-5.4-mini",
            models: [AIProvider.codex.rawValue: "gpt-5.4-mini"],
            consentGrants: [AIProvider.codex.rawValue: malformed]
        )

        store.configureProcessProviders(
            codex: codex,
            claudeCode: ScriptedStoreClaudeProvider(updates: []),
            overlay: overlay
        )
        for _ in 0..<20 { await Task.yield() }

        let calls = await codex.probeCallCount()
        XCTAssertEqual(calls, 0)
    }

    func testConfigureProcessProvidersReconnectsOnlyActiveProviderWithValidScopedConsent() async {
        let codex = ScriptedStoreCodexProvider(updates: [])
        let claude = ScriptedStoreClaudeProvider(updates: [])
        let (store, overlay, defaults) = makeStore(codex: codex, claude: claude)
        defer { clear(defaults) }
        let valid = ScopedAIConsentGrant(
            providerID: AIProvider.claudeCode.rawValue,
            recipientDisclosure: AIProvider.claudeCode.egressDestination,
            consumers: [.ask],
            policyRevision: ScopedAIConsentGrant.currentPolicyRevision
        )
        store.settings = AIProviderSettings(
            active: AIProvider.claudeCode.rawValue,
            activeModelID: AIProvider.claudeCodeDefaultModel,
            models: [
                AIProvider.codex.rawValue: "gpt-5.4-mini",
                AIProvider.claudeCode.rawValue: AIProvider.claudeCodeDefaultModel,
            ],
            consentGrants: [AIProvider.claudeCode.rawValue: valid]
        )

        store.configureProcessProviders(
            codex: codex,
            claudeCode: claude,
            overlay: overlay
        )
        for _ in 0..<20 { await Task.yield() }

        let codexCalls = await codex.probeCallCount()
        let claudeCalls = await claude.probeCallCount()
        XCTAssertEqual(codexCalls, 0)
        XCTAssertEqual(claudeCalls, 1)
    }

    func testCodexProbePublishesCatalogAndOverlayWithoutMutatingSelectionOrConsent() async throws {
        let adapter = StoreCountingAdapter(providerID: AIProvider.codex.rawValue)
        let codex = ScriptedStoreCodexProvider(updates: [
            CodexConnectionUpdate(
                state: .authenticated(
                    version: CodexBinaryPolicy.allowedVersion,
                    models: ["gpt-5.4-mini", "gpt-5.4"]
                ),
                registration: LLMAdapterRegistration(
                    providerID: AIProvider.codex.rawValue,
                    executedLocally: false,
                    adapter: adapter
                )
            ),
        ])
        let (store, overlay, defaults) = makeStore(codex: codex)
        defer { clear(defaults) }
        let before = store.settings

        await store.connect(.codex)

        XCTAssertEqual(store.settings, before)
        XCTAssertFalse(store.hasConsent(.codex))
        XCTAssertEqual(
            store.codexConnection,
            .authenticated(
                version: CodexBinaryPolicy.allowedVersion,
                models: ["gpt-5.4-mini", "gpt-5.4"]
            )
        )
        XCTAssertEqual(
            store.catalogState(.codex),
            .authoritative(["gpt-5.4-mini", "gpt-5.4"])
        )
        XCTAssertEqual(store.status(.codex), .connected(2))
        let registration = await overlay.registration(for: AIProvider.codex.rawValue)
        let generationCalls = await adapter.generateCallCount()
        XCTAssertEqual(registration?.providerID, AIProvider.codex.rawValue)
        XCTAssertEqual(generationCalls, 0)
    }

    func testForcedCodexRefreshDrainsOlderProbeBeforeUntrustedResultRemovesStaleOverlay() async {
        let adapter = StoreCountingAdapter(providerID: AIProvider.codex.rawValue)
        let codex = GatedStoreCodexProvider(
            delayed: CodexConnectionUpdate(
                state: .authenticated(
                    version: CodexBinaryPolicy.allowedVersion,
                    models: ["stale-model"]
                ),
                registration: LLMAdapterRegistration(
                    providerID: AIProvider.codex.rawValue,
                    executedLocally: false,
                    adapter: adapter
                )
            ),
            immediate: CodexConnectionUpdate(state: .untrusted, registration: nil)
        )
        let (store, overlay, defaults) = makeStore(codex: codex)
        defer { clear(defaults) }

        let stale = Task { @MainActor in await store.connect(.codex) }
        await codex.waitUntilFirstProbeEntered()
        let refresh = Task { @MainActor in await store.connect(.codex) }
        for _ in 0..<10 { await Task.yield() }

        let callsBeforeDrain = await codex.probeCallCount()
        XCTAssertEqual(
            callsBeforeDrain,
            1,
            "forced refresh must cancel and await the current App Server probe before replacing it"
        )

        await codex.releaseFirstProbe()
        await stale.value
        await refresh.value

        let finalCallCount = await codex.probeCallCount()
        XCTAssertEqual(finalCallCount, 2)
        XCTAssertEqual(store.codexConnection, .untrusted)
        XCTAssertEqual(store.catalogState(.codex), .unavailable)
        let registration = await overlay.registration(for: AIProvider.codex.rawValue)
        let generationCalls = await adapter.generateCallCount()
        XCTAssertNil(registration)
        XCTAssertEqual(generationCalls, 0)
    }

    func testConcurrentNonForcedCodexProbesCoalesceOneUnderlyingProbe() async {
        let codex = GatedStoreCodexProvider(
            delayed: CodexConnectionUpdate(state: .missing, registration: nil),
            immediate: CodexConnectionUpdate(state: .untrusted, registration: nil)
        )
        let (store, _, defaults) = makeStore(codex: codex)
        defer { clear(defaults) }

        let first = Task { @MainActor in await store.probeCodex() }
        await codex.waitUntilFirstProbeEntered()
        let coalesced = Task { @MainActor in await store.probeCodex() }
        for _ in 0..<10 { await Task.yield() }

        let callsBeforeDrain = await codex.probeCallCount()
        XCTAssertEqual(
            callsBeforeDrain,
            1,
            "all callers must share or drain the one in-flight App Server probe"
        )

        await codex.releaseFirstProbe()
        await first.value
        await coalesced.value

        let finalCallCount = await codex.probeCallCount()
        XCTAssertEqual(finalCallCount, 1)
        XCTAssertEqual(store.codexConnection, .missing)
        XCTAssertEqual(store.catalogState(.codex), .unavailable)
    }

    func testClaudeCuratedCatalogRegistersOnlyAfterExactAuthentication() async throws {
        let adapter = StoreCountingAdapter(providerID: AIProvider.claudeCode.rawValue)
        let claude = ScriptedStoreClaudeProvider(updates: [
            ClaudeCodeConnectionUpdate(
                state: .authenticated(
                    version: ClaudeCodeSecurityPolicy.allowedVersion,
                    executablePath: "/trusted/claude"
                ),
                registration: LLMAdapterRegistration(
                    providerID: AIProvider.claudeCode.rawValue,
                    executedLocally: false,
                    adapter: adapter
                )
            ),
            ClaudeCodeConnectionUpdate(state: .untrusted, registration: nil),
        ])
        let (store, overlay, defaults) = makeStore(claude: claude)
        defer { clear(defaults) }
        let before = store.settings

        await store.connect(.claudeCode)

        XCTAssertEqual(store.settings, before)
        XCTAssertEqual(store.claudeCode, .found("/trusted/claude"))
        XCTAssertEqual(store.catalogState(.claudeCode), .notLoaded)
        XCTAssertEqual(store.availableModels(for: .claudeCode), AIProvider.claudeCodeModels)
        let authenticatedRegistration = await overlay.registration(for: AIProvider.claudeCode.rawValue)
        let authenticatedGenerationCalls = await adapter.generateCallCount()
        XCTAssertNotNil(authenticatedRegistration)
        XCTAssertEqual(authenticatedGenerationCalls, 0)

        await store.connect(.claudeCode)

        let rejectedRegistration = await overlay.registration(for: AIProvider.claudeCode.rawValue)
        let rejectedGenerationCalls = await adapter.generateCallCount()
        XCTAssertNil(rejectedRegistration)
        XCTAssertEqual(store.catalogState(.claudeCode), .unavailable)
        XCTAssertEqual(rejectedGenerationCalls, 0)
    }

    func testCancelledCodexProbePreservesLastKnownGoodStateAndOverlay() async throws {
        let adapter = StoreCountingAdapter(providerID: AIProvider.codex.rawValue)
        let authenticated = CodexConnectionUpdate(
            state: .authenticated(
                version: CodexBinaryPolicy.allowedVersion,
                models: ["gpt-5.4-mini"]
            ),
            registration: LLMAdapterRegistration(
                providerID: AIProvider.codex.rawValue,
                executedLocally: false,
                adapter: adapter
            )
        )
        let codex = GatedSecondStoreCodexProvider(
            initial: authenticated,
            delayed: CodexConnectionUpdate(
                state: .error("Codex connection failed."),
                registration: nil
            )
        )
        let (store, overlay, defaults) = makeStore(codex: codex)
        defer { clear(defaults) }
        await store.probeCodex(force: true)
        let initialRegistration = await overlay.registration(
            for: AIProvider.codex.rawValue
        )
        XCTAssertNotNil(initialRegistration)

        let cancelled = Task { @MainActor in
            await store.probeCodex(force: true)
        }
        await codex.waitUntilSecondProbeEntered()
        let registrationDuringProbe = await overlay.registration(
            for: AIProvider.codex.rawValue
        )
        XCTAssertEqual(store.codexConnection, authenticated.state)
        XCTAssertEqual(
            store.catalogState(.codex),
            .authoritative(["gpt-5.4-mini"])
        )
        XCTAssertNotNil(
            registrationDuringProbe,
            "a refresh must not tear down the last-known-good adapter before it commits"
        )
        cancelled.cancel()
        await codex.releaseSecondProbe()
        await cancelled.value

        XCTAssertEqual(store.codexConnection, authenticated.state)
        XCTAssertEqual(
            store.catalogState(.codex),
            .authoritative(["gpt-5.4-mini"])
        )
        XCTAssertEqual(store.status(.codex), .connected(1))
        let finalRegistration = await overlay.registration(
            for: AIProvider.codex.rawValue
        )
        XCTAssertNotNil(finalRegistration)
    }

    func testCancellationDuringCodexClientSwapPublishesTheLiveReplacement() async throws {
        let previous = SwapGatedCodexClient(
            modelID: "previous-model",
            response: "previous",
            gatesShutdown: true
        )
        let replacement = SwapGatedCodexClient(
            modelID: "replacement-model",
            response: "replacement",
            gatesShutdown: false
        )
        let factory = StoreSequencedCodexClientFactory(
            clients: [previous, replacement]
        )
        let connection = CodexProviderConnection(clientFactory: { factory.make() })
        let (store, overlay, defaults) = makeStore(codex: connection)
        defer { clear(defaults) }
        await store.probeCodex(force: true)

        let refresh = Task { @MainActor in
            await store.probeCodex(force: true)
        }
        await previous.waitUntilShutdownEntered()
        refresh.cancel()
        await previous.releaseShutdown()
        await refresh.value

        XCTAssertEqual(
            store.codexConnection,
            .authenticated(
                version: CodexBinaryPolicy.allowedVersion,
                models: ["replacement-model"]
            )
        )
        XCTAssertEqual(
            store.catalogState(.codex),
            .authoritative(["replacement-model"])
        )
        let currentRegistration = await overlay.registration(
            for: AIProvider.codex.rawValue
        )
        let registration = try XCTUnwrap(currentRegistration)
        let response = try await registration.adapter.generate(
            request: LLMRequest(
                id: UUID(),
                consumer: .ask,
                priority: .ask,
                systemPrompt: "system",
                userPrompt: "prompt",
                maximumOutputTokens: 16,
                timeout: .seconds(1)
            ),
            selection: ProviderSelectionSnapshot(
                providerID: AIProvider.codex.rawValue,
                modelID: "replacement-model",
                selectionRevision: .zero,
                authorizationEpoch: .zero
            )
        )
        XCTAssertEqual(response.content, "replacement")
        let previousShutdowns = await previous.shutdownCallCount()
        let replacementShutdowns = await replacement.shutdownCallCount()
        XCTAssertEqual(previousShutdowns, 1)
        XCTAssertEqual(replacementShutdowns, 0)
    }

    func testCancelledClaudeProbePreservesLastKnownGoodStateAndOverlay() async throws {
        let adapter = StoreCountingAdapter(providerID: AIProvider.claudeCode.rawValue)
        let authenticated = ClaudeCodeConnectionUpdate(
            state: .authenticated(
                version: ClaudeCodeSecurityPolicy.allowedVersion,
                executablePath: "/trusted/claude"
            ),
            registration: LLMAdapterRegistration(
                providerID: AIProvider.claudeCode.rawValue,
                executedLocally: false,
                adapter: adapter
            )
        )
        let claude = GatedSecondStoreClaudeProvider(
            initial: authenticated,
            delayed: ClaudeCodeConnectionUpdate(
                state: .error("Claude Code connection failed."),
                registration: nil
            )
        )
        let (store, overlay, defaults) = makeStore(claude: claude)
        defer { clear(defaults) }
        await store.probeClaudeCode(force: true)
        let initialRegistration = await overlay.registration(
            for: AIProvider.claudeCode.rawValue
        )
        XCTAssertNotNil(initialRegistration)

        let cancelled = Task { @MainActor in
            await store.probeClaudeCode(force: true)
        }
        await claude.waitUntilSecondProbeEntered()
        let registrationDuringProbe = await overlay.registration(
            for: AIProvider.claudeCode.rawValue
        )
        XCTAssertEqual(store.claudeCode, .found("/trusted/claude"))
        XCTAssertEqual(store.catalogState(.claudeCode), .notLoaded)
        XCTAssertNotNil(
            registrationDuringProbe,
            "a refresh must not tear down the last-known-good adapter before it commits"
        )
        cancelled.cancel()
        await claude.releaseSecondProbe()
        await cancelled.value

        XCTAssertEqual(store.claudeCode, .found("/trusted/claude"))
        XCTAssertEqual(store.catalogState(.claudeCode), .notLoaded)
        XCTAssertEqual(
            store.status(.claudeCode),
            .connected(AIProvider.claudeCodeModels.count)
        )
        let finalRegistration = await overlay.registration(
            for: AIProvider.claudeCode.rawValue
        )
        XCTAssertNotNil(finalRegistration)
    }

    func testCancelledNewestForcedCodexRefreshDoesNotStartReplacementAfterDrain() async {
        let adapter = StoreCountingAdapter(providerID: AIProvider.codex.rawValue)
        let authenticated = CodexConnectionUpdate(
            state: .authenticated(
                version: CodexBinaryPolicy.allowedVersion,
                models: ["gpt-5.4-mini"]
            ),
            registration: LLMAdapterRegistration(
                providerID: AIProvider.codex.rawValue,
                executedLocally: false,
                adapter: adapter
            )
        )
        let codex = GatedSecondStoreCodexProvider(
            initial: authenticated,
            delayed: CodexConnectionUpdate(
                state: .error("Codex connection failed."),
                registration: nil
            )
        )
        let (store, overlay, defaults) = makeStore(codex: codex)
        defer { clear(defaults) }
        await store.probeCodex(force: true)

        let older = Task { @MainActor in await store.probeCodex(force: true) }
        await codex.waitUntilProbeCount(2)
        let newer = Task { @MainActor in await store.probeCodex(force: true) }
        for _ in 0..<10 { await Task.yield() }
        let callsBeforeDrain = await codex.probeCallCount()
        XCTAssertEqual(
            callsBeforeDrain,
            2,
            "the replacement probe must not start before the cancelled probe drains"
        )
        newer.cancel()
        await codex.releaseSecondProbe()
        await newer.value
        await older.value

        let finalCallCount = await codex.probeCallCount()
        XCTAssertEqual(finalCallCount, 2)
        XCTAssertEqual(store.codexConnection, authenticated.state)
        XCTAssertEqual(store.status(.codex), .connected(1))
        XCTAssertEqual(
            store.catalogState(.codex),
            .authoritative(["gpt-5.4-mini"])
        )
        let registration = await overlay.registration(for: AIProvider.codex.rawValue)
        XCTAssertNotNil(registration)
    }

    func testCancelledNewerClaudeRefreshRestoresCommittedStateNotOlderProbeState() async {
        let adapter = StoreCountingAdapter(providerID: AIProvider.claudeCode.rawValue)
        let authenticated = ClaudeCodeConnectionUpdate(
            state: .authenticated(
                version: ClaudeCodeSecurityPolicy.allowedVersion,
                executablePath: "/trusted/claude"
            ),
            registration: LLMAdapterRegistration(
                providerID: AIProvider.claudeCode.rawValue,
                executedLocally: false,
                adapter: adapter
            )
        )
        let claude = GatedSecondStoreClaudeProvider(
            initial: authenticated,
            delayed: ClaudeCodeConnectionUpdate(
                state: .error("Claude Code connection failed."),
                registration: nil
            )
        )
        let (store, overlay, defaults) = makeStore(claude: claude)
        defer { clear(defaults) }
        await store.probeClaudeCode(force: true)

        let older = Task { @MainActor in await store.probeClaudeCode(force: true) }
        await claude.waitUntilProbeCount(2)
        let newer = Task { @MainActor in await store.probeClaudeCode(force: true) }
        await claude.waitUntilProbeCount(3)
        newer.cancel()
        await claude.releaseSecondProbe()
        await newer.value
        await older.value

        XCTAssertEqual(store.claudeCode, .found("/trusted/claude"))
        XCTAssertEqual(
            store.status(.claudeCode),
            .connected(AIProvider.claudeCodeModels.count)
        )
        XCTAssertEqual(store.catalogState(.claudeCode), .notLoaded)
        let registration = await overlay.registration(
            for: AIProvider.claudeCode.rawValue
        )
        XCTAssertNotNil(registration)
    }

    func testRevokingConsentStopsRouterBeforeRegisteredCodexAdapterSeesPrompt() async throws {
        let adapter = StoreCountingAdapter(providerID: AIProvider.codex.rawValue)
        let codex = ScriptedStoreCodexProvider(updates: [
            CodexConnectionUpdate(
                state: .authenticated(
                    version: CodexBinaryPolicy.allowedVersion,
                    models: ["gpt-5.4-mini"]
                ),
                registration: LLMAdapterRegistration(
                    providerID: AIProvider.codex.rawValue,
                    executedLocally: false,
                    adapter: adapter
                )
            ),
        ])
        let (store, overlay, defaults) = makeStore(codex: codex)
        defer { clear(defaults) }
        await store.connect(.codex)
        let intent = try XCTUnwrap(
            store.activationIntent(for: .codex, modelID: "gpt-5.4-mini")
        )
        XCTAssertTrue(store.commitActivation(intent, grantCloudConsent: true))
        XCTAssertTrue(store.hasConsent(.codex, for: .ask))
        let router = LLMRouter(snapshotProvider: store, adapterRegistry: overlay)

        store.revokeConsent(.codex)

        do {
            _ = try await router.generate(LLMRequest(
                id: UUID(),
                consumer: .ask,
                priority: .ask,
                systemPrompt: "system",
                userPrompt: "HISTORY-CANARY",
                maximumOutputTokens: 64,
                timeout: .seconds(2)
            ))
            XCTFail("revoked consent must fail before adapter dispatch")
        } catch {
            XCTAssertEqual(error as? LLMRouterError, .noAuthorizedSelection)
        }
        let generationCalls = await adapter.generateCallCount()
        XCTAssertEqual(generationCalls, 0)
    }

    func testBackgroundConsumersRequireSeparateNamedConsent() {
        let provider = AIProvider.anthropic
        let (store, _, defaults) = makeStore()
        defer { clear(defaults) }
        let interactiveConsumers = AISetupOrigin.settings.consentConsumers
        let grant = ScopedAIConsentGrant(
            providerID: provider.rawValue,
            recipientDisclosure: provider.egressDestination,
            consumers: interactiveConsumers,
            policyRevision: ScopedAIConsentGrant.currentPolicyRevision
        )
        store.settings = AIProviderSettings(
            active: provider.rawValue,
            activeModelID: "claude-haiku-4-5-20251001",
            models: [provider.rawValue: "claude-haiku-4-5-20251001"],
            consentGrants: [provider.rawValue: grant]
        )

        XCTAssertFalse(store.hasConsent(provider, for: .scheduledSummary))
        XCTAssertFalse(store.hasConsent(provider, for: .generatedLabels))
        XCTAssertTrue(store.setAutomaticConsumerConsent(
            .scheduledSummary,
            enabled: true,
            for: provider
        ))
        XCTAssertTrue(store.hasConsent(provider, for: .scheduledSummary))
        XCTAssertFalse(store.hasConsent(provider, for: .generatedLabels))
        XCTAssertTrue(store.setAutomaticConsumerConsent(
            .scheduledSummary,
            enabled: false,
            for: provider
        ))
        XCTAssertFalse(store.hasConsent(provider, for: .scheduledSummary))
    }

    func testSelectionAndAuthorizationMutationsNotifyRouterOncePerSettingsCommit() async throws {
        let catalog = ScriptedStoreCatalogClient(results: [
            .authoritative(["local-model"]),
        ])
        let (store, _, defaults) = makeStore(catalogClient: catalog)
        defer { clear(defaults) }
        let notifications = StoreRoutingChangeRecorder()
        store.configureRouterChangeNotification {
            await notifications.record()
        }

        store.setEndpoint("http://127.0.0.1:18080/v1", for: .custom)
        store.setModel("local-model", for: .custom)
        await store.connect(.custom)
        for _ in 0..<10 { await Task.yield() }
        let countBeforeRoutingMutation = await notifications.value()
        XCTAssertEqual(countBeforeRoutingMutation, 0)

        let intent = try XCTUnwrap(
            store.activationIntent(for: .custom, modelID: "local-model")
        )
        XCTAssertTrue(store.commitActivation(intent))
        let activationNotified = await notifications.waitUntilCount(1)
        XCTAssertTrue(activationNotified)

        store.setEndpoint("http://127.0.0.1:18081/v1", for: .custom)
        let authorizationNotified = await notifications.waitUntilCount(2)
        XCTAssertTrue(authorizationNotified)

        store.deactivate()
        let deactivationNotified = await notifications.waitUntilCount(3)
        XCTAssertTrue(deactivationNotified)
        let finalCount = await notifications.value()
        XCTAssertEqual(finalCount, 3)
    }

    func testCodexAuthorizationCommitNotifiesRouterAfterOverlayUpdate() async {
        let adapter = StoreCountingAdapter(providerID: AIProvider.codex.rawValue)
        let codex = ScriptedStoreCodexProvider(updates: [
            CodexConnectionUpdate(
                state: .authenticated(
                    version: CodexBinaryPolicy.allowedVersion,
                    models: ["gpt-5.4-mini"]
                ),
                registration: LLMAdapterRegistration(
                    providerID: AIProvider.codex.rawValue,
                    executedLocally: false,
                    adapter: adapter
                )
            ),
            CodexConnectionUpdate(state: .untrusted, registration: nil),
        ])
        let (store, overlay, defaults) = makeStore(codex: codex)
        defer { clear(defaults) }
        let notifications = StoreRoutingChangeRecorder()
        store.configureRouterChangeNotification {
            let registered = await overlay.registration(
                for: AIProvider.codex.rawValue
            ) != nil
            await notifications.record(overlayRegistered: registered)
        }

        await store.connect(.codex)
        let authenticatedNotified = await notifications.waitUntilCount(1)
        let authenticatedOverlayStates = await notifications.overlayStates()
        XCTAssertTrue(authenticatedNotified)
        XCTAssertEqual(authenticatedOverlayStates, [true])

        await store.connect(.codex)
        let rejectedNotified = await notifications.waitUntilCount(2)
        let rejectedOverlayStates = await notifications.overlayStates()
        XCTAssertTrue(rejectedNotified)
        XCTAssertEqual(rejectedOverlayStates, [true, false])
    }

    func testCancelledHTTPProbeRestoresPreviousStatusAndPublishesNoCatalog() async {
        let catalog = GatedStoreCatalogClient(
            delayed: .authoritative(["cancelled-model"]),
            immediate: .authoritative([])
        )
        let (store, _, defaults) = makeStore(catalogClient: catalog)
        defer { clear(defaults) }
        store.setEndpoint("http://127.0.0.1:18080/v1", for: .custom)

        let probe = Task { @MainActor in await store.connect(.custom) }
        await catalog.waitUntilFirstLoadEntered()
        probe.cancel()
        await catalog.releaseFirstLoad()
        await probe.value

        XCTAssertEqual(store.status(.custom), .notConfigured)
        XCTAssertEqual(store.catalogState(.custom), .notLoaded)
        XCTAssertTrue(store.availableModels(for: .custom).isEmpty)
    }

    func testEndpointChangeMakesOlderHTTPProbeUnableToOverwriteNewCatalog() async {
        let catalog = GatedStoreCatalogClient(
            delayed: .authoritative(["stale-model"]),
            immediate: .authoritative(["new-model"])
        )
        let (store, _, defaults) = makeStore(catalogClient: catalog)
        defer { clear(defaults) }
        store.setEndpoint("http://127.0.0.1:18080/v1", for: .custom)

        let staleProbe = Task { @MainActor in await store.connect(.custom) }
        await catalog.waitUntilFirstLoadEntered()
        store.setEndpoint("http://127.0.0.1:18081/v1", for: .custom)
        await store.connect(.custom)
        await catalog.releaseFirstLoad()
        await staleProbe.value

        XCTAssertEqual(store.status(.custom), .connected(1))
        XCTAssertEqual(store.catalogState(.custom), .authoritative(["new-model"]))
        XCTAssertEqual(store.availableModels(for: .custom), ["new-model"])
    }

    func testEndpointChangeMakesOlderAutomaticLocalProbeUnableToRestoreStaleCatalog() async {
        let catalog = GatedStoreCatalogClient(
            delayed: .authoritative(["stale-model"]),
            immediate: .authoritative([])
        )
        let (store, _, defaults) = makeStore(catalogClient: catalog)
        defer { clear(defaults) }
        store.setEndpoint("http://127.0.0.1:18080/v1", for: .lmstudio)

        let staleProbe = Task { @MainActor in await store.autoProbeLocal() }
        await catalog.waitUntilFirstLoadEntered()
        store.setEndpoint("http://127.0.0.1:18081/v1", for: .lmstudio)
        await catalog.releaseFirstLoad()
        await staleProbe.value

        XCTAssertEqual(store.status(.lmstudio), .notConfigured)
        XCTAssertEqual(store.catalogState(.lmstudio), .notLoaded)
        XCTAssertTrue(store.availableModels(for: .lmstudio).isEmpty)
    }

    func testAutomaticLocalDiscoveryStartsEveryProviderProbeConcurrently() async {
        let catalog = ConcurrentStoreCatalogClient()
        let (store, _, defaults) = makeStore(catalogClient: catalog)
        defer { clear(defaults) }
        store.setEndpoint("http://127.0.0.1:18080/v1", for: .lmstudio)
        store.setEndpoint("http://127.0.0.1:18081/v1", for: .ollama)
        store.setEndpoint("http://127.0.0.1:18082/v1", for: .custom)

        let probe = Task { @MainActor in await store.autoProbeLocal() }
        await catalog.waitUntilLoadCount(1)
        for _ in 0..<20 { await Task.yield() }
        let enteredBeforeRelease = await catalog.enteredProviderIDs()
        await catalog.releaseAll()
        await probe.value

        XCTAssertEqual(
            Set(enteredBeforeRelease),
            Set(["lmstudio", "ollama", "custom"])
        )
    }

    func testReplacingAPIKeyInvalidatesProbeStartedWithPreviousCredential() async {
        let catalog = GatedStoreCatalogClient(
            delayed: .authoritative(["stale-model"]),
            immediate: .authoritative([])
        )
        let credentials = StoreCredentialStore(values: [
            "llm.anthropic": "old-key",
        ])
        let (store, _, defaults) = makeStore(
            catalogClient: catalog,
            storedKeyExists: { $0 == .anthropic },
            credentialStore: credentials
        )
        defer { clear(defaults) }

        let staleProbe = Task { @MainActor in await store.connect(.anthropic) }
        await catalog.waitUntilFirstLoadEntered()
        let saved = store.saveKey("new-key", for: .anthropic, connectAfterSave: false)
        await catalog.releaseFirstLoad()
        await staleProbe.value

        XCTAssertTrue(saved)
        XCTAssertEqual(credentials.get("llm.anthropic"), "new-key")
        XCTAssertEqual(store.status(.anthropic), .notConfigured)
        XCTAssertEqual(store.catalogState(.anthropic), .notLoaded)
        XCTAssertTrue(store.availableModels(for: .anthropic).isEmpty)
    }

    func testFailedKeyReplacementKeepsOldKeyButDurablyRevokesAuthorizationAcrossRestart() throws {
        let provider = AIProvider.anthropic
        let account = try XCTUnwrap(provider.keychainAccount)
        let credentials = StoreCredentialStore(
            values: [account: "old-key"],
            setResult: false
        )
        let name = "AIProviderProcessStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AIProviderStore(
            defaults: defaults,
            credentialStore: credentials,
            persistenceSynchronizer: { true }
        )
        let grant = ScopedAIConsentGrant(
            providerID: provider.rawValue,
            recipientDisclosure: provider.egressDestination,
            consumers: Set(AIConsumer.allCases),
            policyRevision: ScopedAIConsentGrant.currentPolicyRevision
        )
        let startingEpoch = AuthorizationEpoch(rawValue: 51)
        store.settings = AIProviderSettings(
            active: provider.rawValue,
            activeModelID: "claude-haiku-4-5-20251001",
            models: [provider.rawValue: "claude-haiku-4-5-20251001"],
            authorizationEpoch: startingEpoch,
            consentGrants: [provider.rawValue: grant]
        )
        XCTAssertNotNil(store.activeConfig)

        let saved = store.saveKey("new-key", for: provider, connectAfterSave: false)

        XCTAssertFalse(saved, "the view must keep the pasted key visible after a failed save")
        XCTAssertEqual(credentials.setCalls, 1)
        XCTAssertEqual(credentials.get(account), "old-key")
        XCTAssertTrue(store.hasKey(provider))
        XCTAssertFalse(store.hasConsent(provider, for: .ask))
        XCTAssertNil(store.activeConfig)
        XCTAssertEqual(
            store.settings.authorizationEpoch,
            AuthorizationEpoch(rawValue: startingEpoch.rawValue + 1)
        )
        XCTAssertEqual(
            store.status(provider),
            .error("Couldn't replace the API key in the Keychain. The previous key was kept, and access was revoked. Try again.")
        )

        let restarted = AIProviderStore(
            defaults: defaults,
            credentialStore: credentials,
            persistenceSynchronizer: { true }
        )
        XCTAssertTrue(restarted.hasKey(provider))
        XCTAssertFalse(restarted.hasConsent(provider, for: .ask))
        XCTAssertNil(restarted.activeConfig)
    }

    func testFailedKeyReplacementPausesRuntimeWhenRevocationAcknowledgementFails() throws {
        let provider = AIProvider.anthropic
        let account = try XCTUnwrap(provider.keychainAccount)
        let credentials = StoreCredentialStore(
            values: [account: "old-key"],
            setResult: false
        )
        let name = "AIProviderProcessStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        var acknowledgementCalls = 0
        let store = AIProviderStore(
            defaults: defaults,
            credentialStore: credentials,
            persistenceSynchronizer: {
                acknowledgementCalls += 1
                return false
            }
        )
        let grant = ScopedAIConsentGrant(
            providerID: provider.rawValue,
            recipientDisclosure: provider.egressDestination,
            consumers: Set(AIConsumer.allCases),
            policyRevision: ScopedAIConsentGrant.currentPolicyRevision
        )
        store.settings = AIProviderSettings(
            active: provider.rawValue,
            activeModelID: "claude-haiku-4-5-20251001",
            models: [provider.rawValue: "claude-haiku-4-5-20251001"],
            consentGrants: [provider.rawValue: grant]
        )
        XCTAssertNotNil(store.activeConfig)

        store.saveKey("new-key", for: provider, connectAfterSave: false)

        XCTAssertEqual(credentials.setCalls, 1)
        XCTAssertEqual(acknowledgementCalls, 1)
        XCTAssertEqual(credentials.get(account), "old-key")
        XCTAssertTrue(store.hasKey(provider))
        XCTAssertFalse(store.hasConsent(provider, for: .ask))
        XCTAssertNil(store.activeConfig)
        XCTAssertEqual(
            store.status(provider),
            .error("Couldn't save the access revocation. The previous API key was kept; processing is paused. Try again.")
        )
    }

    func testFailedKeyDeletionRevokesPersistedAuthorizationBeforeAttemptAndStaysFailClosedAfterRestart() throws {
        let provider = AIProvider.anthropic
        let account = try XCTUnwrap(provider.keychainAccount)
        let credentials = StoreCredentialStore(
            values: [account: "retained-key"],
            deletionResult: false
        )
        let name = "AIProviderProcessStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AIProviderStore(
            defaults: defaults,
            credentialStore: credentials
        )
        let grant = ScopedAIConsentGrant(
            providerID: provider.rawValue,
            recipientDisclosure: provider.egressDestination,
            consumers: Set(AIConsumer.allCases),
            policyRevision: ScopedAIConsentGrant.currentPolicyRevision
        )
        let startingEpoch = AuthorizationEpoch(rawValue: 41)
        store.settings = AIProviderSettings(
            active: provider.rawValue,
            activeModelID: "claude-haiku-4-5-20251001",
            models: [provider.rawValue: "claude-haiku-4-5-20251001"],
            authorizationEpoch: startingEpoch,
            consentGrants: [provider.rawValue: grant]
        )
        XCTAssertNotNil(store.activeConfig)

        var persistedAtDeletion: AIProviderSettings?
        credentials.onDelete = {
            guard let data = defaults.data(forKey: "zbseye.ai.provider") else { return }
            persistedAtDeletion = try? JSONDecoder().decode(AIProviderSettings.self, from: data)
        }

        store.removeKey(for: provider)

        XCTAssertNil(persistedAtDeletion?.consentGrant(forProviderID: provider.rawValue))
        XCTAssertEqual(
            persistedAtDeletion?.authorizationEpoch,
            AuthorizationEpoch(rawValue: startingEpoch.rawValue + 1)
        )
        XCTAssertNotNil(credentials.get(account), "a failed deletion retains the real credential")
        XCTAssertTrue(store.hasKey(provider), "absence is not proven after a Keychain error")
        XCTAssertFalse(store.hasConsent(provider, for: .ask))
        XCTAssertNil(store.activeConfig)
        XCTAssertEqual(
            store.status(provider),
            .error("Couldn't remove the API key from the Keychain. Access was revoked; try again.")
        )

        let restarted = AIProviderStore(
            defaults: defaults,
            credentialStore: credentials
        )
        XCTAssertTrue(restarted.hasKey(provider))
        XCTAssertFalse(restarted.hasConsent(provider, for: .ask))
        XCTAssertNil(restarted.activeConfig)
    }

    func testKeyDeletionWaitsForDurableRevocationAndStillPausesRuntimeOnPersistenceFailure() throws {
        let provider = AIProvider.anthropic
        let account = try XCTUnwrap(provider.keychainAccount)
        let credentials = StoreCredentialStore(values: [account: "retained-key"])
        let name = "AIProviderProcessStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AIProviderStore(
            defaults: defaults,
            credentialStore: credentials,
            persistenceSynchronizer: { false }
        )
        let grant = ScopedAIConsentGrant(
            providerID: provider.rawValue,
            recipientDisclosure: provider.egressDestination,
            consumers: Set(AIConsumer.allCases),
            policyRevision: ScopedAIConsentGrant.currentPolicyRevision
        )
        store.settings = AIProviderSettings(
            active: provider.rawValue,
            activeModelID: "claude-haiku-4-5-20251001",
            models: [provider.rawValue: "claude-haiku-4-5-20251001"],
            consentGrants: [provider.rawValue: grant]
        )
        XCTAssertNotNil(store.activeConfig)

        store.removeKey(for: provider)

        XCTAssertEqual(credentials.deleteCalls, 0)
        XCTAssertEqual(credentials.get(account), "retained-key")
        XCTAssertTrue(store.hasKey(provider))
        XCTAssertFalse(store.hasConsent(provider, for: .ask))
        XCTAssertNil(store.activeConfig)
        XCTAssertEqual(
            store.status(provider),
            .error("Couldn't save the access revocation. The API key was not deleted; processing is paused. Try again.")
        )
    }

    func testAuthoritativeEmptyAnthropicCatalogDoesNotExposeFallbackOrSavedPreference() async {
        let catalog = ScriptedStoreCatalogClient(results: [.authoritative([])])
        let (store, _, defaults) = makeStore(
            catalogClient: catalog,
            storedKeyExists: { $0 == .anthropic }
        )
        defer { clear(defaults) }
        store.setModel("claude-haiku-4-5-20251001", for: .anthropic)

        await store.connect(.anthropic)

        XCTAssertEqual(store.status(.anthropic), .connected(0))
        XCTAssertEqual(store.catalogState(.anthropic), .authoritative([]))
        XCTAssertTrue(store.fetchedModels(.anthropic).isEmpty)
        XCTAssertTrue(store.availableModels(for: .anthropic).isEmpty)
        XCTAssertEqual(
            store.selectionAvailability(.anthropic),
            .missingFromAuthoritativeCatalog
        )
        XCTAssertNil(store.activationIntent(
            for: .anthropic,
            modelID: "claude-haiku-4-5-20251001"
        ))
    }

    func testAuthoritativeEmptyLocalCatalogDoesNotTurnManualPreferenceIntoAuthority() async {
        let catalog = ScriptedStoreCatalogClient(results: [.authoritative([])])
        let (store, _, defaults) = makeStore(catalogClient: catalog)
        defer { clear(defaults) }
        store.setEndpoint("http://127.0.0.1:18080/v1", for: .custom)
        store.setModel("manually-typed-model", for: .custom)

        await store.connect(.custom)

        XCTAssertEqual(store.status(.custom), .connected(0))
        XCTAssertEqual(store.catalogState(.custom), .authoritative([]))
        XCTAssertTrue(store.availableModels(for: .custom).isEmpty)
        XCTAssertEqual(
            store.selectionAvailability(.custom),
            .missingFromAuthoritativeCatalog
        )
        XCTAssertNil(store.activationIntent(
            for: .custom,
            modelID: "manually-typed-model"
        ))
    }

    private func makeStore(
        codex: (any CodexProviderConnecting)? = nil,
        claude: (any ClaudeCodeProviderConnecting)? = nil,
        catalogClient: (any AIProviderCatalogLoading)? = nil,
        storedKeyExists: @escaping (AIProvider) -> Bool = { _ in false },
        credentialStore: (any AIProviderCredentialStoring)? = nil
    ) -> (AIProviderStore, LLMAdapterRegistry, UserDefaults) {
        let name = "AIProviderProcessStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = AIProviderStore(
            defaults: defaults,
            storedKeyExists: storedKeyExists,
            catalogClient: catalogClient,
            credentialStore: credentialStore
        )
        let overlay = LLMAdapterRegistry()
        store.configureProcessProviders(
            codex: codex ?? ScriptedStoreCodexProvider(updates: []),
            claudeCode: claude ?? ScriptedStoreClaudeProvider(updates: []),
            overlay: overlay
        )
        return (store, overlay, defaults)
    }

    private func clear(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
    }
}

private final class StoreCredentialStore: AIProviderCredentialStoring {
    private var values: [String: String]
    private let setResult: Bool
    private let deletionResult: Bool
    private(set) var setCalls = 0
    private(set) var deleteCalls = 0
    var onDelete: (() -> Void)?

    init(
        values: [String: String] = [:],
        setResult: Bool = true,
        deletionResult: Bool = true
    ) {
        self.values = values
        self.setResult = setResult
        self.deletionResult = deletionResult
    }

    func get(_ account: String) -> String? { values[account] }

    func set(_ value: String, account: String) -> Bool {
        setCalls += 1
        guard setResult else { return false }
        values[account] = value
        return true
    }

    func delete(_ account: String) -> Bool {
        deleteCalls += 1
        onDelete?()
        guard deletionResult else { return false }
        values.removeValue(forKey: account)
        return true
    }
}

private actor ScriptedStoreCatalogClient: AIProviderCatalogLoading {
    private var results: [ProviderCatalogState]
    private var calls = 0

    init(results: [ProviderCatalogState]) {
        self.results = results
    }

    func load(
        provider: AIProvider,
        baseURL: URL,
        timeout: Duration
    ) async throws -> ProviderCatalogState {
        calls += 1
        guard !results.isEmpty else { return .authoritative([]) }
        return results.removeFirst()
    }

    func loadCallCount() -> Int { calls }
}

private actor GatedStoreCatalogClient: AIProviderCatalogLoading {
    private let delayed: ProviderCatalogState
    private let immediate: ProviderCatalogState
    private var calls = 0
    private var entered = false
    private var released = false

    init(delayed: ProviderCatalogState, immediate: ProviderCatalogState) {
        self.delayed = delayed
        self.immediate = immediate
    }

    func load(
        provider: AIProvider,
        baseURL: URL,
        timeout: Duration
    ) async throws -> ProviderCatalogState {
        calls += 1
        guard calls == 1 else { return immediate }
        entered = true
        while !released { try? await Task.sleep(for: .milliseconds(1)) }
        return delayed
    }

    func waitUntilFirstLoadEntered() async {
        while !entered { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func releaseFirstLoad() { released = true }
}

private actor ConcurrentStoreCatalogClient: AIProviderCatalogLoading {
    private var entered: [String] = []
    private var released = false

    func load(
        provider: AIProvider,
        baseURL: URL,
        timeout: Duration
    ) async throws -> ProviderCatalogState {
        entered.append(provider.rawValue)
        while !released {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return .authoritative(["local-model"])
    }

    func waitUntilLoadCount(_ count: Int) async {
        while entered.count < count {
            await Task.yield()
        }
    }

    func enteredProviderIDs() -> [String] { entered }
    func releaseAll() { released = true }
}

private actor ScriptedStoreCodexProvider: CodexProviderConnecting {
    private var updates: [CodexConnectionUpdate]
    private var calls = 0
    init(updates: [CodexConnectionUpdate]) { self.updates = updates }
    func probe() async -> CodexConnectionUpdate {
        calls += 1
        guard !updates.isEmpty else {
            return CodexConnectionUpdate(state: .missing, registration: nil)
        }
        return updates.removeFirst()
    }
    func startLogin() async -> CodexConnectionUpdate { await probe() }
    func cancelLogin(loginID: String) async -> CodexConnectionUpdate { await probe() }
    func completeLogin(loginID: String) async -> CodexConnectionUpdate { await probe() }
    func shutdown() async {}
    func probeCallCount() -> Int { calls }
}

private final class StoreSequencedCodexClientFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [any CodexAppServerConnecting]

    init(clients: [any CodexAppServerConnecting]) {
        self.clients = clients
    }

    func make() -> any CodexAppServerConnecting {
        lock.lock()
        defer { lock.unlock() }
        precondition(!clients.isEmpty, "unexpected extra Codex client request")
        return clients.removeFirst()
    }
}

private actor SwapGatedCodexClient: CodexAppServerConnecting {
    private let modelID: String
    private let response: String
    private let gatesShutdown: Bool
    private var shutdowns = 0
    private var shutdownEntered = false
    private var shutdownReleased = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    init(modelID: String, response: String, gatesShutdown: Bool) {
        self.modelID = modelID
        self.response = response
        self.gatesShutdown = gatesShutdown
    }

    func probeConnection(timeout: Duration) async throws -> CodexConnectionState {
        .authenticated(
            version: CodexBinaryPolicy.allowedVersion,
            models: [modelID]
        )
    }

    func startLogin() async throws -> CodexLoginChallenge {
        throw CodexAppServerError.unavailable
    }

    func cancelLogin(loginID: String) async throws {}
    func completeLogin(loginID: String, timeout: Duration) async throws {}

    func shutdown() async {
        shutdowns += 1
        shutdownEntered = true
        guard gatesShutdown, !shutdownReleased else { return }
        await withCheckedContinuation { shutdownWaiters.append($0) }
    }

    func generate(
        request: LLMRequest,
        selection: ProviderSelectionSnapshot
    ) async throws -> LLMResponse {
        guard shutdowns == 0 else { throw CodexAppServerError.unavailable }
        return LLMResponse(
            content: response,
            truncated: false,
            provenance: AIExecutionProvenance(
                providerID: AIProvider.codex.rawValue,
                modelID: selection.modelID,
                executedLocally: false,
                generatedAt: Date(),
                brokerUpstream: nil
            )
        )
    }

    func waitUntilShutdownEntered() async {
        while !shutdownEntered { await Task.yield() }
    }

    func releaseShutdown() {
        shutdownReleased = true
        let pending = shutdownWaiters
        shutdownWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func shutdownCallCount() -> Int { shutdowns }
}

private actor ScriptedStoreClaudeProvider: ClaudeCodeProviderConnecting {
    private var updates: [ClaudeCodeConnectionUpdate]
    private var calls = 0
    init(updates: [ClaudeCodeConnectionUpdate]) { self.updates = updates }
    func probe() async -> ClaudeCodeConnectionUpdate {
        calls += 1
        guard !updates.isEmpty else {
            return ClaudeCodeConnectionUpdate(state: .missing, registration: nil)
        }
        return updates.removeFirst()
    }
    func probeCallCount() -> Int { calls }
}

private actor GatedSecondStoreCodexProvider: CodexProviderConnecting {
    private let initial: CodexConnectionUpdate
    private let delayed: CodexConnectionUpdate
    private var calls = 0
    private var secondEntered = false
    private var secondReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(initial: CodexConnectionUpdate, delayed: CodexConnectionUpdate) {
        self.initial = initial
        self.delayed = delayed
    }

    func probe() async -> CodexConnectionUpdate {
        calls += 1
        let readyCountWaiters = countWaiters.filter { calls >= $0.0 }
        countWaiters.removeAll { calls >= $0.0 }
        readyCountWaiters.forEach { $0.1.resume() }
        guard calls > 1 else { return initial }
        secondEntered = true
        let pendingEntries = entryWaiters
        entryWaiters.removeAll()
        pendingEntries.forEach { $0.resume() }
        if !secondReleased {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return delayed
    }

    func waitUntilSecondProbeEntered() async {
        if secondEntered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func waitUntilProbeCount(_ expected: Int) async {
        if calls >= expected { return }
        await withCheckedContinuation { countWaiters.append((expected, $0)) }
    }

    func probeCallCount() -> Int { calls }

    func releaseSecondProbe() {
        secondReleased = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func startLogin() async -> CodexConnectionUpdate { await probe() }
    func cancelLogin(loginID: String) async -> CodexConnectionUpdate { await probe() }
    func completeLogin(loginID: String) async -> CodexConnectionUpdate { await probe() }
    func shutdown() async {}
}

private actor GatedSecondStoreClaudeProvider: ClaudeCodeProviderConnecting {
    private let initial: ClaudeCodeConnectionUpdate
    private let delayed: ClaudeCodeConnectionUpdate
    private var calls = 0
    private var secondEntered = false
    private var secondReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(initial: ClaudeCodeConnectionUpdate, delayed: ClaudeCodeConnectionUpdate) {
        self.initial = initial
        self.delayed = delayed
    }

    func probe() async -> ClaudeCodeConnectionUpdate {
        calls += 1
        let readyCountWaiters = countWaiters.filter { calls >= $0.0 }
        countWaiters.removeAll { calls >= $0.0 }
        readyCountWaiters.forEach { $0.1.resume() }
        guard calls > 1 else { return initial }
        secondEntered = true
        let pendingEntries = entryWaiters
        entryWaiters.removeAll()
        pendingEntries.forEach { $0.resume() }
        if !secondReleased {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return delayed
    }

    func waitUntilSecondProbeEntered() async {
        if secondEntered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func waitUntilProbeCount(_ expected: Int) async {
        if calls >= expected { return }
        await withCheckedContinuation { countWaiters.append((expected, $0)) }
    }

    func releaseSecondProbe() {
        secondReleased = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor GatedStoreCodexProvider: CodexProviderConnecting {
    private let delayed: CodexConnectionUpdate
    private let immediate: CodexConnectionUpdate
    private var calls = 0
    private var entered = false
    private var released = false

    init(delayed: CodexConnectionUpdate, immediate: CodexConnectionUpdate) {
        self.delayed = delayed
        self.immediate = immediate
    }

    func probe() async -> CodexConnectionUpdate {
        calls += 1
        guard calls == 1 else { return immediate }
        entered = true
        while !released { try? await Task.sleep(for: .milliseconds(1)) }
        return delayed
    }

    func waitUntilFirstProbeEntered() async {
        while !entered { try? await Task.sleep(for: .milliseconds(1)) }
    }
    func probeCallCount() -> Int { calls }
    func releaseFirstProbe() { released = true }
    func startLogin() async -> CodexConnectionUpdate { await probe() }
    func cancelLogin(loginID: String) async -> CodexConnectionUpdate { await probe() }
    func completeLogin(loginID: String) async -> CodexConnectionUpdate { await probe() }
    func shutdown() async {}
}

private actor StoreCountingAdapter: LLMAdapter {
    private let providerID: String
    private var generations = 0
    init(providerID: String) { self.providerID = providerID }
    func generate(
        request: LLMRequest,
        selection: ProviderSelectionSnapshot
    ) async throws -> LLMResponse {
        generations += 1
        return LLMResponse(
            content: "unexpected",
            truncated: false,
            provenance: AIExecutionProvenance(
                providerID: providerID,
                modelID: selection.modelID,
                executedLocally: false,
                generatedAt: Date(),
                brokerUpstream: nil
            )
        )
    }
    func generateCallCount() -> Int { generations }
}

private actor StoreRoutingChangeRecorder {
    private var count = 0
    private var recordedOverlayStates: [Bool] = []

    func record() {
        count += 1
    }

    func record(overlayRegistered: Bool) {
        recordedOverlayStates.append(overlayRegistered)
        count += 1
    }

    func value() -> Int { count }
    func overlayStates() -> [Bool] { recordedOverlayStates }

    func waitUntilCount(_ expected: Int) async -> Bool {
        for _ in 0..<1_000 {
            if count >= expected { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return count >= expected
    }
}
