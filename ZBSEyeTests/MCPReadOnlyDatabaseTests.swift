import GRDB
import XCTest

final class MCPReadOnlyDatabaseTests: XCTestCase {
    func testReadOnlyAccessReadsExistingDatabaseButRejectsWrites() async throws {
        let fixture = try ScratchDatabaseFixture()
        defer { fixture.remove() }

        let writer = try ZBSEyeDatabase(path: fixture.databaseURL.path)
        try await writer.pool.write { db in
            try db.execute(
                sql: "INSERT INTO apps (bundleId, name) VALUES (?, ?)",
                arguments: ["com.example.fixture", "Fixture"]
            )
        }

        let reader = try ZBSEyeDatabase(
            path: fixture.databaseURL.path,
            runMigrations: false,
            access: .readOnly
        )
        let count = try await reader.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM apps")
        }
        XCTAssertEqual(count, 1)

        do {
            try await reader.pool.writeWithoutTransaction { db in
                try db.execute(
                    sql: "INSERT INTO apps (bundleId, name) VALUES ('forbidden', 'Forbidden')"
                )
            }
            XCTFail("a read-only helper must never be able to write")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testReadOnlyAccessDoesNotCreateMissingDatabase() throws {
        let fixture = try ScratchDatabaseFixture()
        defer { fixture.remove() }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
        XCTAssertThrowsError(
            try ZBSEyeDatabase(
                path: fixture.databaseURL.path,
                runMigrations: false,
                access: .readOnly
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
    }

    func testReadOnlyAccessRejectsMigrations() throws {
        let fixture = try ScratchDatabaseFixture()
        defer { fixture.remove() }
        _ = FileManager.default.createFile(
            atPath: fixture.databaseURL.path,
            contents: Data()
        )

        XCTAssertThrowsError(
            try ZBSEyeDatabase(
                path: fixture.databaseURL.path,
                runMigrations: true,
                access: .readOnly
            )
        ) { error in
            XCTAssertEqual(
                error as? ZBSEyeDatabase.OpenError,
                .readOnlyMigrationsForbidden
            )
        }
    }
}

private struct ScratchDatabaseFixture {
    let directory: URL
    let databaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-mcp-readonly-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directory.appendingPathComponent("fixture.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
