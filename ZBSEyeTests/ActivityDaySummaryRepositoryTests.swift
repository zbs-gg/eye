import Foundation
import GRDB
import XCTest

final class ActivityDaySummaryRepositoryTests: XCTestCase {
    func testV16MigrationIsAdditiveAndCreatesOneRowPerDayTable() async throws {
        let harness = try DatabaseHarness(runMigrations: false)
        defer { harness.remove() }
        try ZBSEyeDatabase.migrator.migrate(harness.database.pool, upTo: "v15_capture_coverage")
        try await harness.database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO screen_captures(ts, monitorId) VALUES (123, 'main')"
            )
        }

        try ZBSEyeDatabase.migrator.migrate(harness.database.pool)

        let proof = try await harness.database.pool.read { db in
            (
                captures: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM screen_captures") ?? -1,
                tableSQL: try String.fetchOne(
                    db,
                    sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'activity_day_summaries'"
                ),
                stateEpoch: try Int64.fetchOne(
                    db,
                    sql: "SELECT invalidationEpoch FROM activity_day_summary_state WHERE singleton = 1"
                ),
                lastMigration: try String.fetchOne(
                    db,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"
                ),
                integrity: try String.fetchOne(db, sql: "PRAGMA integrity_check")
            )
        }
        XCTAssertEqual(proof.captures, 1)
        XCTAssertTrue(proof.tableSQL?.contains("recipientDisclosure") == true)
        XCTAssertTrue(proof.tableSQL?.contains("endpointDisclosure") == true)
        XCTAssertTrue(proof.tableSQL?.contains("endpointIdentity") == true)
        XCTAssertEqual(proof.stateEpoch, 0)
        XCTAssertEqual(proof.lastMigration, "v16_activity_day_summary")
        XCTAssertEqual(proof.integrity, "ok")
    }

    func testConditionalReplaceSucceedsWithoutInvalidationAndKeepsExactlyOneEntryPerDay() async throws {
        let harness = try DatabaseHarness()
        defer { harness.remove() }
        let repository = ActivityDaySummaryRepository(database: harness.database)
        let first = entry(
            dayKey: "2026-08-08",
            fingerprint: "sha256:first",
            summary: "- Built the cache.",
            modelID: "first-model",
            generatedAtMs: 100,
            executedLocally: false,
            brokerUpstream: nil,
            recipientDisclosure: "Custom API at https://summary-a.example",
            endpointDisclosure: "https://summary-a.example",
            endpointIdentity: "sha256:endpoint-a",
            sourceCount: 4
        )
        let replacement = entry(
            dayKey: "2026-08-08",
            fingerprint: "sha256:replacement",
            summary: "- Verified the replacement.",
            modelID: "cheap-model",
            generatedAtMs: 200,
            executedLocally: false,
            brokerUpstream: "openrouter",
            recipientDisclosure: "Custom API at https://summary-b.example:8443",
            endpointDisclosure: "https://summary-b.example:8443",
            endpointIdentity: "sha256:endpoint-b",
            sourceCount: 9
        )

        let initialSnapshot = try await repository.snapshot(dayKey: first.dayKey)
        let firstAccepted = try await repository.replace(
            first,
            expectedInvalidationEpoch: initialSnapshot.invalidationEpoch
        )
        let replacementSnapshot = try await repository.snapshot(dayKey: replacement.dayKey)
        let replacementAccepted = try await repository.replace(
            replacement,
            expectedInvalidationEpoch: replacementSnapshot.invalidationEpoch
        )

        XCTAssertTrue(firstAccepted)
        XCTAssertTrue(replacementAccepted)
        let fetched = try await repository.snapshot(dayKey: "2026-08-08")
        XCTAssertEqual(fetched.entry, replacement)
        XCTAssertEqual(fetched.invalidationEpoch, initialSnapshot.invalidationEpoch)
        let count = try await harness.database.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM activity_day_summaries") ?? -1
        }
        XCTAssertEqual(count, 1)
    }

    func testHalfOpenOverlapInvalidationKeepsAdjacentDays() async throws {
        let harness = try DatabaseHarness()
        defer { harness.remove() }
        let repository = ActivityDaySummaryRepository(database: harness.database)
        try await insert(entry(dayKey: "2026-08-07", sourceStartMs: 0, sourceEndMs: 100), into: repository)
        try await insert(entry(dayKey: "2026-08-08", sourceStartMs: 100, sourceEndMs: 200), into: repository)
        try await insert(entry(dayKey: "2026-08-09", sourceStartMs: 200, sourceEndMs: 300), into: repository)

        try await repository.deleteOverlapping(fromMs: 100, toMs: 200)

        let prior = try await repository.snapshot(dayKey: "2026-08-07")
        let deleted = try await repository.snapshot(dayKey: "2026-08-08")
        let next = try await repository.snapshot(dayKey: "2026-08-09")
        XCTAssertNotNil(prior.entry)
        XCTAssertNil(deleted.entry)
        XCTAssertNotNil(next.entry)
        XCTAssertEqual(prior.invalidationEpoch, 1)
        try await repository.deleteAll()
        let priorAfterDeleteAll = try await repository.snapshot(dayKey: "2026-08-07")
        let nextAfterDeleteAll = try await repository.snapshot(dayKey: "2026-08-09")
        XCTAssertNil(priorAfterDeleteAll.entry)
        XCTAssertNil(nextAfterDeleteAll.entry)
        XCTAssertEqual(priorAfterDeleteAll.invalidationEpoch, 2)
    }

    func testInvalidationBetweenSnapshotAndReplaceRejectsLateWrite() async throws {
        let harness = try DatabaseHarness()
        defer { harness.remove() }
        let repository = ActivityDaySummaryRepository(database: harness.database)
        let pending = entry(
            dayKey: "2026-08-08",
            summary: "- This response became stale.",
            sourceStartMs: 100,
            sourceEndMs: 200
        )
        let preparedSnapshot = try await repository.snapshot(dayKey: pending.dayKey)

        try await repository.deleteOverlapping(fromMs: 150, toMs: 151)
        let accepted = try await repository.replace(
            pending,
            expectedInvalidationEpoch: preparedSnapshot.invalidationEpoch
        )

        XCTAssertFalse(accepted)
        let afterRace = try await repository.snapshot(dayKey: pending.dayKey)
        XCTAssertNil(afterRace.entry)
        XCTAssertEqual(afterRace.invalidationEpoch, preparedSnapshot.invalidationEpoch + 1)
    }

    func testEpochOverflowFailsClosedWithoutDeletingCachedText() async throws {
        let harness = try DatabaseHarness()
        defer { harness.remove() }
        let repository = ActivityDaySummaryRepository(database: harness.database)
        let cached = entry(dayKey: "2026-08-08")
        try await insert(cached, into: repository)
        try await harness.database.pool.write { db in
            try db.execute(
                sql: "UPDATE activity_day_summary_state SET invalidationEpoch = ? WHERE singleton = 1",
                arguments: [Int64.max]
            )
        }

        do {
            try await repository.deleteAll()
            XCTFail("Expected epoch exhaustion to reject invalidation")
        } catch {
            XCTAssertTrue(error is DatabaseError)
        }

        let afterFailure = try await repository.snapshot(dayKey: cached.dayKey)
        XCTAssertEqual(afterFailure.invalidationEpoch, Int64.max)
        XCTAssertEqual(afterFailure.entry, cached)
    }

    func testDayKeyUsesTheExplicitCalendarTimezone() {
        let epoch = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            ActivityDaySummaryDayKey.make(
                for: epoch,
                timeZone: TimeZone(secondsFromGMT: 0)!
            ),
            "1970-01-01"
        )
        XCTAssertEqual(
            ActivityDaySummaryDayKey.make(
                for: epoch,
                timeZone: TimeZone(identifier: "Pacific/Honolulu")!
            ),
            "1969-12-31"
        )
    }

    private func entry(
        dayKey: String,
        fingerprint: String = "sha256:fixture",
        summary: String = "- Worked on ZBS Eye.",
        modelID: String = "fixture-model",
        generatedAtMs: Int64 = 100,
        executedLocally: Bool = true,
        brokerUpstream: String? = nil,
        recipientDisclosure: String? = nil,
        endpointDisclosure: String? = nil,
        endpointIdentity: String? = nil,
        sourceStartMs: Int64 = 100,
        sourceEndMs: Int64 = 200,
        sourceCount: Int = 1
    ) -> ActivityDaySummaryCacheEntry {
        ActivityDaySummaryCacheEntry(
            dayKey: dayKey,
            inputFingerprint: fingerprint,
            summary: summary,
            providerID: "fixture-provider",
            modelID: modelID,
            executedLocally: executedLocally,
            brokerUpstream: brokerUpstream,
            recipientDisclosure: recipientDisclosure,
            endpointDisclosure: endpointDisclosure,
            endpointIdentity: endpointIdentity,
            promptVersion: "activity-day-summary-v1",
            generatedAtMs: generatedAtMs,
            sourceStartMs: sourceStartMs,
            sourceEndMs: sourceEndMs,
            sourceCount: sourceCount
        )
    }

    private func insert(
        _ entry: ActivityDaySummaryCacheEntry,
        into repository: ActivityDaySummaryRepository
    ) async throws {
        let snapshot = try await repository.snapshot(dayKey: entry.dayKey)
        let accepted = try await repository.replace(
            entry,
            expectedInvalidationEpoch: snapshot.invalidationEpoch
        )
        XCTAssertTrue(accepted)
    }
}

private final class DatabaseHarness {
    let root: URL
    let database: ZBSEyeDatabase

    init(runMigrations: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ZBSEyeActivityDaySummaryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(
            path: root.appendingPathComponent("eye.sqlite").path,
            runMigrations: runMigrations
        )
    }

    func remove() {
        try? database.pool.close()
        try? FileManager.default.removeItem(at: root)
    }
}
