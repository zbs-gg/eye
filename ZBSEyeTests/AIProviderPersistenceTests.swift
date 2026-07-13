import Foundation
import XCTest

final class AIProviderPersistenceTests: XCTestCase {
    func testUnreadableCurrentPayloadRecoversLastKnownGoodAndPreservesRawRecoveryCopy() throws {
        let unreadable = try fixtureData("ai-settings-unreadable")
        let lastKnownGood = AIProviderSettings(
            active: AIProvider.ollama.rawValue,
            activeModelID: "qwen3:4b",
            models: [AIProvider.ollama.rawValue: "qwen3:4b"],
            selectionRevision: SelectionRevision(rawValue: 6),
            authorizationEpoch: AuthorizationEpoch(rawValue: 8)
        )
        let backupData = try JSONEncoder().encode(lastKnownGood)

        let resolution = AIProviderSettingsArchive.resolve(
            currentData: unreadable,
            lastKnownGoodData: backupData
        )

        XCTAssertEqual(resolution.settings, lastKnownGood)
        XCTAssertEqual(resolution.source, .lastKnownGood)
        XCTAssertEqual(resolution.unreadableCurrentData, unreadable)
    }

    func testUnreadableCurrentWithoutValidBackupStillPreservesRecoveryCopy() throws {
        let unreadable = try fixtureData("ai-settings-unreadable")

        let resolution = AIProviderSettingsArchive.resolve(
            currentData: unreadable,
            lastKnownGoodData: Data("also unreadable".utf8)
        )

        XCTAssertEqual(resolution.settings, AIProviderSettings())
        XCTAssertEqual(resolution.source, .defaults)
        XCTAssertEqual(resolution.unreadableCurrentData, unreadable)
    }

    func testReadableCurrentPayloadBecomesTheLastKnownGoodCandidate() throws {
        let current = AIProviderSettings(
            active: AIProvider.lmstudio.rawValue,
            activeModelID: "local-model",
            models: [AIProvider.lmstudio.rawValue: "local-model"]
        )
        let currentData = try JSONEncoder().encode(current)

        let resolution = AIProviderSettingsArchive.resolve(
            currentData: currentData,
            lastKnownGoodData: Data("stale unreadable backup".utf8)
        )

        XCTAssertEqual(resolution.settings, current)
        XCTAssertEqual(resolution.source, .current)
        XCTAssertNil(resolution.unreadableCurrentData)
    }

    func test020PayloadDefaultsMissingFieldsWithoutLosingSelection() throws {
        let settings = try decodeFixture("ai-settings-0.2.0")

        XCTAssertEqual(settings.active, AIProvider.lmstudio.rawValue)
        XCTAssertEqual(settings.models[AIProvider.lmstudio.rawValue], "qwen2.5-7b-instruct")
        XCTAssertFalse(settings.processingDisabledByUser)
        XCTAssertEqual(settings.selectionRevision, SelectionRevision.zero)
        XCTAssertEqual(settings.authorizationEpoch, AuthorizationEpoch.zero)
    }

    func testLegacyCloudConsentMigratesOnlyPreviouslyShippedConsumers() throws {
        let settings = try decodeFixture("ai-settings-0.2.1-cloud")
        let grant = try XCTUnwrap(settings.consentGrant(forProviderID: AIProvider.openrouter.rawValue))

        XCTAssertEqual(grant.policyRevision, ScopedAIConsentGrant.legacyPolicyRevision)
        XCTAssertEqual(grant.providerID, AIProvider.openrouter.rawValue)
        XCTAssertEqual(grant.recipientDisclosure, AIProvider.openrouter.egressDestination)
        XCTAssertTrue(grant.consumers.contains(.ask))
        XCTAssertTrue(grant.consumers.contains(.dailyInsights))
        XCTAssertTrue(grant.consumers.contains(.manualSummary))
        XCTAssertTrue(grant.consumers.contains(.scheduledSummary))
        XCTAssertFalse(grant.consumers.contains(.generatedLabels))
        XCTAssertTrue(settings.isAuthorized(providerID: AIProvider.openrouter.rawValue, consumer: .ask))
        XCTAssertFalse(settings.isAuthorized(providerID: AIProvider.openrouter.rawValue, consumer: .generatedLabels))
    }

