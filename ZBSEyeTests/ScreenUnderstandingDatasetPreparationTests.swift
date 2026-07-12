import CryptoKit
import Foundation
import GRDB
import XCTest

final class ScreenUnderstandingDatasetPreparationTests: XCTestCase {
    func testSyntheticExportIsDeterministicPrivateAndSourcePreserving() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let sourceDBBefore = try digest(fixture.database)
        let mediaBefore = try digest(fixture.media.appendingPathComponent("one.heic"))

        let preparer = ScreenUnderstandingDatasetPreparer()
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
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.base.appendingPathComponent("corpus-a/source.sqlite").path
        ))
    }

    func testExistingSealedCorpusIsNeverOverwritten() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let output = fixture.base.appendingPathComponent("sealed")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let sentinel = output.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)

        XCTAssertThrowsError(try ScreenUnderstandingDatasetPreparer().prepare(
            sourceRoot: fixture.source,
            outputRoot: output,
            repositoryRoot: repositoryRoot(),
            labeledLimit: 1
        ))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    func testSymlinkedSelectedMediaInvalidatesWholeExport() throws {
        let fixture = try makeFixture(useSymlink: true)
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let output = fixture.base.appendingPathComponent("rejected")

        XCTAssertThrowsError(try ScreenUnderstandingDatasetPreparer().prepare(
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

    func testLabelSchemaCannotContainCandidateOutput() throws {
        let schema = repositoryRoot().appendingPathComponent(
            "tools/screen-understanding-bench/schemas/labels.schema.json"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: schema)) as? [String: Any]
        )
        XCTAssertEqual(object["additionalProperties"] as? Bool, false)
        let text = String(decoding: try Data(contentsOf: schema), as: UTF8.self)
        for required in ["requiredFacts", "criticalText", "forbiddenInferences", "meaningfulChange", "ambiguity", "abstentionAllowed"] {
            XCTAssertTrue(text.contains(required), required)
        }
        for forbidden in ["candidateOutput", "methodID", "modelName"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    private struct Fixture {
        let base: URL
        let source: URL
        let database: URL
        let media: URL
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

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
