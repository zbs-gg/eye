import XCTest
import GRDB

final class CallSearchTests: XCTestCase {
    func testLegacyAuthenticationFramesAreAbsentFromFTSSearch() async throws {
        let fixture = try CallSearchFixture()
        let ordinaryID = try await fixture.makeScreen(
            bundleID: "com.example.editor",
            appName: "Editor",
            timestampMs: 1_000,
            text: "ordinary visibility needle"
        )
        _ = try await fixture.makeScreen(
            bundleID: "com.apple.LocalAuthentication.UIAgent",
            appName: "LocalAuthentication UIAgent",
            timestampMs: 2_000,
            text: "protected visibility needle"
        )

        let results = try await fixture.search.search(
            query: "visibility needle",
            filters: SearchFilters(kind: .screen)
        )
        let protectedOnly = try await fixture.search.search(
            query: "protected visibility",
            filters: SearchFilters(kind: .screen)
        )

        XCTAssertEqual(results.map(\.id), [ordinaryID])
        XCTAssertTrue(protectedOnly.isEmpty)
    }

    func testProtectedFTSCandidatesCannotDisplaceAVisibleResultBelowTheWindow() async throws {
        let fixture = try CallSearchFixture()
        for index in 0..<50 {
            _ = try await fixture.makeScreen(
                bundleID: "com.apple.localauthentication.fixture\(index)",
                appName: "LocalAuthentication UIAgent",
                timestampMs: Int64(index + 1) * 1_000,
                text: "displacement needle"
            )
        }
        let ordinaryID = try await fixture.makeScreen(
            bundleID: "com.example.visible",
            appName: "Visible Editor",
            timestampMs: 100_000,
            text: "displacement needle"
        )

        let results = try await fixture.search.search(
            query: "displacement needle",
            filters: SearchFilters(kind: .screen, limit: 1)
        )

        XCTAssertEqual(results.map(\.id), [ordinaryID])
    }

    func testMoreThanFiveThousandProtectedFTSHitsCannotSaturateTheCandidateLimit() async throws {
        let fixture = try CallSearchFixture()
        let ordinaryID = try await fixture.makeProtectedFTSSaturation(count: 5_001)

        let results = try await fixture.search.search(
            query: "saturation",
            filters: SearchFilters(kind: .screen, limit: 1)
        )

        XCTAssertEqual(results.map(\.id), [ordinaryID])
        XCTAssertTrue(results.first?.snippet.contains("⟦saturation⟧") == true)
    }

    func testProtectedSemanticCandidatesAreSkippedWithoutConsumingTheWindow() async throws {
        let fixture = try CallSearchFixture()
        var protectedIDs: [Int64] = []
        for index in 0..<50 {
            protectedIDs.append(try await fixture.makeScreen(
                bundleID: "com.apple.localauthentication.semantic\(index)",
                appName: "LocalAuthentication UIAgent",
                timestampMs: Int64(index + 1) * 1_000,
                text: "lexically unrelated protected frame"
            ))
        }
        let ordinaryID = try await fixture.makeScreen(
            bundleID: "com.example.semantic-visible",
            appName: "Visible Editor",
            timestampMs: 100_000,
            text: "lexically unrelated ordinary frame"
        )
        let queryVector: [Float] = [1] + Array(
            repeating: 0,
            count: ZBSEyeDatabase.embeddingDim - 1
        )
        let ordinaryVector: [Float] = [0.9] + Array(
            repeating: 0,
            count: ZBSEyeDatabase.embeddingDim - 1
        )
        let protectedCaptureIDs = protectedIDs
        try await fixture.database.pool.write { db in
            for captureID in protectedCaptureIDs {
                try db.execute(
                    sql: "INSERT INTO vec_screen(capture_id, bucket_month, embedding) VALUES (?, ?, ?)",
                    arguments: [captureID, 197001, floatBlob(queryVector)]
                )
            }
            try db.execute(
                sql: "INSERT INTO vec_screen(capture_id, bucket_month, embedding) VALUES (?, ?, ?)",
                arguments: [ordinaryID, 197001, floatBlob(ordinaryVector)]
            )
        }
        let hybridSearch = SearchService(
            db: fixture.database,
            embedder: FixedCallSearchEmbedder(vector: queryVector)
        )

        let results = try await hybridSearch.search(
            query: "meaning-only",
            filters: SearchFilters(kind: .screen, limit: 1)
        )

        XCTAssertEqual(results.map(\.id), [ordinaryID])
    }

