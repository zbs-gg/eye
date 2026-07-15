import XCTest

final class CaptureSessionPolicyTests: XCTestCase {
    func testMacOSUnlockedSessionDictionaryOmitsTheLockKey() {
        let validSession: [String: Any] = [
            CaptureSessionPolicy.macOSOnConsoleKey: true,
            CaptureSessionPolicy.macOSLoginDoneKey: true,
        ]

        XCTAssertEqual(CaptureSessionPolicy.sessionLockState(from: validSession), false)
        XCTAssertEqual(
            CaptureSessionPolicy.sessionLockState(
                from: validSession.merging(
                    [CaptureSessionPolicy.macOSLockKey: false],
                    uniquingKeysWith: { _, new in new }
                )
            ),
            false
        )
        XCTAssertEqual(
            CaptureSessionPolicy.sessionLockState(
                from: validSession.merging(
                    [CaptureSessionPolicy.macOSLockKey: true],
                    uniquingKeysWith: { _, new in new }
                )
            ),
            true
        )
    }

    func testFailedOrMalformedSessionQueryStaysFailClosed() {
        XCTAssertNil(CaptureSessionPolicy.sessionLockState(from: nil))
        XCTAssertNil(CaptureSessionPolicy.sessionLockState(from: [:]))
        XCTAssertNil(
            CaptureSessionPolicy.sessionLockState(
                from: [
                    CaptureSessionPolicy.macOSOnConsoleKey: false,
                    CaptureSessionPolicy.macOSLoginDoneKey: true,
                ]
            )
        )
        XCTAssertNil(
            CaptureSessionPolicy.sessionLockState(
                from: [
                    CaptureSessionPolicy.macOSOnConsoleKey: true,
                    CaptureSessionPolicy.macOSLoginDoneKey: true,
                    CaptureSessionPolicy.macOSLockKey: "unexpected",
                ]
            )
        )
    }

    func testScreenSaverStopDoesNotResumeWhileTheSessionIsLocked() {
        XCTAssertFalse(CaptureSessionPolicy.mayResume(screenLocked: true, sessionLockedNow: false))
        XCTAssertFalse(CaptureSessionPolicy.mayResume(screenLocked: false, sessionLockedNow: true))
        XCTAssertFalse(CaptureSessionPolicy.mayResume(screenLocked: false, sessionLockedNow: nil))
        XCTAssertTrue(CaptureSessionPolicy.mayResume(screenLocked: false, sessionLockedNow: false))
    }

    func testLockTransitionRevokesAPreviouslyEligibleRegularAppCapture() {
        XCTAssertTrue(
            CaptureSessionPolicy.mayCapture(
                screenLocked: false,
                bundleId: "com.openai.chat"
            )
        )
        XCTAssertFalse(
            CaptureSessionPolicy.mayCapture(
                screenLocked: true,
                bundleId: "com.openai.chat"
            )
        )
        XCTAssertFalse(
            CaptureSessionPolicy.mayCapture(
                screenLocked: false,
                sessionLockedNow: true,
                bundleId: "com.openai.chat"
            )
        )
        XCTAssertFalse(
            CaptureSessionPolicy.mayCapture(
                screenLocked: false,
                sessionLockedNow: nil,
                bundleId: "com.openai.chat"
            )
        )
    }

    func testLoginAndScreenSaverShellsAreNeverCapturable() {
        XCTAssertFalse(
            CaptureSessionPolicy.mayCapture(
                screenLocked: false,
                bundleId: "com.apple.loginwindow"
            )
        )
        XCTAssertFalse(
            CaptureSessionPolicy.mayCapture(
                screenLocked: false,
                bundleId: "com.apple.screensaver.engine"
            )
        )
        XCTAssertTrue(
            CaptureSessionPolicy.mayCapture(
                screenLocked: false,
                bundleId: "com.openai.chat"
            )
        )
    }
}
