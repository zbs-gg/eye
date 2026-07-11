import Foundation
import XCTest

final class LLMRouterTests: XCTestCase {
    private let snapshot = ProviderSelectionSnapshot(
        providerID: "zbsEyeLocal",
        modelID: "qwen-local",
        selectionRevision: SelectionRevision(rawValue: 7),
        authorizationEpoch: AuthorizationEpoch(rawValue: 11)
    )

    func testRequestCapturesImmutableSelectionAndValidatesMatchingProvenance() async throws {
        let adapter = ControlledLLMAdapter()
        let (router, _, _) = makeRouter(adapter: adapter)
        let request = makeRequest(.ask, id: 1)

        let response = try await router.generate(request)

        XCTAssertEqual(response.content, "answer")
        let captured = await adapter.capturedSelections()
        XCTAssertEqual(captured, [snapshot])
    }

    func testCompletedWorkDoesNotRetainRouterUntilItsTimeoutExpires() async throws {
        let adapter = ControlledLLMAdapter()
        weak var weakRouter: LLMRouter?

        do {
            let (router, _, _) = makeRouter(adapter: adapter)
            weakRouter = router
            _ = try await router.generate(makeRequest(.ask, id: 40))
            let timeoutCount = await router.diagnostics().ownedTimeoutCount
            XCTAssertEqual(timeoutCount, 0)
        }

        let released = await waitForRelease { weakRouter == nil }
        XCTAssertTrue(released, "completed work left its timeout task retaining the router")
    }

    func testCancelledPendingWorkDoesNotRetainRouterUntilItsTimeoutExpires() async throws {
        let adapter = ControlledLLMAdapter()
        weak var weakRouter: LLMRouter?

        do {
            let (router, _, _) = makeRouter(adapter: adapter)
            weakRouter = router
            let blocker = makeRequest(.ask, id: 41)
            let cancelled = makeRequest(.generatedLabels, id: 42)
            await adapter.setBehavior(.gate, for: blocker.id)
            let blockerTask = Task { try await router.generate(blocker) }
            await waitUntilStarted(blocker.id, adapter: adapter)
            let cancelledTask = Task { try await router.generate(cancelled) }
            await waitForQueuedCount(1, router: router)

            cancelledTask.cancel()
            await assertError(.callerCancelled, from: cancelledTask)
            let timeoutCountAfterCancellation = await router.diagnostics().ownedTimeoutCount
            XCTAssertEqual(timeoutCountAfterCancellation, 1)
            await adapter.complete(blocker.id)
            _ = try await blockerTask.value
            let timeoutCountAfterCompletion = await router.diagnostics().ownedTimeoutCount
            XCTAssertEqual(timeoutCountAfterCompletion, 0)
        }

        let released = await waitForRelease { weakRouter == nil }
        XCTAssertTrue(released, "discarded pending work left its timeout task retaining the router")
    }

    func testSupersededPendingWorkDoesNotRetainRouterUntilItsTimeoutExpires() async throws {
        let adapter = ControlledLLMAdapter()
        weak var weakRouter: LLMRouter?

        do {
            let (router, _, _) = makeRouter(adapter: adapter)
            weakRouter = router
            let blocker = makeRequest(.ask, id: 43)
            let oldInsight = makeRequest(.dailyInsights, id: 44, user: "old")
            let newInsight = makeRequest(.dailyInsights, id: 45, user: "new")
            await adapter.setBehavior(.gate, for: blocker.id)
            let blockerTask = Task { try await router.generate(blocker) }
            await waitUntilStarted(blocker.id, adapter: adapter)
            let oldTask = Task { try await router.generate(oldInsight) }
            await waitForQueuedCount(1, router: router)
            let newTask = Task { try await router.generate(newInsight) }

            await assertError(.superseded, from: oldTask)
            let timeoutCountAfterSupersession = await router.diagnostics().ownedTimeoutCount
            XCTAssertEqual(timeoutCountAfterSupersession, 2)
            await adapter.complete(blocker.id)
            _ = try await blockerTask.value
            _ = try await newTask.value
            let timeoutCountAfterCompletion = await router.diagnostics().ownedTimeoutCount
            XCTAssertEqual(timeoutCountAfterCompletion, 0)
        }

        let released = await waitForRelease { weakRouter == nil }
        XCTAssertTrue(released, "superseded work left its timeout task retaining the router")
    }

