import XCTest
import GRDB

final class CallDatabaseTests: XCTestCase {
    func testFreshAndV6StoresMigrateWithoutLosingExistingRows() async throws {
        let fresh = try CallDatabaseTestStore()
        let freshTables = try await fresh.database.pool.read { db in
            try Set(String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            ))
        }
        XCTAssertTrue([
            "calls", "call_source_spans", "call_audio_chunks", "call_bookmarks",
            "call_transcript_jobs", "call_transcript_revisions",
            "call_transcript_segments", "call_transcript_projection_gaps",
            "call_media_mutations", "call_source_gaps", "call_transcript_fts",
        ].allSatisfy(freshTables.contains))

        let upgraded = try CallDatabaseTestStore(runMigrations: false)
        try ZBSEyeDatabase.migrator.migrate(upgraded.database.pool, upTo: "v6_embed_queue")
        try await upgraded.database.pool.write { db in
            try db.execute(sql: "INSERT INTO apps(id, bundleId, name) VALUES (17, 'fixture.app', 'Fixture')")
        }

        try ZBSEyeDatabase.migrator.migrate(upgraded.database.pool)

        let snapshot = try await upgraded.database.pool.read { db in
            (
                appCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM apps") ?? 0,
                migrations: try String.fetchAll(
                    db,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
                ),
                triggerCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'call_%'"
                ) ?? 0
            )
        }
        XCTAssertEqual(snapshot.appCount, 1)
        XCTAssertEqual(snapshot.migrations.last, "v9_call_source_gaps")
        XCTAssertGreaterThanOrEqual(snapshot.triggerCount, 6)
    }

    func testPreferredRevisionAcceptsReadyProjectionThenFinalAndCleansStaleSearchState() async throws {
        let store = try CallDatabaseTestStore()
        let repository = CallRepository(database: store.database)
        let first = try await repository.createCall(startedAtMs: 1_000, idempotencyKey: "call-a")
        let firstFinal = try await repository.endCall(
            callID: try XCTUnwrap(first.id),
            idempotencyKey: "end-a",
            endedAtMs: 2_000
        )
        let second = try await repository.createCall(startedAtMs: 3_000, idempotencyKey: "call-b")
        let secondFinal = try await repository.endCall(
            callID: try XCTUnwrap(second.id),
            idempotencyKey: "end-b",
            endedAtMs: 4_000
        )

        let ids = try await store.database.pool.write { db -> (Int64, Int64, Int64, Int64) in
            var firstReady = CallTranscriptRevisionRow(
                id: nil,
                callId: try XCTUnwrap(first.id),
                jobId: try XCTUnwrap(firstFinal.id),
                projectionKey: nil,
                kind: .final,
                mediaGeneration: 0,
                state: .ready,
                text: "first",
                language: "en",
                engine: "fixture",
                modelRevision: "fixture",
                logicalStartMs: 1_000,
                logicalEndMs: 2_000,
                createdAtMs: 5_000
            )
            try firstReady.insert(db)
            var firstNotReady = CallTranscriptRevisionRow(
                id: nil,
                callId: try XCTUnwrap(first.id),
                jobId: nil,
                projectionKey: "draft-a",
                kind: .final,
                mediaGeneration: 0,
                state: .writing,
                text: "draft",
                language: "en",
                engine: "fixture",
                modelRevision: "fixture",
                logicalStartMs: 1_000,
                logicalEndMs: 2_000,
                createdAtMs: 5_001
            )
            try firstNotReady.insert(db)
            var secondReady = CallTranscriptRevisionRow(
                id: nil,
                callId: try XCTUnwrap(second.id),
                jobId: try XCTUnwrap(secondFinal.id),
                projectionKey: nil,
                kind: .final,
                mediaGeneration: 0,
                state: .ready,
                text: "second",
                language: "en",
                engine: "fixture",
                modelRevision: "fixture",
                logicalStartMs: 3_000,
                logicalEndMs: 4_000,
                createdAtMs: 5_002
            )
            try secondReady.insert(db)
            var firstProjection = CallTranscriptRevisionRow(
                id: nil,
                callId: try XCTUnwrap(first.id),
                jobId: nil,
                projectionKey: "projection-a",
                kind: .projection,
                mediaGeneration: 0,
                state: .ready,
                text: "provisional",
                language: "en",
                engine: "fixture",
                modelRevision: "fixture",
                logicalStartMs: 1_000,
                logicalEndMs: 1_500,
                createdAtMs: 4_999
            )
            try firstProjection.insert(db)
            return (
                try XCTUnwrap(firstReady.id),
                try XCTUnwrap(firstNotReady.id),
                try XCTUnwrap(secondReady.id),
                try XCTUnwrap(firstProjection.id)
            )
        }

        await XCTAssertThrowsAsync {
            try await repository.setPreferredRevision(callID: try XCTUnwrap(first.id), revisionID: ids.2)
        }
        await XCTAssertThrowsAsync {
            try await repository.setPreferredRevision(callID: try XCTUnwrap(first.id), revisionID: ids.1)
        }
        try await repository.setPreferredRevision(callID: try XCTUnwrap(first.id), revisionID: ids.3)
        let vector = Data(count: ZBSEyeDatabase.embeddingDim * MemoryLayout<Float>.size)
        try await store.database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO vec_call_transcripts(revision_id, bucket_month, embedding) VALUES (?, 202607, ?)",
                arguments: [ids.3, vector]
            )
        }
        try await repository.setPreferredRevision(callID: try XCTUnwrap(first.id), revisionID: ids.0)

        let projection = try await store.database.pool.read { db in
            (
                preferred: try Int64.fetchOne(
                    db,
                    sql: "SELECT preferredRevisionId FROM calls WHERE id = ?",
                    arguments: [first.id]
                ),
                indexed: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_fts WHERE revision_id = ?",
                    arguments: [ids.0]
                ) ?? 0,
                staleFTS: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_fts WHERE revision_id = ?",
                    arguments: [ids.3]
                ) ?? 0,
                staleVectors: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM vec_call_transcripts WHERE revision_id = ?",
                    arguments: [ids.3]
                ) ?? 0
            )
        }
        XCTAssertEqual(projection.preferred, ids.0)
        XCTAssertEqual(projection.indexed, 1)
        XCTAssertEqual(projection.staleFTS, 0)
        XCTAssertEqual(projection.staleVectors, 0)
    }

    func testChunkOwnershipAndFinalizedImmutabilityAreEnforcedBySchema() async throws {
        let store = try CallDatabaseTestStore()
        let repository = CallRepository(database: store.database)
        let first = try await repository.createCall(startedAtMs: 1_000, idempotencyKey: "owner-a")
        let firstID = try XCTUnwrap(first.id)
        let firstBookmark = try await repository.createBookmark(
            callID: firstID,
            idempotencyKey: "owner-a-bookmark",
            acceptedAtMs: 1_500,
            meIngressTarget: 1,
            systemIngressTarget: nil,
            logicalStartMs: 1_000,
            logicalEndMs: 1_500,
            contextStartMs: 1_000
        )
        let firstFinal = try await repository.endCall(
            callID: firstID,
            idempotencyKey: "owner-a-end",
            endedAtMs: 2_000
        )
        let second = try await repository.createCall(startedAtMs: 3_000, idempotencyKey: "owner-b")
        let secondID = try XCTUnwrap(second.id)
        _ = try await repository.endCall(
            callID: secondID,
            idempotencyKey: "owner-b-end",
            endedAtMs: 4_000
        )
        let firstSpan = try await repository.recordSourceSpan(
            CallSourceSpanDraft(
                callId: firstID,
                source: .me,
                epoch: 0,
                sampleRate: 16_000,
                startedAtMs: 1_000,
                startSample: 0,
                startHostTimeNs: 0,
                availability: .available
            )
        )
        let secondSpan = try await repository.recordSourceSpan(
            CallSourceSpanDraft(
                callId: secondID,
                source: .system,
                epoch: 0,
                sampleRate: 16_000,
                startedAtMs: 3_000,
                startSample: 0,
                startHostTimeNs: 0,
                availability: .available
            )
        )

        await XCTAssertThrowsAsync {
            _ = try await repository.recordAudioChunk(
                CallAudioChunkDraft(
                    callId: secondID,
                    sourceSpanId: try XCTUnwrap(firstSpan.id),
                    source: .system,
                    epoch: 0,
                    sequence: 0,
                    mediaGeneration: 0,
                    startSample: 0,
                    endSample: 1,
                    startMs: 3_000,
                    endMs: 3_001,
                    relativePath: "calls/cross-owner.pcm",
                    bytes: 2,
                    sha256: "fixture",
                    finalized: true
                )
            )
        }

        let chunk = try await repository.recordAudioChunk(
            CallAudioChunkDraft(
                callId: secondID,
                sourceSpanId: try XCTUnwrap(secondSpan.id),
                source: .system,
                epoch: 0,
                sequence: 0,
                mediaGeneration: 0,
                startSample: 0,
                endSample: 1,
                startMs: 3_000,
                endMs: 3_001,
                relativePath: "calls/owned.pcm",
                bytes: 2,
                sha256: "fixture",
                finalized: true
            )
        )
        await XCTAssertThrowsAsync {
            try await store.database.pool.write { db in
                try db.execute(
                    sql: "UPDATE call_audio_chunks SET relativePath = 'calls/mutated.pcm' WHERE id = ?",
                    arguments: [chunk.id]
                )
            }
        }
        await XCTAssertThrowsAsync {
            try await store.database.pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO call_transcript_jobs(
                            identity, callId, bookmarkId, kind, mediaGeneration, state, priority,
                            logicalStartMs, logicalEndMs, contextStartMs, coverageFrozen,
                            attempts, createdAtMs, updatedAtMs
                        ) VALUES ('cross-bookmark', ?, ?, 'checkpoint', 0, 'preparing', 100,
                            3_000, 3_500, 3_000, 0, 0, 3_500, 3_500)
                        """,
                    arguments: [secondID, firstBookmark.bookmark.id]
                )
            }
        }
        await XCTAssertThrowsAsync {
            try await store.database.pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO call_transcript_revisions(
                            callId, jobId, projectionKey, kind, mediaGeneration, state, text,
                            language, engine, modelRevision, logicalStartMs, logicalEndMs, createdAtMs
                        ) VALUES (?, ?, NULL, 'final', 0, 'ready', 'cross', 'en', 'fixture',
                            'fixture', 3_000, 4_000, 5_000)
                        """,
                    arguments: [secondID, firstFinal.id]
                )
            }
        }
    }

    func testBookmarkAndCurrentGenerationFinalJobAreTransactionallyIdempotent() async throws {
        let store = try CallDatabaseTestStore()
        let repository = CallRepository(database: store.database)
        let call = try await repository.createCall(startedAtMs: 10_000, idempotencyKey: "call")
        let callID = try XCTUnwrap(call.id)

        let first = try await repository.createBookmark(
            callID: callID,
            idempotencyKey: "bookmark-1",
            acceptedAtMs: 11_000,
            meIngressTarget: 41,
            systemIngressTarget: 92,
            logicalStartMs: 10_000,
            logicalEndMs: 11_000,
            contextStartMs: 10_000
        )
        let repeated = try await repository.createBookmark(
            callID: callID,
            idempotencyKey: "bookmark-1",
            acceptedAtMs: 99_000,
            meIngressTarget: 999,
            systemIngressTarget: 999,
            logicalStartMs: 98_000,
            logicalEndMs: 99_000,
            contextStartMs: 97_000
        )
        XCTAssertEqual(first.bookmark.id, repeated.bookmark.id)
        XCTAssertEqual(first.job.id, repeated.job.id)
        XCTAssertEqual(repeated.bookmark.acceptedAtMs, 11_000)
        XCTAssertEqual(repeated.job.state, .preparing)

        let final = try await repository.endCall(
            callID: callID,
            idempotencyKey: "end-1",
            endedAtMs: 12_000
        )
        let repeatedFinal = try await repository.endCall(
            callID: callID,
            idempotencyKey: "end-1",
            endedAtMs: 99_000
        )
        XCTAssertEqual(final.id, repeatedFinal.id)

        let counts = try await store.database.pool.read { db in
            (
                bookmarks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_bookmarks") ?? 0,
                checkpointJobs: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_jobs WHERE kind = 'checkpoint'"
                ) ?? 0,
                finalJobs: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_jobs WHERE kind = 'final'"
                ) ?? 0,
                endedAt: try Int64.fetchOne(
                    db,
                    sql: "SELECT endTs FROM calls WHERE id = ?",
                    arguments: [callID]
                )
            )
        }
        XCTAssertEqual(counts.bookmarks, 1)
        XCTAssertEqual(counts.checkpointJobs, 1)
        XCTAssertEqual(counts.finalJobs, 1)
        XCTAssertEqual(counts.endedAt, 12_000)
    }
}

private final class CallDatabaseTestStore {
    let root: URL
    let database: ZBSEyeDatabase

    init(runMigrations: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "zbseye-call-db-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(
            path: root.appending(path: "eye.sqlite").path,
            runMigrations: runMigrations
        )
    }

    deinit {
        try? database.pool.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private func XCTAssertThrowsAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
