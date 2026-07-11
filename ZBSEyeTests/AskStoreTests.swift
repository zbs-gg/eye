import Foundation
import XCTest

@MainActor
final class AskStoreTests: XCTestCase {
    func testOpeningAndReadingReadinessNeverGenerates() async {
        let execution = context(provider: .ollama, model: "local", local: true)
        let readiness = MutableAskReadiness(execution)
        let service = ImmediateAskAnswering(result: .success(answer(execution: execution)))
        let store = AskStore(service: service, readiness: readiness)

        XCTAssertTrue(store.llmReady)
        XCTAssertTrue(store.messages.isEmpty)
        let calls = await service.callCount()
        XCTAssertEqual(calls, 0)
    }

    func testLocalAndCloudMessagesExposeTruthfulProvenanceAndDisclosure() async throws {
        let cases: [(AskExecutionContext, String, Bool)] = [
            (
                context(provider: .ollama, model: "qwen-local", local: true),
                "on this Mac",
                true
            ),
            (
                context(
                    provider: .openrouter,
                    model: "anthropic/claude-haiku",
                    local: false,
                    recipient: AIProvider.openrouter.egressDestination
                ),
                "OpenRouter",
                false
            ),
        ]

        for (execution, disclosureMarker, expectedLocal) in cases {
            let readiness = MutableAskReadiness(execution)
            let expectedAnswer = answer(execution: execution)
            let service = ImmediateAskAnswering(result: .success(expectedAnswer))
            let store = AskStore(service: service, readiness: readiness)
            store.input = "Question"
            store.send()
            await waitUntilIdle(store)

            let assistant = try XCTUnwrap(store.messages.last)
            XCTAssertEqual(assistant.role, .assistant)
            XCTAssertEqual(assistant.provenance?.executedLocally, expectedLocal)
            XCTAssertEqual(assistant.provenance?.providerID, execution.selection.providerID)
            XCTAssertTrue(store.executionDisclosure.contains(disclosureMarker))
            if expectedLocal {
                XCTAssertFalse(store.executionDisclosure.lowercased().contains("cloud"))
            } else {
                XCTAssertFalse(store.executionDisclosure.contains("stays on this Mac"))
            }
        }
    }

    func testUnavailableSelectionShowsHintWithoutCallingService() async {
        let readiness = MutableAskReadiness(nil)
        let execution = context(provider: .ollama, model: "local", local: true)
        let service = ImmediateAskAnswering(result: .success(answer(execution: execution)))
        let store = AskStore(service: service, readiness: readiness)

        XCTAssertFalse(store.llmReady)
        store.input = "Question"
        store.send()

        let calls = await service.callCount()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(store.messages.count, 2)
        XCTAssertEqual(store.messages.last?.role, .assistant)
        XCTAssertTrue(store.messages.last?.text.contains("AI Models") == true)
        XCTAssertFalse(store.busy)
    }

    func testCloudSelectionEasterEggDoesNotClaimZeroEgress() async {
        let execution = context(
            provider: .openrouter,
            model: "cloud",
            local: false,
            recipient: AIProvider.openrouter.egressDestination
        )
        let service = ImmediateAskAnswering(result: .success(answer(execution: execution)))
        let store = AskStore(
            service: service,
            readiness: MutableAskReadiness(execution)
        )
        store.input = "who are you"
        store.send()

        let message = store.messages.last?.text.lowercased() ?? ""
        XCTAssertFalse(message.contains("no cloud"))
        XCTAssertFalse(message.contains("zero outbound"))
        XCTAssertTrue(message.contains("explicit consent"))
        let calls = await service.callCount()
        XCTAssertEqual(calls, 0)
    }

    func testNoHitAnswerWithoutGenerationProvenanceStillPaintsHonestly() async {
        let execution = context(provider: .ollama, model: "local", local: true)
        let noHits = AskService.Answer(
            text: "Nothing matched.",
            truncated: false,
            sources: [],
            provenance: nil
        )
        let store = AskStore(
            service: ImmediateAskAnswering(result: .success(noHits)),
            readiness: MutableAskReadiness(execution)
        )
        store.input = "Question"
        store.send()
        await waitUntilIdle(store)

        XCTAssertEqual(store.messages.last?.text, "Nothing matched.")
        XCTAssertNil(store.messages.last?.provenance)
    }

    func testClearCancelsIdentityAndLateResultCannotRepaintConversation() async throws {
        let execution = context(provider: .ollama, model: "local", local: true)
        let readiness = MutableAskReadiness(execution)
        let service = DeferredAskAnswering()
        let store = AskStore(service: service, readiness: readiness)
        store.input = "Old question"
        store.send()

        let requestID = try await waitForRequest(service, count: 1).lastUnwrapped
        store.clear()
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertFalse(store.busy)

        await service.complete(requestID, with: .success(answer(execution: execution)))
        await Task.yield()
        XCTAssertTrue(store.messages.isEmpty)
    }

