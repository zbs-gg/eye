import Foundation
import XCTest

/// Bounded compensating stress for the actor boundaries that remain meaningful
/// when MLX/Metal cannot run under Thread Sanitizer. The deterministic seed is
/// the loop index so a failure is reproducible without retry selection.
final class LocalAIConcurrencyStressTests: XCTestCase {
    private let selection = ProviderSelectionSnapshot(
        providerID: AIProvider.zbsEyeLocal.rawValue,
        modelID: BuiltInModelManifest.regular.id,
        selectionRevision: .init(rawValue: 1),
        authorizationEpoch: .init(rawValue: 1)
    )

    func testActivationRevocationCancellationAndShutdownInterleavings() async throws {
        try requireOptIn()
        for iteration in 0..<48 {
            let snapshots = StressSnapshotProvider(selection)
            let adapter = StressLLMAdapter()
            let registry = StressAdapterRegistry(
                registration: LLMAdapterRegistration(
                    providerID: selection.providerID,
                    executedLocally: true,
                    adapter: adapter
                )
            )
            let router = LLMRouter(
                snapshotProvider: snapshots,
                adapterRegistry: registry,
                drainAcknowledgementTimeout: .milliseconds(200)
            )
            let request = LLMRequest(
                id: UUID(),
                consumer: .ask,
                priority: .ask,
                systemPrompt: "system-\(iteration)",
                userPrompt: "user-\(iteration)",
                maximumOutputTokens: 16,
                timeout: .seconds(2)
            )
            let generation = Task { try await router.generate(request) }
            try await waitUntil { await adapter.hasStarted(request.id) }

            let expected: LLMRouterError
            switch iteration % 3 {
            case 0:
                await snapshots.set(nil)
                await router.selectionOrAuthorizationDidChange()
                expected = .selectionChanged
            case 1:
                generation.cancel()
                expected = .callerCancelled
            default:
                let drained = await router.shutdown(timeout: .milliseconds(200))
                XCTAssertTrue(drained, "iteration \(iteration) did not acknowledge shutdown")
                expected = .routerShuttingDown
            }

            await assertError(expected, from: generation, iteration: iteration)
            try await waitUntil { (await router.diagnostics()).active == nil }
            let diagnostic = await router.diagnostics()
            let maximumActiveCount = await adapter.maximumActiveCount()
            XCTAssertTrue(diagnostic.queued.isEmpty, "iteration \(iteration)")
            XCTAssertEqual(diagnostic.ownedTimeoutCount, 0, "iteration \(iteration)")
            XCTAssertLessThanOrEqual(maximumActiveCount, 1, "iteration \(iteration)")
        }
    }

    func testRelocationSuspendAndComputeDrainInterleavings() async throws {
        try requireOptIn()
        for iteration in 0..<48 {
            let coordinator = AIComputeCoordinator(vectorBackfill: .noop)
            if iteration.isMultiple(of: 2) {
                let queryAdmission = await coordinator.acquireSemanticQuery()
                let query = try XCTUnwrap(queryAdmission.lease)
                let generation = Task { try await coordinator.acquireGeneration() }
                try await waitUntil { await coordinator.snapshot().generationPending }
                let relocation = Task { try await coordinator.suspendAndDrain() }
                try await waitUntil { await coordinator.snapshot().externallySuspended }

                await query.release()
                do {
                    _ = try await generation.value
                    XCTFail("iteration \(iteration) acquired generation during relocation")
                } catch {
                    XCTAssertEqual(error as? AIComputeCoordinatorError, .suspended)
                }
                try await relocation.value
            } else {
                let generation = try await coordinator.acquireGeneration()
                let relocation = Task { try await coordinator.suspendAndDrain() }
                try await waitUntil { await coordinator.snapshot().externallySuspended }
                XCTAssertFalse(relocation.isCancelled)
                await generation.release()
                try await relocation.value
            }

            let suspended = await coordinator.snapshot()
            XCTAssertTrue(suspended.externallySuspended, "iteration \(iteration)")
            XCTAssertFalse(suspended.generationPending, "iteration \(iteration)")
            XCTAssertFalse(suspended.generationActive, "iteration \(iteration)")
            XCTAssertEqual(suspended.activeSemanticQueries, 0, "iteration \(iteration)")
            XCTAssertEqual(suspended.activeBackgroundEmbeddings, 0, "iteration \(iteration)")

            await coordinator.resume()
            let resumedAdmission = await coordinator.acquireSemanticQuery()
            let resumedLease = try XCTUnwrap(resumedAdmission.lease, "iteration \(iteration)")
            await resumedLease.release()
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
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("stress condition timed out")
        throw StressFailure.timedOut
    }

    private func requireOptIn() throws {
        let bundle = Bundle(for: LocalAIConcurrencyStressTests.self)
        let value = ProcessInfo.processInfo.environment["ZBS_EYE_LOCAL_AI_CONCURRENCY_STRESS"]
            ?? bundle.object(forInfoDictionaryKey: "ZBSEyeLocalAIConcurrencyStress") as? String
        guard value == "1" else {
            throw XCTSkip("Use verify-local-ai.sh --concurrency-stress or --concurrency-stress-tsan")
        }
    }

    private func assertError(
        _ expected: LLMRouterError,
        from task: Task<LLMResponse, any Error>,
        iteration: Int
    ) async {
        do {
            _ = try await task.value
            XCTFail("iteration \(iteration) unexpectedly completed")
        } catch {
            XCTAssertEqual(error as? LLMRouterError, expected, "iteration \(iteration)")
        }
    }
}

private enum StressFailure: Error {
    case timedOut
}

private actor StressSnapshotProvider: LLMSelectionSnapshotProviding {
    private var selection: ProviderSelectionSnapshot?

    init(_ selection: ProviderSelectionSnapshot?) {
        self.selection = selection
    }

    func currentSnapshot(for consumer: AIConsumer) -> ProviderSelectionSnapshot? {
        selection
    }

    func set(_ selection: ProviderSelectionSnapshot?) {
        self.selection = selection
    }
}

private actor StressAdapterRegistry: LLMAdapterRegistering {
    private let registration: LLMAdapterRegistration

    init(registration: LLMAdapterRegistration) {
        self.registration = registration
    }

    func registration(for providerID: String) -> LLMAdapterRegistration? {
        providerID == registration.providerID ? registration : nil
    }
}

private actor StressLLMAdapter: LLMAdapter {
    private var active = 0
    private var maximumActive = 0
    private var started: Set<UUID> = []

    func generate(
        request: LLMRequest,
        selection: ProviderSelectionSnapshot
    ) async throws -> LLMResponse {
        active += 1
        maximumActive = max(maximumActive, active)
        started.insert(request.id)
        defer { active -= 1 }
        try await Task.sleep(for: .seconds(5))
        return LLMResponse(
            content: "answer",
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

    func hasStarted(_ id: UUID) -> Bool { started.contains(id) }
    func maximumActiveCount() -> Int { maximumActive }
}

private extension SemanticQueryAdmission {
    var lease: AIComputeLease? {
        guard case .granted(let lease) = self else { return nil }
        return lease
    }
}
