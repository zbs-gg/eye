import CryptoKit
import Darwin
import Foundation
import GRDB
import XCTest

final class ScreenUnderstandingDatasetPreparationTests: XCTestCase {
    func testSyntheticExportIsDeterministicPrivateAndSourcePreserving() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let sourceDBBefore = try digest(fixture.database)
        let mediaBefore = try digest(fixture.media.appendingPathComponent("one.heic"))

        let preparer = makePreparer()
        let first = try preparer.prepare(
            sourceRoot: fixture.source,
            outputRoot: fixture.base.appendingPathComponent("corpus-a"),
            repositoryRoot: repositoryRoot(),
            labeledLimit: 4,
            temporalPairLimit: 2
        )
        let second = try preparer.prepare(
            sourceRoot: fixture.source,
            outputRoot: fixture.base.appendingPathComponent("corpus-b"),
            repositoryRoot: repositoryRoot(),
            labeledLimit: 4,
            temporalPairLimit: 2
        )

        XCTAssertEqual(first.cases, second.cases)
        XCTAssertEqual(first.temporalPairs, second.temporalPairs)
        XCTAssertEqual(first.temporalPairs.count, 1)
        XCTAssertEqual(first.singleFrameCaseIDs.count, 3)
        XCTAssertEqual(first.baselineOnlyCaseIDs.count, 1)
        XCTAssertEqual(first.splits, second.splits)
        XCTAssertEqual(first.splitSHA256, second.splitSHA256)
        XCTAssertEqual(first.splitSHA256.count, 64)
        XCTAssertEqual(first.sourceImageRows, 3)
        XCTAssertEqual(first.availableImageRows, 3)
        XCTAssertEqual(first.missingMediaRows, 0)
        XCTAssertTrue(first.temporalPairs.allSatisfy { pair in
            first.cases.contains(where: { $0.id == pair.beforeCaseID })
                && first.cases.contains(where: { $0.id == pair.afterCaseID })
        })
        XCTAssertEqual(first.naturalisticTraceSHA256, second.naturalisticTraceSHA256)
        XCTAssertEqual(first.purgeAfterDecisionDays, 30)
        XCTAssertTrue(first.labelsLockedBeforeOutputs)
        XCTAssertTrue(first.cases.contains(where: { $0.baselineOnly && $0.mediaFile == nil }))
        XCTAssertEqual(try digest(fixture.database), sourceDBBefore)
        XCTAssertEqual(try digest(fixture.media.appendingPathComponent("one.heic")), mediaBefore)

