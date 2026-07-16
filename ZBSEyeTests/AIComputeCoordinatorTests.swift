import XCTest

final class AIComputeCoordinatorTests: XCTestCase {
    func testGenerationWaitsForExistingE5AndDeniesNewSemanticQueries() async throws {
        let events = ComputeEventLog()
        let coordinator = AIComputeCoordinator(
            vectorBackfill: .init(
                suspendAndDrain: { await events.append("backfill-suspend") },
                resume: { await events.append("backfill-resume") }
            )
        )
        let queryAdmission = await coordinator.acquireSemanticQuery()
        let query = try XCTUnwrap(queryAdmission.lease)
        let backgroundAdmission = await coordinator.acquireBackgroundEmbedding()
        let background = try XCTUnwrap(backgroundAdmission)

        let generationTask = Task {
            let lease = try await coordinator.acquireGeneration()
            await events.append("generation-acquired")
            return lease
        }
        try await waitUntil { await coordinator.snapshot().generationPending }

        let fallback = await coordinator.acquireSemanticQuery()
        XCTAssertEqual(fallback.fallbackReason, .localGeneration)
        let deniedBackground = await coordinator.acquireBackgroundEmbedding()
        XCTAssertNil(deniedBackground)
        let eventsWhilePending = await events.values()
        XCTAssertEqual(eventsWhilePending, ["backfill-suspend"])

        await query.release()
        try await Task.sleep(for: .milliseconds(10))
        let eventsAfterQuery = await events.values()
        XCTAssertEqual(eventsAfterQuery, ["backfill-suspend"])
        await background.release()

        let generation = try await generationTask.value
        let eventsAfterAcquire = await events.values()
        XCTAssertEqual(
            eventsAfterAcquire,
            ["backfill-suspend", "generation-acquired"]
        )
        let active = await coordinator.snapshot()
        XCTAssertTrue(active.generationActive)
        XCTAssertEqual(active.activeSemanticQueries, 0)
        XCTAssertEqual(active.activeBackgroundEmbeddings, 0)

        await generation.release()
        try await waitUntil { await events.values().contains("backfill-resume") }
        let resumedAdmission = await coordinator.acquireSemanticQuery()
        XCTAssertNotNil(resumedAdmission.lease)
    }

    func testExternalSuspendDrainsAllComputeBeforeAcknowledging() async throws {
        let events = ComputeEventLog()
        let coordinator = AIComputeCoordinator(
            vectorBackfill: .init(
                suspendAndDrain: { await events.append("backfill-suspend") },
                resume: { await events.append("backfill-resume") }
            )
        )
        let queryAdmission = await coordinator.acquireSemanticQuery()
        let query = try XCTUnwrap(queryAdmission.lease)
        let suspension = Task {
            try await coordinator.suspendAndDrain()
            await events.append("drained")
        }
        try await waitUntil { await coordinator.snapshot().externallySuspended }

        let suspendedAdmission = await coordinator.acquireSemanticQuery()
        XCTAssertEqual(suspendedAdmission.fallbackReason, .computeSuspended)
        let deniedBackground = await coordinator.acquireBackgroundEmbedding()
        XCTAssertNil(deniedBackground)
        let pendingEvents = await events.values()
        XCTAssertEqual(pendingEvents, ["backfill-suspend"])

        await query.release()
        try await suspension.value
        let drainedEvents = await events.values()
        XCTAssertEqual(drainedEvents, ["backfill-suspend", "drained"])

        await coordinator.resume()
        let resumedEvents = await events.values()
        XCTAssertEqual(
            resumedEvents,
            ["backfill-suspend", "drained", "backfill-resume"]
        )
    }

    func testCancelledGenerationWaiterRestoresAdmissions() async throws {
        let coordinator = AIComputeCoordinator(vectorBackfill: .noop)
        let queryAdmission = await coordinator.acquireSemanticQuery()
        let query = try XCTUnwrap(queryAdmission.lease)
        let generation = Task { try await coordinator.acquireGeneration() }
        try await waitUntil { await coordinator.snapshot().generationPending }

        generation.cancel()
        do {
            _ = try await generation.value
            XCTFail("cancelled waiter unexpectedly acquired generation")
        } catch is CancellationError {
            // Expected.
        }
        try await waitUntil { !(await coordinator.snapshot().generationPending) }

        await query.release()
        let resumedAdmission = await coordinator.acquireSemanticQuery()
        XCTAssertNotNil(resumedAdmission.lease)
    }

    func testSpeechWaitsForGenerationAndBlocksNewModelWorkUntilReleased() async throws {
        let coordinator = AIComputeCoordinator(vectorBackfill: .noop)
        let generation = try await coordinator.acquireGeneration()

        let speechTask = Task { try await coordinator.acquireSpeech() }
        try await waitUntil { await coordinator.snapshot().speechPending }
        let fallback = await coordinator.acquireSemanticQuery()
        XCTAssertEqual(fallback.fallbackReason, .speechTranscription)
        let background = await coordinator.acquireBackgroundEmbedding()
        XCTAssertNil(background)
        do {
            _ = try await coordinator.acquireGeneration()
            XCTFail("speech must retain priority")
        } catch {
            XCTAssertEqual(error as? AIComputeCoordinatorError, .generationAlreadyPending)
        }

        await generation.release()
        let speech = try await speechTask.value
        let active = await coordinator.snapshot()
        XCTAssertTrue(active.speechActive)
        XCTAssertFalse(active.generationActive)

        await speech.release()
        let resumed = await coordinator.acquireSemanticQuery()
        XCTAssertNotNil(resumed.lease)
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

private actor ComputeEventLog {
    private var storage: [String] = []

    func append(_ value: String) { storage.append(value) }
    func values() -> [String] { storage }
}

private extension SemanticQueryAdmission {
    var lease: AIComputeLease? {
        guard case .granted(let lease) = self else { return nil }
        return lease
    }

    var fallbackReason: SemanticQueryFallbackReason? {
        guard case .ftsOnly(let reason) = self else { return nil }
        return reason
    }
}