    func testShutdownDoesNotRetainRouterUntilRequestTimeoutsExpire() async {
        let adapter = ControlledLLMAdapter()
        weak var weakRouter: LLMRouter?

        do {
            let (router, _, _) = makeRouter(
                adapter: adapter,
                drainTimeout: .milliseconds(300)
            )
            weakRouter = router
            let active = makeRequest(.ask, id: 46)
            let queued = makeRequest(.generatedLabels, id: 47)
            await adapter.setBehavior(
                .gateCancellationDelay(.milliseconds(20)),
                for: active.id
            )
            let activeTask = Task { try await router.generate(active) }
            await waitUntilStarted(active.id, adapter: adapter)
            let queuedTask = Task { try await router.generate(queued) }
            await waitForQueuedCount(1, router: router)

            let completed = await router.shutdown(timeout: .milliseconds(300))
            XCTAssertTrue(completed)
            await assertError(.routerShuttingDown, from: activeTask)
            await assertError(.routerShuttingDown, from: queuedTask)
            let timeoutCount = await router.diagnostics().ownedTimeoutCount
            XCTAssertEqual(timeoutCount, 0)
        }

        let released = await waitForRelease { weakRouter == nil }
        XCTAssertTrue(released, "shutdown left request timeout tasks retaining the router")
    }

    func testUnhealthyDrainDoesNotRetainRouterUntilRequestTimeoutsExpire() async {
        let adapter = ControlledLLMAdapter()
        weak var weakRouter: LLMRouter?

        do {
            let (router, _, _) = makeRouter(
                adapter: adapter,
                drainTimeout: .milliseconds(30)
            )
            weakRouter = router
            let labels = makeRequest(.generatedLabels, id: 48)
            let ask = makeRequest(.ask, id: 49)
            await adapter.setBehavior(.gateIgnoringCancellation, for: labels.id)
            let labelsTask = Task { try await router.generate(labels) }
            await waitUntilStarted(labels.id, adapter: adapter)
            let askTask = Task { try await router.generate(ask) }

            await assertError(.routerUnhealthy, from: askTask)
            await assertError(.routerUnhealthy, from: labelsTask)
            let timeoutCount = await router.diagnostics().ownedTimeoutCount
            XCTAssertEqual(timeoutCount, 0)
            await adapter.complete(labels.id)
            await waitForNoActiveWork(router)
        }

        let released = await waitForRelease { weakRouter == nil }
        XCTAssertTrue(released, "an unhealthy drain left request timeout tasks retaining the router")
    }

    func testPriorityOrderAndExactlyOneActiveGeneration() async throws {
        let adapter = ControlledLLMAdapter()
        let (router, _, _) = makeRouter(adapter: adapter)
        let ask = makeRequest(.ask, id: 1)
        let labels = makeRequest(.generatedLabels, id: 2)
        let scheduled = makeRequest(.scheduledSummary, id: 3)
        let insight = makeRequest(.dailyInsights, id: 4)
        await adapter.setBehavior(.gate, for: ask.id)

        let askTask = Task { try await router.generate(ask) }
        await waitUntilStarted(ask.id, adapter: adapter)
        let labelTask = Task { try await router.generate(labels) }
        let scheduledTask = Task { try await router.generate(scheduled) }
        let insightTask = Task { try await router.generate(insight) }
        await waitForQueuedCount(3, router: router)

        await adapter.complete(ask.id)

        _ = try await askTask.value
        _ = try await insightTask.value
        _ = try await scheduledTask.value
        _ = try await labelTask.value
        let starts = await adapter.startedRequestIDs()
        let maximumConcurrent = await adapter.maximumConcurrentGenerations()
        XCTAssertEqual(starts, [ask.id, insight.id, scheduled.id, labels.id])
        XCTAssertEqual(maximumConcurrent, 1)
    }

