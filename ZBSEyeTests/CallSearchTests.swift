import XCTest
import GRDB

final class CallSearchTests: XCTestCase {
    func testPreferredCheckpointTranscriptIsSearchableAsCall() async throws {
        let fixture = try CallSearchFixture()
        let callID = try await fixture.makeCall(startedAtMs: 1_000)
        try await fixture.commitCheckpoint(
            callID: callID,
            key: "bookmark-1",
            startMs: 1_000,
            endMs: 2_000,
            text: "budget constellation"
        )

        let results = try await fixture.search.search(
            query: "constellation",
            filters: SearchFilters(kind: .call)
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, callID)
        XCTAssertEqual(results.first?.kind, .call)
        XCTAssertEqual(results.first?.appName, "Call")
        XCTAssertTrue(results.first?.snippet.contains("constellation") == true)
    }

    func testFinalTranscriptAtomicallyReplacesCheckpointSearchText() async throws {
        let fixture = try CallSearchFixture()
        let callID = try await fixture.makeCall(startedAtMs: 1_000)
        try await fixture.commitCheckpoint(
            callID: callID,
            key: "bookmark-1",
            startMs: 1_000,
            endMs: 2_000,
            text: "temporary platypus"
        )

        _ = try await fixture.repository.endCall(
            callID: callID,
            idempotencyKey: "end",
            endedAtMs: 4_000
        )
        let finalCandidate = try await fixture.repository.claimNextTranscriptJob(nowMs: 4_100)
        let finalJob = try XCTUnwrap(finalCandidate)
        _ = try await fixture.repository.commitTranscriptJob(
            jobID: try XCTUnwrap(finalJob.id),
            segments: [
                .init(source: .me, startMs: 1_100, endMs: 3_900, text: "canonical narwhal")
            ],
            language: "en",
            engine: "fixture",
            modelRevision: "fixture-v1",
            degraded: false,
            nowMs: 4_200
        )

        let oldResults = try await fixture.search.search(
            query: "platypus",
            filters: SearchFilters(kind: .call)
        )
        let finalResults = try await fixture.search.search(
            query: "narwhal",
            filters: SearchFilters(kind: .call)
        )

        XCTAssertTrue(oldResults.isEmpty)
        XCTAssertEqual(finalResults.map { $0.id }, [callID])
        XCTAssertEqual(finalResults.first?.windowTitle, "Final transcript")
    }

    func testAppFilterDoesNotLeakCallHitsIntoScreenResults() async throws {
        let fixture = try CallSearchFixture()
        let callID = try await fixture.makeCall(startedAtMs: 1_000)
        try await fixture.commitCheckpoint(
            callID: callID,
            key: "bookmark-1",
            startMs: 1_000,
            endMs: 2_000,
            text: "safari-shaped phrase"
        )

        let results = try await fixture.search.search(
            query: "phrase",
            filters: SearchFilters(app: "Safari")
        )

        XCTAssertTrue(results.isEmpty)
    }

