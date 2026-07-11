import MLXLMCommon
import XCTest

final class LocalInferenceServiceTests: XCTestCase {
    func testCandidateLoaderLoadsOnlyExactProductManifestAndReportsReady() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let driver = FakeLocalRuntimeDriver()
        let service = LocalInferenceService(
            driver: driver,
            computeCoordinator: AIComputeCoordinator(vectorBackfill: .noop),
            idleUnloadDelay: .seconds(60)
        )

        try await service.candidateLoader()(fixture.payload, fixture.manifest)

        let loadEvents = await driver.events()
        XCTAssertEqual(loadEvents, ["load:\(fixture.manifest.id)", "warm"])
        let loadedState = await service.snapshot().state
        XCTAssertEqual(
            loadedState,
            .ready(fixture.installation)
        )

        do {
            try await service.loadVerified(
                directory: fixture.payload,
                manifest: BuiltInModelManifest.smallCandidate
            )
            XCTFail("qualification-only manifest was accepted")
        } catch let error as LocalInferenceError {
            XCTAssertEqual(error, .unrecognizedManifest)
        }
    }

    func testGenerationUsesNativeToolContractAndLocalProvenance() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let driver = FakeLocalRuntimeDriver(
            preparedTokens: 120,
            output: .init(
                textChunks: [],
                toolCalls: [supportedCall(text: "The review is Friday.")],
                generatedTokenCount: 24,
                reachedTokenLimit: false
            )
        )
        let service = LocalInferenceService(
            driver: driver,
            computeCoordinator: AIComputeCoordinator(vectorBackfill: .noop),
            idleUnloadDelay: .seconds(60),
            now: { Date(timeIntervalSince1970: 123) }
        )
        try await service.loadVerified(directory: fixture.payload, manifest: fixture.manifest)

        let response = try await service.generate(
            request: request(),
            selection: fixture.selection
        )

        XCTAssertEqual(response.content, "The review is Friday. [1]")
        XCTAssertFalse(response.truncated)
        XCTAssertEqual(
            response.provenance,
            AIExecutionProvenance(
                providerID: AIProvider.zbsEyeLocal.rawValue,
                modelID: fixture.manifest.id,
                executedLocally: true,
                generatedAt: Date(timeIntervalSince1970: 123),
                brokerUpstream: nil
            )
        )
        let readyState = await service.snapshot().state
        XCTAssertEqual(readyState, .ready(fixture.installation))
        let generatedEvents = await driver.events()
        XCTAssertTrue(generatedEvents.contains("generate"))
    }

    func testStaleSelectionAndOversizedPromptFailBeforeGeneration() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let driver = FakeLocalRuntimeDriver(preparedTokens: fixture.manifest.generation.contextTokenCeiling)
        let service = LocalInferenceService(
            driver: driver,
            computeCoordinator: AIComputeCoordinator(vectorBackfill: .noop),
            idleUnloadDelay: .seconds(60)
        )
        try await service.loadVerified(directory: fixture.payload, manifest: fixture.manifest)

        let wrong = ProviderSelectionSnapshot(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: BuiltInModelManifest.smallCandidate.id,
            selectionRevision: .zero,
            authorizationEpoch: .zero
        )
        await assertLocalError(.staleSelection) {
            _ = try await service.generate(request: self.request(), selection: wrong)
        }
        await assertLocalError(.contextLimitExceeded) {
            _ = try await service.generate(request: self.request(), selection: fixture.selection)
        }
        let rejectedEvents = await driver.events()
        XCTAssertFalse(rejectedEvents.contains("generate"))
    }

    func testFreeTextBesideNativeToolCallIsRejected() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let driver = FakeLocalRuntimeDriver(
            output: .init(
                textChunks: ["unvalidated prose"],
                toolCalls: [supportedCall()],
                generatedTokenCount: 10,
                reachedTokenLimit: false
            )
        )
        let service = LocalInferenceService(
            driver: driver,
            computeCoordinator: AIComputeCoordinator(vectorBackfill: .noop),
            idleUnloadDelay: .seconds(60)
        )
        try await service.loadVerified(directory: fixture.payload, manifest: fixture.manifest)

        await assertLocalError(.invalidOutput) {
            _ = try await service.generate(
                request: self.request(),
                selection: fixture.selection
            )
        }
    }

    func testBareJSONTextWithoutNativeToolEventIsRejected() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let driver = FakeLocalRuntimeDriver(
            output: .init(
                textChunks: [
                    #"{"status":"supported","item1_text":"The review is Friday.","item1_sources":["[1]"]}"#,
                ],
                toolCalls: [],
                generatedTokenCount: 10,
                reachedTokenLimit: false
            )
        )
        let service = LocalInferenceService(
            driver: driver,
            computeCoordinator: AIComputeCoordinator(vectorBackfill: .noop),
            idleUnloadDelay: .seconds(60)
        )
        try await service.loadVerified(directory: fixture.payload, manifest: fixture.manifest)

        await assertLocalError(.invalidOutput) {
            _ = try await service.generate(
                request: self.request(),
                selection: fixture.selection
            )
        }
    }

    func testSecondGenerationIsRejectedAndCallerCancellationDrainsProducer() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let driver = FakeLocalRuntimeDriver(blockGeneration: true)
        let service = LocalInferenceService(
            driver: driver,
            computeCoordinator: AIComputeCoordinator(vectorBackfill: .noop),
            idleUnloadDelay: .seconds(60)
        )
        try await service.loadVerified(directory: fixture.payload, manifest: fixture.manifest)

        let firstRequest = request()
        let firstSelection = fixture.selection
        let first = Task {
            try await service.generate(request: firstRequest, selection: firstSelection)
        }
        await driver.waitUntilGenerating()

        await assertLocalError(.generationBusy) {
            _ = try await service.generate(
                request: self.request(id: UUID()),
                selection: fixture.selection
            )
        }

        let started = ContinuousClock().now
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("cancelled generation returned a response")
        } catch is CancellationError {
            // Expected.
        }
        let elapsed = started.duration(to: ContinuousClock().now)
        XCTAssertLessThan(elapsed, .seconds(1))
        try await waitUntil { await driver.events().contains("cancel-and-drain") }
        let cancellationEvents = await driver.events()
        XCTAssertTrue(cancellationEvents.contains("cancel-and-drain"))
        try await waitUntil { await service.snapshot().state == .ready(fixture.installation) }
        let stateAfterCancellation = await service.snapshot().state
        XCTAssertEqual(stateAfterCancellation, .ready(fixture.installation))
    }

    func testCallerCancellationWaitsForCooperativeDrainBeforeReturning() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let coordinator = AIComputeCoordinator(vectorBackfill: .noop)
        let driver = FakeLocalRuntimeDriver(
            blockGeneration: true,
            blockRuntimeDrain: true
        )
        let service = LocalInferenceService(
            driver: driver,
            computeCoordinator: coordinator,
            idleUnloadDelay: .seconds(60),
            drainAcknowledgementTimeout: .seconds(1)
        )
        try await service.loadVerified(directory: fixture.payload, manifest: fixture.manifest)

        let cancellationRequest = request(id: UUID())
        let selection = fixture.selection
        let generation = Task {
            try await service.generate(
                request: cancellationRequest,
                selection: selection
            )
        }
        await driver.waitUntilGenerating()

        generation.cancel()
        let prematureReturn = await LocalRuntimeTaskDeadline.wait(
            for: generation,
            timeout: .milliseconds(20)
        )
        XCTAssertEqual(prematureReturn, .timedOut)

        await driver.releaseRuntimeDrain()
        do {
            _ = try await generation.value
            XCTFail("cancelled generation returned a response")
        } catch is CancellationError {
            // Expected after the producer and its compute lease are drained.
        }

        let serviceState = await service.snapshot()
        XCTAssertNil(serviceState.activeRequestID)
        XCTAssertEqual(serviceState.state, .ready(fixture.installation))
        let computeState = await coordinator.snapshot()
        XCTAssertFalse(computeState.generationActive)
    }

    func testCallerCancellationReturnsBoundedWhenRuntimeDrainDoesNotAcknowledge() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let coordinator = AIComputeCoordinator(vectorBackfill: .noop)
        let driver = FakeLocalRuntimeDriver(
            blockGeneration: true,
            blockRuntimeDrain: true
        )
        let service = LocalInferenceService(
            driver: driver,
            computeCoordinator: coordinator,
            idleUnloadDelay: .seconds(60),
            drainAcknowledgementTimeout: .milliseconds(20)
        )
        try await service.loadVerified(directory: fixture.payload, manifest: fixture.manifest)

        let cancellationRequest = request(id: UUID())
        let selection = fixture.selection
        let generation = Task {
            try await service.generate(
                request: cancellationRequest,
                selection: selection
            )
        }
        await driver.waitUntilGenerating()

        let started = ContinuousClock().now
        generation.cancel()
        let boundedReturn = await LocalRuntimeTaskDeadline.wait(
            for: generation,
            timeout: .milliseconds(500)
        )
        XCTAssertEqual(boundedReturn, .completed)
        XCTAssertLessThan(
            started.duration(to: ContinuousClock().now),
            .milliseconds(500)
        )
        let retained = await service.snapshot()
        XCTAssertEqual(retained.activeRequestID, cancellationRequest.id)
        guard case .failed(let installation, _) = retained.state else {
            return XCTFail("unacknowledged caller drain was not failed at return: \(retained.state)")
        }
        XCTAssertEqual(installation, fixture.installation)
        let retainedComputeState = await coordinator.snapshot()
        XCTAssertTrue(retainedComputeState.generationActive)

        await driver.releaseRuntimeDrain()
        do {
            _ = try await generation.value
            XCTFail("cancelled generation returned a response")
        } catch is CancellationError {
            // Expected: the caller was released at the acknowledgement deadline.
        }
        try await waitUntil { await service.snapshot().activeRequestID == nil }
        let finalComputeState = await coordinator.snapshot()
        XCTAssertFalse(finalComputeState.generationActive)
    }

    func testRequestTimeoutCancelsAndDrains() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let driver = FakeLocalRuntimeDriver(blockGeneration: true)
        let service = LocalInferenceService(
            driver: driver,
            computeCoordinator: AIComputeCoordinator(vectorBackfill: .noop),
            idleUnloadDelay: .seconds(60)
        )
        try await service.loadVerified(directory: fixture.payload, manifest: fixture.manifest)

        await assertLocalError(.timedOut) {
            _ = try await service.generate(
                request: self.request(timeout: .milliseconds(20)),
                selection: fixture.selection
            )
        }
        try await waitUntil { await driver.events().contains("cancel-and-drain") }
        let timeoutEvents = await driver.events()
        XCTAssertTrue(timeoutEvents.contains("cancel-and-drain"))
        try await waitUntil { await service.snapshot().state == .ready(fixture.installation) }
        let stateAfterTimeout = await service.snapshot().state
        XCTAssertEqual(stateAfterTimeout, .ready(fixture.installation))
    }

    func testRequestTimeoutReturnsWithoutFakingDrainOfNonCooperativeRuntime() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let driver = FakeLocalRuntimeDriver(
            blockGeneration: true,
            blockRuntimeDrain: true
        )
        let service = LocalInferenceService(
            driver: driver,
            computeCoordinator: AIComputeCoordinator(vectorBackfill: .noop),
            idleUnloadDelay: .seconds(60),
            drainAcknowledgementTimeout: .milliseconds(20)
        )
        try await service.loadVerified(directory: fixture.payload, manifest: fixture.manifest)

        let started = ContinuousClock().now
        let timedRequest = request(timeout: .milliseconds(20))
        let selection = fixture.selection
        let requestTask = Task {
            try await service.generate(
                request: timedRequest,
                selection: selection
            )
        }
        let bounded = await LocalRuntimeTaskDeadline.wait(
            for: requestTask,
            timeout: .milliseconds(500)
        )
        XCTAssertEqual(bounded, .completed)
        XCTAssertLessThan(started.duration(to: ContinuousClock().now), .milliseconds(500))

        let retained = await service.snapshot()
        XCTAssertNotNil(retained.activeRequestID)
        XCTAssertNotEqual(retained.state, .unloaded)

        try await waitUntil {
            if case .failed = await service.snapshot().state { return true }
            return false
        }
        await driver.releaseRuntimeDrain()
        do {
            _ = try await requestTask.value
            XCTFail("timed-out generation returned a response")
        } catch let error as LocalInferenceError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("unexpected timeout error: \(error)")
        }
        try await waitUntil { await service.snapshot().activeRequestID == nil }
        let finalState = await service.snapshot().state
        guard case .failed(let installation, _) = finalState else {
            return XCTFail("late producer completion cleared unhealthy runtime: \(finalState)")
        }
        XCTAssertEqual(installation, fixture.installation)
    }

    func testRuntimeDrainerAndIdleDeadlineDropTheLoadedContainer() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let driver = FakeLocalRuntimeDriver()
        let service = LocalInferenceService(
            driver: driver,
            computeCoordinator: AIComputeCoordinator(vectorBackfill: .noop),
            idleUnloadDelay: .milliseconds(20)
        )
        try await service.loadVerified(directory: fixture.payload, manifest: fixture.manifest)
        _ = try await service.generate(request: request(), selection: fixture.selection)

        try await waitUntil { await service.snapshot().state == .unloaded }
        let idleEvents = await driver.events()
        XCTAssertTrue(idleEvents.contains("unload"))

        let coldReloaded = try await service.generate(
            request: request(id: UUID()),
            selection: fixture.selection
        )
        XCTAssertEqual(coldReloaded.content, "The review is Friday. [1]")
        let coldReloadEvents = await driver.events()
        XCTAssertEqual(
            coldReloadEvents.filter { $0 == "load:\(fixture.manifest.id)" }.count,
            2
        )
        XCTAssertEqual(coldReloadEvents.filter { $0 == "warm" }.count, 2)

        try await service.loadVerified(directory: fixture.payload, manifest: fixture.manifest)
        try await service.runtimeDrainer()(fixture.installation)
        let drainedState = await service.snapshot().state
        XCTAssertEqual(drainedState, .unloaded)
    }

    func testSuccessfulWarmupArmsIdleUnloadWithoutGeneration() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let driver = FakeLocalRuntimeDriver()
        let service = LocalInferenceService(
            driver: driver,
            computeCoordinator: AIComputeCoordinator(vectorBackfill: .noop),
            idleUnloadDelay: .milliseconds(20)
        )

        try await service.loadVerified(
            directory: fixture.payload,
            manifest: fixture.manifest
        )

        try await waitUntil { await service.snapshot().state == .unloaded }
        let events = await driver.events()
        XCTAssertTrue(events.contains("unload"))
    }

    func testContextLimitFailureRearmsIdleUnload() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let driver = FakeLocalRuntimeDriver(
            preparedTokens: fixture.manifest.generation.contextTokenCeiling
        )
        let service = LocalInferenceService(
            driver: driver,
            computeCoordinator: AIComputeCoordinator(vectorBackfill: .noop),
            idleUnloadDelay: .milliseconds(20)
        )
        try await service.loadVerified(
            directory: fixture.payload,
            manifest: fixture.manifest
        )

        await assertLocalError(.contextLimitExceeded) {
            _ = try await service.generate(
                request: self.request(),
                selection: fixture.selection
            )
        }

        try await waitUntil { await service.snapshot().state == .unloaded }
        let events = await driver.events()
        XCTAssertEqual(events.filter { $0 == "unload" }.count, 1)
        XCTAssertFalse(events.contains("generate"))
    }

    func testRuntimeDrainerInterruptsInFlightWarmupBeforeAcknowledgingUnload() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let driver = FakeLocalRuntimeDriver(blockWarmUp: true)
        let service = LocalInferenceService(
            driver: driver,
            computeCoordinator: AIComputeCoordinator(vectorBackfill: .noop),
            idleUnloadDelay: .seconds(60),
            drainAcknowledgementTimeout: .milliseconds(100)
        )

        let loadTask = Task {
            try await service.loadVerified(
                directory: fixture.payload,
                manifest: fixture.manifest
            )
        }
        await driver.waitUntilWarmingUp()

        try await service.runtimeDrainer()(nil)
        do {
            try await loadTask.value
            XCTFail("interrupted warmup was reported ready after runtime unload")
        } catch is CancellationError {
            // The runtime drainer invalidated this exact load operation.
        }

        let state = await service.snapshot()
        XCTAssertEqual(state.state, .unloaded)
        XCTAssertNil(state.loadedModelID)
        let events = await driver.events()
        XCTAssertGreaterThanOrEqual(events.filter { $0 == "unload" }.count, 2)
    }

    func testLateWarmupCompletionRetriesUnloadAndPreservesFailedBarrierState() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let driver = FakeLocalRuntimeDriver(
            blockWarmUp: true,
            unloadOutcomes: [.timedOut, .stopped]
        )
        let service = LocalInferenceService(
            driver: driver,
            computeCoordinator: AIComputeCoordinator(vectorBackfill: .noop),
            idleUnloadDelay: .seconds(60),
            drainAcknowledgementTimeout: .milliseconds(20)
        )
        let loadTask = Task {
            try await service.loadVerified(
                directory: fixture.payload,
                manifest: fixture.manifest
            )
        }
        await driver.waitUntilWarmingUp()

        do {
            try await service.runtimeDrainer()(nil)
            XCTFail("runtime barrier acknowledged a timed-out warm-up unload")
        } catch let error as LocalInferenceError {
            XCTAssertEqual(error, .runtimeDrainUnconfirmed)
        }
        let failedAtDeadline = await service.snapshot().state
        guard case .failed = failedAtDeadline else {
            return XCTFail("timed-out warm-up unload was not kept failed")
        }

        await driver.releaseWarmUp()
        do {
            try await loadTask.value
            XCTFail("invalidated warm-up completed as a live runtime")
        } catch is CancellationError {
            // Expected: the stale candidate is discarded after its final unload.
        }

        let events = await driver.events()
        XCTAssertEqual(events.filter { $0 == "unload" }.count, 2)
        let finalState = await service.snapshot().state
        guard case .failed = finalState else {
            return XCTFail("eventual cleanup erased the failed barrier state: \(finalState)")
        }
    }

    func testMemoryPressureCancelsGenerationAndUnloads() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let driver = FakeLocalRuntimeDriver(blockGeneration: true)
        let service = LocalInferenceService(
            driver: driver,
            computeCoordinator: AIComputeCoordinator(vectorBackfill: .noop),
            idleUnloadDelay: .seconds(60)
        )
        try await service.loadVerified(directory: fixture.payload, manifest: fixture.manifest)
        let pressureRequest = request()
        let pressureSelection = fixture.selection
        let generation = Task {
            try await service.generate(
                request: pressureRequest,
                selection: pressureSelection
            )
        }
        await driver.waitUntilGenerating()

        await service.handleMemoryPressure()
        _ = try? await generation.value

        let pressureState = await service.snapshot().state
        XCTAssertEqual(pressureState, .unloaded)
        let events = await driver.events()
        XCTAssertTrue(events.contains("cancel-and-drain"))
        XCTAssertTrue(events.contains("unload"))
    }

    func testRuntimeDrainerCancelsGenerationWaitingForSemanticQueryDrain() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let coordinator = AIComputeCoordinator(vectorBackfill: .noop)
        let driver = FakeLocalRuntimeDriver()
        let service = LocalInferenceService(
            driver: driver,
            computeCoordinator: coordinator,
            idleUnloadDelay: .seconds(60)
        )
        try await service.loadVerified(directory: fixture.payload, manifest: fixture.manifest)
        let queryAdmission = await coordinator.acquireSemanticQuery()
        guard case .granted(let query) = queryAdmission else {
            return XCTFail("semantic query was not admitted")
        }

        let pendingRequest = request(id: UUID())
        let pendingSelection = fixture.selection
        let generation = Task {
            try await service.generate(
                request: pendingRequest,
                selection: pendingSelection
            )
        }
        try await waitUntil { await coordinator.snapshot().generationPending }

        let started = ContinuousClock().now
        try await service.runtimeDrainer()(fixture.installation)
        XCTAssertLessThan(started.duration(to: ContinuousClock().now), .seconds(1))
        do {
            _ = try await generation.value
            XCTFail("drained pending generation unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
        await query.release()
        let state = await service.snapshot().state
        XCTAssertEqual(state, .unloaded)
    }

    func testRuntimeDrainerTimesOutWithoutDetachingNonCooperativeReservation() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let gate = SuspendAndDrainGate()
        let coordinator = AIComputeCoordinator(
            vectorBackfill: AIComputeVectorBackfillHooks(
                suspendAndDrain: { await gate.enter() },
                resume: {}
            )
        )
        let driver = FakeLocalRuntimeDriver()
        let service = LocalInferenceService(
            driver: driver,
            computeCoordinator: coordinator,
            idleUnloadDelay: .seconds(60),
            drainAcknowledgementTimeout: .milliseconds(20)
        )
        try await service.loadVerified(directory: fixture.payload, manifest: fixture.manifest)

        let pendingRequest = request(id: UUID())
        let pendingSelection = fixture.selection
        let generation = Task {
            try await service.generate(
                request: pendingRequest,
                selection: pendingSelection
            )
        }
        await gate.waitUntilBlockedCall()

        let started = ContinuousClock().now
        let drainer = Task {
            try await service.runtimeDrainer()(fixture.installation)
        }
        let bounded = await LocalRuntimeTaskDeadline.wait(
            for: drainer,
            timeout: .milliseconds(500)
        )
        XCTAssertEqual(bounded, .completed)
        XCTAssertLessThan(started.duration(to: ContinuousClock().now), .milliseconds(500))
        let retainedRequestID = await service.snapshot().activeRequestID
        XCTAssertEqual(retainedRequestID, pendingRequest.id)

        await gate.releaseBlockedCall()
        do {
            try await drainer.value
            XCTFail("non-cooperative reservation was reported as drained")
        } catch let error as LocalInferenceError {
            XCTAssertEqual(error, .runtimeDrainUnconfirmed)
        } catch {
            XCTFail("unexpected drain error: \(error)")
        }
        do {
            _ = try await generation.value
            XCTFail("drained reservation unexpectedly generated a response")
        } catch is CancellationError {
            // Expected.
        }
        let events = await driver.events()
        XCTAssertFalse(events.contains("prepare"))
        XCTAssertFalse(events.contains("generate"))
        let state = await service.snapshot().state
        guard case .failed(let installation, _) = state else {
            return XCTFail("unconfirmed drain was not kept unhealthy: \(state)")
        }
        XCTAssertEqual(installation, fixture.installation)
    }

    private func request(
        id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
        timeout: Duration = .seconds(3)
    ) -> LLMRequest {
        LLMRequest(
            id: id,
            consumer: .ask,
            priority: .ask,
            systemPrompt: "Answer with the native tool.",
            userPrompt: "[1] The review is Friday.",
            maximumOutputTokens: 64,
            timeout: timeout,
            localOutputContract: .init(
                purpose: .ask,
                language: .en,
                allowedSources: ["[1]"]
            )
        )
    }

    private func supportedCall(text: String = "The review is Friday.") -> ToolCall {
        ToolCall(
            function: .init(
                name: LocalAIAnswerToolContract.functionName,
                arguments: [
                    "status": .string("supported"),
                    "item1_text": .string(text),
                    "item1_sources": .array([.string("[1]")]),
                ]
            )
        )
    }

    private func assertLocalError(
        _ expected: LocalInferenceError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)")
        } catch let error as LocalInferenceError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition timed out")
    }
}