    func testSelectionSwitchDuringGenerationDiscardsOldResult() async throws {
        let old = context(provider: .ollama, model: "old", local: true)
        let new = context(
            provider: .openrouter,
            model: "new",
            local: false,
            recipient: AIProvider.openrouter.egressDestination,
            revision: 8,
            epoch: 12
        )
        let readiness = MutableAskReadiness(old)
        let service = DeferredAskAnswering()
        let store = AskStore(service: service, readiness: readiness)
        store.input = "Question"
        store.send()

        let requestID = try await waitForRequest(service, count: 1).lastUnwrapped
        readiness.execution = new
        await service.complete(requestID, with: .success(answer(execution: old)))
        await waitUntilIdle(store)

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.only?.role, .user)
        XCTAssertNil(store.messages.first(where: { $0.role == .assistant }))
    }

    func testNewRequestAfterClearWinsEvenWhenOldCompletionArrivesLast() async throws {
        let execution = context(provider: .ollama, model: "local", local: true)
        let readiness = MutableAskReadiness(execution)
        let service = DeferredAskAnswering()
        let store = AskStore(service: service, readiness: readiness)

        store.input = "Old"
        store.send()
        let oldID = try await waitForRequest(service, count: 1).lastUnwrapped
        store.clear()

        store.input = "New"
        store.send()
        let ids = try await waitForRequest(service, count: 2)
        let newID = try XCTUnwrap(ids.last)
        await service.complete(newID, with: .success(answer(
            text: "New answer [1]",
            execution: execution
        )))
        await waitUntilIdle(store)
        await service.complete(oldID, with: .success(answer(
            text: "Old answer [1]",
            execution: execution
        )))
        await Task.yield()

        XCTAssertEqual(store.messages.map(\.text), ["New", "New answer [1]"])
        XCTAssertFalse(store.messages.contains(where: { $0.text.contains("Old answer") }))
    }

    func testRevokedSelectionErrorDoesNotClaimLocalOrPaintWrongProvenance() async {
        let execution = context(
            provider: .openrouter,
            model: "cloud",
            local: false,
            recipient: AIProvider.openrouter.egressDestination
        )
        let readiness = MutableAskReadiness(execution)
        let service = ImmediateAskAnswering(result: .failure(.selectionUnavailable))
        let store = AskStore(service: service, readiness: readiness)
        store.input = "Question"
        store.send()
        await waitUntilIdle(store)

        XCTAssertEqual(store.messages.last?.role, .assistant)
        XCTAssertNil(store.messages.last?.provenance)
        XCTAssertTrue(store.messages.last?.text.contains("⚠️") == true)
        XCTAssertFalse(store.executionDisclosure.contains("stays on this Mac"))
    }

    // MARK: helpers

    private func context(
        provider: AIProvider,
        model: String,
        local: Bool,
        recipient: String? = nil,
        revision: UInt64 = 7,
        epoch: UInt64 = 11
    ) -> AskExecutionContext {
        AskExecutionContext(
            selection: ProviderSelectionSnapshot(
                providerID: provider.rawValue,
                modelID: model,
                selectionRevision: SelectionRevision(rawValue: revision),
                authorizationEpoch: AuthorizationEpoch(rawValue: epoch)
            ),
            contextTokenCeiling: 4_096,
            executedLocally: local,
            recipientDisclosure: recipient
        )
    }

    private func answer(
        text: String = "Answer [1]",
        execution: AskExecutionContext
    ) -> AskService.Answer {
        AskService.Answer(
            text: text,
            truncated: false,
            sources: [],
            provenance: AIExecutionProvenance(
                providerID: execution.selection.providerID,
                modelID: execution.selection.modelID,
                executedLocally: execution.executedLocally,
                generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                brokerUpstream: execution.executedLocally ? nil : "Synthetic upstream"
            )
        )
    }

    private func waitUntilIdle(_ store: AskStore) async {
        for _ in 0..<2_000 {
            if !store.busy { return }
            await Task.yield()
        }
        XCTFail("AskStore did not become idle")
    }

    private func waitForRequest(
        _ service: DeferredAskAnswering,
        count: Int
    ) async throws -> [UUID] {
        for _ in 0..<2_000 {
            let ids = await service.requestIDs()
            if ids.count >= count { return ids }
            await Task.yield()
        }
        throw AskStoreTestError.timedOut
    }
}

@MainActor
private final class MutableAskReadiness: AskReadinessProviding {
    var execution: AskExecutionContext?

    init(_ execution: AskExecutionContext?) {
        self.execution = execution
    }

    func currentAskExecutionContext() -> AskExecutionContext? { execution }
}

private actor ImmediateAskAnswering: AskAnswering {
    private let result: Result<AskService.Answer, AskServiceError>
    private var count = 0

    init(result: Result<AskService.Answer, AskServiceError>) {
        self.result = result
    }

    func answer(
        question: String,
        execution: AskExecutionContext,
        requestID: UUID,
        limits: AskGenerationLimits
    ) async throws -> AskService.Answer {
        count += 1
        return try result.get()
    }

    func callCount() -> Int { count }
}

private actor DeferredAskAnswering: AskAnswering {
    private var continuations: [
        UUID: CheckedContinuation<AskService.Answer, any Error>
    ] = [:]
    private var order: [UUID] = []

    func answer(
        question: String,
        execution: AskExecutionContext,
        requestID: UUID,
        limits: AskGenerationLimits
    ) async throws -> AskService.Answer {
        order.append(requestID)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[requestID] = continuation
        }
    }

    func requestIDs() -> [UUID] { order }

    func complete(
        _ requestID: UUID,
        with result: Result<AskService.Answer, AskServiceError>
    ) {
        continuations.removeValue(forKey: requestID)?.resume(with: result.mapError { $0 })
    }
}

private enum AskStoreTestError: Error {
    case timedOut
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

private extension Array where Element == UUID {
    var lastUnwrapped: UUID {
        get throws {
            guard let last else { throw AskStoreTestError.timedOut }
            return last
        }
    }
}
