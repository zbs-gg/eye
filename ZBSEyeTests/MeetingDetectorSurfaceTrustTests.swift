import XCTest

final class MeetingDetectorSurfaceTrustTests: XCTestCase {
    func testTransientUnknownRetainsTrustedSurfaceUntilPositiveRevalidation() {
        let firstFailure = CallSurfaceTrustWindow.decide(
            previouslyConfirmed: true,
            latestSurfaceMatch: nil,
            trustReadFailed: true,
            unknownSince: nil,
            now: 100,
            maximumUnknown: 12
        )
        XCTAssertEqual(
            firstFailure,
            CallSurfaceTrustDecision(surfaceConfirmed: true, unknownSince: 100)
        )

        let betweenProbes = CallSurfaceTrustWindow.decide(
            previouslyConfirmed: firstFailure.surfaceConfirmed,
            latestSurfaceMatch: nil,
            trustReadFailed: false,
            unknownSince: firstFailure.unknownSince,
            now: 106,
            maximumUnknown: 12
        )
        XCTAssertEqual(
            betweenProbes,
            CallSurfaceTrustDecision(surfaceConfirmed: true, unknownSince: 100)
        )

        XCTAssertEqual(
            CallSurfaceTrustWindow.decide(
                previouslyConfirmed: betweenProbes.surfaceConfirmed,
                latestSurfaceMatch: true,
                trustReadFailed: false,
                unknownSince: betweenProbes.unknownSince,
                now: 108,
                maximumUnknown: 12
            ),
            CallSurfaceTrustDecision(surfaceConfirmed: true, unknownSince: nil)
        )
    }

    func testPersistentUnknownExpiresTrustedSurfaceAtBound() {
        let firstFailure = CallSurfaceTrustWindow.decide(
            previouslyConfirmed: true,
            latestSurfaceMatch: nil,
            trustReadFailed: true,
            unknownSince: nil,
            now: 100,
            maximumUnknown: 12
        )

        XCTAssertEqual(
            CallSurfaceTrustWindow.decide(
                previouslyConfirmed: firstFailure.surfaceConfirmed,
                latestSurfaceMatch: nil,
                trustReadFailed: true,
                unknownSince: firstFailure.unknownSince,
                now: 111.999,
                maximumUnknown: 12
            ),
            CallSurfaceTrustDecision(surfaceConfirmed: true, unknownSince: 100)
        )
        let expired = CallSurfaceTrustWindow.decide(
            previouslyConfirmed: firstFailure.surfaceConfirmed,
            latestSurfaceMatch: nil,
            trustReadFailed: false,
            unknownSince: firstFailure.unknownSince,
            now: 112,
            maximumUnknown: 12
        )
        XCTAssertEqual(
            expired,
            CallSurfaceTrustDecision(surfaceConfirmed: false, unknownSince: nil)
        )
        XCTAssertEqual(
            CallSurfaceTrustWindow.decide(
                previouslyConfirmed: expired.surfaceConfirmed,
                latestSurfaceMatch: nil,
                trustReadFailed: false,
                unknownSince: expired.unknownSince,
                now: 120,
                maximumUnknown: 12
            ),
            CallSurfaceTrustDecision(surfaceConfirmed: false, unknownSince: nil),
            "Two-sided audio between probes must not revive expired AX trust."
        )
    }

    func testKnownObscuredContinuityClearsEarlierAXFailureWindow() {
        XCTAssertEqual(NativeCallSurfaceState.obscured.directSurfaceMatch, true)
        let failedRead = CallSurfaceTrustWindow.decide(
            previouslyConfirmed: true,
            latestSurfaceMatch: nil,
            trustReadFailed: true,
            unknownSince: nil,
            now: 100,
            maximumUnknown: 12
        )
        XCTAssertEqual(failedRead.unknownSince, 100)

        // MeetingDetector maps the exact retained native `.obscured` state to a positive match.
        let minimizedWindow = CallSurfaceTrustWindow.decide(
            previouslyConfirmed: failedRead.surfaceConfirmed,
            latestSurfaceMatch: true,
            trustReadFailed: false,
            unknownSince: failedRead.unknownSince,
            now: 104,
            maximumUnknown: 12
        )
        XCTAssertEqual(
            minimizedWindow,
            CallSurfaceTrustDecision(surfaceConfirmed: true, unknownSince: nil)
        )
    }

    func testBackgroundTabAmbiguityDoesNotStartTrustLossWindow() {
        var decision = CallSurfaceTrustDecision(surfaceConfirmed: true, unknownSince: nil)
        for now in [10_000.0, 10_012.0, 10_120.0] {
            decision = CallSurfaceTrustWindow.decide(
                previouslyConfirmed: true,
                latestSurfaceMatch: nil,
                trustReadFailed: false,
                unknownSince: decision.unknownSince,
                now: now,
                maximumUnknown: 12
            )
            XCTAssertEqual(
                decision,
                CallSurfaceTrustDecision(surfaceConfirmed: true, unknownSince: nil)
            )
        }
        XCTAssertEqual(
            decision,
            CallSurfaceTrustDecision(surfaceConfirmed: true, unknownSince: nil)
        )
    }

    func testExplicitMismatchEndsTrustImmediately() {
        XCTAssertEqual(
            CallSurfaceTrustWindow.decide(
                previouslyConfirmed: true,
                latestSurfaceMatch: false,
                trustReadFailed: false,
                unknownSince: 100,
                now: 101,
                maximumUnknown: 12
            ),
            CallSurfaceTrustDecision(surfaceConfirmed: false, unknownSince: nil)
        )
    }
}