private actor SuspendAndDrainGate {
    private var callCount = 0
    private var blockedCall: CheckedContinuation<Void, Never>?
    private var blockedCallWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        callCount += 1
        guard callCount > 1 else { return }
        let waiters = blockedCallWaiters
        blockedCallWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { blockedCall = $0 }
    }

    func waitUntilBlockedCall() async {
        if callCount > 1 { return }
        await withCheckedContinuation { blockedCallWaiters.append($0) }
    }

    func releaseBlockedCall() {
        blockedCall?.resume()
        blockedCall = nil
    }
}

private struct RuntimeFixture {
    let root: URL
    let payload: URL
    let manifest = BuiltInModelManifest.regular
    let installation: BuiltInModelInstallation

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "local-inference-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let id = UUID()
        payload = root
            .appending(path: "installed", directoryHint: .isDirectory)
            .appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
            .appending(path: "payload", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        installation = BuiltInModelInstallation(
            artifact: .init(
                modelID: manifest.id,
                artifactVersion: manifest.artifactVersion,
                manifestFingerprintSHA256: manifest.aggregateFingerprintSHA256
            ),
            installationID: id,
            relativeDirectory: "installed/\(id.uuidString.lowercased())/payload"
        )!
    }

    var selection: ProviderSelectionSnapshot {
        ProviderSelectionSnapshot(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: manifest.id,
            selectionRevision: .init(rawValue: 7),
            authorizationEpoch: .init(rawValue: 9)
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor FakeLocalRuntimeDriver: LocalInferenceRuntimeDriving {
    private let preparedTokens: Int
    private let output: LocalRuntimeGenerationOutput
    private let blockGeneration: Bool
    private let blockRuntimeDrain: Bool
    private let blockWarmUp: Bool
    private var unloadOutcomes: [LocalRuntimeDrainOutcome]
    private var log: [String] = []
    private var generationWaiter: CheckedContinuation<Void, Never>?
    private var generationStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var runtimeDrainWaiter: CheckedContinuation<Void, Never>?
    private var warmUpWaiter: CheckedContinuation<Void, Never>?
    private var warmUpStartedWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        preparedTokens: Int = 120,
        output: LocalRuntimeGenerationOutput = .init(
            textChunks: [],
            toolCalls: [ToolCall(function: .init(
                name: LocalAIAnswerToolContract.functionName,
                arguments: [
                    "status": .string("supported"),
                    "item1_text": .string("The review is Friday."),
                    "item1_sources": .array([.string("[1]")]),
                ]
            ))],
            generatedTokenCount: 20,
            reachedTokenLimit: false
        ),
        blockGeneration: Bool = false,
        blockRuntimeDrain: Bool = false,
        blockWarmUp: Bool = false,
        unloadOutcomes: [LocalRuntimeDrainOutcome] = []
    ) {
        self.preparedTokens = preparedTokens
        self.output = output
        self.blockGeneration = blockGeneration
        self.blockRuntimeDrain = blockRuntimeDrain
        self.blockWarmUp = blockWarmUp
        self.unloadOutcomes = unloadOutcomes
    }

    func load(directory: URL, manifest: BuiltInModelManifest) async throws {
        log.append("load:\(manifest.id)")
    }

    func warmUp() async throws {
        log.append("warm")
        let started = warmUpStartedWaiters
        warmUpStartedWaiters.removeAll()
        for waiter in started { waiter.resume() }
        if blockWarmUp {
            await withCheckedContinuation { warmUpWaiter = $0 }
        }
    }

    func preparedInputTokenCount(for request: LocalRuntimeGenerationRequest) async throws -> Int {
        log.append("prepare")
        return preparedTokens
    }

    func generate(_ request: LocalRuntimeGenerationRequest) async throws -> LocalRuntimeGenerationOutput {
        log.append("generate")
        let started = generationStartedWaiters
        generationStartedWaiters.removeAll()
        for waiter in started { waiter.resume() }
        if blockGeneration {
            await withCheckedContinuation { continuation in
                generationWaiter = continuation
            }
            try Task.checkCancellation()
        }
        return output
    }

    func cancelAndDrain(timeout: Duration) async -> LocalRuntimeDrainOutcome {
        log.append("cancel-and-drain")
        if blockRuntimeDrain {
            await withCheckedContinuation { runtimeDrainWaiter = $0 }
        }
        generationWaiter?.resume()
        generationWaiter = nil
        return .stopped
    }

    func unload(timeout: Duration) async -> LocalRuntimeDrainOutcome {
        log.append("unload")
        let outcome = unloadOutcomes.isEmpty ? .stopped : unloadOutcomes.removeFirst()
        if outcome.isConfirmedStopped {
            warmUpWaiter?.resume()
            warmUpWaiter = nil
            generationWaiter?.resume()
            generationWaiter = nil
        }
        return outcome
    }

    func events() -> [String] { log }

    func waitUntilGenerating() async {
        if log.contains("generate") { return }
        await withCheckedContinuation { generationStartedWaiters.append($0) }
    }

    func releaseRuntimeDrain() {
        runtimeDrainWaiter?.resume()
        runtimeDrainWaiter = nil
    }

    func waitUntilWarmingUp() async {
        if log.contains("warm") { return }
        await withCheckedContinuation { warmUpStartedWaiters.append($0) }
    }

    func releaseWarmUp() {
        warmUpWaiter?.resume()
        warmUpWaiter = nil
    }
}
