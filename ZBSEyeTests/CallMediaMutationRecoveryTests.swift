import Foundation
import XCTest

final class CallMediaMutationRecoveryTests: XCTestCase {
    func testScratchPreparationScavengesEveryAbandonedHelperJob() throws {
        let root = try temporaryRoot("scratch-scavenge")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CallHelperScratchStore(dataRoot: root)
        let active = UUID().uuidString.lowercased()
        let abandoned = UUID().uuidString.lowercased()
        let activeRoot = store.jobsRoot.appendingPathComponent(active, isDirectory: true)
        let abandonedRoot = store.jobsRoot.appendingPathComponent(abandoned, isDirectory: true)
        try FileManager.default.createDirectory(at: activeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: abandonedRoot, withIntermediateDirectories: true)
        try Data("active".utf8).write(to: activeRoot.appendingPathComponent("manifest.json"))
        try Data("orphan".utf8).write(to: abandonedRoot.appendingPathComponent("result.json"))

        try store.prepareForJob(active)

        XCTAssertTrue(FileManager.default.fileExists(atPath: activeRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedRoot.path))
        XCTAssertEqual(try store.inventory().jobDirectories, 1)
    }

    func testScratchGlobalLimitFailsBeforeAnotherResultCanMaterialize() throws {
        let root = try temporaryRoot("scratch-limit")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CallHelperScratchStore(dataRoot: root)
        let active = UUID().uuidString.lowercased()
        let activeRoot = store.jobsRoot.appendingPathComponent(active, isDirectory: true)
        try FileManager.default.createDirectory(at: activeRoot, withIntermediateDirectories: true)
        let result = activeRoot.appendingPathComponent("result.json")
        FileManager.default.createFile(atPath: result.path, contents: nil)
        let handle = try FileHandle(forWritingTo: result)
        try handle.truncate(atOffset: UInt64(CallHelperScratchStore.maximumGlobalBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try store.prepareForJob(active)) { error in
            XCTAssertEqual(error as? CallHelperScratchError, .globalLimitExceeded)
        }
    }

    func testScratchInventoryRejectsSymlinks() throws {
        let root = try temporaryRoot("scratch-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CallHelperScratchStore(dataRoot: root)
        let job = UUID().uuidString.lowercased()
        let jobRoot = store.jobsRoot.appendingPathComponent(job, isDirectory: true)
        try FileManager.default.createDirectory(at: jobRoot, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("outside")
        try Data("private".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: jobRoot.appendingPathComponent("result.json"),
            withDestinationURL: target
        )

        XCTAssertThrowsError(try store.inventory()) { error in
            XCTAssertEqual(error as? CallHelperScratchError, .unsafeEntry)
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("private".utf8))
    }

    private func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
