import Foundation
import XCTest

final class AutomationAuditWriterTests: XCTestCase {
    func testRelocationDrainWaitsForInFlightAppendAndBlocksNewAdmission() async throws {
        let writeGate = AutomationAuditWriteGate()
        let writer = AutomationAuditWriter(
            resolveURL: { URL(fileURLWithPath: "/tmp/automation-audit.jsonl") },
            appendData: { _, _ in await writeGate.hold() }
        )
        let entry = AuditEntry(
            at: Date(timeIntervalSince1970: 1),
            automation: "test",
            day: "1970-01-01",
            action: "append",
            model: "none",
            sessions: 0,
            captures: 0,
            outputChars: 0,
            destPath: nil,
            ok: true,
            error: nil
        )

        let append = Task { try await writer.append(entry) }
        await writeGate.waitUntilStarted()
        let drain = Task { await writer.suspendAndDrainForRelocation() }

        for _ in 0..<20 { await Task.yield() }
        do {
            try await writer.append(entry)
            XCTFail("Expected audit admission to remain closed during relocation")
        } catch {
            XCTAssertEqual(error as? DatabaseWriterMaintenanceError, .suspendedForRelocation)
        }

        await writeGate.release()
        try await append.value
        let acknowledgement = await drain.value
        XCTAssertEqual(acknowledgement, DatabaseWriterDrainAcknowledgement(activeOperations: 0))

        await writer.resumeAfterRelocation()
        try await writer.append(entry)
        let startCount = await writeGate.startCount()
        XCTAssertEqual(startCount, 2)
    }
}

private actor AutomationAuditWriteGate {
    private var starts = 0
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        starts += 1
        let pending = startWaiters
        startWaiters.removeAll()
        pending.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard starts == 0 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func startCount() -> Int { starts }
}
