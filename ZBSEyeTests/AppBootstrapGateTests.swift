import XCTest

@MainActor
final class AppBootstrapGateTests: XCTestCase {
    func testCompletedBootstrapIsNotRunAgainWhenWindowReopens() async {
        let gate = AppBootstrapGate()
        let executions = BootstrapExecutionCounter()

        await gate.run { await executions.increment() }
        await gate.run { await executions.increment() }

        let executionCount = await executions.value()
        XCTAssertEqual(executionCount, 1)
    }

    func testConcurrentBootstrapCallsShareTheInFlightOperation() async {
        let gate = AppBootstrapGate()
        let probe = BootstrapExecutionProbe()
        let first = Task { @MainActor in
            await gate.run { await probe.runAndWait() }
        }
        await probe.waitUntilStarted()

        let second = Task { @MainActor in
            await gate.run { await probe.runAndWait() }
        }
        for _ in 0..<20 { await Task.yield() }
        let startsBeforeRelease = await probe.starts()
        XCTAssertEqual(startsBeforeRelease, 1)

        await probe.release()
        await first.value
        await second.value
        let startsAfterRelease = await probe.starts()
        XCTAssertEqual(startsAfterRelease, 1)
    }
}

private actor BootstrapExecutionCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

private actor BootstrapExecutionProbe {
    private var count = 0
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func runAndWait() async {
        count += 1
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async {
        if count > 0 { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func starts() -> Int { count }
}
