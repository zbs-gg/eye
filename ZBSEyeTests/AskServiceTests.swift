import Foundation
import XCTest

final class AskServiceTests: XCTestCase {
    func testProviderPayloadAllowlistContainsOnlyQuestionAndEvidenceText() {
        let pathCanary = "/synthetic/private/raw-frame.heic"
        let mediaCanary = "RAW_IMAGE_BYTES_CANARY"
        let source = SearchResult(
            id: 1,
            kind: .screen,
            ts: Date(timeIntervalSince1970: 10),
            bundleId: "gg.test",
            appName: "Test",
            windowTitle: "Window",
            browserURL: "https://example.test/private",
            snippet: "Visible text",
            relativePath: pathCanary
        )
        let payload = AskProviderTextPayload(
            question: "What happened?",
            evidence: [AskRetrievedEvidence(source: source, text: "Allowed excerpt")]
        )
        let serialized = ([payload.question] + payload.evidenceTexts).joined(separator: "\n")

        XCTAssertEqual(payload.question, "What happened?")
        XCTAssertEqual(payload.evidenceTexts, ["Allowed excerpt"])
        XCTAssertFalse(serialized.contains(pathCanary))
        XCTAssertFalse(serialized.contains(mediaCanary))
        XCTAssertFalse(serialized.contains("example.test/private"))
    }

    func testLocalAnswerUsesAskMetadataCitationsSourcesAndProvenance() async throws {
        let evidence = [
            evidence(id: 11, text: "The build passed after enabling strict concurrency."),
            evidence(id: 22, kind: .audio, text: "We agreed to ship on Friday."),
        ]
        let retrieval = StubAskRetrieval(evidence: evidence)
        let execution = context(provider: .ollama, model: "qwen-local", local: true)
        let generatedAt = Date(timeIntervalSince1970: 1_800_000_123)
        let router = StubAskRouter(result: .success(response(
            content: "It passed [1] and ships Friday [2].",
            execution: execution,
            generatedAt: generatedAt
        )))
        let service = AskService(retrieval: retrieval, router: router)
        let requestID = UUID()

        let answer = try await service.answer(
            question: "When does it ship?",
            execution: execution,
            requestID: requestID
        )

        XCTAssertEqual(answer.text, "It passed [1] and ships Friday [2].")
        XCTAssertEqual(answer.sources.map(\.id), [11, 22])
        let provenance = try XCTUnwrap(answer.provenance)
        XCTAssertEqual(provenance.providerID, AIProvider.ollama.rawValue)
        XCTAssertEqual(provenance.modelID, "qwen-local")
        XCTAssertTrue(provenance.executedLocally)
        XCTAssertEqual(provenance.generatedAt, generatedAt)
        XCTAssertNil(provenance.brokerUpstream)

        let calls = await router.calls()
        let call = try XCTUnwrap(calls.only)
        XCTAssertEqual(call.expectedSelection, execution.selection)
        XCTAssertEqual(call.request.id, requestID)
        XCTAssertEqual(call.request.consumer, .ask)
        XCTAssertEqual(call.request.priority, .ask)
        XCTAssertEqual(call.request.maximumOutputTokens, 800)
        XCTAssertEqual(call.request.timeout, .seconds(300))
        XCTAssertEqual(call.request.localOutputContract?.purpose, .ask)
        XCTAssertEqual(call.request.localOutputContract?.language, .en)
        XCTAssertEqual(
            call.request.localOutputContract?.allowedSources,
            Set(["[1]", "[2]"])
        )
        XCTAssertTrue(call.request.userPrompt.contains("[1]"))
        XCTAssertTrue(call.request.userPrompt.contains("[2]"))
        XCTAssertTrue(call.request.userPrompt.contains(evidence[0].text))
        XCTAssertTrue(call.request.userPrompt.contains(evidence[1].text))
    }

