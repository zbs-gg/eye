import XCTest

final class AIModelsPresentationTests: XCTestCase {
    func testProviderGroupsMatchTheApprovedProviderFirstHierarchy() {
        XCTAssertEqual(
            AIModelsPresentation.primaryProviders,
            [.codex, .openrouter, .anthropic]
        )
        XCTAssertEqual(
            AIModelsPresentation.localServerProviders,
            [.ollama, .lmstudio, .custom]
        )
        XCTAssertEqual(
            AIModelsPresentation.moreProviders,
            [.moonshot, .zai, .xiaomi, .openai, .claudeCode]
        )

        let visible = AIModelsPresentation.primaryProviders
            + AIModelsPresentation.localServerProviders
            + AIModelsPresentation.moreProviders
        XCTAssertEqual(Set(visible).count, visible.count)
        XCTAssertFalse(visible.contains(.zbsEyeLocal), "built-in local AI owns the hero, not a peer card")
    }

    func testModelsRemainNestedInsideTheirProviderAndRecommendationIsLocalToCard() {
        let openRouter = AIModelsProviderCardPresentation(
            provider: .openrouter,
            modelIDs: [
                "openai/gpt-5-mini",
                "anthropic/claude-haiku-4.5",
            ]
        )
        let anthropic = AIModelsProviderCardPresentation(
            provider: .anthropic,
            modelIDs: [
                "claude-haiku-4-5-20251001",
                "claude-sonnet-5",
            ]
        )

        XCTAssertEqual(openRouter.provider, .openrouter)
        XCTAssertEqual(openRouter.models.map(\.provider), [.openrouter, .openrouter])
        XCTAssertEqual(openRouter.models.filter(\.isRecommended).map(\.id), [
            "anthropic/claude-haiku-4.5",
        ])

        XCTAssertEqual(anthropic.provider, .anthropic)
        XCTAssertEqual(anthropic.models.map(\.provider), [.anthropic, .anthropic])
        XCTAssertEqual(anthropic.models.filter(\.isRecommended).map(\.id), [
            "claude-haiku-4-5-20251001",
        ])
    }

    func testFriendlyModelNamesDoNotTurnModelsIntoProviderLabels() {
        let moonshot = AIModelsProviderCardPresentation(
            provider: .moonshot,
            modelIDs: ["moonshot-v1-128k", "kimi-k2.5"]
        )
        let xiaomi = AIModelsProviderCardPresentation(
            provider: .xiaomi,
            modelIDs: ["mimo-v2.5-pro"]
        )

        XCTAssertEqual(moonshot.title, "Moonshot AI")
        XCTAssertEqual(moonshot.models.last?.shortName, "kimi-k2.5")
        XCTAssertEqual(xiaomi.title, "Xiaomi")
        XCTAssertEqual(xiaomi.models.first?.shortName, "mimo-v2.5-pro")
    }
}
