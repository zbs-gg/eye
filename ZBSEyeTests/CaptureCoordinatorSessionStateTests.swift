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

    func testCaptureCycleRechecksSessionAfterAwaitBeforeWriting() throws {
        let source = try coordinatorSource
        let frameReady = try XCTUnwrap(source.range(of: "guard let frame else { return }"))
        let finalGate = try XCTUnwrap(source.range(of: "guard currentSessionStillAllowsCapture() else { return }"))
        let firstWrite = try XCTUnwrap(
            source.range(of: "await write(", range: finalGate.upperBound..<source.endIndex)
        )

        XCTAssertLessThan(frameReady.lowerBound, finalGate.lowerBound)
        XCTAssertLessThan(finalGate.lowerBound, firstWrite.lowerBound)
        XCTAssertTrue(source.contains("sessionLockedNow: Self.currentSessionLocked()"))
    }
}