    func testHigherPriorityCancelsLowerAndWaitsForAcknowledgedDrain() async throws {
        let adapter = ControlledLLMAdapter()
        let (router, _, _) = makeRouter(
            adapter: adapter,
            drainTimeout: .milliseconds(300)
        )
        let labels = makeRequest(.generatedLabels, id: 1)
        let ask = makeRequest(.ask, id: 2)
        await adapter.setBehavior(.gateCancellationDelay(.milliseconds(40)), for: labels.id)

        let lowTask = Task { try await router.generate(labels) }
        await waitUntilStarted(labels.id, adapter: adapter)
        let askTask = Task { try await router.generate(ask) }

        await assertError(.preempted, from: lowTask)
        _ = try await askTask.value
        let starts = await adapter.startedRequestIDs()
        let maximumConcurrent = await adapter.maximumConcurrentGenerations()
        let health = await router.diagnostics().health
        XCTAssertEqual(starts, [labels.id, ask.id])
        XCTAssertEqual(maximumConcurrent, 1)
        XCTAssertEqual(health, .healthy)
    }

    func testUnacknowledgedDrainMarksRouterUnhealthyAndNeverStartsReplacement() async {
        let adapter = ControlledLLMAdapter()
        let (router, _, _) = makeRouter(
            adapter: adapter,
            drainTimeout: .milliseconds(40)
        )
        let labels = makeRequest(.generatedLabels, id: 1)
        let ask = makeRequest(.ask, id: 2)
        await adapter.setBehavior(.gateIgnoringCancellation, for: labels.id)

        let lowTask = Task { try await router.generate(labels) }
        await waitUntilStarted(labels.id, adapter: adapter)
        let askTask = Task { try await router.generate(ask) }

        await assertError(.routerUnhealthy, from: askTask)
        await assertError(.routerUnhealthy, from: lowTask)
        let diagnostic = await router.diagnostics()
        XCTAssertEqual(
            diagnostic.health,
            .unhealthy(.drainAcknowledgementTimedOut)
        )
        let starts = await adapter.startedRequestIDs()
        XCTAssertEqual(starts, [labels.id])

        await adapter.complete(labels.id)
    }

    func testQueuesAreBoundedCoalescedAndLabelContentIsDeduplicated() async throws {
        let adapter = ControlledLLMAdapter()
        let (router, _, _) = makeRouter(adapter: adapter, labelBacklogLimit: 2)
        let blocker = makeRequest(.ask, id: 1)
        await adapter.setBehavior(.gate, for: blocker.id)
        let blockerTask = Task { try await router.generate(blocker) }
        await waitUntilStarted(blocker.id, adapter: adapter)

        let oldInsight = makeRequest(.dailyInsights, id: 2, user: "old")
        let newInsight = makeRequest(.dailyInsights, id: 3, user: "new")
        let oldInsightTask = Task { try await router.generate(oldInsight) }
        await waitForQueuedCount(1, router: router)
        let newInsightTask = Task { try await router.generate(newInsight) }
        await assertError(.superseded, from: oldInsightTask)

        let oldScheduled = makeRequest(.scheduledSummary, id: 4, user: "old")
        let newScheduled = makeRequest(.scheduledSummary, id: 5, user: "new")
        let oldScheduledTask = Task { try await router.generate(oldScheduled) }
        await waitForConsumer(.scheduledSummary, router: router)
        let newScheduledTask = Task { try await router.generate(newScheduled) }
        await assertError(.superseded, from: oldScheduledTask)

        let labelA1 = makeRequest(.generatedLabels, id: 6, user: "same")
        let labelA2 = makeRequest(.generatedLabels, id: 7, user: "same")
        let labelB = makeRequest(.generatedLabels, id: 8, user: "other")
        let labelC = makeRequest(.generatedLabels, id: 9, user: "overflow")
        let labelA1Task = Task { try await router.generate(labelA1) }
        await waitForConsumer(.generatedLabels, router: router)
        let labelA2Task = Task { try await router.generate(labelA2) }
        let labelBTask = Task { try await router.generate(labelB) }
        await waitForLabelBacklog(2, router: router)
        let labelCTask = Task { try await router.generate(labelC) }
        await assertError(.queueFull, from: labelCTask)

        let queued = await router.diagnostics()
        XCTAssertEqual(queued.queued.filter { $0.consumer == .dailyInsights }.count, 1)
        XCTAssertEqual(queued.queued.filter { $0.consumer == .scheduledSummary }.count, 1)
        XCTAssertEqual(queued.labelBacklogCount, 2)

        await adapter.complete(blocker.id)
        _ = try await blockerTask.value
        _ = try await newInsightTask.value
        _ = try await newScheduledTask.value
        _ = try await labelA1Task.value
        _ = try await labelA2Task.value
        _ = try await labelBTask.value

        let starts = await adapter.startedRequestIDs()
        XCTAssertTrue(starts.contains(labelA1.id))
        XCTAssertFalse(starts.contains(labelA2.id), "duplicate content must share one generation")
    }

