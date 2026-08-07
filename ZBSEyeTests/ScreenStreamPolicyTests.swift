import XCTest

final class ScreenStreamPolicyTests: XCTestCase {
    func testHundredTriggersRetainOneProcessingAndLatestWaitingIntent() {
        var policy = LatestCaptureWorkPolicy()

        for _ in 0..<100 { _ = policy.submit() }

        XCTAssertEqual(policy.processing, 1)
        XCTAssertEqual(policy.waiting, 100)
        XCTAssertEqual(policy.retainedCount, 2)
        XCTAssertEqual(policy.complete(1), 100)
        XCTAssertNil(policy.waiting)
        XCTAssertEqual(policy.retainedCount, 1)
    }

    func testIntentNeedsFreshCompleteOrIdleFrameFromCurrentGeneration() {
        var policy = ScreenStreamFreshnessPolicy()
        policy.beginGeneration(7)
        XCTAssertEqual(
            policy.observe(.init(generation: 7, status: .complete, displayTime: 100)),
            .heartbeat
        )
        let intent = policy.requestFrame()

        XCTAssertEqual(
            policy.observe(.init(generation: 6, status: .complete, displayTime: 101)),
            .rejected
        )
        XCTAssertEqual(
            policy.observe(.init(generation: 7, status: .nonProgress, displayTime: 102)),
            .rejected
        )
        XCTAssertEqual(
            policy.observe(.init(generation: 7, status: .idle, displayTime: 100)),
            .rejected
        )
        XCTAssertEqual(
            policy.observe(.init(generation: 7, status: .idle, displayTime: 103)),
            .fulfilled(intent)
        )
    }

    func testLatestIntentReplacesEarlierIntentWithoutChangingGeneration() {
        var policy = ScreenStreamFreshnessPolicy()
        policy.beginGeneration(11)
        let first = policy.requestFrame()
        let latest = policy.requestFrame()

        XCTAssertNotEqual(first.id, latest.id)
        XCTAssertEqual(first.generation, latest.generation)
        XCTAssertEqual(
            policy.observe(.init(generation: 11, status: .complete, displayTime: 1)),
            .fulfilled(latest)
        )
    }

    func testFirstIdleWithoutRetainedPixelsKeepsIntentForNextCompleteFrame() {
        var policy = ScreenStreamFreshnessPolicy()
        policy.beginGeneration(4)
        let intent = policy.requestFrame()

        XCTAssertEqual(
            policy.observe(
                .init(generation: 4, status: .idle, displayTime: 1),
                canFulfillIntent: false
            ),
            .heartbeat
        )
        XCTAssertEqual(policy.pendingIntent, intent)
        XCTAssertEqual(
            policy.observe(
                .init(generation: 4, status: .complete, displayTime: 2),
                canFulfillIntent: true
            ),
            .fulfilled(intent)
        )
    }

    func testSamePixelsStayHealthyAndOnlyEightSecondsOfFrameSilenceFails() {
        var policy = ScreenStreamLivenessPolicy(timeoutMs: 8_000)
        policy.started(generation: 3, nowMs: 0)

        // No pixel fingerprint participates in this policy. Repeated idle
        // compositor events are enough to keep a static desktop healthy.
        XCTAssertTrue(policy.observed(
            .init(generation: 3, status: .idle, displayTime: 1),
            nowMs: 7_999
        ))
        XCTAssertFalse(policy.shouldReportStall(nowMs: 15_998))
        XCTAssertTrue(policy.shouldReportStall(nowMs: 15_999))
        XCTAssertFalse(policy.shouldReportStall(nowMs: 30_000))
    }

    func testGenerationChangeRejectsLateFrameAndResetsFreshness() {
        var policy = ScreenStreamFreshnessPolicy()
        policy.beginGeneration(1)
        _ = policy.requestFrame()
        policy.beginGeneration(2)
        let current = policy.requestFrame()

        XCTAssertEqual(
            policy.observe(.init(generation: 1, status: .complete, displayTime: 999)),
            .rejected
        )
        XCTAssertEqual(
            policy.observe(.init(generation: 2, status: .complete, displayTime: 1)),
            .fulfilled(current)
        )
    }

    func testQueuedStartEventIsRejectedAfterFenceInvalidation() {
        let fence = ScreenStreamEventFence()
        let admittedRevision = fence.snapshot()
        var publication = ScreenStreamPublicationPolicy()
        publication.bind(generation: 9, eventRevision: admittedRevision)

        let queuedStartRevision = publication.publishIfPending(generation: 9)
        XCTAssertEqual(queuedStartRevision, admittedRevision)

        fence.invalidate()
        if let queuedStartRevision {
            XCTAssertFalse(fence.isCurrent(queuedStartRevision))
        }
        XCTAssertTrue(fence.isCurrent(fence.snapshot()))
    }

    func testFailedPendingInitialStartPublishesNeitherStartNorFailure() {
        var publication = ScreenStreamPublicationPolicy()
        publication.bind(generation: 5, eventRevision: 2)

        XCTAssertNil(publication.failureEvent(boundGeneration: 5))
        publication.end()
        XCTAssertNil(publication.publishIfPending(generation: 5))
    }

    func testDelegateStopCannotBeErasedByRebindOrLatePublication() throws {
        var publication = ScreenStreamPublicationPolicy()
        publication.bind(generation: 1, eventRevision: 4)
        XCTAssertEqual(publication.publishIfPending(generation: 1), 4)
        XCTAssertTrue(
            publication.rebindIfPublished(
                from: 1,
                to: 2,
                eventRevision: 4
            )
        )

        let failure = try XCTUnwrap(
            publication.failureEvent(boundGeneration: 2)
        )
        XCTAssertEqual(failure.generation, 1)
        XCTAssertEqual(failure.eventRevision, 4)

        publication.end()
        XCTAssertNil(publication.publishIfPending(generation: 2))
        XCTAssertNil(publication.failureEvent(boundGeneration: 2))
    }

