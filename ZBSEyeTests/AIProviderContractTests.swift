import Foundation
import MLXLLM
import MLXLMCommon
import XCTest

final class AIProviderContractTests: XCTestCase {
    func testEveryProviderDeclaresStableTransportAndCatalogDialects() throws {
        struct Expected {
            let provider: AIProvider
            let transport: AIProvider.Wire
            let catalog: AIProvider.CatalogDialect
        }

        let expected: [Expected] = [
            .init(provider: .zbsEyeLocal, transport: .builtInMLX, catalog: .bundledManifest),
            .init(provider: .codex, transport: .codexAppServer, catalog: .codexAppServer),
            .init(provider: .openrouter, transport: .openAICompatible, catalog: .openAIModels),
            .init(provider: .anthropic, transport: .anthropicMessages, catalog: .anthropicModels),
            .init(provider: .moonshot, transport: .openAICompatible, catalog: .openAIModels),
            .init(provider: .zai, transport: .openAICompatible, catalog: .documentedSuggestions),
            .init(provider: .xiaomi, transport: .openAICompatible, catalog: .documentedSuggestions),
            .init(provider: .openai, transport: .openAICompatible, catalog: .openAIModels),
            .init(provider: .claudeCode, transport: .claudeCodeCLI, catalog: .curatedClaudeCode),
            .init(provider: .ollama, transport: .openAICompatible, catalog: .openAIModels),
            .init(provider: .lmstudio, transport: .openAICompatible, catalog: .openAIModels),
            .init(provider: .custom, transport: .openAICompatible, catalog: .openAIModels),
        ]

        XCTAssertEqual(expected.map(\.provider), AIProvider.allCases)
        for item in expected {
            XCTAssertEqual(item.provider.descriptor.transport, item.transport)
            XCTAssertEqual(item.provider.descriptor.catalog, item.catalog)
        }

        XCTAssertEqual(AIProvider.Wire.builtInMLX.rawValue, "mlx-in-process-v1")
        XCTAssertEqual(AIProvider.Wire.openAICompatible.rawValue, "openai-chat-completions-v1")
        XCTAssertEqual(AIProvider.Wire.anthropicMessages.rawValue, "anthropic-messages-v1")
        XCTAssertEqual(AIProvider.Wire.codexAppServer.rawValue, "codex-app-server-v1")
        XCTAssertEqual(AIProvider.Wire.claudeCodeCLI.rawValue, "claude-code-cli-v1")
        XCTAssertEqual(AIProvider.CatalogDialect.bundledManifest.rawValue, "bundled-manifest-v1")
        XCTAssertEqual(AIProvider.CatalogDialect.openAIModels.rawValue, "openai-models-v1")
        XCTAssertEqual(AIProvider.CatalogDialect.anthropicModels.rawValue, "anthropic-models-v1")
        XCTAssertEqual(
            AIProvider.CatalogDialect.documentedSuggestions.rawValue,
            "documented-suggestions-v1"
        )
        XCTAssertEqual(AIProvider.CatalogDialect.codexAppServer.rawValue, "codex-app-server-v1")
        XCTAssertEqual(AIProvider.CatalogDialect.curatedClaudeCode.rawValue, "curated-claude-code-v1")
    }

    func testCatalogPayloadParserDistinguishesValidEmptyFromMalformed() throws {
        let validEmpty = Data(#"{"data":[]}"#.utf8)
        let malformedShape = Data(#"{"models":[]}"#.utf8)
        let malformedIdentifier = Data(#"{"data":[{"id":42}]}"#.utf8)

        XCTAssertEqual(try ProviderCatalogPayload.modelIDs(from: validEmpty), [])
        XCTAssertThrowsError(try ProviderCatalogPayload.modelIDs(from: malformedShape))
        XCTAssertThrowsError(try ProviderCatalogPayload.modelIDs(from: malformedIdentifier))
    }

    func testCatalogValidationFailsClosedWithoutFoldingInPersistedSelection() {
        let settings = AIProviderSettings(
            active: AIProvider.lmstudio.rawValue,
            activeModelID: "keep-active",
            models: [AIProvider.lmstudio.rawValue: "keep-preferred"],
            selectionRevision: SelectionRevision(rawValue: 7),
            authorizationEpoch: AuthorizationEpoch(rawValue: 11)
        )
        let before = settings

        let validEmpty = ProviderCatalogState.validatingSuccessfulPayload([])
        let malformed = ProviderCatalogState.validatingSuccessfulPayload(["  ", "\n"])
        let validCatalog = ProviderCatalogState.validatingSuccessfulPayload([
            " server-model ", "server-model", "another-model",
        ])

        XCTAssertEqual(validEmpty, .authoritative([]))
        XCTAssertEqual(malformed, .unavailable)
        XCTAssertEqual(validCatalog, .authoritative(["server-model", "another-model"]))
        XCTAssertEqual(validCatalog.models, ["server-model", "another-model"])
        XCTAssertFalse(validCatalog.models.contains("keep-preferred"))
        XCTAssertEqual(settings, before)
    }

    func testLocalProvidersDeclareNoRemoteEgress() {
        for provider in AIProvider.allCases where !provider.isCloud {
            XCTAssertNil(provider.egressDestination, "\(provider.displayName) must remain local")
            XCTAssertNil(provider.apiHost, "\(provider.displayName) must not pin a remote API host")
        }
    }

    func testCloudProvidersDeclareDestinationAndBoundTransport() {
        for provider in AIProvider.allCases where provider.isCloud {
            XCTAssertNotNil(provider.egressDestination, "\(provider.displayName) must name its egress destination")
            XCTAssertTrue(
                provider.isSubprocess || provider.apiHost != nil,
                "\(provider.displayName) must use a constrained subprocess or a pinned API host"
            )
        }
    }

    func testProviderSettingsRoundTripPreservesSelectionAndConsent() throws {
        let settings = AIProviderSettings(
            active: AIProvider.openrouter.rawValue,
            models: [AIProvider.openrouter.rawValue: "anthropic/claude-haiku"],
            endpoints: [AIProvider.ollama.rawValue: AIProvider.ollama.defaultBaseURL],
            cloudConsent: [AIProvider.openrouter.rawValue: true],
            processingDisabledByUser: false
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AIProviderSettings.self, from: data)

        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.activeProvider, .openrouter)
    }

    func testPinnedMLXReleaseContainsSelectedQwenConfigurations() {
        XCTAssertEqual(LLMRegistry.qwen3_1_7b_4bit.name, "mlx-community/Qwen3-1.7B-4bit")
        XCTAssertEqual(LLMRegistry.qwen3_5_2b_4bit.name, "mlx-community/Qwen3.5-2B-4bit")
    }
}
