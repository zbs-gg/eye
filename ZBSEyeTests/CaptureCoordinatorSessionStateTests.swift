import Foundation
import XCTest

final class CaptureCoordinatorSessionStateTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var coordinatorSource: String {
        get throws {
            return try String(
                contentsOf: projectRoot.appending(path: "ZBSEyeApp/Capture/CaptureCoordinator.swift"),
                encoding: .utf8
            )
        }
    }

    func testStartSeedsAConservativeGateFromTheCurrentSession() throws {
        let source = try coordinatorSource

        XCTAssertTrue(source.contains("CGSessionCopyCurrentDictionary"))
        XCTAssertTrue(source.contains("CaptureSessionPolicy.startupGate"))
        XCTAssertTrue(source.contains("applySessionGate(initialSessionGate)"))
        XCTAssertTrue(source.contains("if initialSessionGate.isOpen { trigger() }"))
    }

    func testActiveTickReconcilesBeforeItsCaptureGate() throws {
        let source = try coordinatorSource
        let tick = try XCTUnwrap(source.range(of: "private func tickFired()"))
        let reconcile = try XCTUnwrap(
            source.range(of: "CaptureSessionPolicy.periodicGate", range: tick.upperBound..<source.endIndex)
        )
        let captureGate = try XCTUnwrap(
            source.range(
                of: "CaptureSessionPolicy.mayCapture(screenLocked: screenLocked)",
                range: reconcile.upperBound..<source.endIndex
            )
        )

        XCTAssertLessThan(reconcile.lowerBound, captureGate.lowerBound)
        XCTAssertTrue(source.contains("applySessionGate(gate)"))
        XCTAssertTrue(source.contains("await openGateAfterSessionBoundary(gate)"))
        XCTAssertTrue(source.contains("await pipeline.invalidateSessionBoundary()"))
    }

    func testSessionBoundaryInvalidationCompletesBeforeLiveRecheckAndTrigger() throws {
        let source = try coordinatorSource
        let method = try XCTUnwrap(source.range(of: "private func openGateAfterSessionBoundary"))
        let invalidation = try XCTUnwrap(
            source.range(of: "await pipeline.invalidateSessionBoundary()", range: method.upperBound..<source.endIndex)
        )
        let liveRecheck = try XCTUnwrap(
            source.range(
                of: "guard isRunning, gateRevision == expectedRevision else { return }",
                range: invalidation.upperBound..<source.endIndex
            )
        )
        let trigger = try XCTUnwrap(
            source.range(of: "triggerAndArmBurst()", range: liveRecheck.upperBound..<source.endIndex)
        )

        XCTAssertLessThan(invalidation.lowerBound, liveRecheck.lowerBound)
        XCTAssertLessThan(liveRecheck.lowerBound, trigger.lowerBound)
    }

    func testCaptureCycleRechecksSessionAfterAwaitBeforeWriting() throws {
        let source = try coordinatorSource
        let frameReady = try XCTUnwrap(source.range(of: "guard let frame else { return }"))
        let finalGate = try XCTUnwrap(
            source.range(
                of: "guard currentSessionStillAllowsCapture() else { return }",
                range: frameReady.upperBound..<source.endIndex
            )
        )
        let firstWrite = try XCTUnwrap(
            source.range(of: "await write(", range: finalGate.upperBound..<source.endIndex)
        )

        XCTAssertLessThan(frameReady.lowerBound, finalGate.lowerBound)
        XCTAssertLessThan(finalGate.lowerBound, firstWrite.lowerBound)
        XCTAssertTrue(source.contains("sessionLockedNow: Self.currentSessionLocked()"))
    }

    func testCaptureCycleReattestsBeforeAXAndBeforeScreenCaptureKit() throws {
        let source = try coordinatorSource
        let cycle = try XCTUnwrap(source.range(of: "private func runCycle()"))
        let firstLiveGate = try XCTUnwrap(
            source.range(
                of: "guard currentSessionStillAllowsCapture() else { return }",
                range: cycle.upperBound..<source.endIndex
            )
        )
        let axRead = try XCTUnwrap(
            source.range(of: "ax = await axReader.extract(pid: pid)", range: firstLiveGate.upperBound..<source.endIndex)
        )
        let secondLiveGate = try XCTUnwrap(
            source.range(
                of: "guard currentSessionStillAllowsCapture() else { return }",
                range: axRead.upperBound..<source.endIndex
            )
        )
        let screenCapture = try XCTUnwrap(
            source.range(of: "frame = try await pipeline.process", range: secondLiveGate.upperBound..<source.endIndex)
        )

        XCTAssertLessThan(firstLiveGate.lowerBound, axRead.lowerBound)
        XCTAssertLessThan(axRead.lowerBound, secondLiveGate.lowerBound)
        XCTAssertLessThan(secondLiveGate.lowerBound, screenCapture.lowerBound)
    }

    func testNameFallbackRejectsProtectedFrontmostAppBeforeAXAndAtFinalGate() throws {
        let source = try coordinatorSource
        let cycle = try XCTUnwrap(source.range(of: "private func runCycle()"))
        let appName = try XCTUnwrap(
            source.range(of: "let appName = app.localizedName ?? bundleId", range: cycle.upperBound..<source.endIndex)
        )
        let earlyNameGate = try XCTUnwrap(
            source.range(of: "appName: appName", range: appName.upperBound..<source.endIndex)
        )
        let axRead = try XCTUnwrap(
            source.range(of: "ax = await axReader.extract(pid: pid)", range: earlyNameGate.upperBound..<source.endIndex)
        )
        let finalGate = try XCTUnwrap(source.range(of: "private func currentSessionStillAllowsCapture()"))
        let finalNameGate = try XCTUnwrap(
            source.range(of: "appName: app.localizedName ?? bundleId", range: finalGate.upperBound..<source.endIndex)
        )

        XCTAssertLessThan(appName.lowerBound, earlyNameGate.lowerBound)
        XCTAssertLessThan(earlyNameGate.lowerBound, axRead.lowerBound)
        XCTAssertLessThan(finalGate.lowerBound, finalNameGate.lowerBound)
    }

    func testEachResumeNotificationClearsOnlyItsMatchingReason() throws {
        let source = try coordinatorSource

        XCTAssertTrue(source.contains("resumeIfSessionUnlocked(clearing: .systemSleep)"))
        XCTAssertTrue(source.contains("resumeIfSessionUnlocked(clearing: .displaySleep)"))
        XCTAssertTrue(source.contains("resumeIfSessionUnlocked(clearing: .session)"))
        XCTAssertTrue(source.contains("resumeIfSessionUnlocked(clearing: .screenSaver)"))
        XCTAssertTrue(source.contains("suspend(for: .systemSleep)"))
        XCTAssertTrue(source.contains("suspend(for: .displaySleep)"))
        XCTAssertTrue(source.contains("suspend(for: .session)"))
        XCTAssertTrue(source.contains("suspend(for: .screenSaver)"))
    }

    func testProtectedApplicationSnapshotIsAttestedAcrossFrameProcessing() throws {
        let source = try coordinatorSource
        let pipeline = try String(
            contentsOf: projectRoot.appendingPathComponent("ZBSEyeApp/Capture/FramePipeline.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("let protectedApplicationSnapshot = CaptureSessionPolicy.protectedRunningApplicationSnapshot()"))
        XCTAssertTrue(source.contains("protectedApplicationSnapshot: protectedApplicationSnapshot"))
        XCTAssertTrue(source.contains("CaptureSessionPolicy.protectedRunningApplicationSnapshot()"))
        XCTAssertTrue(source.contains("NSWorkspace.didLaunchApplicationNotification"))
        XCTAssertTrue(source.contains("CaptureSessionPolicy.recordProtectedApplicationLifecycle"))
        XCTAssertTrue(pipeline.contains("onScreenWindowsOnly: false"))
        XCTAssertTrue(pipeline.contains("contentCoversProtectedApplications"))
    }

    func testProtectedLifecycleRevisionBumpsBeforeUnstructuredInvalidationTask() throws {
        let source = try coordinatorSource
        let launchObserver = try XCTUnwrap(
            source.range(of: "NSWorkspace.didLaunchApplicationNotification")
        )
        let synchronousBump = try XCTUnwrap(
            source.range(of: "MainActor.assumeIsolated", range: launchObserver.upperBound..<source.endIndex)
        )
        let invalidationTask = try XCTUnwrap(
            source.range(of: "Task { @MainActor", range: synchronousBump.upperBound..<source.endIndex)
        )

        XCTAssertLessThan(synchronousBump.lowerBound, invalidationTask.lowerBound)
    }

    func testEveryClosingNotificationRevokesAdmissionSynchronously() throws {
        let source = try coordinatorSource

        for (notification, reason) in [
            ("NSWorkspace.willSleepNotification", ".systemSleep"),
            ("NSWorkspace.screensDidSleepNotification", ".displaySleep"),
            ("com.apple.screenIsLocked", ".session"),
            ("com.apple.screensaver.didstart", ".screenSaver"),
        ] {
            let observer = try XCTUnwrap(source.range(of: notification), notification)
            let synchronousClose = try XCTUnwrap(
                source.range(
                    of: "MainActor.assumeIsolated { self?.suspend(for: \(reason)) }",
                    range: observer.upperBound..<source.endIndex
                ),
                notification
            )
            let callbackEnd = try XCTUnwrap(
                source.range(of: "})", range: synchronousClose.upperBound..<source.endIndex),
                notification
            )

            XCTAssertLessThan(synchronousClose.lowerBound, callbackEnd.lowerBound, notification)
        }
    }

    func testFinalSessionCheckRequiresEverySuspensionReasonToBeClear() throws {
        let source = try coordinatorSource
        let method = try XCTUnwrap(source.range(of: "private func currentSessionStillAllowsCapture()"))
        let gate = try XCTUnwrap(
            source.range(of: "guard sessionGate.isOpen else { return false }", range: method.upperBound..<source.endIndex)
        )
        let sessionQuery = try XCTUnwrap(
            source.range(of: "sessionLockedNow: Self.currentSessionLocked()", range: gate.upperBound..<source.endIndex)
        )

        XCTAssertLessThan(gate.lowerBound, sessionQuery.lowerBound)
    }

    func testDefaultNotificationObserversAreRemovedFromTheirOwningCenter() throws {
        let source = try coordinatorSource

        XCTAssertTrue(source.contains("defaultObservers.append(NotificationCenter.default.addObserver"))
        XCTAssertTrue(source.contains("defaultObservers.forEach { nc.removeObserver($0) }"))
    }
}