    func testLabelRequestsWithDifferentLocalOutputContractsDoNotCoalesce() async throws {
        let adapter = ControlledLLMAdapter()
        let (router, _, _) = makeRouter(adapter: adapter, labelBacklogLimit: 8)
        let blocker = makeRequest(.ask, id: 50)
        await adapter.setBehavior(.gate, for: blocker.id)
        let blockerTask = Task { try await router.generate(blocker) }
        await waitUntilStarted(blocker.id, adapter: adapter)

        let requests = [
            makeRequest(
                .generatedLabels,
                id: 51,
                localOutputContract: LocalAIOutputContractRequest(
                    purpose: .label,
                    language: .en,
                    allowedSources: ["scene:1"]
                )
            ),
            makeRequest(
                .generatedLabels,
                id: 52,
                localOutputContract: LocalAIOutputContractRequest(
                    purpose: .summary,
                    language: .en,
                    allowedSources: ["scene:1"]
                )
            ),
            makeRequest(
                .generatedLabels,
                id: 53,
                localOutputContract: LocalAIOutputContractRequest(
                    purpose: .label,
                    language: .ru,
                    allowedSources: ["scene:1"]
                )
            ),
            makeRequest(
                .generatedLabels,
                id: 54,
                localOutputContract: LocalAIOutputContractRequest(
                    purpose: .label,
                    language: .en,
                    allowedSources: ["scene:2"]
                )
            ),
        ]
        let requestTasks = requests.map { request in
            Task { try await router.generate(request) }
        }
        await waitForLabelBacklog(requests.count, router: router)

        await adapter.complete(blocker.id)
        _ = try await blockerTask.value
        for task in requestTasks {
            _ = try await task.value
        }

        let requestIDs = Set(requests.map(\.id))
        let starts = (await adapter.startedRequestIDs()).filter(requestIDs.contains)
        XCTAssertEqual(starts.count, requests.count)
        XCTAssertEqual(Set(starts), requestIDs)
    }

    func testSameRequestIDWithDifferentPayloadDoesNotCoalesce() async throws {
        let adapter = ControlledLLMAdapter()
        let (router, _, _) = makeRouter(adapter: adapter, labelBacklogLimit: 4)
        let blocker = makeRequest(.ask, id: 60)
        await adapter.setBehavior(.gate, for: blocker.id)
        let blockerTask = Task { try await router.generate(blocker) }
        await waitUntilStarted(blocker.id, adapter: adapter)

        let first = makeRequest(
            .generatedLabels,
            id: 61,
            user: "first payload",
            localOutputContract: LocalAIOutputContractRequest(
                purpose: .label,
                language: .en,
                allowedSources: ["scene:1"]
            )
        )
        let second = LLMRequest(
            id: first.id,
            consumer: first.consumer,
            priority: first.priority,
            systemPrompt: first.systemPrompt,
            userPrompt: "second payload",
            maximumOutputTokens: first.maximumOutputTokens,
            timeout: first.timeout,
            localOutputContract: LocalAIOutputContractRequest(
                purpose: .label,
                language: .ru,
                allowedSources: ["scene:2"]
            )
        )
        let firstTask = Task { try await router.generate(first) }
        await waitForLabelBacklog(1, router: router)
        let secondTask = Task { try await router.generate(second) }
        await waitForLabelBacklog(2, router: router)

        await adapter.complete(blocker.id)
        _ = try await blockerTask.value
        _ = try await firstTask.value
        _ = try await secondTask.value

        let starts = (await adapter.startedRequestIDs()).filter { $0 == first.id }
        XCTAssertEqual(starts.count, 2)
    }

