import Foundation
import XCTest

final class AIConsumerGenerationTests: XCTestCase {
    func testLocalInsightsDispatchCarriesExactSelectionLanguageContractAndProvenance() async throws {
        let execution = context(provider: .ollama, model: "qwen-local", local: true)
        let generatedAt = Date(timeIntervalSince1970: 1_800_100_000)
        let router = StubConsumerRouter(result: .success(response(
            content: "Сборка прошла.\nКонтекст переключался часто.",
            execution: execution,
            generatedAt: generatedAt
        )))
        let generator = RoutedAIConsumerGenerator(router: router)
        let requestID = UUID()

        let result = try await generator.generate(
            plan: plan(
                consumer: .dailyInsights,
                priority: .explicitInsight,
                promptVersion: "daily-insights-v2",
                language: .ru,
                purpose: .insights,
                fragments: [
                    .init(sourceID: "top_app", text: "Xcode — 120 минут"),
                    .init(sourceID: "context_switches", text: "38 переключений контекста"),
                ]
            ),
            execution: execution,
            requestID: requestID
        )

        XCTAssertEqual(result.content, "Сборка прошла.\nКонтекст переключался часто.")
        XCTAssertEqual(result.promptVersion, "daily-insights-v2")
        XCTAssertEqual(result.provenance.generatedAt, generatedAt)
        XCTAssertTrue(result.provenance.executedLocally)

        let calls = await router.calls()
        let call = try XCTUnwrap(calls.only)
        XCTAssertEqual(call.expectedSelection, execution.selection)
        XCTAssertEqual(call.request.id, requestID)
        XCTAssertEqual(call.request.consumer, .dailyInsights)
        XCTAssertEqual(call.request.priority, .explicitInsight)
        XCTAssertEqual(call.request.localOutputContract?.purpose, .insights)
        XCTAssertEqual(call.request.localOutputContract?.language, .ru)
        XCTAssertEqual(
            call.request.localOutputContract?.allowedSources,
            Set(["top_app", "context_switches"])
        )
    }

    func testSyntheticCloudSummaryPreservesBrokerAndDeterministicallyCompactsOversizedDay() async throws {
        let execution = context(
            provider: .openrouter,
            model: "anthropic/claude-haiku",
            local: false,
            recipient: AIProvider.openrouter.egressDestination,
            ceiling: 2_100
        )
        let fragments = (0..<12).map {
            AIConsumerPromptFragment(
                sourceID: "slice:\($0)",
                text: "[10:00-10:30] Xcode " + String(repeating: "implementation ", count: 30)
            )
        }

        func run() async throws -> (AIConsumerGenerationResult, LLMRequest) {
            let router = StubConsumerRouter(result: .success(response(
                content: "## What I worked on\n- Implemented the router.",
                execution: execution,
                upstream: "Anthropic"
            )))
            let generator = RoutedAIConsumerGenerator(router: router)
            let result = try await generator.generate(
                plan: plan(
                    consumer: .manualSummary,
                    priority: .explicitInsight,
                    promptVersion: "daily-summary-v2",
                    language: .en,
                    purpose: .summary,
                    fragments: fragments,
                    maximumFragmentCharacters: 1_000,
                    maximumOutputTokens: 300
                ),
                execution: execution,
                requestID: UUID()
            )
            let calls = await router.calls()
            return (result, try XCTUnwrap(calls.only?.request))
        }

        let first = try await run()
        let second = try await run()
        XCTAssertEqual(first.1.systemPrompt, second.1.systemPrompt)
        XCTAssertEqual(first.1.userPrompt, second.1.userPrompt)
        XCTAssertEqual(first.0.includedSourceIDs, second.0.includedSourceIDs)
        XCTAssertTrue(first.0.contextTruncated)
        XCTAssertLessThan(first.0.includedSourceIDs.count, fragments.count)
        XCTAssertEqual(first.0.provenance.brokerUpstream, "Anthropic")
        XCTAssertFalse(first.0.provenance.executedLocally)
        XCTAssertEqual(first.1.localOutputContract?.purpose, .summary)
        XCTAssertEqual(
            first.1.localOutputContract?.allowedSources,
            Set(first.0.includedSourceIDs)
        )
        XCTAssertLessThanOrEqual(
            LocalAIContextPolicy.generationTokenUpperBound(
                systemPrompt: first.1.systemPrompt,
                userPrompt: first.1.userPrompt,
                outputTokens: first.1.maximumOutputTokens
            ),
            execution.contextTokenCeiling
        )
    }