    func testSyntheticCloudAnswerPreservesBrokerProvenance() async throws {
        let retrieval = StubAskRetrieval(evidence: [evidence(id: 1, text: "Cloud evidence")])
        let execution = context(
            provider: .openrouter,
            model: "anthropic/claude-haiku",
            local: false,
            recipient: AIProvider.openrouter.egressDestination
        )
        let router = StubAskRouter(result: .success(response(
            content: "Cloud answer [1]",
            execution: execution,
            upstream: "Anthropic"
        )))
        let service = AskService(retrieval: retrieval, router: router)

        let answer = try await service.answer(
            question: "What happened?",
            execution: execution,
            requestID: UUID()
        )

        let provenance = try XCTUnwrap(answer.provenance)
        XCTAssertFalse(provenance.executedLocally)
        XCTAssertEqual(provenance.providerID, AIProvider.openrouter.rawValue)
        XCTAssertEqual(provenance.brokerUpstream, "Anthropic")
    }

    func testAskSeparatesBuiltInNativeToolPromptFromEveryVisibleTextProvider() async throws {
        for question in ["What happened?", "Что произошло?"] {
            for provider in [AIProvider.zbsEyeLocal, .ollama, .openrouter] {
                let execution = context(
                    provider: provider,
                    model: "model",
                    local: !provider.isCloud,
                    recipient: provider.egressDestination
                )
                let router = StubAskRouter(result: .success(response(
                    content: "Visible answer [1]",
                    execution: execution,
                    upstream: provider.isCloud ? "upstream" : nil
                )))
                let service = AskService(
                    retrieval: StubAskRetrieval(evidence: [
                        evidence(id: 1, text: "The release passed."),
                    ]),
                    router: router
                )

                _ = try await service.answer(
                    question: question,
                    execution: execution,
                    requestID: UUID()
                )

                let calls = await router.calls()
                let request = try XCTUnwrap(calls.only?.request)
                let modelFacingPrompt = request.systemPrompt + "\n" + request.userPrompt
                if provider == .zbsEyeLocal {
                    XCTAssertTrue(modelFacingPrompt.contains(
                        "function emit_zbs_eye_answer is available"
                    ))
                    XCTAssertTrue(modelFacingPrompt.contains("MUST call it exactly once"))
                    XCTAssertTrue(modelFacingPrompt.contains("Bare JSON is invalid"))
                    XCTAssertTrue(request.userPrompt.contains(
                        "Call emit_zbs_eye_answer now."
                    ))
                    XCTAssertFalse(modelFacingPrompt.contains("If the function is unavailable"))
                } else {
                    XCTAssertFalse(modelFacingPrompt.contains("emit_zbs_eye_answer"))
                    XCTAssertFalse(modelFacingPrompt.contains("Bare JSON"))
                }
            }
        }
    }

    func testNoHitsReturnsLanguageAwareEmptyAnswerWithoutDispatch() async throws {
        for (question, expectedText) in [
            ("What happened?", "Nothing in your history matched"),
            ("Что произошло?", "В истории ничего не нашлось"),
        ] {
            let retrieval = StubAskRetrieval(evidence: [])
            let router = StubAskRouter(result: .failure(.adapterUnavailable))
            let service = AskService(retrieval: retrieval, router: router)
            let answer = try await service.answer(
                question: question,
                execution: context(provider: .ollama, model: "local", local: true),
                requestID: UUID()
            )
            XCTAssertTrue(answer.text.contains(expectedText))
            XCTAssertTrue(answer.sources.isEmpty)
            XCTAssertNil(answer.provenance)
            let dispatchCount = await router.callCount()
            XCTAssertEqual(dispatchCount, 0)
        }
    }

