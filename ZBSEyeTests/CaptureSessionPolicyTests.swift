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

    func testAuthoritativeUnlockRecoversFromAMissedUnlockNotification() {
        XCTAssertEqual(
            CaptureSessionPolicy.periodicGate(
                previous: CaptureSessionGateState(reasons: .session),
                sessionLockedNow: false
            ),
            CaptureSessionGateState(reasons: [])
        )
    }

    func testPeriodicReconciliationPreservesAnUnrelatedSuspension() {
        XCTAssertEqual(
            CaptureSessionPolicy.periodicGate(
                previous: CaptureSessionGateState(reasons: .screenSaver),
                sessionLockedNow: false
            ),
            CaptureSessionGateState(reasons: .screenSaver)
        )
        XCTAssertEqual(
            CaptureSessionPolicy.periodicGate(
                previous: CaptureSessionGateState(reasons: [.session, .screenSaver]),
                sessionLockedNow: false
            ),
            CaptureSessionGateState(reasons: .screenSaver)
        )
    }

    func testResumeSignalsClearOnlyTheirOwnSuspensionReason() {
        XCTAssertEqual(
            CaptureSessionPolicy.resumeSignalGate(
                previous: CaptureSessionGateState(reasons: [.session, .screenSaver]),
                clearing: .session,
                sessionLockedNow: false
            ),
            CaptureSessionGateState(reasons: .screenSaver)
        )
        XCTAssertEqual(
            CaptureSessionPolicy.resumeSignalGate(
                previous: CaptureSessionGateState(reasons: [.session, .screenSaver]),
                clearing: .screenSaver,
                sessionLockedNow: true
            ),
            CaptureSessionGateState(reasons: .session)
        )
        XCTAssertEqual(
            CaptureSessionPolicy.resumeSignalGate(
                previous: CaptureSessionGateState(reasons: [.systemSleep, .displaySleep]),
                clearing: .systemSleep,
                sessionLockedNow: false
            ),
            CaptureSessionGateState(reasons: .displaySleep)
        )
    }

    func testLockedOrUnknownSessionReconciliationStaysFailClosed() {
        XCTAssertEqual(
            CaptureSessionPolicy.startupGate(sessionLockedNow: nil),
            CaptureSessionGateState(reasons: .session)
        )
        XCTAssertEqual(
            CaptureSessionPolicy.periodicGate(
                previous: CaptureSessionGateState(reasons: []),
                sessionLockedNow: true
            ),
            CaptureSessionGateState(reasons: .session)
        )
        XCTAssertNil(
            CaptureSessionPolicy.periodicGate(
                previous: CaptureSessionGateState(reasons: []),
                sessionLockedNow: nil
            )
        )
        XCTAssertEqual(
            CaptureSessionPolicy.resumeSignalGate(
                previous: CaptureSessionGateState(reasons: .screenSaver),
                clearing: .screenSaver,
                sessionLockedNow: nil
            ),
            CaptureSessionGateState(reasons: .session)
        )
    }

    func testInvalidationEpochRejectsWorkStartedBeforeTheBoundary() {
        var epoch = CaptureContentEpoch()
        let workStartedAt = epoch.value

        XCTAssertTrue(epoch.contains(workStartedAt))
        epoch.invalidate()
        XCTAssertFalse(epoch.contains(workStartedAt))
        XCTAssertTrue(epoch.contains(epoch.value))
    }

    func testSCKInventoryMustRepresentEveryLongLivedProtectedApplication() {
        let authAgent = ProtectedCaptureApplicationIdentity(
            bundleIdentifier: "com.apple.localauthentication.uiagent",
            applicationName: "localauthentication uiagent",
            processIdentifier: 101
        )
        let remoteService = ProtectedCaptureApplicationIdentity(
            bundleIdentifier: "com.apple.localauthenticationremoteservice",
            applicationName: "localauthenticationremoteservice",
            processIdentifier: 202
        )
        let expected = ProtectedCaptureApplicationSnapshot(
            revision: 7,
            applications: [authAgent, remoteService]
        )

        XCTAssertFalse(
            CaptureSessionPolicy.contentCoversProtectedApplications(
                expected: expected,
                represented: [authAgent]
            )
        )
        XCTAssertTrue(
            CaptureSessionPolicy.contentCoversProtectedApplications(
                expected: expected,
                represented: [
                    ProtectedCaptureApplicationIdentity(
                        bundleIdentifier: "com.apple.LocalAuthentication.UIAgent",
                        applicationName: "coreautha",
                        processIdentifier: 101
                    ),
                    ProtectedCaptureApplicationIdentity(
                        bundleIdentifier: "com.apple.LocalAuthenticationRemoteService",
                        applicationName: "LocalAuthenticationRemoteService",
                        processIdentifier: 202
                    ),
                ]
            )
        )
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
        for bundleId in [
            "com.apple.LocalAuthentication.UIAgent",
            "com.apple.LocalAuthenticationRemoteService",
            "com.apple.SecurityAgent",
            "com.apple.authorizationhost",
        ] {
            XCTAssertFalse(
                CaptureSessionPolicy.mayCapture(
                    screenLocked: false,
                    bundleId: bundleId
                ),
                bundleId
            )
        }
        XCTAssertTrue(
            CaptureSessionPolicy.mayCapture(
                screenLocked: false,
                bundleId: "com.openai.chat"
            )
        )
        XCTAssertFalse(
            CaptureSessionPolicy.mayCapture(
                screenLocked: false,
                bundleId: "com.example.noncanonical-auth-helper",
                appName: "SecurityAgent"
            )
        )
        XCTAssertFalse(
            CaptureSessionPolicy.mayCapture(
                screenLocked: false,
                bundleId: "com.example.noncanonical-auth-helper",
                appName: "coreautha"
            )
        )
    }

    func testSensitiveAuthenticationSurfacesStayFilteredFromLegacyActivity() {
        for bundleId in [
            "com.apple.LocalAuthentication.UIAgent",
            "com.apple.LocalAuthenticationRemoteService",
            "com.apple.SecurityAgent",
            "com.apple.authorizationhost",
        ] {
            XCTAssertTrue(SystemAppFilter.isSystem(bundleId: bundleId), bundleId)
        }
        for appName in [
            "SecurityAgent",
            "authorizationhost",
            "LocalAuthentication UIAgent",
            "  LocalAuthenticationRemoteService  ",
            "coreautha",
        ] {
            XCTAssertTrue(
                SystemAppFilter.isSystem(bundleId: nil, appName: appName),
                appName
            )
            XCTAssertTrue(
                SystemAppFilter.isProtectedCaptureSurface(
                    bundleId: "imported.\(appName.trimmingCharacters(in: .whitespaces))",
                    appName: appName
                ),
                appName
            )
        }
        XCTAssertFalse(
            SystemAppFilter.isProtectedCaptureSurface(
                bundleId: "com.apple.dock",
                appName: "Dock"
            )
        )
    }
}