    func testPreferredCheckpointIsQueuedForSemanticIndexing() async throws {
        let fixture = try CallSearchFixture()
        let callID = try await fixture.makeCall(startedAtMs: 1_000)
        try await fixture.commitCheckpoint(
            callID: callID,
            key: "bookmark-1",
            startMs: 1_000,
            endMs: 2_000,
            text: "semantic checkpoint"
        )

        let queued = try await fixture.database.pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT q.row_id AS revisionID, q.kind AS kind
                FROM embed_queue q
                JOIN calls c ON c.preferredRevisionId = q.row_id
                WHERE c.id = ? AND q.kind = 2
                """, arguments: [callID])
        }

        XCTAssertNotNil(queued)
        XCTAssertEqual(queued?["kind"] as Int?, 2)
    }

    func testSemanticCallHitUsesOnlyCurrentPreferredRevision() async throws {
        let fixture = try CallSearchFixture()
        let callID = try await fixture.makeCall(startedAtMs: 1_000)
        try await fixture.commitCheckpoint(
            callID: callID,
            key: "bookmark-1",
            startMs: 1_000,
            endMs: 2_000,
            text: "lexically unrelated"
        )
        let vector: [Float] = [1] + Array(repeating: 0, count: ZBSEyeDatabase.embeddingDim - 1)
        try await fixture.database.pool.write { db in
            let preferredID = try XCTUnwrap(Int64.fetchOne(
                db,
                sql: "SELECT preferredRevisionId FROM calls WHERE id = ?",
                arguments: [callID]
            ))
            let revisionIDs = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM call_transcript_revisions WHERE callId = ? ORDER BY id",
                arguments: [callID]
            )
            XCTAssertTrue(revisionIDs.contains(where: { $0 != preferredID }))
            for revisionID in revisionIDs {
                try db.execute(
                    sql: "INSERT INTO vec_call_transcripts(revision_id, bucket_month, embedding) VALUES (?, ?, ?)",
                    arguments: [revisionID, 197001, floatBlob(vector)]
                )
            }
        }
        let hybridSearch = SearchService(
            db: fixture.database,
            embedder: FixedCallSearchEmbedder(vector: vector)
        )

        let results = try await hybridSearch.search(
            query: "meaning-only",
            filters: SearchFilters(kind: .call)
        )

        XCTAssertEqual(results.map { $0.id }, [callID])
    }

    func testFinalPromotionKeepsOnlyFinalSemanticQueueEntry() async throws {
        let fixture = try CallSearchFixture()
        let callID = try await fixture.makeCall(startedAtMs: 1_000)
        try await fixture.commitCheckpoint(
            callID: callID,
            key: "bookmark-1",
            startMs: 1_000,
            endMs: 2_000,
            text: "checkpoint"
        )
        let provisionalID = try await fixture.database.pool.read { db in
            try XCTUnwrap(Int64.fetchOne(
                db,
                sql: "SELECT preferredRevisionId FROM calls WHERE id = ?",
                arguments: [callID]
            ))
        }

        _ = try await fixture.repository.endCall(
            callID: callID,
            idempotencyKey: "end",
            endedAtMs: 4_000
        )
        let candidate = try await fixture.repository.claimNextTranscriptJob(nowMs: 4_100)
        let finalJob = try XCTUnwrap(candidate)
        let final = try await fixture.repository.commitTranscriptJob(
            jobID: try XCTUnwrap(finalJob.id),
            segments: [.init(source: .me, startMs: 1_000, endMs: 4_000, text: "final")],
            language: "en",
            engine: "fixture",
            modelRevision: "fixture-v1",
            degraded: false,
            nowMs: 4_200
        )

        let queued = try await fixture.database.pool.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT q.row_id FROM embed_queue q
                JOIN call_transcript_revisions r ON r.id = q.row_id
                WHERE q.kind = 2 AND r.callId = ? ORDER BY q.row_id
                """, arguments: [callID])
        }
        XCTAssertEqual(queued, [final.preferredRevisionID])
        XCTAssertNotEqual(final.preferredRevisionID, provisionalID)
    }
}

private struct UnavailableCallSearchEmbedder: SearchEmbeddingProviding {
    func embed(query: String) async -> [Float]? { nil }
}

private struct FixedCallSearchEmbedder: SearchEmbeddingProviding {
    let vector: [Float]
    func embed(query: String) async -> [Float]? { vector }
}

private final class CallSearchFixture {
    let root: URL
    let database: ZBSEyeDatabase
    let repository: CallRepository
    let search: SearchService

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-call-search-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        repository = CallRepository(database: database)
        search = SearchService(
            db: database,
            embedder: UnavailableCallSearchEmbedder(),
            semanticPolicy: .ftsOnly(.secondaryProcess)
        )
    }

    func makeCall(startedAtMs: Int64) async throws -> Int64 {
        let call = try await repository.createCall(
            startedAtMs: startedAtMs,
            idempotencyKey: "call-\(startedAtMs)"
        )
        return try XCTUnwrap(call.id)
    }

    func commitCheckpoint(
        callID: Int64,
        key: String,
        startMs: Int64,
        endMs: Int64,
        text: String
    ) async throws {
        let created = try await repository.createBookmark(
            callID: callID,
            idempotencyKey: key,
            acceptedAtMs: endMs,
            meIngressTarget: 16_000,
            systemIngressTarget: 16_000,
            logicalStartMs: startMs,
            logicalEndMs: endMs,
            contextStartMs: max(1_000, startMs - 45_000)
        )
        _ = try await repository.freezeBookmarkCoverage(
            bookmarkID: try XCTUnwrap(created.bookmark.id),
            jobID: try XCTUnwrap(created.job.id),
            meEndSample: 16_000,
            systemEndSample: 16_000,
            degraded: false,
            nowMs: endMs
        )
        let candidate = try await repository.claimNextTranscriptJob(nowMs: endMs + 100)
        let job = try XCTUnwrap(candidate)
        _ = try await repository.commitTranscriptJob(
            jobID: try XCTUnwrap(job.id),
            segments: [.init(source: .me, startMs: startMs, endMs: endMs, text: text)],
            language: "en",
            engine: "fixture",
            modelRevision: "fixture-v1",
            degraded: false,
            nowMs: endMs + 200
        )
    }

    deinit {
        try? database.pool.close()
        try? FileManager.default.removeItem(at: root)
    }
}
