import Foundation
import XCTest

@MainActor
final class AISetupPresentationTests: XCTestCase {
    func testThreePathsExposeOnlySupportedProvidersWithoutAProviderWall() {
        XCTAssertEqual(
            AISetupPresentation.providers(for: .onThisMac),
            [.zbsEyeLocal, .ollama, .lmstudio, .custom]
        )
        XCTAssertEqual(
            AISetupPresentation.providers(for: .accountOrCode),
            [.codex, .claudeCode]
        )
        XCTAssertEqual(
            AISetupPresentation.providers(for: .apiProvider),
            [.openrouter, .anthropic, .moonshot, .zai, .xiaomi, .openai, .customAPI]
        )

        let visible = AISetupPath.allCases.flatMap(AISetupPresentation.providers(for:))
        XCTAssertEqual(Set(visible).count, visible.count)
    }

    func testOpeningSetupIsSideEffectFreeAndStartsWithNoProviderSelected() {
        let presentation = AISetupPresentation()

        let sessionID = presentation.present(origin: .ask)

        XCTAssertTrue(presentation.isPresented)
        XCTAssertEqual(presentation.sessionID, sessionID)
        XCTAssertEqual(presentation.origin, .ask)
        XCTAssertEqual(presentation.selectedPath, .onThisMac)
        XCTAssertNil(presentation.selectedProvider)
        XCTAssertFalse(presentation.hasEphemeralWork)
    }

    func testAIOffIsACompleteActiveStatusWithoutInventingAProvider() {
        XCTAssertEqual(
            AISetupPresentation.activeLabel(provider: nil, modelID: nil),
            "AI Off"
        )
        XCTAssertEqual(
            AISetupPresentation.activeLabel(provider: .openrouter, modelID: "model"),
            "OpenRouter · model"
        )
    }

    func testSettingsActivationDoesNotBundleBackgroundConsumers() {
        XCTAssertEqual(
            AISetupOrigin.settings.consentConsumers,
            [.ask, .dailyInsights, .manualSummary]
        )
        XCTAssertFalse(AISetupOrigin.settings.consentConsumers.contains(.scheduledSummary))
        XCTAssertFalse(AISetupOrigin.settings.consentConsumers.contains(.generatedLabels))
    }

    func testModelNamesStayInsideTheSelectedProvider() {
        XCTAssertEqual(
            AISetupPresentation.modelShortName(
                "anthropic/claude-haiku-4.5",
                provider: .openrouter
            ),
            "claude-haiku-4.5"
        )
        XCTAssertEqual(
            AISetupPresentation.modelShortName(
                AIProvider.claudeCodeDefaultModel,
                provider: .claudeCode
            ),
            "Provider default"
        )
    }

    func testConcurrentEntryReusesOneAppWideSessionWithoutOverwritingOrigin() {
        let presentation = AISetupPresentation()
        let askSession = presentation.present(origin: .ask)

        let settingsSession = presentation.present(origin: .settings)

        XCTAssertEqual(settingsSession, askSession)
        XCTAssertEqual(presentation.origin, .ask)
        XCTAssertEqual(presentation.sessionID, askSession)
    }

    func testDismissInvalidatesLateCompletionAndTheNextSessionGetsNewIdentity() throws {
        let presentation = AISetupPresentation()
        let first = presentation.present(origin: .ask)
        let operation = try XCTUnwrap(presentation.beginEphemeralOperation(sessionID: first))

        presentation.dismiss(sessionID: first)

        XCTAssertFalse(presentation.mayComplete(operation))
        XCTAssertFalse(presentation.hasEphemeralWork)
        let second = presentation.present(origin: .settings)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(presentation.origin, .settings)
    }

    func testDismissCancelsOwnedEphemeralWork() async throws {
        let presentation = AISetupPresentation()
        let session = presentation.present(origin: .ask)
        let cancellation = AISetupCancellationProbe()
        presentation.runEphemeral(sessionID: session) {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                await cancellation.markCancelled()
            }
        }
        XCTAssertTrue(presentation.hasEphemeralWork)

        presentation.dismiss(sessionID: session)

        for _ in 0..<50 {
            if await cancellation.wasCancelled() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let wasCancelled = await cancellation.wasCancelled()
        XCTAssertTrue(wasCancelled)
        XCTAssertFalse(presentation.hasEphemeralWork)
    }
}

private actor AISetupCancellationProbe {
    private var cancelled = false
    func markCancelled() { cancelled = true }
    func wasCancelled() -> Bool { cancelled }
}
