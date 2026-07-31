import Foundation
import GRDB
import XCTest

final class CaptureCoveragePersistenceTests: XCTestCase {
    private var root: URL!
    private var database: ZBSEyeDatabase!
    private var ingest: IngestService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "zbseye-capture-coverage-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        ingest = IngestService(
            db: database,
            storage: try StorageManager(mediaDirectory: root.appendingPathComponent("media"))
        )
    }

    override func tearDownWithError() throws {
        ingest = nil
        try? database?.pool.close()
        database = nil
        if root != nil { try? FileManager.default.removeItem(at: root) }
    }

    func testOpenSurvivesReopenAndCloseUsesEpisodeGenerationCAS() async throws {
        let open = CaptureCoverageOpen(
            leg: .screen,
            reason: .screenRequestFailed,
            episodeID: "episode-a",
            generation: 4,
            startMs: 1_000
        )
        let firstOpen = try await ingest.openCaptureCoverage(open)
        XCTAssertTrue(firstOpen)
        let replayOpen = try await ingest.openCaptureCoverage(open)
        XCTAssertFalse(replayOpen, "same identity is idempotent")

        let path = root.appendingPathComponent("eye.sqlite").path
        ingest = nil
        try database.pool.close()
        database = nil
        database = try ZBSEyeDatabase(path: path)
        let query = CaptureCoverageQuery(database: database)
        let reopened = try await query.openIntervals()
        guard case .available(let rows) = reopened else {
            return XCTFail("v15 metadata should be available")
        }
        XCTAssertEqual(rows.map(\.episodeID), ["episode-a"])

        ingest = IngestService(
            db: database,
            storage: try StorageManager(mediaDirectory: root.appendingPathComponent("media"))
        )
        let mismatchedClose = try await ingest.closeCaptureCoverage(.init(
            leg: .screen,
            episodeID: "episode-a",
            generation: 3,
            endMs: 1_100,
            cause: .verifiedProgress
        ))
        XCTAssertFalse(mismatchedClose)
        let matchingClose = try await ingest.closeCaptureCoverage(.init(
            leg: .screen,
            episodeID: "episode-a",
            generation: 4,
            endMs: 1_100,
            cause: .verifiedProgress
        ))
        XCTAssertTrue(matchingClose)
        let repeatedClose = try await ingest.closeCaptureCoverage(.init(
            leg: .screen,
            episodeID: "episode-a",
            generation: 4,
            endMs: 1_200,
            cause: .verifiedProgress
        ))
        XCTAssertFalse(repeatedClose)
    }

    func testOneOpenIntervalPerLegAndHalfOpenOverlap() async throws {
        let screenOpen = try await ingest.openCaptureCoverage(.init(
            leg: .screen,
            reason: .screenProgressUnverified,
            episodeID: "screen-a",
            generation: 1,
            startMs: 100
        ))
        XCTAssertTrue(screenOpen)
        let conflictingScreenOpen = try await ingest.openCaptureCoverage(.init(
            leg: .screen,
            reason: .screenRequestFailed,
            episodeID: "screen-b",
            generation: 2,
            startMs: 120
        ))
        XCTAssertFalse(conflictingScreenOpen)
        let audioOpen = try await ingest.openCaptureCoverage(.init(
            leg: .systemAudio,
            reason: .systemAudioStartFailed,
            episodeID: "audio-a",
            generation: 1,
            startMs: 150
        ))
        XCTAssertTrue(audioOpen)
        let screenClose = try await ingest.closeCaptureCoverage(.init(
            leg: .screen,
            episodeID: "screen-a",
            generation: 1,
            endMs: 200,
            cause: .verifiedProgress
        ))
        XCTAssertTrue(screenClose)

        let query = CaptureCoverageQuery(database: database)
        guard case .available(let before) = try await query.overlapping(startMs: 50, endMs: 100) else {
            return XCTFail("metadata unavailable")
        }
        XCTAssertTrue(before.isEmpty, "an interval starting at the query end does not overlap")

        guard case .available(let atStart) = try await query.overlapping(startMs: 100, endMs: 101) else {
            return XCTFail("metadata unavailable")
        }
        XCTAssertEqual(atStart.map(\.episodeID), ["screen-a"])

        guard case .available(let atEnd) = try await query.overlapping(startMs: 200, endMs: 201) else {
            return XCTFail("metadata unavailable")
        }
        XCTAssertEqual(atEnd.map(\.episodeID), ["audio-a"], "a closed interval ending at query start does not overlap")
        let emptyRange = try await query.overlapping(startMs: 300, endMs: 300)
        XCTAssertEqual(emptyRange, .available([]))
    }

    func testMissingTableReportsMetadataUnavailable() async throws {
        try await database.pool.write { db in
            try db.execute(sql: "DROP TABLE capture_coverage_intervals")
        }
        let read = try await CaptureCoverageQuery(database: database).openIntervals()
        XCTAssertEqual(read, .metadataUnavailable)
    }

    func testMigrationIsAdditiveAndDatabaseIntegrityPasses() async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO apps(bundleId, name) VALUES (?, ?)",
                arguments: ["com.example.app", "Example"]
            )
            let appID = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO screen_captures(ts, appId, monitorId)
                    VALUES (?, ?, ?)
                    """,
                arguments: [123, appID, "main"]
            )
            // Reconstruct a real pre-v15 database without touching capture rows.
            try db.execute(sql: "DROP TABLE capture_coverage_intervals")
            try db.execute(sql: """
                DELETE FROM grdb_migrations
                WHERE identifier = 'v15_capture_coverage'
                """)
        }

        let path = root.appendingPathComponent("eye.sqlite").path
        ingest = nil
        try database.pool.close()
        database = nil
        database = try ZBSEyeDatabase(path: path)
        let proof = try await database.pool.read { db -> (Int, String, Int, Int, String) in
            let captures = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM screen_captures") ?? -1
            let integrity = try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "missing"
            let foreignKeys = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check") ?? -1
            let indexes = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE type = 'index'
                      AND name IN (
                        'idx_capture_coverage_one_open_per_leg',
                        'idx_capture_coverage_overlap'
                      )
                    """
            ) ?? -1
            let rangeIndexLeadingColumn = try String.fetchOne(
                db,
                sql: """
                    SELECT name
                    FROM pragma_index_info('idx_capture_coverage_overlap')
                    ORDER BY seqno
                    LIMIT 1
                    """
            ) ?? "missing"
            return (captures, integrity, foreignKeys, indexes, rangeIndexLeadingColumn)
        }
        XCTAssertEqual(proof.0, 1)
        XCTAssertEqual(proof.1, "ok")
        XCTAssertEqual(proof.2, 0)
        XCTAssertEqual(proof.3, 2)
        XCTAssertEqual(proof.4, "start_ms")
    }

    func testUnknownFutureMigrationRemainsWarningOnly() async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO grdb_migrations(identifier) VALUES ('future_capture_schema')"
            )
        }
        let path = root.appendingPathComponent("eye.sqlite").path
        ingest = nil
        try database.pool.close()
        database = nil
        XCTAssertNoThrow(database = try ZBSEyeDatabase(path: path))
    }
}
