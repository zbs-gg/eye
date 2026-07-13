import Foundation
import XCTest

final class CaptureCoordinatorSessionStateTests: XCTestCase {
    private var coordinatorSource: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(
                contentsOf: root.appending(path: "ZBSEyeApp/Capture/CaptureCoordinator.swift"),
                encoding: .utf8
            )
        }
    }

    func testStartSuspendsCaptureWhenTheSessionWasAlreadyLocked() throws {
        let source = try coordinatorSource

        XCTAssertTrue(source.contains("CGSessionCopyCurrentDictionary"))
        XCTAssertTrue(source.contains("screenLocked = sessionWasAlreadyLocked"))
        XCTAssertTrue(source.contains("suspended = sessionWasAlreadyLocked"))
        XCTAssertTrue(source.contains("if !sessionWasAlreadyLocked { trigger() }"))
    }
}
