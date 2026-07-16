import GRDB
import XCTest

final class MCPCallEvidenceRoutingTests: XCTestCase {
    func testMCPUsesTheSameProjectionAsRESTContract() async throws {
        let fixture = try CallAgentFixture()
        let ids = try await fixture.makeReadyCall(segmentCount: 4, micOnly: false)
        let coordinator = MCPCallEvidenceCoordinator(service: fixture.service)

        let directCandidate = try await fixture.service.envelope(callID: ids.callID)
        let direct = try XCTUnwrap(directCandidate)
        let routedCandidate = try await coordinator.envelope(callID: CallEvidenceIdentifier.call(ids.callID))
        let routed = try XCTUnwrap(routedCandidate)
        XCTAssertEqual(routed, direct)

        let transcript = try await coordinator.transcript(
            callID: CallEvidenceIdentifier.call(ids.callID),
            selector: "preferred",
            bookmarkID: nil,
            limit: 2,
            offset: 2
        )
        XCTAssertEqual(transcript.segments.map(\.text), ["line 2", "line 3"])
        XCTAssertFalse(transcript.hasMore)
    }

    func testDirectDatabaseModeIsActuallyReadOnly() async throws {
        let fixture = try CallAgentFixture()
        let ids = try await fixture.makeReadyCall(segmentCount: 1, micOnly: false)
        let path = fixture.root.appendingPathComponent("eye.sqlite").path
        let readOnly = try ZBSEyeDatabase(path: path, runMigrations: false, access: .readOnly)
        defer { try? readOnly.pool.close() }

        let service = CallEvidenceQueryService(database: readOnly)
        let envelope = try await service.envelope(callID: ids.callID)
        XCTAssertNotNil(envelope)
        do {
            try await readOnly.pool.write { db in
                try db.execute(sql: "UPDATE calls SET updatedAtMs = updatedAtMs + 1 WHERE id = ?", arguments: [ids.callID])
            }
            XCTFail("read-only MCP database accepted a write")
        } catch {
            XCTAssertTrue(true)
        }
    }

    func testCoordinatorRejectsRawAndCrossTypedIdentifiers() async throws {
        let fixture = try CallAgentFixture()
        let coordinator = MCPCallEvidenceCoordinator(service: fixture.service)

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.envelope(callID: "1")
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.transcript(
                callID: "bookmark:1",
                selector: "preferred",
                bookmarkID: nil,
                limit: 10,
                offset: 0
            )
        }
        XCTAssertTrue(MCPCallEvidenceCoordinator.requestsAlternateStorage(argumentKeys: ["call_id", "root"]))
        XCTAssertTrue(MCPCallEvidenceCoordinator.requestsAlternateStorage(argumentKeys: ["database_path"]))
        XCTAssertFalse(MCPCallEvidenceCoordinator.requestsAlternateStorage(argumentKeys: ["call_id", "limit"]))
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}
