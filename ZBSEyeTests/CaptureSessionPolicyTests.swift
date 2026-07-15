import XCTest

final class CaptureSessionPolicyTests: XCTestCase {
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