    func testExplicitNoneAndPerProviderChoicesSurviveMigration() throws {
        let settings = try decodeFixture("ai-settings-explicit-none")

        XCTAssertNil(settings.active)
        XCTAssertTrue(settings.processingDisabledByUser)
        XCTAssertEqual(settings.models[AIProvider.ollama.rawValue], "qwen2.5:7b")
        XCTAssertEqual(
            settings.endpoints[AIProvider.ollama.rawValue],
            "http://127.0.0.1:11434/v1"
        )
    }

    func testUnknownFutureProviderConfigurationIsPreservedLosslessly() throws {
        let original = try fixtureData("ai-settings-future-provider")
        let settings = try JSONDecoder().decode(AIProviderSettings.self, from: original)

        XCTAssertEqual(settings.active, "future.provider")
        XCTAssertNil(settings.activeProvider)
        XCTAssertEqual(settings.models["future.provider"], "future-model-v7")
        XCTAssertEqual(settings.endpoints["future.provider"], "https://future.invalid/v1")
        XCTAssertEqual(settings.selectionRevision, SelectionRevision(rawValue: 8))
        XCTAssertEqual(settings.authorizationEpoch, AuthorizationEpoch(rawValue: 13))
        XCTAssertFalse(settings.isAuthorized(providerID: "future.provider", consumer: .ask))

        let roundTrip = try JSONDecoder().decode(
            AIProviderSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(roundTrip.active, "future.provider")
        XCTAssertEqual(roundTrip.models["future.provider"], "future-model-v7")
        XCTAssertEqual(roundTrip.endpoints["future.provider"], "https://future.invalid/v1")
    }

    func testMalformedAndFutureScopedGrantsDoNotEraseValidGrant() throws {
        let settings = try decodeFixture("ai-settings-forward-consent")

        let validGrant = try XCTUnwrap(
            settings.consentGrant(forProviderID: AIProvider.openrouter.rawValue)
        )
        XCTAssertTrue(validGrant.consumers.contains(.ask))
        XCTAssertTrue(settings.isAuthorized(
            providerID: AIProvider.openrouter.rawValue,
            consumer: .ask
        ))

        // A malformed scoped entry is discarded in isolation. Because the
        // scoped map was explicitly present, its legacy boolean must not be
        // migrated back into an authorization grant.
        XCTAssertNil(settings.consentGrant(forProviderID: AIProvider.anthropic.rawValue))
        XCTAssertFalse(settings.isAuthorized(
            providerID: AIProvider.anthropic.rawValue,
            consumer: .ask
        ))

        XCTAssertNotNil(settings.consentGrant(forProviderID: "future.provider"))
        XCTAssertFalse(settings.isAuthorized(providerID: "future.provider", consumer: .ask))
    }

    func testUnknownConsentIDsAndLegacyDecisionsRoundTripLosslesslyButFailClosed() throws {
        let settings = try decodeFixture("ai-settings-forward-consent")
        let encoded = try JSONEncoder().encode(settings)
        let roundTrip = try JSONDecoder().decode(AIProviderSettings.self, from: encoded)

        XCTAssertEqual(roundTrip.consentGrants, settings.consentGrants)
        XCTAssertEqual(roundTrip.cloudConsent, settings.cloudConsent)
        XCTAssertEqual(roundTrip.cloudConsent["future.legacy.allowed"], true)
        XCTAssertEqual(roundTrip.cloudConsent["future.legacy.revoked"], false)
        XCTAssertFalse(roundTrip.isAuthorized(
            providerID: "future.legacy.allowed",
            consumer: .ask
        ))
        XCTAssertFalse(roundTrip.isAuthorized(providerID: "future.provider", consumer: .ask))

        // Unknown consumer IDs remain opaque data: this build cannot turn one
        // into an AIConsumer and therefore cannot authorize it. It must still
        // write the exact ID back for a newer build.
        XCTAssertNil(AIConsumer(rawValue: "future.generatedDigest"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let grants = try XCTUnwrap(object["consentGrants"] as? [String: Any])
        let openRouter = try XCTUnwrap(grants[AIProvider.openrouter.rawValue] as? [String: Any])
        let consumerIDs = try XCTUnwrap(openRouter["consumers"] as? [String])
        XCTAssertEqual(
            Set(consumerIDs),
            Set([AIConsumer.ask.rawValue, "future.generatedDigest"])
        )
    }

    func testExplicitConsentRevokeSurvivesRoundTripWithoutLegacyResurrection() throws {
        var settings = try decodeFixture("ai-settings-forward-consent")

        settings.revokeConsent(providerID: AIProvider.openrouter.rawValue)

        let roundTrip = try JSONDecoder().decode(
            AIProviderSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertNil(roundTrip.cloudConsent[AIProvider.openrouter.rawValue])
        XCTAssertNil(roundTrip.consentGrant(forProviderID: AIProvider.openrouter.rawValue))
        XCTAssertFalse(roundTrip.isAuthorized(
            providerID: AIProvider.openrouter.rawValue,
            consumer: .ask
        ))
    }

    func testMalformedOptionalFieldsDoNotEraseValidActiveModelOrLegacyConsent() throws {
        let settings = try decodeFixture("ai-settings-corrupt-optionals")

        XCTAssertEqual(settings.activeProvider, .anthropic)
        XCTAssertEqual(settings.models[AIProvider.anthropic.rawValue], "claude-haiku-4-5-20251001")
        XCTAssertTrue(settings.endpoints.isEmpty)
        XCTAssertFalse(settings.processingDisabledByUser)
        XCTAssertEqual(settings.selectionRevision, .zero)
        XCTAssertEqual(settings.authorizationEpoch, AuthorizationEpoch(rawValue: 4))
        XCTAssertTrue(settings.isAuthorized(providerID: AIProvider.anthropic.rawValue, consumer: .ask))
    }

    func testSelectionSnapshotCarriesImmutableRevisionAndAuthorizationEpoch() {
        let settings = AIProviderSettings(
            active: AIProvider.openrouter.rawValue,
            activeModelID: "anthropic/claude-3.5-haiku",
            models: [AIProvider.openrouter.rawValue: "anthropic/claude-3.5-haiku"],
            endpoints: [:],
            cloudConsent: [:],
            processingDisabledByUser: false,
            selectionRevision: SelectionRevision(rawValue: 9),
            authorizationEpoch: AuthorizationEpoch(rawValue: 12),
            consentGrants: [:]
        )

        XCTAssertEqual(
            settings.selectionSnapshot,
            ProviderSelectionSnapshot(
                providerID: AIProvider.openrouter.rawValue,
                modelID: "anthropic/claude-3.5-haiku",
                selectionRevision: SelectionRevision(rawValue: 9),
                authorizationEpoch: AuthorizationEpoch(rawValue: 12)
            )
        )
    }

    func testProviderCardPreferenceCannotSilentlyChangeTheActivePair() {
        var settings = AIProviderSettings(
            active: AIProvider.openrouter.rawValue,
            activeModelID: "anthropic/claude-3.5-haiku",
            models: [AIProvider.openrouter.rawValue: "anthropic/claude-3.5-haiku"],
            selectionRevision: SelectionRevision(rawValue: 4)
        )
        let before = settings.selectionSnapshot

        settings.setPreferredModel("openai/gpt-5-mini", providerID: AIProvider.openrouter.rawValue)

        XCTAssertEqual(settings.models[AIProvider.openrouter.rawValue], "openai/gpt-5-mini")
        XCTAssertEqual(settings.selectionSnapshot, before)
        XCTAssertEqual(settings.selectionRevision, SelectionRevision(rawValue: 4))
    }

    func testPresentEmptyScopedGrantDoesNotResurrectLegacyConsent() throws {
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "active": "openrouter",
              "activeModelID": "anthropic/claude-3.5-haiku",
              "models": {"openrouter": "anthropic/claude-3.5-haiku"},
              "cloudConsent": {"openrouter": true},
              "consentGrants": {}
            }
            """.utf8
        )

        let settings = try JSONDecoder().decode(AIProviderSettings.self, from: data)

        XCTAssertNil(settings.consentGrant(forProviderID: AIProvider.openrouter.rawValue))
        XCTAssertFalse(settings.isAuthorized(providerID: AIProvider.openrouter.rawValue, consumer: .ask))
    }

    func testCloudConfirmationCommitsConsentAndPairWithOneRevisionAdvance() {
        var settings = AIProviderSettings()
        let grant = ScopedAIConsentGrant(
            providerID: AIProvider.openrouter.rawValue,
            recipientDisclosure: AIProvider.openrouter.egressDestination,
            consumers: Set(AIConsumer.allCases),
            policyRevision: ScopedAIConsentGrant.currentPolicyRevision
        )
        let intent = ActivationIntent(
            providerID: AIProvider.openrouter.rawValue,
            modelID: "anthropic/claude-haiku",
            expectedSelectionRevision: .zero
        )

        XCTAssertTrue(settings.commitActivation(intent, consentDraft: grant))

        XCTAssertEqual(settings.selectionRevision, SelectionRevision(rawValue: 1))
        XCTAssertEqual(settings.authorizationEpoch, AuthorizationEpoch(rawValue: 1))
        XCTAssertEqual(settings.selectionSnapshot?.providerID, AIProvider.openrouter.rawValue)
        XCTAssertEqual(settings.selectionSnapshot?.modelID, "anthropic/claude-haiku")
        XCTAssertTrue(settings.isAuthorized(
            providerID: AIProvider.openrouter.rawValue,
            consumer: .generatedLabels
        ))
    }

    func testAskOriginCloudConfirmationAuthorizesOnlyAsk() {
        var settings = AIProviderSettings()
        let grant = ScopedAIConsentGrant(
            providerID: AIProvider.openrouter.rawValue,
            recipientDisclosure: AIProvider.openrouter.egressDestination,
            consumers: [.ask],
            policyRevision: ScopedAIConsentGrant.currentPolicyRevision
        )
        let intent = ActivationIntent(
            providerID: AIProvider.openrouter.rawValue,
            modelID: "anthropic/claude-haiku",
            expectedSelectionRevision: .zero
        )

        XCTAssertTrue(settings.commitActivation(
            intent,
            consentDraft: grant,
            requiredConsumers: [.ask]
        ))
        XCTAssertTrue(settings.isAuthorized(
            providerID: AIProvider.openrouter.rawValue,
            consumer: .ask
        ))
        XCTAssertFalse(settings.isAuthorized(
            providerID: AIProvider.openrouter.rawValue,
            consumer: .dailyInsights
        ))
        XCTAssertFalse(settings.isAuthorized(
            providerID: AIProvider.openrouter.rawValue,
            consumer: .generatedLabels
        ))
    }

    func testCustomAPIConsentIsBoundToTheConfiguredHTTPSOrigin() throws {
        let provider = AIProvider.customAPI
        let endpoint = "https://inference.example/v1"
        var settings = AIProviderSettings(
            endpoints: [provider.rawValue: endpoint]
        )
        let recipient = try XCTUnwrap(provider.egressDestination(for: endpoint))
        let grant = ScopedAIConsentGrant(
            providerID: provider.rawValue,
            recipientDisclosure: recipient,
            consumers: [.ask],
            policyRevision: ScopedAIConsentGrant.currentPolicyRevision
        )
        let intent = ActivationIntent(
            providerID: provider.rawValue,
            modelID: "model",
            expectedSelectionRevision: .zero
        )

        XCTAssertTrue(settings.commitActivation(
            intent,
            consentDraft: grant,
            requiredConsumers: [.ask]
        ))
        XCTAssertTrue(settings.isAuthorized(providerID: provider.rawValue, consumer: .ask))

        settings.endpoints[provider.rawValue] = "https://other.example/v1"
        XCTAssertFalse(settings.isAuthorized(providerID: provider.rawValue, consumer: .ask))
    }

    func testCloudConfirmationWithInvalidConsentMutatesNothing() {
        var settings = AIProviderSettings(
            active: AIProvider.lmstudio.rawValue,
            activeModelID: "local-model",
            models: [AIProvider.lmstudio.rawValue: "local-model"],
            selectionRevision: SelectionRevision(rawValue: 4),
            authorizationEpoch: AuthorizationEpoch(rawValue: 7)
        )
        let before = settings
        let mismatchedGrant = ScopedAIConsentGrant(
            providerID: AIProvider.anthropic.rawValue,
            recipientDisclosure: AIProvider.anthropic.egressDestination,
            consumers: Set(AIConsumer.allCases),
            policyRevision: ScopedAIConsentGrant.currentPolicyRevision
        )
        let intent = ActivationIntent(
            providerID: AIProvider.openrouter.rawValue,
            modelID: "anthropic/claude-haiku",
            expectedSelectionRevision: SelectionRevision(rawValue: 4)
        )

        XCTAssertFalse(settings.commitActivation(intent, consentDraft: mismatchedGrant))

        XCTAssertEqual(settings, before)
    }

    func testStaleActivationIntentMutatesNothing() {
        var settings = AIProviderSettings(
            active: AIProvider.lmstudio.rawValue,
            activeModelID: "local-model",
            models: [AIProvider.lmstudio.rawValue: "local-model"],
            selectionRevision: SelectionRevision(rawValue: 4),
            authorizationEpoch: AuthorizationEpoch(rawValue: 7)
        )
        let staleIntent = ActivationIntent(
            providerID: AIProvider.ollama.rawValue,
            modelID: "qwen3:4b",
            expectedSelectionRevision: settings.selectionRevision
        )
        settings.deactivate()
        let beforeAttempt = settings

        XCTAssertFalse(settings.commitActivation(staleIntent))
        XCTAssertEqual(settings, beforeAttempt)
    }

    func testDeactivationIntentCannotTurnOffANewerProviderSelection() {
        var settings = AIProviderSettings(
            active: AIProvider.zbsEyeLocal.rawValue,
            activeModelID: "zbs-eye-local-qwen3.5-4b-4bit-v1",
            models: [AIProvider.zbsEyeLocal.rawValue: "zbs-eye-local-qwen3.5-4b-4bit-v1"],
            selectionRevision: SelectionRevision(rawValue: 4),
            authorizationEpoch: AuthorizationEpoch(rawValue: 7)
        )
        let removalIntent = DeactivationIntent(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: "zbs-eye-local-qwen3.5-4b-4bit-v1",
            expectedSelectionRevision: settings.selectionRevision
        )
        let replacement = ActivationIntent(
            providerID: AIProvider.ollama.rawValue,
            modelID: "qwen3:4b",
            expectedSelectionRevision: settings.selectionRevision
        )
        XCTAssertTrue(settings.commitActivation(replacement))
        let newerSelection = settings.selectionSnapshot

        XCTAssertFalse(settings.commitDeactivation(removalIntent))
        XCTAssertEqual(settings.selectionSnapshot, newerSelection)
        XCTAssertFalse(settings.processingDisabledByUser)
    }

    func testCurrentDeactivationIntentCommitsTheDeliberateOffState() {
        var settings = AIProviderSettings(
            active: AIProvider.zbsEyeLocal.rawValue,
            activeModelID: "zbs-eye-local-qwen3.5-4b-4bit-v1",
            models: [AIProvider.zbsEyeLocal.rawValue: "zbs-eye-local-qwen3.5-4b-4bit-v1"],
            selectionRevision: SelectionRevision(rawValue: 4),
            authorizationEpoch: AuthorizationEpoch(rawValue: 7)
        )
        let removalIntent = DeactivationIntent(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: "zbs-eye-local-qwen3.5-4b-4bit-v1",
            expectedSelectionRevision: settings.selectionRevision
        )

        XCTAssertTrue(settings.commitDeactivation(removalIntent))
        XCTAssertNil(settings.selectionSnapshot)
        XCTAssertTrue(settings.processingDisabledByUser)
        XCTAssertEqual(settings.selectionRevision, SelectionRevision(rawValue: 5))
        XCTAssertEqual(settings.authorizationEpoch, AuthorizationEpoch(rawValue: 8))
    }

    func testCloudActivationWithoutCurrentConsentMutatesNothing() {
        var settings = AIProviderSettings(
            selectionRevision: SelectionRevision(rawValue: 2),
            authorizationEpoch: AuthorizationEpoch(rawValue: 3)
        )
        let before = settings
        let intent = ActivationIntent(
            providerID: AIProvider.openrouter.rawValue,
            modelID: "anthropic/claude-haiku",
            expectedSelectionRevision: settings.selectionRevision
        )

        XCTAssertFalse(settings.commitActivation(intent))
        XCTAssertEqual(settings, before)
    }

    func testCloudActivationCanReuseExistingFullyScopedConsent() {
        let grant = ScopedAIConsentGrant(
            providerID: AIProvider.openrouter.rawValue,
            recipientDisclosure: AIProvider.openrouter.egressDestination,
            consumers: Set(AIConsumer.allCases),
            policyRevision: ScopedAIConsentGrant.currentPolicyRevision
        )
        var settings = AIProviderSettings(
            selectionRevision: SelectionRevision(rawValue: 2),
            authorizationEpoch: AuthorizationEpoch(rawValue: 3),
            consentGrants: [AIProvider.openrouter.rawValue: grant]
        )
        let intent = ActivationIntent(
            providerID: AIProvider.openrouter.rawValue,
            modelID: "anthropic/claude-haiku",
            expectedSelectionRevision: settings.selectionRevision
        )

        XCTAssertTrue(settings.commitActivation(intent))
        XCTAssertEqual(settings.selectionRevision, SelectionRevision(rawValue: 3))
        XCTAssertEqual(settings.authorizationEpoch, AuthorizationEpoch(rawValue: 4))
        XCTAssertEqual(settings.selectionSnapshot?.modelID, "anthropic/claude-haiku")
    }

    func testLocalActivationCommitsOnlyAtExpectedRevision() {
        var settings = AIProviderSettings(
            selectionRevision: SelectionRevision(rawValue: 8),
            authorizationEpoch: AuthorizationEpoch(rawValue: 11)
        )
        let intent = ActivationIntent(
            providerID: AIProvider.ollama.rawValue,
            modelID: "  qwen3:4b  ",
            expectedSelectionRevision: settings.selectionRevision
        )

        XCTAssertTrue(settings.commitActivation(intent))
        XCTAssertEqual(settings.selectionSnapshot?.providerID, AIProvider.ollama.rawValue)
        XCTAssertEqual(settings.selectionSnapshot?.modelID, "qwen3:4b")
        XCTAssertEqual(settings.selectionRevision, SelectionRevision(rawValue: 9))
        XCTAssertEqual(settings.authorizationEpoch, AuthorizationEpoch(rawValue: 12))
    }

    func testCatalogAuthorityNeverMutatesSelection() {
        let selected = "removed-model"
        let catalog = ProviderCatalogState.authoritative(["recommended-model", "other-model"])

        XCTAssertEqual(catalog.selectionAvailability(for: selected), .missingFromAuthoritativeCatalog)
        XCTAssertEqual(catalog.recommendation(from: ["recommended-model"]), "recommended-model")
        XCTAssertEqual(selected, "removed-model")
        XCTAssertNil(ProviderCatalogState.notLoaded.recommendation(from: ["recommended-model"]))
        XCTAssertNil(ProviderCatalogState.unavailable.recommendation(from: ["recommended-model"]))
    }

    func testProviderCatalogContainsProviderEntitiesWithoutPromotingModelsToProviders() {
        let required: Set<AIProvider> = [
            .zbsEyeLocal, .codex, .openrouter, .anthropic, .moonshot, .zai, .xiaomi,
            .openai, .claudeCode, .ollama, .lmstudio, .custom, .customAPI,
        ]

        XCTAssertEqual(Set(AIProvider.allCases), required)
        XCTAssertEqual(AIProvider.moonshot.apiHost, "api.moonshot.ai")
        XCTAssertEqual(AIProvider.moonshot.defaultBaseURL, "https://api.moonshot.ai/v1")
        XCTAssertEqual(AIProvider.moonshot.displayName, "Moonshot AI")
        XCTAssertEqual(AIProvider.xiaomi.displayName, "Xiaomi")
        XCTAssertEqual(AIProvider.zai.apiHost, "api.z.ai")
        XCTAssertEqual(AIProvider.xiaomi.apiHost, "api.xiaomimimo.com")
        XCTAssertEqual(AIProvider.zai.catalogDialect, .documentedSuggestions)
        XCTAssertEqual(AIProvider.xiaomi.catalogDialect, .documentedSuggestions)
        XCTAssertEqual(AIProvider.moonshot.catalogDialect, .openAIModels)
        XCTAssertEqual(AIProvider.zai.documentedSuggestedModels.first, "glm-5.1")
        XCTAssertEqual(AIProvider.xiaomi.documentedSuggestedModels.first, "mimo-v2.5-pro")
        XCTAssertEqual(AIProvider.zbsEyeLocal.displayName, "ZBS Eye Local")
    }

    func testRecommendationsStayInsideTheirProviderCatalogAndNeverInventAuthority() {
        let openRouter = [
            "moonshotai/kimi-k2",
            "anthropic/claude-haiku-4.5",
            "z-ai/glm-5",
        ]
        XCTAssertEqual(
            AIProvider.openrouter.recommendedModel(in: openRouter),
            "anthropic/claude-haiku-4.5"
        )
        XCTAssertNil(AIProvider.anthropic.recommendedModel(in: ["claude-sonnet-5"]))
        XCTAssertEqual(
            AIProvider.moonshot.recommendedModel(in: ["kimi-k2.5", "kimi-k2"]),
            "kimi-k2.5"
        )
        XCTAssertEqual(
            AIProvider.zai.recommendedModel(in: ["glm-5", "glm-5.1"]),
            "glm-5.1"
        )
        XCTAssertEqual(
            AIProvider.xiaomi.recommendedModel(in: ["mimo-v2.5", "mimo-v2.5-pro"]),
            "mimo-v2.5-pro"
        )
        XCTAssertNil(AIProvider.openai.recommendedModel(in: ["gpt-5-mini"]))
        XCTAssertNil(AIProvider.openrouter.recommendedModel(in: []))
    }

    private func decodeFixture(_ name: String) throws -> AIProviderSettings {
        try JSONDecoder().decode(AIProviderSettings.self, from: fixtureData(name))
    }

    private func fixtureData(_ name: String) throws -> Data {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension("json")
        return try Data(contentsOf: file)
    }
}
