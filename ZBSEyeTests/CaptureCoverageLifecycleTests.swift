import Foundation
import GRDB
import XCTest

final class CaptureCoverageLifecycleTests: XCTestCase {
    func testRangeDeletionSplitsIntervalsOnExactHalfOpenBoundaries() async throws {
        let harness = try CoverageLifecycleHarness()
        defer { harness.remove() }
        try await harness.insertCoverage(
            episodeID: "span",
            leg: .screen,
            startMs: 0,
            endMs: 100,
            closeCause: .verifiedProgress
        )
        try await harness.insertCoverage(
            episodeID: "inside",
            leg: .systemAudio,
            startMs: 20,
            endMs: 80,
            closeCause: .verifiedProgress
        )
        try await harness.insertCoverage(
            episodeID: "left-boundary",
            leg: .screen,
            startMs: 10,
            endMs: 20,
            closeCause: .verifiedProgress
        )
        try await harness.insertCoverage(
            episodeID: "right-boundary",
            leg: .systemAudio,
            startMs: 80,
            endMs: 90,
            closeCause: .verifiedProgress
        )

        try await harness.db.pool.write {
            try CaptureCoverageMaintenance.subtractDeletedRange(
                in: $0,
                fromMs: 20,
                toMs: 80
            )
        }

        let rows = try await harness.coverageRows()
        XCTAssertNil(rows.first { $0.episodeID == "inside" })
        XCTAssertEqual(
            rows.first { $0.episodeID == "span" },
            .init(
                episodeID: "span",
                startMs: 80,
                endMs: 100,
                closeCause: .verifiedProgress
            )
        )
        XCTAssertEqual(
            rows.first { $0.episodeID.hasPrefix("span#before-") },
            .init(
                episodeID: "span#before-20-80",
                startMs: 0,
                endMs: 20,
                closeCause: .historyDeleted
            )
        )
        XCTAssertNotNil(rows.first { $0.episodeID == "left-boundary" })
        XCTAssertNotNil(rows.first { $0.episodeID == "right-boundary" })
    }

    func testOpenIntervalKeepsItsIdentityAfterSplitAndCanStillClose() async throws {
        let harness = try CoverageLifecycleHarness()
        defer { harness.remove() }
        try await harness.insertCoverage(
            episodeID: "live-open",
            leg: .screen,
            startMs: 0,
            endMs: nil,
            closeCause: nil
        )
        try await harness.db.pool.write {
            try CaptureCoverageMaintenance.subtractDeletedRange(
                in: $0,
                fromMs: 20,
                toMs: 80
            )
        }

        let ingest = IngestService(db: harness.db, storage: harness.storage)
        let closed = try await ingest.closeCaptureCoverage(.init(
            leg: .screen,
            episodeID: "live-open",
            generation: 1,
            endMs: 120,
            cause: .verifiedProgress
        ))
        XCTAssertTrue(closed)

        let rows = try await harness.coverageRows()
        XCTAssertEqual(
            rows.first { $0.episodeID == "live-open" },
            .init(
                episodeID: "live-open",
                startMs: 80,
                endMs: 120,
                closeCause: .verifiedProgress
            )
        )
        XCTAssertEqual(rows.count, 2)
    }

    func testPrivacyDeletionRemovesHistoryAndSubtractsCoverageAfterCompletion() async throws {
        let harness = try CoverageLifecycleHarness()
        defer { harness.remove() }
        try harness.writeSparseFile("frame.heic", bytes: 3)
        try harness.writeSparseFile("audio.m4a", bytes: 5)
        try await harness.insertScreen(ts: 10, path: "frame.heic", bytes: 3)
        try await harness.insertAudio(ts: 30, path: "audio.m4a", bytes: 5)
        try await harness.insertCoverage(
            episodeID: "gap",
            leg: .screen,
            startMs: 0,
            endMs: 100,
            closeCause: .verifiedProgress
        )
        let retention = RetentionManager(db: harness.db, storage: harness.storage)

        let report = try await retention.deleteRange(fromMs: 20, toMs: 40)

        XCTAssertEqual(report.framesDeleted, 0)
        XCTAssertEqual(report.audioDeleted, 1)
        XCTAssertTrue(harness.fileExists("frame.heic"))
        XCTAssertFalse(harness.fileExists("audio.m4a"))
        let counts = try await harness.captureCounts()
        XCTAssertEqual(counts.screen, 1)
        XCTAssertEqual(counts.audio, 0)
        let coverage = try await harness.coverageRows()
        XCTAssertEqual(coverage.map(\.startMs).sorted(), [0, 41])
        XCTAssertEqual(coverage.map(\.endMs), [20, 100])

        _ = try await retention.deleteRange(fromMs: 0, toMs: Int64.max)
        let afterFullDeletion = try await harness.coverageRows()
        XCTAssertTrue(afterFullDeletion.isEmpty)
    }

