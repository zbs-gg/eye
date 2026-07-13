import XCTest

final class SearchSemanticPolicyTests: XCTestCase {
    func testActiveGenerationReturnsExplicitFTSFallbackWithoutCallingE5() async throws {
        let coordinator = AIComputeCoordinator(vectorBackfill: .noop)
        let generation = try await coordinator.acquireGeneration()
        let calls = SemanticCallCounter()
        let runner = SearchSemanticQueryRunner(policy: .coordinated(coordinator)) { query in
            await calls.record(query)
            return [1]
        }

        let outcome = await runner.run(query: "needle")

        XCTAssertEqual(outcome, .ftsOnly(.localGeneration))
        let calledQueries = await calls.values()
        XCTAssertEqual(calledQueries, [])
        await generation.release()
    }

    func testGenerationWaitsUntilInFlightQueryEmbeddingReleasesItsLease() async throws {
        let coordinator = AIComputeCoordinator(vectorBackfill: .noop)
        let embedder = BlockingSemanticEmbedder()
        let runner = SearchSemanticQueryRunner(policy: .coordinated(coordinator)) { query in
            await embedder.embed(query)
        }
        let search = Task { await runner.run(query: "needle") }
        await embedder.waitUntilStarted()

        let generation = Task { try await coordinator.acquireGeneration() }
        try await waitUntil { await coordinator.snapshot().generationPending }
        let releasedBeforeGeneration = await embedder.isReleased()
        XCTAssertFalse(releasedBeforeGeneration)

        await embedder.release(with: [0.25, 0.5])
        let searchOutcome = await search.value
        XCTAssertEqual(searchOutcome, .vector([0.25, 0.5]))
        let generationLease = try await generation.value
        let generationActive = await coordinator.snapshot().generationActive
        XCTAssertTrue(generationActive)
        await generationLease.release()
    }

    func testSecondaryProcessPolicyIsAlwaysFTSOnly() async {
        let calls = SemanticCallCounter()
        let runner = SearchSemanticQueryRunner(policy: .ftsOnly(.secondaryProcess)) { query in
            await calls.record(query)
            return [1]
        }

        let outcome = await runner.run(query: "helper")
        XCTAssertEqual(outcome, .ftsOnly(.secondaryProcess))
        let calledQueries = await calls.values()
        XCTAssertEqual(calledQueries, [])
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

private actor SemanticCallCounter {
    private var queries: [String] = []
    func record(_ query: String) { queries.append(query) }
    func values() -> [String] { queries }
}

private actor BlockingSemanticEmbedder {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<[Float]?, Never>?

    func embed(_ query: String) async -> [Float]? {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release(with vector: [Float]) {
        released = true
        continuation?.resume(returning: vector)
        continuation = nil
    }

    func isReleased() -> Bool { released }
}