    func testBoundedScopeReachesRetrievalAsOneFrozenSnapshot() async throws {
        let scope = AskScope.range(
            from: Date(timeIntervalSince1970: 1_000),
            to: Date(timeIntervalSince1970: 2_000)
        ).snapshot(revision: 14, calendar: .current)
        let retrieval = ScopedRecordingAskRetrieval(evidence: [
            evidence(id: 7, text: "Bounded evidence"),
        ])
        let execution = context(provider: .ollama, model: "local", local: true)
        let router = StubAskRouter(result: .success(response(
            content: "Bounded answer [1]",
            execution: execution
        )))
        let service = AskService(retrieval: retrieval, router: router)

        _ = try await service.answer(
            question: "What happened here?",
            scope: scope,
            execution: execution,
            requestID: UUID()
        )

        let scopes = await retrieval.recordedScopes()
        XCTAssertEqual(scopes, [scope])
    }

    func testBoundedScopeFailsClosedForLegacyOnlyRetrieval() async throws {
        let retrieval = LegacyOnlyAskRetrieval(evidence: [
            evidence(id: 99, text: "all-history evidence that must not leak"),
        ])
        let router = StubAskRouter(result: .failure(.adapterUnavailable))
        let service = AskService(retrieval: retrieval, router: router)
        let scope = AskScope.moment(Date()).snapshot(
            revision: 1,
            calendar: .current
        )

        await assertAskError(.contextUnavailable) {
            _ = try await service.answer(
                question: "Question",
                scope: scope,
                execution: self.context(
                    provider: .ollama,
                    model: "local",
                    local: true
                ),
                requestID: UUID()
            )
        }

        let legacyCalls = await retrieval.callCount()
        let dispatches = await router.callCount()
        XCTAssertEqual(legacyCalls, 0)
        XCTAssertEqual(dispatches, 0)
    }

    func testEnglishAndRussianPromptsPreserveQuestionLanguage() async throws {
        let cases: [(String, String, String)] = [
            ("Where was the release discussed?", "Answer in English", "Question:"),
            ("Где обсуждали релиз?", "Отвечай по-русски", "Вопрос:"),
        ]

        for (question, systemMarker, userMarker) in cases {
            let execution = context(provider: .ollama, model: "local", local: true)
            let retrieval = StubAskRetrieval(evidence: [evidence(id: 1, text: "Релиз обсуждали в чате.")])
            let router = StubAskRouter(result: .success(response(
                content: "Answer [1]", execution: execution
            )))
            let service = AskService(retrieval: retrieval, router: router)
            _ = try await service.answer(
                question: question,
                execution: execution,
                requestID: UUID()
            )
            let calls = await router.calls()
            let request = try XCTUnwrap(calls.only?.request)
            XCTAssertTrue(request.systemPrompt.contains(systemMarker))
            XCTAssertTrue(request.userPrompt.contains(userMarker))
            XCTAssertTrue(request.userPrompt.contains(question))
            XCTAssertEqual(
                request.localOutputContract?.language,
                question == cases[0].0 ? .en : .ru
            )
        }
    }

    func testCitationContextUsesUnconfirmedHintWhenEvidenceCannotProveCompletion() async throws {
        let execution = context(provider: .ollama, model: "local", local: true)
        let retrieval = StubAskRetrieval(evidence: [
            evidence(id: 1, text: "The submit button was not pressed; status is still pending."),
        ])
        let router = StubAskRouter(result: .success(response(
            content: "Submission was not confirmed [1].", execution: execution
        )))
        let service = AskService(retrieval: retrieval, router: router)

        _ = try await service.answer(
            question: "Was it submitted?",
            execution: execution,
            requestID: UUID()
        )

        let calls = await router.calls()
        let request = try XCTUnwrap(calls.only?.request)
        XCTAssertTrue(request.systemPrompt.contains("not confirmed"))
        XCTAssertTrue(request.userPrompt.contains("[1]"))
    }

