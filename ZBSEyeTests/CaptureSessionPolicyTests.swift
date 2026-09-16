import XCTest
import CoreGraphics

final class CaptureSessionPolicyTests: XCTestCase {
    func testDormantAuthenticationHelperNeedsPositiveAllWindowEvidence() {
        let helper = ProtectedCaptureApplicationIdentity(
            bundleIdentifier: "com.apple.localauthentication.uiagent",
            applicationName: "coreautha", processIdentifier: 101
        )
        let unknown = ProtectedCaptureApplicationSnapshot(revision: 1, applications: [helper])
        XCTAssertFalse(CaptureSessionPolicy.contentCoversProtectedApplications(expected: unknown, represented: []))
        let dormant = ProtectedCaptureApplicationSnapshot(revision: 1, applications: [helper], windows: [])
        XCTAssertTrue(CaptureSessionPolicy.contentCoversProtectedApplications(expected: dormant, represented: []))
        let windowed = ProtectedCaptureApplicationSnapshot(
            revision: 1, applications: [helper],
            windows: [.init(processIdentifier: 101, windowIdentifier: 200)]
        )
        XCTAssertFalse(CaptureSessionPolicy.contentCoversProtectedApplications(expected: windowed, represented: []))
        XCTAssertTrue(CaptureSessionPolicy.contentCoversProtectedApplications(expected: windowed, represented: [helper]))
        // Existing pre/post-await equality guards must reject a window created
        // by the same long-lived process, without any app lifecycle change.
        XCTAssertNotEqual(dormant, windowed)
        XCTAssertNotEqual(windowed, ProtectedCaptureApplicationSnapshot(
            revision: 1, applications: [helper],
            windows: [.init(processIdentifier: 101, windowIdentifier: 201)]
        ))
        // An explicit user exclusion always requires the exact SCK process.
        XCTAssertFalse(CaptureSessionPolicy.contentCoversUserIgnoredApplications(
            expected: [.init(processIdentifier: 101, bundleIdentifier: "com.apple.localauthentication.uiagent")],
            represented: []
        ))
    }

    func testWindowlessExemptionDoesNotApplyToOtherProtectedProcesses() {
        for bundle in ["com.apple.loginwindow", "com.apple.securityagent", "com.apple.screensaver.engine"] {
            let snapshot = ProtectedCaptureApplicationSnapshot(
                revision: 1,
                applications: [.init(bundleIdentifier: bundle, applicationName: nil, processIdentifier: 101)],
                windows: []
            )
            XCTAssertFalse(CaptureSessionPolicy.contentCoversProtectedApplications(expected: snapshot, represented: []))
        }
    }

    func testIndependentWindowInventoryIncludesOffscreenAndFailsClosed() {
        let owner = kCGWindowOwnerPID as String
        let number = kCGWindowNumber as String
        let rows: [[String: Any]] = [
            [owner: 101, number: 200, kCGWindowIsOnscreen as String: false],
            [owner: 42, number: 201]
        ]
        XCTAssertEqual(CaptureSessionPolicy.protectedWindowInventory(rows: rows, protectedPIDs: [101]),
                       [.init(processIdentifier: 101, windowIdentifier: 200)])
        XCTAssertEqual(CaptureSessionPolicy.protectedWindowInventory(rows: rows, protectedPIDs: [102]), [])
        XCTAssertNil(CaptureSessionPolicy.protectedWindowInventory(rows: nil, protectedPIDs: [101]))
        XCTAssertNil(CaptureSessionPolicy.protectedWindowInventory(rows: [], protectedPIDs: [101]))
        XCTAssertNil(CaptureSessionPolicy.protectedWindowInventory(rows: [[owner: 101]], protectedPIDs: [101]))
        XCTAssertNil(CaptureSessionPolicy.protectedWindowInventory(rows: [[number: 200]], protectedPIDs: [101]))
    }

    func testInclusionKeepsRecordingWhenSCKOmitsAProtectedBackgroundProcess() {
        let omittedAuth = ProtectedCaptureApplicationIdentity(
            bundleIdentifier: "com.apple.localauthentication.uiagent",
            applicationName: "coreautha", processIdentifier: 101
        )
        let snapshot = ProtectedCaptureApplicationSnapshot(revision: 1, applications: [omittedAuth])
        let editor = ScreenCaptureFilterApplication(
            processIdentifier: 42, bundleIdentifier: "com.example.editor", applicationName: "Editor"
        )
        XCTAssertFalse(CaptureSessionPolicy.contentCoversProtectedApplications(expected: snapshot, represented: []))
        XCTAssertTrue(CaptureSessionPolicy.mayIncludeApplication(
            editor, excludedBundleIDs: [], protectedSnapshot: snapshot, ignoredSnapshot: []
        ))
        // The same missing process can later appear with incomplete SCK metadata.
        // Its independent PID attestation still prevents its admission.
        XCTAssertFalse(CaptureSessionPolicy.mayIncludeApplication(
            .init(processIdentifier: 101, bundleIdentifier: "", applicationName: ""),
            excludedBundleIDs: [], protectedSnapshot: snapshot, ignoredSnapshot: []
        ))
    }

    func testInclusionRejectsProtectedNamesBundlesUserExclusionsAndNativeScreenshots() {
        let empty = ProtectedCaptureApplicationSnapshot(revision: 0, applications: [])
        let denied: [ScreenCaptureFilterApplication] = [
            .init(processIdentifier: 1, bundleIdentifier: "com.apple.LocalAuthentication.UIAgent", applicationName: "Agent"),
            .init(processIdentifier: 2, bundleIdentifier: "", applicationName: "SecurityAgent"),
            .init(processIdentifier: 3, bundleIdentifier: "com.example.private", applicationName: "Private"),
            .init(processIdentifier: 4, bundleIdentifier: "gg.zbs.eye", applicationName: "ZBS Eye"),
            .init(processIdentifier: 5, bundleIdentifier: "com.apple.screencaptureui", applicationName: "Screenshot"),
            .init(processIdentifier: 6, bundleIdentifier: "", applicationName: "Helper")
        ]
        for app in denied {
            XCTAssertFalse(CaptureSessionPolicy.mayIncludeApplication(
                app, excludedBundleIDs: ["com.example.private", "gg.zbs.eye"],
                protectedSnapshot: empty,
                ignoredSnapshot: [.init(processIdentifier: 6, bundleIdentifier: "com.example.private")]
            ), "Unexpected admission: \(app)")
        }
    }

    func testCallAudioPriorityKeepsScreenClosedUntilCallEnds() {
        let duringCall = CaptureSessionPolicy.suspendedGate(
            previous: CaptureSessionGateState(reasons: []),
            adding: .callAudioPriority
        )
        XCTAssertTrue(duringCall.suspended)
        XCTAssertTrue(duringCall.reasons.contains(.callAudioPriority))

        let unrelatedWake = CaptureSessionPolicy.resumeSignalGate(
            previous: duringCall,
            clearing: .displaySleep,
            sessionLockedNow: false
        )
        XCTAssertTrue(unrelatedWake.reasons.contains(.callAudioPriority))

        let afterCall = CaptureSessionPolicy.resumeSignalGate(
            previous: unrelatedWake,
            clearing: .callAudioPriority,
            sessionLockedNow: false
        )
        XCTAssertTrue(afterCall.isOpen)
    }

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