    func testAutomaticRetentionKeepsCoverageMetadata() async throws {
        let harness = try CoverageLifecycleHarness()
        defer { harness.remove() }
        let sixGB = 6 * KeepMediaPolicy.bytesPerGB
        try harness.writeSparseFile("old.heic", bytes: sixGB)
        try await harness.insertScreen(ts: 1, path: "old.heic", bytes: sixGB)
        try await harness.insertCoverage(
            episodeID: "historical-gap",
            leg: .screen,
            startMs: 0,
            endMs: 2,
            closeCause: .verifiedProgress
        )
        let admission = AutomaticRetentionAdmission(record: .init(
            revision: 1,
            policy: .fiveGB,
            phase: .finiteAdmitted,
            source: .explicitSelection
        ))
        let permit = try XCTUnwrap(admission.currentPermit())
        let retention = RetentionManager(db: harness.db, storage: harness.storage)

        _ = try await retention.pruneAutomatically(permit: permit, admission: admission)

        let retainedCoverage = try await harness.coverageRows()
        XCTAssertEqual(retainedCoverage.map(\.episodeID), ["historical-gap"])
    }

    func testOnlineBackupPreservesExactOpenAndClosedCoverageRows() async throws {
        let harness = try CoverageLifecycleHarness()
        defer { harness.remove() }
        try await harness.insertCoverage(
            episodeID: "closed",
            leg: .screen,
            startMs: 1,
            endMs: 2,
            closeCause: .verifiedProgress
        )
        try await harness.insertCoverage(
            episodeID: "open",
            leg: .systemAudio,
            startMs: 3,
            endMs: nil,
            closeCause: nil
        )
        let destinationURL = harness.root.appendingPathComponent("backup.sqlite")
        let destination = try DatabaseQueue(path: destinationURL.path)
        defer { try? destination.close() }

        try harness.db.pool.backup(to: destination)

        let source = try await harness.coverageRows()
        let copied = try await destination.read { database in
            try CoverageLifecycleHarness.coverageRows(in: database)
        }
        XCTAssertEqual(copied, source)
        let checks = try await destination.read { database in
            (
                try String.fetchOne(database, sql: "PRAGMA integrity_check"),
                try Int.fetchOne(database, sql: "PRAGMA foreign_key_check")
            )
        }
        XCTAssertEqual(checks.0, "ok")
        XCTAssertNil(checks.1)
    }
}

private struct CoverageLifecycleRow: Sendable, Equatable {
    let episodeID: String
    let startMs: Int64
    let endMs: Int64?
    let closeCause: CaptureCoverageCloseCause?
}

private final class CoverageLifecycleHarness: @unchecked Sendable {
    let root: URL
    let db: ZBSEyeDatabase
    let storage: StorageManager

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ZBSEyeCaptureCoverageLifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storage = try StorageManager(
            mediaDirectory: root.appendingPathComponent("media", isDirectory: true)
        )
        db = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
    }

    func remove() {
        try? db.pool.close()
        try? FileManager.default.removeItem(at: root)
    }

    func insertCoverage(
        episodeID: String,
        leg: CaptureLeg,
        startMs: Int64,
        endMs: Int64?,
        closeCause: CaptureCoverageCloseCause?
    ) async throws {
        try await db.pool.write { database in
            try database.execute(
                sql: """
                    INSERT INTO capture_coverage_intervals(
                        leg, reason, episode_id, generation,
                        start_ms, end_ms, close_cause
                    ) VALUES (?, ?, ?, 1, ?, ?, ?)
                    """,
                arguments: [
                    leg.rawValue,
                    CaptureHealthReason.screenRequestFailed.rawValue,
                    episodeID,
                    startMs,
                    endMs,
                    closeCause?.rawValue,
                ]
            )
        }
    }

    func coverageRows() async throws -> [CoverageLifecycleRow] {
        try await db.pool.read { try Self.coverageRows(in: $0) }
    }

    static func coverageRows(in database: Database) throws -> [CoverageLifecycleRow] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT episode_id, start_ms, end_ms, close_cause
                FROM capture_coverage_intervals
                ORDER BY start_ms, id
                """
        ).map { row in
            let cause: String? = row["close_cause"]
            return CoverageLifecycleRow(
                episodeID: row["episode_id"],
                startMs: row["start_ms"],
                endMs: row["end_ms"],
                closeCause: cause.flatMap(CaptureCoverageCloseCause.init(rawValue:))
            )
        }
    }

    func insertScreen(ts: Int64, path: String, bytes: Int64) async throws {
        try await db.pool.write { database in
            try database.execute(
                sql: """
                    INSERT INTO screen_captures(ts, monitorId, relativePath, bytes)
                    VALUES (?, 'test', ?, ?)
                    """,
                arguments: [ts, path, bytes]
            )
        }
    }

    func insertAudio(ts: Int64, path: String, bytes: Int64) async throws {
        try await db.pool.write { database in
            try database.execute(
                sql: """
                    INSERT INTO audio_captures(ts, relativePath, durationSec, channel, bytes)
                    VALUES (?, ?, 1, 'system', ?)
                    """,
                arguments: [ts, path, bytes]
            )
        }
    }

    func captureCounts() async throws -> (screen: Int, audio: Int) {
        try await db.pool.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM screen_captures") ?? -1,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM audio_captures") ?? -1
            )
        }
    }

    func writeSparseFile(_ name: String, bytes: Int64) throws {
        let url = storage.mediaDirectory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
    }

    func fileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: storage.mediaDirectory.appendingPathComponent(name).path
        )
    }
}