    func testSwitchOrRevokeFailsQueuedWorkAndCancelsActiveSnapshot() async {
        let adapter = ControlledLLMAdapter()
        let (router, snapshots, _) = makeRouter(adapter: adapter)
        let ask = makeRequest(.ask, id: 1)
        let labels = makeRequest(.generatedLabels, id: 2)
        await adapter.setBehavior(.gate, for: ask.id)
        let askTask = Task { try await router.generate(ask) }
        await waitUntilStarted(ask.id, adapter: adapter)
        let labelTask = Task { try await router.generate(labels) }
        await waitForQueuedCount(1, router: router)

        await snapshots.set(
            ProviderSelectionSnapshot(
                providerID: snapshot.providerID,
                modelID: snapshot.modelID,
                selectionRevision: snapshot.selectionRevision,
                authorizationEpoch: AuthorizationEpoch(rawValue: 12)
            )
        )
        await router.selectionOrAuthorizationDidChange()

        await assertError(.selectionChanged, from: askTask)
        await assertError(.selectionChanged, from: labelTask)
        let starts = await adapter.startedRequestIDs()
        XCTAssertEqual(starts, [ask.id])
    }

    func testResultIsDiscardedWhenSnapshotChangesWithoutNotification() async {
        let adapter = ControlledLLMAdapter()
        let (router, snapshots, _) = makeRouter(adapter: adapter)
        let ask = makeRequest(.ask, id: 1)
        await adapter.setBehavior(.gate, for: ask.id)
        let task = Task { try await router.generate(ask) }
        await waitUntilStarted(ask.id, adapter: adapter)

        await snapshots.set(
            ProviderSelectionSnapshot(
                providerID: "openrouter",
                modelID: "another-model",
                selectionRevision: SelectionRevision(rawValue: 8),
                authorizationEpoch: AuthorizationEpoch(rawValue: 12)
            )
        )
        await adapter.complete(ask.id)

        await assertError(.selectionChanged, from: task)
    }

    func testTimeoutAndCallerCancellationDrainCooperatively() async {
        let timeoutAdapter = ControlledLLMAdapter()
        let (timeoutRouter, _, _) = makeRouter(adapter: timeoutAdapter)
        var timed = makeRequest(.ask, id: 1)
        timed = LLMRequest(
            id: timed.id,
            consumer: timed.consumer,
            priority: timed.priority,
            systemPrompt: timed.systemPrompt,
            userPrompt: timed.userPrompt,
            maximumOutputTokens: timed.maximumOutputTokens,
            timeout: .milliseconds(30)
        )
        await timeoutAdapter.setBehavior(.gate, for: timed.id)
        let timedTask = Task { try await timeoutRouter.generate(timed) }
        await assertError(.timedOut, from: timedTask)
        let timeoutHealth = await timeoutRouter.diagnostics().health
        XCTAssertEqual(timeoutHealth, .healthy)

        let cancelAdapter = ControlledLLMAdapter()
        let (cancelRouter, _, _) = makeRouter(adapter: cancelAdapter)
        let cancelled = makeRequest(.ask, id: 2)
        await cancelAdapter.setBehavior(.gate, for: cancelled.id)
        let cancelledTask = Task { try await cancelRouter.generate(cancelled) }
        await waitUntilStarted(cancelled.id, adapter: cancelAdapter)
        cancelledTask.cancel()
        await assertError(.callerCancelled, from: cancelledTask)
        let cancellationHealth = await cancelRouter.diagnostics().health
        XCTAssertEqual(cancellationHealth, .healthy)
    }

