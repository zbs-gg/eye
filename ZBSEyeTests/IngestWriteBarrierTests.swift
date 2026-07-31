import XCTest

final class IngestWriteBarrierTests: XCTestCase {
    func testDrainWaitsForWriteSuspendedAcrossAwait() async {
        let barrier = IngestWriteBarrier()
        let completion = AsyncBarrierCompletion()
        XCTAssertTrue(barrier.beginWrite())

        let drain = Task {
            let acknowledgement = await barrier.drain()
            await completion.markCompleted()
            return acknowledgement
        }
        for _ in 0..<20 { await Task.yield() }

        let completedBeforeWrite = await completion.isCompleted
        XCTAssertFalse(completedBeforeWrite)
        barrier.finishWrite()

        let acknowledgement = await drain.value
        XCTAssertEqual(acknowledgement.activeWrites, 0)
        let completedAfterWrite = await completion.isCompleted
        XCTAssertTrue(completedAfterWrite)
    }

    func testDrainWaitsForEveryConcurrentWrite() async {
        let barrier = IngestWriteBarrier()
        let completion = AsyncBarrierCompletion()
        XCTAssertTrue(barrier.beginWrite())
        XCTAssertTrue(barrier.beginWrite())

        let drain = Task {
            let acknowledgement = await barrier.drain()
            await completion.markCompleted()
            return acknowledgement
        }
        barrier.finishWrite()
        for _ in 0..<20 { await Task.yield() }

        let completedWithOneWriteLeft = await completion.isCompleted
        XCTAssertFalse(completedWithOneWriteLeft)
        barrier.finishWrite()

        let acknowledgement = await drain.value
        XCTAssertEqual(acknowledgement, IngestDrainAcknowledgement(activeWrites: 0))
    }

    func testSuspendClosesAdmissionUntilExactDrainIsResumed() async {
        let barrier = IngestWriteBarrier()
        XCTAssertTrue(barrier.beginWrite())

        let suspension = Task { await barrier.suspendAndDrain() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(barrier.beginWrite())
        XCTAssertTrue(barrier.snapshot().suspended)

        barrier.finishWrite()
        let acknowledgement = await suspension.value
        XCTAssertEqual(acknowledgement.activeWrites, 0)
        XCTAssertFalse(barrier.beginWrite())

        barrier.resume()
        XCTAssertTrue(barrier.beginWrite())
        barrier.finishWrite()
    }
}

private actor AsyncBarrierCompletion {
    private(set) var isCompleted = false
    func markCompleted() { isCompleted = true }
}