    func testSemanticPaginationBeyondTwoHundredFiftyKeepsItsCallerWindow() async throws {
        let fixture = try CallSearchFixture()
        let queryVector: [Float] = [1] + Array(
            repeating: 0,
            count: ZBSEyeDatabase.embeddingDim - 1
        )
        var captureIDs: [Int64] = []
        for index in 0..<292 {
            captureIDs.append(try await fixture.makeScreen(
                bundleID: "com.example.pagination.\(index)",
                appName: "Pagination Fixture",
                timestampMs: Int64(index + 1) * 1_000,
                text: "unrelated pagination fixture \(index)"
            ))
        }
        let immutableCaptureIDs = captureIDs
        try await fixture.database.pool.write { db in
            for captureID in immutableCaptureIDs {
                try db.execute(
                    sql: "INSERT INTO vec_screen(capture_id, bucket_month, embedding) VALUES (?, ?, ?)",
                    arguments: [captureID, 197001, floatBlob(queryVector)]
                )
            }
        }
        let semanticSearch = SearchService(
            db: fixture.database,
            embedder: FixedCallSearchEmbedder(vector: queryVector)
        )

        let results = try await semanticSearch.search(
            query: "meaning-only-offset",
            filters: SearchFilters(kind: .screen, limit: 1, offset: 251)
        )

        XCTAssertEqual(results.count, 1)
    }

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

    func makeScreen(
        bundleID: String,
        appName: String,
        timestampMs: Int64,
        text: String
    ) async throws -> Int64 {
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO apps(bundleId, name) VALUES (?, ?)",
                arguments: [bundleID, appName]
            )
            let appID = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO screen_captures(ts, appId, monitorId, windowTitle)
                    VALUES (?, ?, 'main', 'Fixture')
                    """,
                arguments: [timestampMs, appID]
            )
            let captureID = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO text_blocks(captureId, source, text) VALUES (?, 'ocr', ?)",
                arguments: [captureID, text]
            )
            return captureID
        }
    }

    func makeProtectedFTSSaturation(count: Int) async throws -> Int64 {
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO apps(bundleId, name) VALUES (?, ?)",
                arguments: ["com.apple.LocalAuthentication.UIAgent", "LocalAuthentication UIAgent"]
            )
            let protectedAppID = db.lastInsertedRowID
            for index in 0..<count {
                try db.execute(
                    sql: """
                        INSERT INTO screen_captures(ts, appId, monitorId, windowTitle)
                        VALUES (?, ?, 'main', 'Authentication')
                        """,
                    arguments: [Int64(index + 1) * 1_000, protectedAppID]
                )
                let captureID = db.lastInsertedRowID
                try db.execute(
                    sql: """
                        INSERT INTO text_blocks(captureId, source, text)
                        VALUES (?, 'ocr', 'saturation saturation saturation saturation saturation')
                        """,
                    arguments: [captureID]
                )
            }

            try db.execute(
                sql: "INSERT INTO apps(bundleId, name) VALUES (?, ?)",
                arguments: ["com.example.visible", "Visible Editor"]
            )
            let visibleAppID = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO screen_captures(ts, appId, monitorId, windowTitle)
                    VALUES (?, ?, 'main', 'Visible')
                    """,
                arguments: [Int64(count + 1) * 1_000, visibleAppID]
            )
            let visibleCaptureID = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO text_blocks(captureId, source, text)
                    VALUES (?, 'ocr', 'saturation')
                    """,
                arguments: [visibleCaptureID]
            )
            return visibleCaptureID
        }
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