    func testEmptyEvidenceDoesNotShiftCitationSourceIdentity() async throws {
        let execution = context(provider: .ollama, model: "local", local: true)
        let retrieval = StubAskRetrieval(evidence: [
            evidence(id: 1, text: " \n\t "),
            evidence(id: 2, text: "The actual evidence."),
        ])
        let router = StubAskRouter(result: .success(response(
            content: "Answer [1]", execution: execution
        )))
        let service = AskService(retrieval: retrieval, router: router)

        let answer = try await service.answer(
            question: "Question",
            execution: execution,
            requestID: UUID()
        )

        XCTAssertEqual(answer.sources.map(\.id), [2])
        let calls = await router.calls()
        let request = try XCTUnwrap(calls.only?.request)
        XCTAssertTrue(request.userPrompt.contains("[1] The actual evidence."))
        XCTAssertFalse(request.userPrompt.contains("[2]"))
    }

    func testContextBudgetIsDeterministicAndReturnsOnlyIncludedCitationSources() async throws {
        let execution = context(
            provider: .zbsEyeLocal,
            model: "small",
            local: true,
            ceiling: 3_000
        )
        let allEvidence = [
            evidence(id: 1, text: String(repeating: "alpha ", count: 90)),
            evidence(id: 2, text: String(repeating: "beta ", count: 90)),
            evidence(id: 3, text: String(repeating: "gamma ", count: 90)),
        ]

        func run() async throws -> (AskService.Answer, LLMRequest) {
            let retrieval = StubAskRetrieval(evidence: allEvidence)
            let router = StubAskRouter(result: .success(response(
                content: "Budgeted [1]", execution: execution
            )))
            let service = AskService(retrieval: retrieval, router: router)
            let answer = try await service.answer(
                question: "Summarize",
                execution: execution,
                requestID: UUID(),
                limits: AskGenerationLimits(
                    retrievalLimit: 10,
                    maximumSampleCharacters: 1_000,
                    maximumOutputTokens: 200,
                    requestTimeout: .seconds(10)
                )
            )
            let calls = await router.calls()
            return (answer, try XCTUnwrap(calls.only?.request))
        }

        let first = try await run()
        let second = try await run()
        XCTAssertEqual(first.1.systemPrompt, second.1.systemPrompt)
        XCTAssertEqual(first.1.userPrompt, second.1.userPrompt)
        XCTAssertEqual(first.0.sources.map(\.id), second.0.sources.map(\.id))
        XCTAssertLessThan(first.0.sources.count, allEvidence.count)
        XCTAssertTrue(first.1.userPrompt.contains("…"))
        XCTAssertEqual(
            first.1.localOutputContract?.allowedSources,
            Set((1...first.0.sources.count).map { "[\($0)]" })
        )
        XCTAssertLessThanOrEqual(
            LocalAIContextPolicy.askTokenUpperBound(
                systemPrompt: first.1.systemPrompt,
                userPrompt: first.1.userPrompt,
                outputTokens: first.1.maximumOutputTokens
            ),
            execution.contextTokenCeiling
        )
    }

    func testOversizedQuestionFailsBeforeRetrievalOrGeneration() async throws {
        let retrieval = StubAskRetrieval(evidence: [evidence(id: 1, text: "unused")])
        let router = StubAskRouter(result: .failure(.adapterUnavailable))
        let service = AskService(retrieval: retrieval, router: router)
        let execution = context(
            provider: .zbsEyeLocal,
            model: "tiny",
            local: true,
            ceiling: 700
        )

        await assertAskError(.inputTooLarge) {
            _ = try await service.answer(
                question: String(repeating: "Ж", count: 800),
                execution: execution,
                requestID: UUID(),
                limits: AskGenerationLimits(
                    retrievalLimit: 10,
                    maximumSampleCharacters: 360,
                    maximumOutputTokens: 200,
                    requestTimeout: .seconds(10)
                )
            )
        }
        let retrievalCount = await retrieval.callCount()
        let dispatchCount = await router.callCount()
        XCTAssertEqual(retrievalCount, 0)
        XCTAssertEqual(dispatchCount, 0)
    }