    func testGeneratedLabelUsesAutomaticPriorityAndStructuredLabelContract() async throws {
        let execution = context(provider: .zbsEyeLocal, model: "built-in", local: true)
        let router = StubConsumerRouter(result: .success(response(
            content: "Работа над ZBS Eye в Xcode",
            execution: execution
        )))
        let generator = RoutedAIConsumerGenerator(router: router)

        _ = try await generator.generate(
            plan: plan(
                consumer: .generatedLabels,
                priority: .generatedLabels,
                promptVersion: "block-label-v2",
                language: .ru,
                purpose: .label,
                fragments: [.init(sourceID: "activity_block", text: "Xcode, ZBS Eye")],
                maximumOutputTokens: 60
            ),
            execution: execution,
            requestID: UUID()
        )

        let calls = await router.calls()
        let request = try XCTUnwrap(calls.only?.request)
        XCTAssertEqual(request.consumer, .generatedLabels)
        XCTAssertEqual(request.priority, .generatedLabels)
        XCTAssertEqual(request.localOutputContract?.purpose, .label)
        XCTAssertEqual(request.localOutputContract?.allowedSources, ["activity_block"])
    }

    func testOversizedFixedPromptFailsBeforeDispatch() async {
        let execution = context(
            provider: .zbsEyeLocal,
            model: "tiny",
            local: true,
            ceiling: 900
        )
        let router = StubConsumerRouter(result: .failure(.adapterUnavailable))
        let generator = RoutedAIConsumerGenerator(router: router)

        await assertGenerationError(.inputTooLarge) {
            _ = try await generator.generate(
                plan: self.plan(
                    consumer: .manualSummary,
                    priority: .explicitInsight,
                    promptVersion: "daily-summary-v2",
                    language: .ru,
                    purpose: .summary,
                    systemPrompt: String(repeating: "Ж", count: 900),
                    fragments: [.init(sourceID: "slice:0", text: "unused")],
                    maximumOutputTokens: 300
                ),
                execution: execution,
                requestID: UUID()
            )
        }
        let callCount = await router.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testSelectionErrorsAndMismatchedProvenanceFailClosed() async {
        let execution = context(provider: .ollama, model: "local", local: true)
        for (routerError, expected) in [
            (LLMRouterError.noAuthorizedSelection, AIConsumerGenerationError.selectionUnavailable),
            (.adapterUnavailable, .selectionUnavailable),
            (.selectionChanged, .selectionChanged),
        ] {
            let generator = RoutedAIConsumerGenerator(
                router: StubConsumerRouter(result: .failure(routerError))
            )
            await assertGenerationError(expected) {
                _ = try await generator.generate(
                    plan: self.plan(
                        consumer: .dailyInsights,
                        priority: .explicitInsight,
                        promptVersion: "daily-insights-v2",
                        language: .en,
                        purpose: .insights,
                        fragments: [.init(sourceID: "top_app", text: "Xcode")]
                    ),
                    execution: execution,
                    requestID: UUID()
                )
            }
        }

        let mismatched = LLMResponse(
            content: "Wrong locality",
            truncated: false,
            provenance: .init(
                providerID: execution.selection.providerID,
                modelID: execution.selection.modelID,
                executedLocally: false,
                generatedAt: Date(),
                brokerUpstream: nil
            )
        )
        let generator = RoutedAIConsumerGenerator(
            router: StubConsumerRouter(result: .success(mismatched))
        )
        await assertGenerationError(.provenanceMismatch) {
            _ = try await generator.generate(
                plan: self.plan(
                    consumer: .dailyInsights,
                    priority: .explicitInsight,
                    promptVersion: "daily-insights-v2",
                    language: .en,
                    purpose: .insights,
                    fragments: [.init(sourceID: "top_app", text: "Xcode")]
                ),
                execution: execution,
                requestID: UUID()
            )
        }
    }

    func testRequestOwnershipRejectsNewRequestSwitchAndConsentRevocation() {
        let initial = context(provider: .openrouter, model: "model-a", local: false,
                              recipient: AIProvider.openrouter.egressDestination)
        let requestID = UUID()
        let ownership = AIConsumerRequestOwnership(
            requestID: requestID,
            consumer: .dailyInsights,
            execution: initial
        )

        XCTAssertTrue(ownership.accepts(
            requestID: requestID,
            consumer: .dailyInsights,
            execution: initial
        ))
        XCTAssertFalse(ownership.accepts(
            requestID: UUID(),
            consumer: .dailyInsights,
            execution: initial
        ))

        let switched = context(provider: .openrouter, model: "model-b", local: false,
                               recipient: AIProvider.openrouter.egressDestination,
                               revision: 2, authorization: 1)
        XCTAssertFalse(ownership.accepts(
            requestID: requestID,
            consumer: .dailyInsights,
            execution: switched
        ))

        let revoked = context(provider: .openrouter, model: "model-a", local: false,
                              recipient: AIProvider.openrouter.egressDestination,
                              revision: 1, authorization: 2)
        XCTAssertFalse(ownership.accepts(
            requestID: requestID,
            consumer: .dailyInsights,
            execution: revoked
        ))
    }

    func testGeneratedLabelCacheIdentityIncludesPairAuthorizationAndPromptVersion() {
        let base = context(provider: .ollama, model: "qwen", local: true)
        let identity = GeneratedLabelCacheIdentity(
            selection: base.selection,
            promptVersion: "block-label-v2",
            blockFingerprint: "block"
        )
        XCTAssertNotEqual(identity, .init(
            selection: context(provider: .lmstudio, model: "qwen", local: true).selection,
            promptVersion: "block-label-v2",
            blockFingerprint: "block"
        ))
        XCTAssertNotEqual(identity, .init(
            selection: context(provider: .ollama, model: "qwen-2", local: true).selection,
            promptVersion: "block-label-v2",
            blockFingerprint: "block"
        ))
        XCTAssertNotEqual(identity, .init(
            selection: context(provider: .ollama, model: "qwen", local: true,
                               authorization: 2).selection,
            promptVersion: "block-label-v2",
            blockFingerprint: "block"
        ))
        XCTAssertNotEqual(identity, .init(
            selection: base.selection,
            promptVersion: "block-label-v3",
            blockFingerprint: "block"
        ))
    }

    func testVersionedFactoriesProduceEnglishRussianAndAutomaticConsumerContracts() {
        let hints = LocalAIInsightsHints(
            mode: .normal,
            totalCaptures: 500,
            contextSwitches: 38,
            topApp: .init(name: "Xcode", minutes: 120, captures: 300),
            secondApp: .init(name: "Safari", minutes: 40, captures: 100),
            safeResultSamples: ["Сборка успешно завершена"]
        )
        let insights = AIConsumerPromptFactory.dailyInsights(
            hints: hints,
            language: .ru,
            maximumSampleCharacters: 360,
            timeout: .seconds(30)
        )
        XCTAssertEqual(insights.consumer, .dailyInsights)
        XCTAssertEqual(insights.promptVersion, "daily-insights-v4")
        XCTAssertEqual(insights.purpose, .insights)
        XCTAssertTrue(insights.systemPrompt.contains("по-русски"))
        XCTAssertEqual(
            Set(insights.fragments.map(\.sourceID)),
            Set(hints.requiredOutputSourceIDs)
        )

        let summary = AIConsumerPromptFactory.dailySummary(
            consumer: .scheduledSummary,
            language: .en,
            dateLine: "Friday, 11 July 2026",
            countLine: "Sessions: 2",
            fragments: [.init(sourceID: "slice:0", text: "Xcode")],
            maximumFragmentCharacters: 900,
            maximumOutputTokens: 800,
            timeout: .seconds(30)
        )
        XCTAssertEqual(summary.consumer, .scheduledSummary)
        XCTAssertEqual(summary.priority, .scheduledSummary)
        XCTAssertEqual(summary.promptVersion, "daily-summary-v4")
        XCTAssertEqual(summary.purpose, .summary)
        XCTAssertTrue(summary.userPostamble.contains("## What I worked on"))

        let activitySummary = AIConsumerPromptFactory.activitySummary(
            language: .ru,
            dateLine: "11 июля 2026",
            fragments: [
                .init(sourceID: "activity:0", text: "Собирал релиз ZBS Eye"),
                .init(sourceID: "activity:1", text: "Проверял автоматические звонки"),
                .init(sourceID: "activity:2", text: "Исправлял приоритет скриншотов"),
            ],
            maximumFragmentCharacters: 900,
            maximumOutputTokens: 500,
            timeout: .seconds(30)
        )
        XCTAssertEqual(activitySummary.consumer, .activitySummary)
        XCTAssertEqual(activitySummary.priority, .explicitInsight)
        XCTAssertEqual(activitySummary.promptVersion, "activity-summary-v1")
        XCTAssertEqual(activitySummary.purpose, .summary)
        XCTAssertTrue(activitySummary.systemPrompt.contains("3–6"))
        XCTAssertTrue(activitySummary.userPostamble.contains("ровно 3–6"))

        let label = AIConsumerPromptFactory.generatedLabel(
            serializedBlock: #"{"apps":["Xcode"]}"#,
            language: .ru,
            maximumFragmentCharacters: 900,
            timeout: .seconds(30)
        )
        XCTAssertEqual(label.consumer, .generatedLabels)
        XCTAssertEqual(label.priority, .generatedLabels)
        XCTAssertEqual(label.promptVersion, "block-label-v4")
        XCTAssertEqual(label.purpose, .label)
        XCTAssertTrue(label.systemPrompt.contains("по-русски"))
    }

    func testActivitySummaryOutputRequiresThreeToSixPlainGroundedBullets() async throws {
        let execution = context(
            provider: .anthropic,
            model: "claude-haiku-4-5-20251001",
            local: false,
            recipient: AIProvider.anthropic.egressDestination
        )
        let plan = AIConsumerPromptFactory.activitySummary(
            language: .en,
            dateLine: "Friday",
            fragments: [
                .init(sourceID: "activity:0", text: "Prepared the ZBS Eye release"),
                .init(sourceID: "activity:1", text: "Tested automatic Calls"),
                .init(sourceID: "activity:2", text: "Fixed screenshot priority"),
            ],
            maximumFragmentCharacters: 900,
            maximumOutputTokens: 500,
            timeout: .seconds(30)
        )
        let valid = "- Prepared the ZBS Eye release\n- Tested automatic Calls\n- Fixed screenshot priority"
        XCTAssertTrue(ActivitySummaryOutputValidator.isValid(valid))
        XCTAssertFalse(ActivitySummaryOutputValidator.isValid("## What I did\n\(valid)"))
        XCTAssertFalse(ActivitySummaryOutputValidator.isValid("- One\n- Two"))
        XCTAssertFalse(ActivitySummaryOutputValidator.isValid("\(valid)\n- Read https://example.com"))

        let accepted = try await RoutedAIConsumerGenerator(
            router: StubConsumerRouter(result: .success(response(
                content: valid,
                execution: execution
            )))
        ).generate(plan: plan, execution: execution, requestID: UUID())
        XCTAssertEqual(accepted.content, valid)

        await assertGenerationError(.generationFailed) {
            _ = try await RoutedAIConsumerGenerator(
                router: StubConsumerRouter(result: .success(self.response(
                    content: "## Generic paragraph",
                    execution: execution
                )))
            ).generate(plan: plan, execution: execution, requestID: UUID())
        }
    }

    func testSummaryMetadataStaysOutOfContentAndLabelBudgetCoversToolEnvelope() {
        for language in [LocalAIOutputLanguage.en, .ru] {
            let summary = AIConsumerPromptFactory.dailySummary(
                consumer: .manualSummary,
                language: language,
                dateLine: language == .ru ? "Пятница" : "Friday",
                countLine: language == .ru ? "Сессий: 2" : "Sessions: 2",
                fragments: [.init(sourceID: "slice:0", text: "Implemented the router")],
                maximumFragmentCharacters: 900,
                maximumOutputTokens: 800,
                timeout: .seconds(30)
            )
            XCTAssertEqual(summary.promptVersion, "daily-summary-v4")
            XCTAssertTrue(summary.systemPrompt.contains(
                language == .ru
                    ? "Дата и числа сессий/кадров — только служебный контекст"
                    : "Date and session/frame counts are coverage metadata only"
            ))
            XCTAssertTrue(summary.systemPrompt.contains(
                language == .ru
                    ? "Любое число в резюме должно дословно присутствовать во включённом фрагменте истории."
                    : "Every number in the summary must appear verbatim inside an included history fragment."
            ))
        }

        for language in [LocalAIOutputLanguage.en, .ru] {
            let label = AIConsumerPromptFactory.generatedLabel(
                serializedBlock: #"{"apps":["Xcode"]}"#,
                language: language,
                maximumFragmentCharacters: 900,
                timeout: .seconds(30)
            )
            XCTAssertEqual(label.maximumOutputTokens, 160)
            XCTAssertEqual(label.promptVersion, "block-label-v4")
            XCTAssertTrue(label.systemPrompt.contains(
                language == .ru
                    ? "самую конкретную тему или проект"
                    : "the most specific project or topic"
            ))
            XCTAssertTrue(label.nativeToolSystemPrompt?.contains(
                language == .ru
                    ? "Не добавляй остальные необязательные поля."
                    : "Omit all remaining optional fields."
            ) == true)
        }
    }

    func testInsightsFactorySeparatesTrustedNativeAndVisibleDirections() {
        let base = LocalAIInsightsHints(
            mode: .normal,
            totalCaptures: 120,
            contextSwitches: 9,
            topApp: .init(name: "Xcode", minutes: 60, captures: 80),
            secondApp: .init(name: "Safari", minutes: 30, captures: 40),
            safeResultSamples: []
        )
        let modes: [(LocalAIInsightsHints, String)] = [
            (base, "normal"),
            (.init(
                mode: .conflict,
                totalCaptures: base.totalCaptures,
                contextSwitches: base.contextSwitches,
                topApp: base.topApp,
                secondApp: base.secondApp,
                safeResultSamples: ["Release is Monday", "Release is Tuesday"]
            ), "conflict"),
            (.init(
                mode: .insufficient,
                totalCaptures: 5,
                contextSwitches: 1,
                topApp: base.topApp,
                secondApp: nil,
                safeResultSamples: []
            ), "insufficient"),
        ]

        for (hints, mode) in modes {
            let plan = AIConsumerPromptFactory.dailyInsights(
                hints: hints,
                language: .en,
                maximumSampleCharacters: 360,
                timeout: .seconds(30)
            )
            XCTAssertEqual(plan.promptVersion, "daily-insights-v4")
            XCTAssertFalse(plan.systemPrompt.contains("emit_zbs_eye_answer"))
            XCTAssertTrue(plan.nativeToolSystemPrompt?.contains(
                "function emit_zbs_eye_answer is available"
            ) == true)
            XCTAssertTrue(plan.nativeToolSystemPrompt?.contains("MUST call it exactly once") == true)
            XCTAssertTrue(plan.userPostamble.contains("Trusted mode: \(mode)"))
            XCTAssertFalse(plan.systemPrompt.contains("item1_text"))
            XCTAssertFalse(plan.systemPrompt.contains("{"))
        }

        let insufficient = AIConsumerPromptFactory.dailyInsights(
            hints: modes[2].0,
            language: .en,
            maximumSampleCharacters: 360,
            timeout: .seconds(30)
        )
        XCTAssertTrue(insufficient.nativeToolSystemPrompt?.contains("status insufficient") == true)
        XCTAssertTrue(insufficient.systemPrompt.contains(
            "There is not enough data for a reliable insight."
        ))
    }

    func testSyntheticCloudInsightsSummaryAndLabelReturnOnlyUserVisibleContent() async throws {
        let execution = context(
            provider: .openrouter,
            model: "anthropic/claude-haiku",
            local: false,
            recipient: AIProvider.openrouter.egressDestination
        )
        let hints = LocalAIInsightsHints(
            mode: .normal,
            totalCaptures: 400,
            contextSwitches: 12,
            topApp: .init(name: "Xcode", minutes: 95, captures: 250),
            secondApp: .init(name: "Safari", minutes: 30, captures: 80),
            safeResultSamples: []
        )
        let cases: [(AIConsumerGenerationPlan, String)] = [
            (
                AIConsumerPromptFactory.dailyInsights(
                    hints: hints,
                    language: .en,
                    maximumSampleCharacters: 360,
                    timeout: .seconds(30)
                ),
                "Xcode led the day with 95 minutes.\nThere were 12 context switches."
            ),
            (
                AIConsumerPromptFactory.dailySummary(
                    consumer: .manualSummary,
                    language: .en,
                    dateLine: "Friday",
                    countLine: "Sessions: 1",
                    fragments: [.init(sourceID: "slice:0", text: "Xcode release work")],
                    maximumFragmentCharacters: 900,
                    maximumOutputTokens: 800,
                    timeout: .seconds(30)
                ),
                "## What I worked on\n- Prepared the release in Xcode."
            ),
            (
                AIConsumerPromptFactory.generatedLabel(
                    serializedBlock: #"{"apps":["Xcode"]}"#,
                    language: .en,
                    maximumFragmentCharacters: 900,
                    timeout: .seconds(30)
                ),
                "Preparing the ZBS Eye release in Xcode"
            ),
        ]

        for (plan, visibleContent) in cases {
            XCTAssertFalse(plan.systemPrompt.contains("emit_zbs_eye_answer"))
            let router = StubConsumerRouter(result: .success(response(
                content: visibleContent,
                execution: execution,
                upstream: "Anthropic"
            )))
            let result = try await RoutedAIConsumerGenerator(router: router).generate(
                plan: plan,
                execution: execution,
                requestID: UUID()
            )
            XCTAssertEqual(result.content, visibleContent)
            XCTAssertFalse(result.content.contains("item1_text"))
            XCTAssertFalse(result.content.hasPrefix("{"))
            let calls = await router.calls()
            XCTAssertNotNil(calls.only?.request.localOutputContract)
        }
    }

    func testBuiltInUsesMandatoryNativeToolPromptsWhileVisibleProvidersNeverSeeToolInstructions() async throws {
        let hints = LocalAIInsightsHints(
            mode: .normal,
            totalCaptures: 400,
            contextSwitches: 12,
            topApp: .init(name: "Xcode", minutes: 95, captures: 250),
            secondApp: .init(name: "Safari", minutes: 30, captures: 80),
            safeResultSamples: []
        )
        let plans = [
            AIConsumerPromptFactory.dailyInsights(
                hints: hints,
                language: .en,
                maximumSampleCharacters: 360,
                timeout: .seconds(30)
            ),
            AIConsumerPromptFactory.dailySummary(
                consumer: .manualSummary,
                language: .ru,
                dateLine: "Пятница",
                countLine: "Сессий: 1",
                fragments: [.init(sourceID: "slice:0", text: "Работа над релизом")],
                maximumFragmentCharacters: 900,
                maximumOutputTokens: 800,
                timeout: .seconds(30)
            ),
            AIConsumerPromptFactory.generatedLabel(
                serializedBlock: #"{"apps":["Xcode"]}"#,
                language: .en,
                maximumFragmentCharacters: 900,
                timeout: .seconds(30)
            ),
        ]

        for plan in plans {
            for provider in [AIProvider.zbsEyeLocal, .ollama, .openrouter] {
                let local = !provider.isCloud
                let execution = context(
                    provider: provider,
                    model: "model",
                    local: local,
                    recipient: provider.egressDestination
                )
                let router = StubConsumerRouter(result: .success(response(
                    content: "Visible result",
                    execution: execution,
                    upstream: provider.isCloud ? "upstream" : nil
                )))
                _ = try await RoutedAIConsumerGenerator(router: router).generate(
                    plan: plan,
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

    private func plan(
        consumer: AIConsumer,
        priority: LLMRequestPriority,
        promptVersion: String,
        language: LocalAIOutputLanguage,
        purpose: LocalAIOutputPurpose,
        systemPrompt: String = "System prompt",
        fragments: [AIConsumerPromptFragment],
        maximumFragmentCharacters: Int = 500,
        maximumOutputTokens: Int = 200
    ) -> AIConsumerGenerationPlan {
        AIConsumerGenerationPlan(
            consumer: consumer,
            priority: priority,
            promptVersion: promptVersion,
            language: language,
            purpose: purpose,
            systemPrompt: systemPrompt,
            nativeToolSystemPrompt: LocalAINativeToolPrompt.system(
                taskInstructions: systemPrompt,
                purposeInstructions: "Use the status and source fields required for this consumer."
            ),
            userPreamble: "Evidence:\n",
            fragments: fragments,
            userPostamble: "\nReturn the result.",
            nativeToolUserPostamble: "\nFill the function fields from the evidence.",
            maximumFragmentCharacters: maximumFragmentCharacters,
            maximumOutputTokens: maximumOutputTokens,
            timeout: .seconds(30)
        )
    }

    private func context(
        provider: AIProvider,
        model: String,
        local: Bool,
        recipient: String? = nil,
        ceiling: Int = 4_096,
        revision: UInt64 = 1,
        authorization: UInt64 = 1
    ) -> AIConsumerExecutionContext {
        AIConsumerExecutionContext(
            selection: .init(
                providerID: provider.rawValue,
                modelID: model,
                selectionRevision: .init(rawValue: revision),
                authorizationEpoch: .init(rawValue: authorization)
            ),
            contextTokenCeiling: ceiling,
            executedLocally: local,
            recipientDisclosure: recipient
        )
    }

    private func response(
        content: String,
        execution: AIConsumerExecutionContext,
        generatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        upstream: String? = nil
    ) -> LLMResponse {
        LLMResponse(
            content: content,
            truncated: false,
            provenance: .init(
                providerID: execution.selection.providerID,
                modelID: execution.selection.modelID,
                executedLocally: execution.executedLocally,
                generatedAt: generatedAt,
                brokerUpstream: upstream
            )
        )
    }

    private func assertGenerationError(
        _ expected: AIConsumerGenerationError,
        operation: @escaping () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as AIConsumerGenerationError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor StubConsumerRouter: AIConsumerLLMRouting {
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
        recorded.append(.init(request: request, expectedSelection: expectedSelection))
        return try result.get()
    }

    func calls() -> [Call] { recorded }
    func callCount() -> Int { recorded.count }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