    func testShutdownRejectsNewWorkAndDrainsActiveAndQueuedGenerations() async {
        let adapter = ControlledLLMAdapter()
        let (router, _, _) = makeRouter(
            adapter: adapter,
            drainTimeout: .milliseconds(300)
        )
        let activeRequest = makeRequest(.ask, id: 30)
        let queuedRequest = makeRequest(.generatedLabels, id: 31)
        await adapter.setBehavior(
            .gateCancellationDelay(.milliseconds(40)),
            for: activeRequest.id
        )

        let activeTask = Task { try await router.generate(activeRequest) }
        await waitUntilStarted(activeRequest.id, adapter: adapter)
        let queuedTask = Task { try await router.generate(queuedRequest) }
        await waitForQueuedCount(1, router: router)

        let completed = await router.shutdown(timeout: .milliseconds(300))

        XCTAssertTrue(completed)
        await assertError(.routerShuttingDown, from: activeTask)
        await assertError(.routerShuttingDown, from: queuedTask)
        let diagnostics = await router.diagnostics()
        XCTAssertNil(diagnostics.active)
        XCTAssertTrue(diagnostics.queued.isEmpty)
        let rejectedRequest = makeRequest(.ask, id: 32)
        await assertError(
            .routerShuttingDown,
            from: Task { try await router.generate(rejectedRequest) }
        )
    }

    func testShutdownDeadlineIsBoundedWhenAdapterIgnoresCancellation() async {
        let adapter = ControlledLLMAdapter()
        let (router, _, _) = makeRouter(adapter: adapter)
        let request = makeRequest(.ask, id: 33)
        await adapter.setBehavior(.gateIgnoringCancellation, for: request.id)
        let generation = Task { try await router.generate(request) }
        await waitUntilStarted(request.id, adapter: adapter)
        let started = ContinuousClock.now

        let completed = await router.shutdown(timeout: .milliseconds(30))

        XCTAssertFalse(completed)
        XCTAssertLessThan(started.duration(to: ContinuousClock.now), .seconds(1))
        await assertError(.routerShuttingDown, from: generation)

        // Release the deliberately non-cooperative test double after proving
        // the deadline, so it cannot strand the test process.
        await adapter.complete(request.id)
    }

    func testNoFallbackAndResponseProvenanceMustMatchExactSelectionAndLocality() async {
        let missingAdapter = ControlledLLMAdapter()
        let snapshots = MockSnapshotProvider(snapshot)
        let registry = MockLLMAdapterRegistry(registrations: [
            "some-other-provider": LLMAdapterRegistration(
                providerID: "some-other-provider",
                executedLocally: false,
                adapter: missingAdapter
            ),
        ])
        let missingRouter = LLMRouter(
            snapshotProvider: snapshots,
            adapterRegistry: registry
        )
        let missingRequest = makeRequest(.ask, id: 1)
        await assertError(
            .adapterUnavailable,
            from: Task { try await missingRouter.generate(missingRequest) }
        )
        let lookups = await registry.lookups()
        XCTAssertEqual(lookups, [snapshot.providerID])

        for (offset, mismatch) in [
            ControlledLLMAdapter.ProvenanceOverride(providerID: "wrong", modelID: nil, local: nil),
            ControlledLLMAdapter.ProvenanceOverride(providerID: nil, modelID: "wrong", local: nil),
            ControlledLLMAdapter.ProvenanceOverride(providerID: nil, modelID: nil, local: false),
        ].enumerated() {
            let adapter = ControlledLLMAdapter()
            let request = makeRequest(.ask, id: UInt64(10 + offset))
            await adapter.setProvenanceOverride(mismatch, for: request.id)
            let (router, _, _) = makeRouter(adapter: adapter)
            await assertError(
                .provenanceMismatch,
                from: Task { try await router.generate(request) }
            )
        }
    }