    func testRebindCannotMovePublishedStreamAcrossFenceRevision() {
        var publication = ScreenStreamPublicationPolicy()
        publication.bind(generation: 1, eventRevision: 7)
        XCTAssertEqual(publication.publishIfPending(generation: 1), 7)

        XCTAssertFalse(
            publication.rebindIfPublished(
                from: 1,
                to: 2,
                eventRevision: 8
            )
        )
        XCTAssertTrue(publication.isPublished(generation: 1, eventRevision: 7))
    }

    func testThreeAcceptedProgressEventsWithoutPixelsOpenRecovery() {
        var policy = ScreenStreamMissingPixelPolicy(progressLimit: 3)

        XCTAssertEqual(
            policy.observe(
                acceptedProgress: false,
                hasUsablePixel: false,
                hasWaiter: true
            ),
            .none
        )
        XCTAssertEqual(policy.progressCount, 0)
        for expectedCount in 1...2 {
            XCTAssertEqual(
                policy.observe(
                    acceptedProgress: true,
                    hasUsablePixel: false,
                    hasWaiter: true
                ),
                .none
            )
            XCTAssertEqual(policy.progressCount, expectedCount)
        }
        XCTAssertEqual(
            policy.observe(
                acceptedProgress: true,
                hasUsablePixel: false,
                hasWaiter: true
            ),
            .failWaiter
        )
        XCTAssertEqual(policy.progressCount, 0)
    }

    func testUsablePixelAndNoWaiterResetMissingPixelRun() {
        var policy = ScreenStreamMissingPixelPolicy(progressLimit: 3)
        _ = policy.observe(
            acceptedProgress: true,
            hasUsablePixel: false,
            hasWaiter: true
        )
        XCTAssertEqual(policy.progressCount, 1)
        _ = policy.observe(
            acceptedProgress: true,
            hasUsablePixel: true,
            hasWaiter: true
        )
        XCTAssertEqual(policy.progressCount, 0)
        _ = policy.observe(
            acceptedProgress: true,
            hasUsablePixel: false,
            hasWaiter: false
        )
        XCTAssertEqual(policy.progressCount, 0)
    }

    func testFailedStopRetainsExactOwnershipUntilRetrySucceeds() {
        var ownership = ScreenStreamStopOwnership<Int>()

        guard case .own(11) = ownership.begin(target: 11) else {
            XCTFail("first stop must own the active stream")
            return
        }
        guard case .join(11) = ownership.begin(target: 22) else {
            XCTFail("concurrent stop must join the existing stream")
            return
        }
        XCTAssertTrue(ownership.complete(11, confirmed: false))
        XCTAssertFalse(ownership.permitsReplacement)

        guard case .own(11) = ownership.begin(target: 22) else {
            XCTFail("retry must retain the failed stream, not select a replacement")
            return
        }
        XCTAssertTrue(ownership.complete(11, confirmed: true))
        XCTAssertTrue(ownership.permitsReplacement)
    }

    func testQueuedStartAndStopHaveOneLinearPhysicalOutcome() async {
        for _ in 0..<100 {
            let handshake = ScreenStreamStartHandshake()
            let start = Task.detached { handshake.beginPhysicalStart() }
            let stop = Task.detached { handshake.stopDisposition() }
            let (startBegan, disposition) = await (start.value, stop.value)

            XCTAssertEqual(
                disposition,
                startBegan ? .requiresPhysicalStop : .confirmedNotStarted
            )
        }
    }

    func testConcurrentStopCallersJoinOneOperationAndOutcome() async {
        let gate = ScreenStreamStopTestGate()
        let harness = ScreenStreamStopTestHarness(gate: gate)
        let first = Task { await harness.stop(target: 1, confirmed: false) }
        await gate.waitUntilEntered()

        let second = Task { await harness.stop(target: 2, confirmed: true) }
        for _ in 0..<1_000 {
            if await harness.waiterCount == 1 { break }
            await Task.yield()
        }
        let operationCount = await harness.operationCount
        let waiterCount = await harness.waiterCount
        XCTAssertEqual(operationCount, 1)
        XCTAssertEqual(waiterCount, 1)

        await gate.open()
        let firstResult = await first.value
        let secondResult = await second.value
        let failedResource = await harness.failedResource
        XCTAssertFalse(firstResult)
        XCTAssertFalse(secondResult)
        XCTAssertEqual(failedResource, 1)
    }
}

private actor ScreenStreamStopTestHarness {
    private let gate: ScreenStreamStopTestGate
    private var ownership = ScreenStreamStopOwnership<Int>()
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private(set) var operationCount = 0

    init(gate: ScreenStreamStopTestGate) {
        self.gate = gate
    }

    var failedResource: Int? { ownership.failed }
    var waiterCount: Int { waiters.count }

    func stop(target: Int, confirmed: Bool) async -> Bool {
        switch ownership.begin(target: target) {
        case .noResource:
            return true
        case .join:
            return await withCheckedContinuation { waiters.append($0) }
        case .own(let resource):
            operationCount += 1
            await gate.wait()
            let matched = ownership.complete(resource, confirmed: confirmed)
            let result = matched && confirmed
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume(returning: result) }
            return result
        }
    }
}

private actor ScreenStreamStopTestGate {
    private var isOpen = false
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let pendingEntries = entryWaiters
        entryWaiters.removeAll()
        pendingEntries.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = openWaiters
        openWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
