import XCTest

final class DatabaseWriterMaintenanceGateTests: XCTestCase {
    func testSuspendedAdmissionErrorExplainsRelocation() {
        let error = DatabaseWriterMaintenanceError.suspendedForRelocation

        XCTAssertEqual(
            error.errorDescription,
            "Database maintenance is paused while storage is being moved."
        )
    }

    func testResumeIsNoOpWhenThisWriterWasNeverSuspended() {
        let gate = DatabaseWriterMaintenanceGate()

        XCTAssertTrue(gate.beginOperation())
        gate.resume()

        XCTAssertEqual(
            gate.snapshot(),
            DatabaseWriterMaintenanceSnapshot(activeOperations: 1, suspended: false)
        )
        gate.finishOperation()
    }

    func testSuspendBlocksNewAdmissionsUntilActiveOperationDrainsAndResume() async {
        let gate = DatabaseWriterMaintenanceGate()
        let completion = CompletionProbe()

        XCTAssertTrue(gate.beginOperation())

        let drainTask = Task {
            let acknowledgement = await gate.suspendAndDrain()
            await completion.markCompleted()
            return acknowledgement
        }

        while !gate.snapshot().suspended {
            await Task.yield()
        }

        XCTAssertFalse(gate.beginOperation())
        let completedBeforeFinish = await completion.isCompleted
        XCTAssertFalse(completedBeforeFinish)

        gate.finishOperation()

        let acknowledgement = await drainTask.value
        XCTAssertEqual(
            acknowledgement,
            DatabaseWriterDrainAcknowledgement(activeOperations: 0)
        )
        let completedAfterFinish = await completion.isCompleted
        XCTAssertTrue(completedAfterFinish)
        XCTAssertFalse(gate.beginOperation())

        gate.resume()

        XCTAssertTrue(gate.beginOperation())
        gate.finishOperation()
    }

    func testSuspendWaitsForEveryOperationAdmittedAcrossActorReentrancy() async {
        let gate = DatabaseWriterMaintenanceGate()
        let completion = CompletionProbe()

        XCTAssertTrue(gate.beginOperation())
        XCTAssertTrue(gate.beginOperation())
        XCTAssertTrue(gate.beginOperation())

        let drainTask = Task {
            let acknowledgement = await gate.suspendAndDrain()
            await completion.markCompleted()
            return acknowledgement
        }

        while !gate.snapshot().suspended {
            await Task.yield()
        }

        gate.finishOperation()
        gate.finishOperation()
        await Task.yield()

        let completedBeforeFinalFinish = await completion.isCompleted
        XCTAssertFalse(completedBeforeFinalFinish)
        XCTAssertEqual(
            gate.snapshot(),
            DatabaseWriterMaintenanceSnapshot(activeOperations: 1, suspended: true)
        )

        gate.finishOperation()

        let acknowledgement = await drainTask.value
        XCTAssertEqual(
            acknowledgement,
            DatabaseWriterDrainAcknowledgement(activeOperations: 0)
        )
        let completedAfterFinalFinish = await completion.isCompleted
        XCTAssertTrue(completedAfterFinalFinish)
    }
}

private actor CompletionProbe {
    private var completed = false

    var isCompleted: Bool { completed }

    func markCompleted() {
        completed = true
    }
}