    func testUnavailableAndChangedSelectionFailClosed() async throws {
        let cases: [(LLMRouterError, AskServiceError)] = [
            (.noAuthorizedSelection, .selectionUnavailable),
            (.adapterUnavailable, .selectionUnavailable),
            (.selectionChanged, .selectionChanged),
        ]
        for (routerError, expected) in cases {
            let retrieval = StubAskRetrieval(evidence: [evidence(id: 1, text: "evidence")])
            let router = StubAskRouter(result: .failure(routerError))
            let service = AskService(retrieval: retrieval, router: router)
            await assertAskError(expected) {
                _ = try await service.answer(
                    question: "Question",
                    execution: self.context(provider: .ollama, model: "local", local: true),
                    requestID: UUID()
                )
            }
        }
    }

    func testMismatchedProvenanceFailsClosed() async throws {
        let execution = context(
            provider: .openrouter,
            model: "cloud-model",
            local: false,
            recipient: AIProvider.openrouter.egressDestination
        )
        let mismatched = LLMResponse(
            content: "Answer [1]",
            truncated: false,
            provenance: AIExecutionProvenance(
                providerID: execution.selection.providerID,
                modelID: execution.selection.modelID,
                executedLocally: true,
                generatedAt: Date(),
                brokerUpstream: nil
            )
        )
        let service = AskService(
            retrieval: StubAskRetrieval(evidence: [evidence(id: 1, text: "evidence")]),
            router: StubAskRouter(result: .success(mismatched))
        )
        await assertAskError(.provenanceMismatch) {
            _ = try await service.answer(
                question: "Question",
                execution: execution,
                requestID: UUID()
            )
        }
    }

    func testRouterRejectsChangedBudgetSnapshotBeforeAdapterDispatch() async throws {
        let expected = context(provider: .ollama, model: "old", local: true).selection
        let current = ProviderSelectionSnapshot(
            providerID: expected.providerID,
            modelID: "new",
            selectionRevision: SelectionRevision(rawValue: 8),
            authorizationEpoch: AuthorizationEpoch(rawValue: 12)
        )
        let snapshots = FixedAskSnapshots(current)
        let adapter = CountingAskAdapter()
        let registry = FixedAskRegistry(
            registration: LLMAdapterRegistration(
                providerID: current.providerID,
                executedLocally: true,
                adapter: adapter
            )
        )
        let router = LLMRouter(snapshotProvider: snapshots, adapterRegistry: registry)
        let request = LLMRequest(
            id: UUID(),
            consumer: .ask,
            priority: .ask,
            systemPrompt: "system",
            userPrompt: "user",
            maximumOutputTokens: 10,
            timeout: .seconds(1)
        )

        do {
            _ = try await router.generate(request, expectedSelection: expected)
            XCTFail("Expected selectionChanged")
        } catch let error as LLMRouterError {
            XCTAssertEqual(error, .selectionChanged)
        }
        let dispatches = await adapter.callCount()
        XCTAssertEqual(dispatches, 0)
    }

    // MARK: helpers

    private func context(
        provider: AIProvider,
        model: String,
        local: Bool,
        recipient: String? = nil,
        ceiling: Int = 4_096
    ) -> AskExecutionContext {
        AskExecutionContext(
            selection: ProviderSelectionSnapshot(
                providerID: provider.rawValue,
                modelID: model,
                selectionRevision: SelectionRevision(rawValue: 7),
                authorizationEpoch: AuthorizationEpoch(rawValue: 11)
            ),
            contextTokenCeiling: ceiling,
            executedLocally: local,
            recipientDisclosure: recipient
        )
    }

    private func evidence(
        id: Int64,
        kind: SearchKind = .screen,
        text: String
    ) -> AskRetrievedEvidence {
        AskRetrievedEvidence(
            source: SearchResult(
                id: id,
                kind: kind,
                ts: Date(timeIntervalSince1970: Double(id)),
                bundleId: kind == .screen ? "gg.test" : nil,
                appName: kind == .screen ? "Test App" : "Other party",
                windowTitle: nil,
                browserURL: nil,
                snippet: text,
                relativePath: nil
            ),
            text: text
        )
    }

