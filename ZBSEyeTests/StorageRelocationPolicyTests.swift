import Foundation
import XCTest

final class StorageRelocationPolicyTests: XCTestCase {
    func testDataRootProcessLockRefusesSecondOwner() throws {
        let root = try makeTemporaryDirectory(prefix: "zbseye-data-root-lock-owned")
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try StorageRelocationProcessLock(dataRoot: root)
        try withExtendedLifetime(first) {
            XCTAssertThrowsError(
                try StorageRelocationProcessLock(dataRoot: root)
            ) { error in
                XCTAssertEqual(
                    error as? StorageRelocationProcessLockError,
                    .alreadyOwned
                )
            }
        }
    }

    func testDataRootProcessLockReleaseAllowsRetry() throws {
        let root = try makeTemporaryDirectory(prefix: "zbseye-data-root-lock-release")
        defer { try? FileManager.default.removeItem(at: root) }

        var first: StorageRelocationProcessLock? = try StorageRelocationProcessLock(
            dataRoot: root
        )
        XCTAssertNotNil(first)
        first = nil

        XCTAssertNoThrow(try StorageRelocationProcessLock(dataRoot: root))
    }

    func testDataRootProcessLockRejectsUnsafeSymlink() throws {
        let root = try makeTemporaryDirectory(prefix: "zbseye-data-root-lock-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target", isDirectory: false)
        let lockURL = root.appendingPathComponent(
            StorageRelocationProcessLock.lockFileName,
            isDirectory: false
        )
        try Data("sentinel".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: lockURL,
            withDestinationURL: target
        )

        XCTAssertThrowsError(
            try StorageRelocationProcessLock(dataRoot: root)
        ) { error in
            XCTAssertEqual(
                error as? StorageRelocationProcessLockError,
                .unsafeLockFile
            )
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("sentinel".utf8))
    }

    func testExistingDestinationEnumerationFailureFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-relocation-unreadable-\(UUID().uuidString)")
        let current = root
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent("ZBS Eye", isDirectory: true)
        let chosen = root.appendingPathComponent("chosen", isDirectory: true)
        let destination = chosen.appendingPathComponent("ZBS Eye", isDirectory: true)
        let sentinel = destination.appendingPathComponent("existing.sqlite")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileManager = EnumerationFailingFileManager(failingPath: destination.path)
        XCTAssertThrowsError(
            try StorageRelocationPolicy.destinationRoot(
                currentRoot: current,
                chosenParent: chosen,
                fileManager: fileManager
            )
        ) { error in
            guard case RelocationError.verifyFailed(let message) = error else {
                return XCTFail("expected verifyFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("inspect"))
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("existing".utf8))
    }

    func testOccupiedDestinationIsRestoredWhenRelocationFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-relocation-rollback-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("ZBS Eye", isDirectory: true)
        let replacement = root.appendingPathComponent("ZBS Eye.replaced-test", isDirectory: true)
        let original = destination.appendingPathComponent("existing.sqlite")
        let partial = destination.appendingPathComponent("partial.sqlite")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: original)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try StorageRelocationDestinationTransaction.run(
                destinationRoot: destination,
                replacementRoot: replacement
            ) {
                XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
                XCTAssertEqual(
                    try Data(contentsOf: replacement.appendingPathComponent("existing.sqlite")),
                    Data("original".utf8)
                )
                try Data("partial".utf8).write(to: partial)
                throw ExpectedRelocationFailure.copyFailed
            }
        ) { error in
            XCTAssertEqual(error as? ExpectedRelocationFailure, .copyFailed)
        }

        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacement.path))
    }

    func testDestinationValidationRejectsSymlinkAliasOfCurrentRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-relocation-path-\(UUID().uuidString)")
        let parent = root.appendingPathComponent("real", isDirectory: true)
        let current = parent.appendingPathComponent("ZBS Eye", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try StorageRelocationPolicy.destinationRoot(
                currentRoot: current,
                chosenParent: alias
            )
        ) { error in
            guard case RelocationError.sameLocation = error else {
                return XCTFail("expected sameLocation, got \(error)")
            }
        }
    }

    func testDestinationValidationRejectsDescendantOfCurrentRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-relocation-descendant-\(UUID().uuidString)")
        let current = root.appendingPathComponent("ZBS Eye", isDirectory: true)
        let chosen = current.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try StorageRelocationPolicy.destinationRoot(
                currentRoot: current,
                chosenParent: chosen
            )
        ) { error in
            guard case RelocationError.sameLocation = error else {
                return XCTFail("expected sameLocation, got \(error)")
            }
        }
    }

    func testRequiredFreeSpacePreservesCaptureReserveAndSafetyMargin() throws {
        let payload: Int64 = 3_000_000_000
        let required = try StorageRelocationPolicy.requiredFreeBytes(
            databaseBytes: 100_000_000,
            mediaBytes: 200_000_000,
            modelBytes: 2_700_000_000
        )
        XCTAssertEqual(
            required,
            payload + (2 * 1024 * 1024 * 1024) + (512 * 1024 * 1024)
        )
        XCTAssertNoThrow(
            try StorageRelocationPolicy.requireCapacity(
                requiredBytes: required,
                availableBytes: required
            )
        )
    }

    func testUnknownOrInsufficientCapacityFailsClosed() throws {
        XCTAssertThrowsError(
            try StorageRelocationPolicy.requireCapacity(
                requiredBytes: 10,
                availableBytes: nil
            )
        ) { error in
            guard case RelocationError.capacityUnavailable = error else {
                return XCTFail("expected capacityUnavailable, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try StorageRelocationPolicy.requireCapacity(
                requiredBytes: 10,
                availableBytes: 9
            )
        ) { error in
            guard case RelocationError.insufficientSpace(needed: 10, free: 9) = error else {
                return XCTFail("expected insufficientSpace, got \(error)")
            }
        }
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private enum ExpectedRelocationFailure: Error, Equatable {
    case copyFailed
}

private final class EnumerationFailingFileManager: FileManager, @unchecked Sendable {
    private let failingPath: String

    init(failingPath: String) {
        self.failingPath = URL(fileURLWithPath: failingPath).standardizedFileURL.path
        super.init()
    }

    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        if URL(fileURLWithPath: path).standardizedFileURL.path == failingPath {
            throw CocoaError(.fileReadNoPermission)
        }
        return try super.contentsOfDirectory(atPath: path)
    }
}