        let manifestURL = fixture.base.appendingPathComponent("corpus-a/manifest.json")
        let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertFalse(manifestText.contains(fixture.source.path))
        XCTAssertFalse(manifestText.contains("relativePath"))
        XCTAssertFalse(manifestText.contains("timestampMs"))
        let permissions = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.base.appendingPathComponent("corpus-a/.metadata_never_index").path
        ))
        let sealedNames = try FileManager.default.contentsOfDirectory(
            atPath: fixture.base.appendingPathComponent("corpus-a").path
        )
        XCTAssertTrue(sealedNames.allSatisfy { !$0.hasPrefix("source.sqlite") })
    }

    func testExistingSealedCorpusIsNeverOverwritten() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let output = fixture.base.appendingPathComponent("sealed")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let sentinel = output.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)

        XCTAssertThrowsError(try makePreparer().prepare(
            sourceRoot: fixture.source,
            outputRoot: output,
            repositoryRoot: repositoryRoot(),
            labeledLimit: 1
        ))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    func testMissingMediaIsReconciledBeforeSplitWithoutCopyRetry() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        try FileManager.default.removeItem(at: fixture.media.appendingPathComponent("two.heic"))

        let manifest = try makePreparer().prepare(
            sourceRoot: fixture.source,
            outputRoot: fixture.base.appendingPathComponent("reconciled"),
            repositoryRoot: repositoryRoot(),
            labeledLimit: 4,
            temporalPairLimit: 2
        )

        XCTAssertEqual(manifest.sourceImageRows, 3)
        XCTAssertEqual(manifest.availableImageRows, 2)
        XCTAssertEqual(manifest.missingMediaRows, 1)
        XCTAssertEqual(manifest.singleFrameCaseIDs.count, 2)
        XCTAssertEqual(manifest.baselineOnlyCaseIDs.count, 2)
        XCTAssertTrue(manifest.cases.contains { $0.baselineOnly && $0.mediaFile == nil })
    }

    func testSymlinkedSelectedMediaInvalidatesWholeExport() throws {
        let fixture = try makeFixture(useSymlink: true)
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let output = fixture.base.appendingPathComponent("rejected")

        XCTAssertThrowsError(try makePreparer().prepare(
            sourceRoot: fixture.source,
            outputRoot: output,
            repositoryRoot: repositoryRoot(),
            labeledLimit: 4
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: fixture.base,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".rejected.staging-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testEqualLengthInPlaceRewriteInvalidatesExportAndCleansStaging() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let original = fixture.media.appendingPathComponent("one.heic")
        let originalData = try Data(contentsOf: original)
        let replacement = Data("rewritten".utf8)
        XCTAssertEqual(replacement.count, originalData.count)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 10)],
            ofItemAtPath: original.path
        )
        var beforeStat = stat()
        XCTAssertEqual(lstat(original.path, &beforeStat), 0)
        var didRewrite = false
        let preparer = makePreparer(beforeMediaCopy: { url in
            guard url.lastPathComponent == "one.heic", !didRewrite else { return }
            didRewrite = true
            let handle = try FileHandle(forWritingTo: url)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: replacement)
            try handle.synchronize()
            try handle.close()
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 20)],
                ofItemAtPath: url.path
            )
            var afterStat = stat()
            XCTAssertEqual(lstat(url.path, &afterStat), 0)
            XCTAssertEqual(afterStat.st_dev, beforeStat.st_dev)
            XCTAssertEqual(afterStat.st_ino, beforeStat.st_ino)
            XCTAssertEqual(afterStat.st_size, beforeStat.st_size)
        })
        let output = fixture.base.appendingPathComponent("rewrite-rejected")

        XCTAssertThrowsError(try preparer.prepare(
            sourceRoot: fixture.source,
            outputRoot: output,
            repositoryRoot: repositoryRoot(),
            labeledLimit: 4
        )) { error in
            guard case ScreenUnderstandingDatasetError.sourceChanged = error else {
                return XCTFail("Expected sourceChanged, got \(error)")
            }
        }
        XCTAssertTrue(didRewrite)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try assertNoStagingDirectory(named: "rewrite-rejected", below: fixture.base)
    }

    func testIncompleteCurrentDayIsSkippedForLatestCompletedLocalDay() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let calendar = localCalendar()
        let previousStart = try localDate(
            year: 2026, month: 7, day: 12, hour: 0, calendar: calendar
        )
        let now = try localDate(
            year: 2026, month: 7, day: 13, hour: 10, calendar: calendar
        )
        try setCaptureTimestamps([
            milliseconds(try localDate(year: 2026, month: 7, day: 12, hour: 1, calendar: calendar)),
            milliseconds(try localDate(year: 2026, month: 7, day: 12, hour: 5, calendar: calendar)),
            milliseconds(try localDate(year: 2026, month: 7, day: 12, hour: 9, calendar: calendar)),
            milliseconds(try localDate(year: 2026, month: 7, day: 13, hour: 9, calendar: calendar)),
        ], in: fixture.database)
        let output = fixture.base.appendingPathComponent("completed-local-day")

        _ = try makePreparer(
            calendar: calendar,
            now: now,
            minimumElapsedCoverageMs: 8 * 60 * 60 * 1_000,
            minimumActivityCount: 3
        ).prepare(
            sourceRoot: fixture.source,
            outputRoot: output,
            repositoryRoot: repositoryRoot(),
            labeledLimit: 4
        )

        let trace = try decodeTrace(from: output)
        XCTAssertEqual(trace.calendarIdentifier, "gregorian")
        XCTAssertEqual(trace.timeZoneIdentifier, "Asia/Ho_Chi_Minh")
        XCTAssertEqual(trace.localDayStartMs, milliseconds(previousStart))
        XCTAssertEqual(trace.entries.count, 3)
        XCTAssertEqual(trace.activityCount, 3)
        XCTAssertEqual(trace.observedElapsedMs, 8 * 60 * 60 * 1_000)
        XCTAssertEqual(trace.minimumElapsedCoverageMs, 8 * 60 * 60 * 1_000)
        XCTAssertEqual(trace.minimumActivityCount, 3)
    }

    func testNoCompletedDayMeetingCoverageFailsAndCleansStaging() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let calendar = localCalendar()
        let now = try localDate(
            year: 2026, month: 7, day: 13, hour: 10, calendar: calendar
        )
        try setCaptureTimestamps([
            milliseconds(try localDate(year: 2026, month: 7, day: 13, hour: 1, calendar: calendar)),
            milliseconds(try localDate(year: 2026, month: 7, day: 13, hour: 3, calendar: calendar)),
            milliseconds(try localDate(year: 2026, month: 7, day: 13, hour: 6, calendar: calendar)),
            milliseconds(try localDate(year: 2026, month: 7, day: 13, hour: 9, calendar: calendar)),
        ], in: fixture.database)
        let output = fixture.base.appendingPathComponent("no-completed-day")

        XCTAssertThrowsError(try makePreparer(
            calendar: calendar,
            now: now,
            minimumElapsedCoverageMs: 8 * 60 * 60 * 1_000,
            minimumActivityCount: 4
        ).prepare(
            sourceRoot: fixture.source,
            outputRoot: output,
            repositoryRoot: repositoryRoot(),
            labeledLimit: 4
        )) { error in
            guard case ScreenUnderstandingDatasetError.invalidPolicy = error else {
                return XCTFail("Expected invalidPolicy, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try assertNoStagingDirectory(named: "no-completed-day", below: fixture.base)
    }

    func testLocalDaySelectionKeepsEventsAcrossUTCBoundary() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let calendar = localCalendar()
        let selectedStart = try localDate(
            year: 2026, month: 7, day: 13, hour: 0, calendar: calendar
        )
        let now = try localDate(
            year: 2026, month: 7, day: 14, hour: 3, calendar: calendar
        )
        try setCaptureTimestamps([
            milliseconds(try localDate(
                year: 2026, month: 7, day: 13, hour: 0, minute: 30, calendar: calendar
            )),
            milliseconds(try localDate(
                year: 2026, month: 7, day: 13, hour: 12, calendar: calendar
            )),
            milliseconds(try localDate(
                year: 2026, month: 7, day: 13, hour: 23, minute: 30, calendar: calendar
            )),
            milliseconds(try localDate(
                year: 2026, month: 7, day: 14, hour: 0, minute: 30, calendar: calendar
            )),
        ], in: fixture.database)
        let output = fixture.base.appendingPathComponent("local-boundary")

        _ = try makePreparer(
            calendar: calendar,
            now: now,
            minimumElapsedCoverageMs: 23 * 60 * 60 * 1_000,
            minimumActivityCount: 3
        ).prepare(
            sourceRoot: fixture.source,
            outputRoot: output,
            repositoryRoot: repositoryRoot(),
            labeledLimit: 4
        )

        let trace = try decodeTrace(from: output)
        XCTAssertEqual(trace.localDayStartMs, milliseconds(selectedStart))
        XCTAssertEqual(trace.entries.count, 3)
        XCTAssertEqual(trace.observedElapsedMs, 23 * 60 * 60 * 1_000)
        XCTAssertEqual(trace.timeZoneIdentifier, "Asia/Ho_Chi_Minh")
    }

    func testLabelSchemaCannotContainCandidateOutput() throws {
        let schema = repositoryRoot().appendingPathComponent(
            "tools/screen-understanding-bench/schemas/labels.schema.json"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: schema)) as? [String: Any]
        )
        XCTAssertEqual(object["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        let text = String(decoding: try Data(contentsOf: schema), as: UTF8.self)
        for required in ["requiredFacts", "criticalText", "forbiddenInferences", "meaningfulChange", "ambiguity", "abstentionAllowed"] {
            XCTAssertTrue(text.contains(required), required)
        }
        for canonical in [
            "annotation",
            "frontier-vlm",
            "blindedToCandidateOutputs",
            "rubricVersion",
        ] {
            XCTAssertTrue(text.contains(canonical), canonical)
        }
        for forbidden in ["candidateOutput", "methodID", "modelName"] {
            XCTAssertNil(properties[forbidden], forbidden)
        }
    }

    private struct Fixture {
        let base: URL
        let source: URL
        let database: URL
        let media: URL
    }

    private func makePreparer(
        calendar: Calendar? = nil,
        now: Date = Date(timeIntervalSince1970: 2 * 86_400),
        minimumElapsedCoverageMs: Int64 = 3_000,
        minimumActivityCount: Int = 4,
        beforeMediaCopy: ((URL) throws -> Void)? = nil
    ) -> ScreenUnderstandingDatasetPreparer {
        ScreenUnderstandingDatasetPreparer(
            tracePolicy: .init(
                calendar: calendar ?? utcCalendar(),
                now: now,
                minimumElapsedCoverageMs: minimumElapsedCoverageMs,
                minimumActivityCount: minimumActivityCount
            ),
            beforeMediaCopy: beforeMediaCopy
        )
    }

    private func makeFixture(useSymlink: Bool = false) throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "screen-understanding-\(UUID().uuidString)",
            isDirectory: true
        )
        let source = base.appendingPathComponent("source", isDirectory: true)
        let media = source.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let database = source.appendingPathComponent("zbseye.sqlite")
        var queue: DatabaseQueue? = try DatabaseQueue(path: database.path)
        try queue!.write { db in
            try db.execute(sql: "CREATE TABLE apps (id INTEGER PRIMARY KEY, name TEXT)")
            try db.execute(sql: """
                CREATE TABLE screen_captures (
                    id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, appId INTEGER,
                    windowTitle TEXT, browserUrl TEXT, monitorId TEXT NOT NULL,
                    relativePath TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE text_blocks (
                    id INTEGER PRIMARY KEY, captureId INTEGER NOT NULL,
                    source TEXT NOT NULL, text TEXT NOT NULL
                )
                """)
            try db.execute(sql: "INSERT INTO apps (id, name) VALUES (1, 'Editor'), (2, 'Canvas')")
            try db.execute(sql: """
                INSERT INTO screen_captures
                    (id, ts, appId, windowTitle, browserUrl, monitorId, relativePath)
                VALUES
                    (1, 1000, 1, 'Notes', NULL, 'display-a', 'one.heic'),
                    (2, 2000, 2, 'Board', NULL, 'display-a', 'two.heic'),
                    (3, 3000, 1, 'Notes', NULL, 'display-a', NULL),
                    (4, 4000, 1, 'Notes', NULL, 'display-a', 'three.heic')
                """)
            try db.execute(sql: """
                INSERT INTO text_blocks (captureId, source, text) VALUES
                    (1, 'ax', 'A short note'),
                    (1, 'ocr', 'Visible title'),
                    (3, 'ax', 'Context changed without a new pixel frame'),
                    (4, 'ocr', 'Привет mixed script')
                """)
        }
        queue = nil

        try Data("one-image".utf8).write(to: media.appendingPathComponent("one.heic"))
        try Data("two-image".utf8).write(to: media.appendingPathComponent("two.heic"))
        let third = media.appendingPathComponent("three.heic")
        if useSymlink {
            let outside = base.appendingPathComponent("outside.heic")
            try Data("outside".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: third, withDestinationURL: outside)
        } else {
            try Data("three-image".utf8).write(to: third)
        }
        return Fixture(base: base, source: source, database: database, media: media)
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func decodeTrace(from output: URL) throws -> ScreenUnderstandingNaturalisticTrace {
        try JSONDecoder().decode(
            ScreenUnderstandingNaturalisticTrace.self,
            from: Data(contentsOf: output.appendingPathComponent("naturalistic-trace.json"))
        )
    }

    private func setCaptureTimestamps(_ timestamps: [Int64], in database: URL) throws {
        XCTAssertEqual(timestamps.count, 4)
        let queue = try DatabaseQueue(path: database.path)
        try queue.write { db in
            for (index, timestamp) in timestamps.enumerated() {
                try db.execute(
                    sql: "UPDATE screen_captures SET ts = ? WHERE id = ?",
                    arguments: [timestamp, index + 1]
                )
            }
        }
    }

    private func assertNoStagingDirectory(named outputName: String, below base: URL) throws {
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".\(outputName).staging-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    private func localCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return calendar
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func localDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0,
        calendar: Calendar
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