    private func response(
        content: String,
        execution: AskExecutionContext,
        generatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        upstream: String? = nil
    ) -> LLMResponse {
        LLMResponse(
            content: content,
            truncated: false,
            provenance: AIExecutionProvenance(
                providerID: execution.selection.providerID,
                modelID: execution.selection.modelID,
                executedLocally: execution.executedLocally,
                generatedAt: generatedAt,
                brokerUpstream: upstream
            )
        )
    }

    private func assertAskError(
        _ expected: AskServiceError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as AskServiceError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))")
        }
    }
}

private actor StubAskRetrieval: AskRetrievalProviding {
    private let evidence: [AskRetrievedEvidence]
    private var count = 0

    init(evidence: [AskRetrievedEvidence]) {
        self.evidence = evidence
    }

    func retrieve(question: String, limit: Int) async throws -> [AskRetrievedEvidence] {
        count += 1
        return Array(evidence.prefix(limit))
    }

    func callCount() -> Int { count }
}

private actor ScopedRecordingAskRetrieval: AskRetrievalProviding {
    private let evidence: [AskRetrievedEvidence]
    private var scopes: [AskScopeSnapshot] = []

    init(evidence: [AskRetrievedEvidence]) {
        self.evidence = evidence
    }

    func retrieve(question: String, limit: Int) async throws -> [AskRetrievedEvidence] {
        Array(evidence.prefix(limit))
    }

    func retrieve(
        question: String,
        scope: AskScopeSnapshot,
        limit: Int
    ) async throws -> [AskRetrievedEvidence] {
        scopes.append(scope)
        return Array(evidence.prefix(limit))
    }

    func recordedScopes() -> [AskScopeSnapshot] { scopes }
}

private actor LegacyOnlyAskRetrieval: AskRetrievalProviding {
    private let evidence: [AskRetrievedEvidence]
    private var count = 0

    init(evidence: [AskRetrievedEvidence]) {
        self.evidence = evidence
    }

    func retrieve(question: String, limit: Int) async throws -> [AskRetrievedEvidence] {
        count += 1
        return Array(evidence.prefix(limit))
    }

    func callCount() -> Int { count }
}

private actor StubAskRouter: AskLLMRouting {
    struct Call: Sendable {
        let request: LLMRequest
        let expectedSelection: ProviderSelectionSnapshot
    }

    private let result: Result<LLMResponse, LLMRouterError>
    private var recorded: [Call] = []

    init(result: Result<LLMResponse, LLMRouterError>) {
        self.result = result
    }

    func generate(
        _ request: LLMRequest,
        expectedSelection: ProviderSelectionSnapshot
    ) async throws -> LLMResponse {
        recorded.append(Call(request: request, expectedSelection: expectedSelection))
        return try result.get()
    }

    func calls() -> [Call] { recorded }
    func callCount() -> Int { recorded.count }
}

private struct FixedAskSnapshots: LLMSelectionSnapshotProviding {
    let snapshot: ProviderSelectionSnapshot?

    init(_ snapshot: ProviderSelectionSnapshot?) {
        self.snapshot = snapshot
    }

    func currentSnapshot(for consumer: AIConsumer) async -> ProviderSelectionSnapshot? {
        snapshot
    }
}

private struct FixedAskRegistry: LLMAdapterRegistering {
    let registration: LLMAdapterRegistration?

    func registration(for providerID: String) async -> LLMAdapterRegistration? {
        registration
    }
}

private actor CountingAskAdapter: LLMAdapter {
    private var count = 0

    func generate(
        request: LLMRequest,
        selection: ProviderSelectionSnapshot
    ) async throws -> LLMResponse {
        count += 1
        return LLMResponse(
            content: "unused",
            truncated: false,
            provenance: AIExecutionProvenance(
                providerID: selection.providerID,
                modelID: selection.modelID,
                executedLocally: true,
                generatedAt: Date(),
                brokerUpstream: nil
            )
        )
    }

    func callCount() -> Int { count }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