    func testDiagnosticsAreImmutablePromptFreeValueSnapshots() async throws {
        let adapter = ControlledLLMAdapter()
        let (router, _, _) = makeRouter(adapter: adapter)
        let request = makeRequest(.ask, id: 1, user: "secret prompt")
        await adapter.setBehavior(.gate, for: request.id)
        let task = Task { try await router.generate(request) }
        await waitUntilStarted(request.id, adapter: adapter)

        let before = await router.diagnostics()
        await adapter.complete(request.id)
        _ = try await task.value
        let after = await router.diagnostics()

        XCTAssertEqual(before.active?.requestID, request.id)
        XCTAssertNil(after.active)
        XCTAssertEqual(before.active?.requestID, request.id)
        XCTAssertFalse(String(describing: before).contains("secret prompt"))
    }

    func testConsumerCannotEscalateItsDeclaredPriority() async {
        let adapter = ControlledLLMAdapter()
        let (router, _, _) = makeRouter(adapter: adapter)
        let invalid = LLMRequest(
            id: UUID(),
            consumer: .generatedLabels,
            priority: .ask,
            systemPrompt: "system",
            userPrompt: "user",
            maximumOutputTokens: 32,
            timeout: .seconds(2)
        )

        await assertError(
            .invalidPriority,
            from: Task { try await router.generate(invalid) }
        )
        let starts = await adapter.startedRequestIDs()
        XCTAssertEqual(starts, [])
    }

    private func makeRouter(
        adapter: ControlledLLMAdapter,
        labelBacklogLimit: Int = 8,
        drainTimeout: Duration = .milliseconds(100)
    ) -> (LLMRouter, MockSnapshotProvider, MockLLMAdapterRegistry) {
        let snapshots = MockSnapshotProvider(snapshot)
        let registry = MockLLMAdapterRegistry(registrations: [
            snapshot.providerID: LLMAdapterRegistration(
                providerID: snapshot.providerID,
                executedLocally: true,
                adapter: adapter
            ),
        ])
        return (
            LLMRouter(
                snapshotProvider: snapshots,
                adapterRegistry: registry,
                labelBacklogLimit: labelBacklogLimit,
                drainAcknowledgementTimeout: drainTimeout
            ),
            snapshots,
            registry
        )
    }

    private func makeRequest(
        _ consumer: AIConsumer,
        id: UInt64,
        user: String = "user",
        localOutputContract: LocalAIOutputContractRequest? = nil
    ) -> LLMRequest {
        LLMRequest(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llu", id))!,
            consumer: consumer,
            priority: LLMRouter.expectedPriority(for: consumer),
            systemPrompt: "system",
            userPrompt: user,
            maximumOutputTokens: 64,
            timeout: .seconds(3),
            localOutputContract: localOutputContract
        )
    }

