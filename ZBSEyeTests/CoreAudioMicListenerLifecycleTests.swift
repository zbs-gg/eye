import XCTest

final class CoreAudioMicListenerLifecycleTests: XCTestCase {
    typealias Policy = CoreAudioMicListenerLifecyclePolicy

    func testStartSubscribesBeforeFirstRead() {
        XCTAssertEqual(
            Policy.effects(for: .start),
            [
                .installSystemListeners,
                .reconcileProcessListeners,
                .wakePoll,
            ]
        )
    }

    func testInputActivityWakesImmediatelyWithoutRegistrationChurn() {
        XCTAssertEqual(Policy.effects(for: .inputActivity), [.wakePoll])
    }

    func testProcessListChangeReadsImmediatelyAndAgainAfterReconcile() {
        XCTAssertEqual(
            Policy.effects(for: .processListChanged),
            [
                .wakePoll,
                .reconcileProcessListeners,
                .wakePoll,
            ]
        )
    }

    func testServiceRestartReadsImmediatelyThenForgetsAndRebuildsBeforePostRead() {
        XCTAssertEqual(
            Policy.effects(for: .serviceRestarted),
            [
                .wakePoll,
                .forgetRegistrations,
                .installSystemListeners,
                .reconcileProcessListeners,
                .wakePoll,
            ]
        )
    }

    func testSystemWakeReinstallsEverythingBeforePostRead() {
        XCTAssertEqual(
            Policy.effects(for: .systemWake),
            [
                .removeAllListeners,
                .installSystemListeners,
                .reconcileProcessListeners,
                .wakePoll,
            ]
        )
    }

    func testStopOnlyRemovesRegistrationsAndNeverReads() {
        XCTAssertEqual(Policy.effects(for: .stop), [.removeAllListeners])
    }

    func testPropertySelectorClassificationPrefersServiceRestartThenProcessList() {
        let input: UInt32 = 10
        let processList: UInt32 = 20
        let restart: UInt32 = 30

        XCTAssertEqual(
            Policy.event(
                forPropertySelectors: [input],
                runningInputSelector: input,
                processListSelector: processList,
                serviceRestartedSelector: restart
            ),
            .inputActivity
        )
        XCTAssertEqual(
            Policy.event(
                forPropertySelectors: [input, processList],
                runningInputSelector: input,
                processListSelector: processList,
                serviceRestartedSelector: restart
            ),
            .processListChanged
        )
        XCTAssertEqual(
            Policy.event(
                forPropertySelectors: [input, processList, restart],
                runningInputSelector: input,
                processListSelector: processList,
                serviceRestartedSelector: restart
            ),
            .serviceRestarted
        )
        XCTAssertNil(
            Policy.event(
                forPropertySelectors: [99],
                runningInputSelector: input,
                processListSelector: processList,
                serviceRestartedSelector: restart
            )
        )
    }

    func testProcessPlanAddsNewAndRemovesVanishedObjectsDeterministically() {
        XCTAssertEqual(
            Policy.processListenerPlan(
                current: [7, 2, 9],
                registered: [1, 2, 7, 4]
            ),
            Policy.ProcessListenerPlan(remove: [1, 4], add: [9])
        )
    }

    func testProcessPlanDoesNothingWhenRegistrationsAlreadyMatch() {
        XCTAssertEqual(
            Policy.processListenerPlan(current: [2, 7], registered: [7, 2]),
            Policy.ProcessListenerPlan(remove: [], add: [])
        )
    }

    func testTimeoutResumeRequiresFreshPositiveMicrophoneEvidence() {
        XCTAssertFalse(
            CoreAudioMicTimeoutRecheckPolicy.confirmsMicrophoneResume(
                collectionSucceeded: false,
                activeOwnerCount: 1
            ),
            "Unknown HAL state after the grace deadline must save, not reopen the timer"
        )
        XCTAssertFalse(
            CoreAudioMicTimeoutRecheckPolicy.confirmsMicrophoneResume(
                collectionSucceeded: true,
                activeOwnerCount: 0
            )
        )
        XCTAssertTrue(
            CoreAudioMicTimeoutRecheckPolicy.confirmsMicrophoneResume(
                collectionSucceeded: true,
                activeOwnerCount: 2
            )
        )
    }

    func testPartialInputReadsAllowPositiveEdgesButNeverAdvanceIdleSuppression() {
        XCTAssertFalse(
            CoreAudioMicEvidenceAuthorityPolicy.permitsNegativeSuppressionMutation(
                collectionSucceeded: true,
                inputStateAuthoritative: false
            )
        )
        XCTAssertTrue(
            CoreAudioMicEvidenceAuthorityPolicy.requiresStaleSnapshot(
                inputStateAuthoritative: false,
                unsuppressedPositiveOwnerCount: 0
            )
        )
        XCTAssertFalse(
            CoreAudioMicEvidenceAuthorityPolicy.requiresStaleSnapshot(
                inputStateAuthoritative: false,
                unsuppressedPositiveOwnerCount: 1
            ),
            "A trustworthy positive owner can still start or continue a Call"
        )
        XCTAssertTrue(
            CoreAudioMicEvidenceAuthorityPolicy.permitsNegativeSuppressionMutation(
                collectionSucceeded: true,
                inputStateAuthoritative: true
            )
        )
    }

