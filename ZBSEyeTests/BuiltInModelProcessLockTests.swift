import Foundation
import XCTest

final class BuiltInModelProcessLockTests: XCTestCase {
    func testSecondOwnerFailsClosedUntilFirstOwnerReleasesLock() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "zbseye-model-lock-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var first: BuiltInModelProcessLock? = try BuiltInModelProcessLock(modelRoot: root)
        try withExtendedLifetime(first) {
            XCTAssertThrowsError(try BuiltInModelProcessLock(modelRoot: root)) { error in
                XCTAssertEqual(error as? BuiltInModelProcessLockError, .alreadyOwned)
            }
        }

        first = nil
        XCTAssertNoThrow(try BuiltInModelProcessLock(modelRoot: root))
    }
}