    private func assertError(
        _ expected: LLMRouterError,
        from task: Task<LLMResponse, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LLMRouterError, expected, file: file, line: line)
        }
    }

    private func waitUntilStarted(
        _ id: UUID,
        adapter: ControlledLLMAdapter
    ) async {
        for _ in 0..<2_000 {
            if await adapter.hasStarted(id) { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("request did not start: \(id)")
    }

    private func waitForQueuedCount(_ count: Int, router: LLMRouter) async {
        for _ in 0..<2_000 {
            if (await router.diagnostics()).queued.count == count { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("queue did not reach \(count)")
    }

    private func waitForConsumer(_ consumer: AIConsumer, router: LLMRouter) async {
        for _ in 0..<2_000 {
            if (await router.diagnostics()).queued.contains(where: { $0.consumer == consumer }) {
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("consumer was not queued: \(consumer)")
    }

    private func waitForLabelBacklog(_ count: Int, router: LLMRouter) async {
        for _ in 0..<2_000 {
            if (await router.diagnostics()).labelBacklogCount == count { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("label backlog did not reach \(count)")
    }

    private func waitForNoActiveWork(_ router: LLMRouter) async {
        for _ in 0..<2_000 {
            if (await router.diagnostics()).active == nil { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("active work did not drain")
    }

    private func waitForRelease(_ released: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if released() { return true }
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(20))
        return released()
    }
}

private actor MockSnapshotProvider: LLMSelectionSnapshotProviding {
    private var snapshot: ProviderSelectionSnapshot?

    init(_ snapshot: ProviderSelectionSnapshot?) {
        self.snapshot = snapshot
    }

    func currentSnapshot(for consumer: AIConsumer) async -> ProviderSelectionSnapshot? {
        snapshot
    }

    func set(_ snapshot: ProviderSelectionSnapshot?) {
        self.snapshot = snapshot
    }
}

private actor MockLLMAdapterRegistry: LLMAdapterRegistering {
    private let registrations: [String: LLMAdapterRegistration]
    private var requestedProviderIDs: [String] = []

    init(registrations: [String: LLMAdapterRegistration]) {
        self.registrations = registrations
    }

    func registration(for providerID: String) async -> LLMAdapterRegistration? {
        requestedProviderIDs.append(providerID)
        return registrations[providerID]
    }

    func lookups() -> [String] { requestedProviderIDs }
}

private actor ControlledLLMAdapter: LLMAdapter {
    enum Behavior: Sendable {
        case automatic
        case gate
        case gateCancellationDelay(Duration)
        case gateIgnoringCancellation
    }

    struct ProvenanceOverride: Sendable {
        let providerID: String?
        let modelID: String?
        let local: Bool?
    }

    private struct Gate {
        let continuation: CheckedContinuation<LLMResponse, Error>
        let selection: ProviderSelectionSnapshot
        let request: LLMRequest
    }

    private var behaviors: [UUID: Behavior] = [:]
    private var overrides: [UUID: ProvenanceOverride] = [:]
    private var gates: [UUID: Gate] = [:]
    private var starts: [UUID] = []
    private var selections: [ProviderSelectionSnapshot] = []
    private var activeCount = 0
    private var maximumActiveCount = 0

    func setBehavior(_ behavior: Behavior, for id: UUID) {
        behaviors[id] = behavior
    }

    func setProvenanceOverride(_ override: ProvenanceOverride, for id: UUID) {
        overrides[id] = override
    }

    func generate(
        request: LLMRequest,
        selection: ProviderSelectionSnapshot
    ) async throws -> LLMResponse {
        starts.append(request.id)
        selections.append(selection)
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        defer { activeCount -= 1 }

        switch behaviors[request.id] ?? .automatic {
        case .automatic:
            return response(for: request, selection: selection)
        case .gate, .gateCancellationDelay, .gateIgnoringCancellation:
            let response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    gates[request.id] = Gate(
                        continuation: continuation,
                        selection: selection,
                        request: request
                    )
                }
            } onCancel: {
                Task { await self.cancelGate(request.id) }
            }
            try Task.checkCancellation()
            return response
        }
    }

    func complete(_ id: UUID) {
        guard let gate = gates.removeValue(forKey: id) else { return }
        gate.continuation.resume(
            returning: response(for: gate.request, selection: gate.selection)
        )
    }

    func hasStarted(_ id: UUID) -> Bool { gates[id] != nil || starts.contains(id) }
    func startedRequestIDs() -> [UUID] { starts }
    func capturedSelections() -> [ProviderSelectionSnapshot] { selections }
    func maximumConcurrentGenerations() -> Int { maximumActiveCount }

    private func cancelGate(_ id: UUID) async {
        guard let behavior = behaviors[id] else { return }
        switch behavior {
        case .gateIgnoringCancellation:
            return
        case .gateCancellationDelay(let delay):
            try? await Task.sleep(for: delay)
        case .automatic, .gate:
            break
        }
        guard let gate = gates.removeValue(forKey: id) else { return }
        gate.continuation.resume(throwing: CancellationError())
    }

    private func response(
        for request: LLMRequest,
        selection: ProviderSelectionSnapshot
    ) -> LLMResponse {
        let override = overrides[request.id]
        return LLMResponse(
            content: "answer",
            truncated: false,
            provenance: AIExecutionProvenance(
                providerID: override?.providerID ?? selection.providerID,
                modelID: override?.modelID ?? selection.modelID,
                executedLocally: override?.local ?? true,
                generatedAt: Date(),
                brokerUpstream: nil
            )
        )
    }
}
