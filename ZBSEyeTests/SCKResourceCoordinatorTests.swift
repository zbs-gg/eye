import XCTest

final class SCKResourceCoordinatorTests: XCTestCase {
    func testSuspendedOperationsNeverOverlapAndRemainFIFO() async {
        let coordinator = SCKResourceCoordinator()
        let firstGate = SCKResourceTestGate()
        let probe = SCKResourceTestProbe()

        let first = Task {
            await coordinator.withExclusiveAccess(
                owner: .screen,
                operation: .start
            ) {
                await probe.enter("screen.start")
                await firstGate.wait()
                await probe.leave("screen.start")
            }
        }
        await probe.waitUntilEntered(1)

        let second = Task {
            await coordinator.withExclusiveAccess(
                owner: .systemAudio,
                operation: .start
            ) {
                await probe.enter("systemAudio.start")
                await probe.leave("systemAudio.start")
            }
        }
        guard await waitForPendingSCKOperations(1, on: coordinator) else {
            await firstGate.open()
            await first.value
            await second.value
            return
        }
        let third = Task {
            await coordinator.withExclusiveAccess(
                owner: .screen,
                operation: .update
            ) {
                await probe.enter("screen.update")
                await probe.leave("screen.update")
            }
        }
        guard await waitForPendingSCKOperations(2, on: coordinator) else {
            await firstGate.open()
            await first.value
            await second.value
            await third.value
            return
        }

        for _ in 0..<20 { await Task.yield() }
        let beforeRelease = await probe.snapshot()
        XCTAssertEqual(beforeRelease.entered, ["screen.start"])
        XCTAssertEqual(beforeRelease.maximumConcurrent, 1)

        await firstGate.open()
        await first.value
        await second.value
        await third.value

        let completed = await probe.snapshot()
        XCTAssertEqual(
            completed.entered,
            ["screen.start", "systemAudio.start", "screen.update"]
        )
        XCTAssertEqual(completed.maximumConcurrent, 1)
        XCTAssertEqual(completed.active, 0)
    }

    func testThrownOperationReleasesTheNextWaiter() async {
        let coordinator = SCKResourceCoordinator()

        do {
            _ = try await coordinator.withExclusiveAccess(
                owner: .systemAudio,
                operation: .stop
            ) {
                throw SCKResourceTestError.expected
            }
            XCTFail("the test operation must throw")
        } catch {
            XCTAssertEqual(error as? SCKResourceTestError, .expected)
        }

        let value = await coordinator.withExclusiveAccess(
            owner: .screen,
            operation: .start
        ) {
            42
        }
        XCTAssertEqual(value, 42)
    }

    func testBodyKeepsCallingActorIsolation() async {
        let coordinator = SCKResourceCoordinator()
        let owner = SCKResourceActorOwnedState()

        await owner.incrementWhileHolding(coordinator)

        let value = await owner.snapshot()
        XCTAssertEqual(value, 1)
    }
}

private func waitForPendingSCKOperations(
    _ expected: Int,
    on coordinator: SCKResourceCoordinator,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> Bool {
    for _ in 0..<10_000 {
        if await coordinator.pendingOperationCount >= expected {
            return true
        }
        await Task.yield()
    }
    XCTFail(
        "Timed out waiting for \(expected) queued SCK operations",
        file: file,
        line: line
    )
    return false
}

private enum SCKResourceTestError: Error, Equatable {
    case expected
}

private actor SCKResourceActorOwnedState {
    private var value = 0

    func incrementWhileHolding(_ coordinator: SCKResourceCoordinator) async {
        await coordinator.withExclusiveAccess(
            owner: .screen,
            operation: .update
        ) {
            value += 1
        }
    }

    func snapshot() -> Int { value }
}

private actor SCKResourceTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor SCKResourceTestProbe {
    private var active = 0
    private var maximumConcurrent = 0
    private var entered: [String] = []
    private var entryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func enter(_ label: String) {
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        entered.append(label)
        let ready = entryWaiters.filter { entered.count >= $0.0 }
        entryWaiters.removeAll { entered.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func leave(_ label: String) {
        active -= 1
    }

    func waitUntilEntered(_ count: Int) async {
        guard entered.count < count else { return }
        await withCheckedContinuation { entryWaiters.append((count, $0)) }
    }

    func snapshot() -> (active: Int, maximumConcurrent: Int, entered: [String]) {
        (active, maximumConcurrent, entered)
    }
}