    func testTwoSidedSuppressionRequiresAuthoritativeOutputAndActiveObjectIdentity() {
        XCTAssertFalse(
            CoreAudioMicEvidenceAuthorityPolicy.permitsFullAudioSuppressionMutation(
                collectionSucceeded: true,
                fullAudioStateAuthoritative: false
            ),
            "A partial output/PID read cannot prove the full audio boundary used by tombstones"
        )
        XCTAssertFalse(
            CoreAudioMicEvidenceAuthorityPolicy.permitsFullAudioSuppressionMutation(
                collectionSucceeded: false,
                fullAudioStateAuthoritative: true
            )
        )
        XCTAssertTrue(
            CoreAudioMicEvidenceAuthorityPolicy.permitsFullAudioSuppressionMutation(
                collectionSucceeded: true,
                fullAudioStateAuthoritative: true
            )
        )
    }

    func testMeetingDetectorUsesFullAudioAuthorityForTwoSidedTombstones() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("ZBSEyeApp/Meeting/MeetingDetector.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("if outputState == nil { fullAudioStateAuthoritative = false }"))
        XCTAssertTrue(source.contains("fullAudioStateAuthoritative = false\n                continue"))
        let authority = try XCTUnwrap(
            source.range(of: "let fullAudioSuppressionMutationPermitted")
        )
        let mutation = try XCTUnwrap(
            source.range(
                of: "await updateSuppressedSessions(",
                range: authority.upperBound..<source.endIndex
            )
        )
        let gate = source[authority.lowerBound..<mutation.lowerBound]
        XCTAssertTrue(gate.contains("if fullAudioSuppressionMutationPermitted"))
    }

    func testMeetingDetectorConsumesTheOwnedCoreAudioBundleID() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("ZBSEyeApp/Meeting/MeetingDetector.swift"),
            encoding: .utf8
        )

        let bundleIDReader = try XCTUnwrap(
            source.range(of: "private static func bundleIDOf")
        )
        let followingFunction = try XCTUnwrap(
            source.range(
                of: "private static func parentPid",
                range: bundleIDReader.upperBound..<source.endIndex
            )
        )
        let implementation = source[bundleIDReader.lowerBound..<followingFunction.lowerBound]
        XCTAssertTrue(implementation.contains("takeRetainedValue()"))
        XCTAssertFalse(implementation.contains("takeUnretainedValue()"))
    }

    func testAppEnvironmentForwardsWorkspaceWakeAndScreenWakeToDetector() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("ZBSEyeApp/App/AppEnvironment.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("NSWorkspace.didWakeNotification"))
        XCTAssertTrue(source.contains("NSWorkspace.screensDidWakeNotification"))
        XCTAssertTrue(source.contains("await detector?.systemDidWake()"))
        XCTAssertTrue(
            source.contains("reconcileAutomaticCallSessionAdmission(clearing: reason)")
        )
        XCTAssertTrue(source.contains("MainActor.assumeIsolated"))
        XCTAssertTrue(source.contains("(NSWorkspace.willSleepNotification, .systemSleep)"))
        XCTAssertTrue(source.contains("(NSWorkspace.screensDidSleepNotification, .displaySleep)"))
        XCTAssertTrue(source.contains("com.apple.screensaver.didstart"))
        XCTAssertTrue(source.contains(".screenSaver"))
        XCTAssertTrue(source.contains("center.removeObserver(observer)"))
        let startLeaseCheck = try XCTUnwrap(
            source.range(of: "self.calls.permitsCallAudioStart(startAdmissionLease)")
        )
        let sinkAdmission = try XCTUnwrap(
            source.range(
                of: "audioCoordinator.admitCallFrameSink(sinkLease)",
                range: startLeaseCheck.upperBound..<source.endIndex
            )
        )
        XCTAssertLessThan(startLeaseCheck.lowerBound, sinkAdmission.lowerBound)
        let latch = try XCTUnwrap(
            source.range(of: "private func latchAutomaticCallSessionBoundary")
        )
        let closeFrames = try XCTUnwrap(
            source.range(
                of: "audio?.closeCallFrameAdmission()",
                range: latch.upperBound..<source.endIndex
            )
        )
        let asyncEnd = try XCTUnwrap(
            source.range(
                of: "private func finishAutomaticCallSessionBoundary() async",
                range: closeFrames.upperBound..<source.endIndex
            )
        )
        XCTAssertLessThan(closeFrames.lowerBound, asyncEnd.lowerBound)
    }
}
