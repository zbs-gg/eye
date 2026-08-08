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

    private var sessionPolicySource: String {
        get throws {
            return try String(
                contentsOf: projectRoot.appending(path: "ZBSEyeApp/Capture/CaptureSessionPolicy.swift"),
                encoding: .utf8
            )
        }
    }

    func testStartSeedsAConservativeGateFromTheCurrentSession() throws {
        let source = try coordinatorSource
        let policySource = try sessionPolicySource

        XCTAssertTrue(source.contains("CaptureSessionPolicy.currentSessionLocked()"))
        XCTAssertTrue(policySource.contains("CGSessionCopyCurrentDictionary"))
        XCTAssertTrue(source.contains("CaptureSessionPolicy.startupGate"))
        XCTAssertTrue(source.contains("applySessionGate(initialSessionGate)"))
        XCTAssertTrue(source.contains("if initialSessionGate.isOpen { trigger(.startup) }"))
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
            source.range(of: "trigger(.sessionResume)", range: liveRecheck.upperBound..<source.endIndex)
        )

        XCTAssertLessThan(invalidation.lowerBound, liveRecheck.lowerBound)
        XCTAssertLessThan(liveRecheck.lowerBound, trigger.lowerBound)
    }

    func testCaptureCycleRechecksSessionAfterAwaitBeforeWriting() throws {
        let source = try coordinatorSource
        let frameReady = try XCTUnwrap(source.range(of: "guard let frame else { return }"))
        let finalGate = try XCTUnwrap(
            source.range(
                of: "guard currentSessionStillAllowsCapture(),",
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

    func testCaptureCycleReattestsTheExactFrontmostSourceBeforeEitherWrite() throws {
        let source = try coordinatorSource
        let frameReady = try XCTUnwrap(source.range(of: "guard let frame else { return }"))
        let finalSourceGate = try XCTUnwrap(
            source.range(
                of: "guard reattestCaptureSourceOrQueueLatest(",
                range: frameReady.upperBound..<source.endIndex
            )
        )
        let duplicateBranch = try XCTUnwrap(
            source.range(of: "if frame.isDuplicate {", range: finalSourceGate.upperBound..<source.endIndex)
        )
        let firstWrite = try XCTUnwrap(
            source.range(of: "await write(", range: duplicateBranch.upperBound..<source.endIndex)
        )

        XCTAssertLessThan(frameReady.lowerBound, finalSourceGate.lowerBound)
        XCTAssertLessThan(finalSourceGate.lowerBound, duplicateBranch.lowerBound)
        XCTAssertLessThan(finalSourceGate.lowerBound, firstWrite.lowerBound)
        XCTAssertTrue(source.contains("triggerApplicationSwitch()"))
    }

    func testApplicationSwitchCancelsPreviousAppsDelayedInputBeforeHardTrigger() throws {
        let source = try coordinatorSource
        let method = try XCTUnwrap(source.range(of: "private func triggerApplicationSwitch()"))
        let bumpRevision = try XCTUnwrap(
            source.range(of: "frontmostApplicationRevision &+= 1", range: method.upperBound..<source.endIndex)
        )
        let cancelTask = try XCTUnwrap(
            source.range(of: "meaningfulInputTask?.cancel()", range: bumpRevision.upperBound..<source.endIndex)
        )
        let cancelPending = try XCTUnwrap(
            source.range(of: "meaningfulInputPolicy.cancelPending()", range: cancelTask.upperBound..<source.endIndex)
        )
        let hardTrigger = try XCTUnwrap(
            source.range(of: "trigger(.applicationSwitch)", range: cancelPending.upperBound..<source.endIndex)
        )

        XCTAssertLessThan(bumpRevision.lowerBound, cancelTask.lowerBound)
        XCTAssertLessThan(cancelTask.lowerBound, cancelPending.lowerBound)
        XCTAssertLessThan(cancelPending.lowerBound, hardTrigger.lowerBound)
        XCTAssertTrue(source[method.upperBound..<hardTrigger.lowerBound].contains("cycleTask?.cancel()"))
        XCTAssertTrue(source.contains("MainActor.assumeIsolated { self?.triggerApplicationSwitch() }"))
    }

    func testCaptureCycleCarriesMonotonicFocusRevisionAcrossBothSourceChecks() throws {
        let source = try coordinatorSource
        XCTAssertTrue(source.contains(
            "let expectedFrontmostApplicationRevision = frontmostApplicationRevision"
        ))
        XCTAssertEqual(
            source.components(
                separatedBy: "expectedFrontmostApplicationRevision: expectedFrontmostApplicationRevision"
            ).count - 1,
            2
        )
        XCTAssertTrue(source.contains("currentFocusRevision: frontmostApplicationRevision"))
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
                of: "guard currentSessionStillAllowsCapture(),",
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
        XCTAssertTrue(source.contains("\\.runningApplications"))
        XCTAssertTrue(source.contains("CaptureSessionPolicy.recordProtectedApplicationInventoryChange"))
        XCTAssertTrue(pipeline.contains("onScreenWindowsOnly: false"))
        XCTAssertTrue(pipeline.contains("contentCoversProtectedApplications"))
    }

    func testStaleShareableContentMissingUserIgnoredHelperFailsClosed() throws {
        let source = try coordinatorSource
        let pipeline = try String(
            contentsOf: projectRoot.appendingPathComponent("ZBSEyeApp/Capture/FramePipeline.swift"),
            encoding: .utf8
        )
        let policy = try String(
            contentsOf: projectRoot.appendingPathComponent("ZBSEyeApp/Capture/CaptureSessionPolicy.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("let userIgnoredApplicationSnapshot = Self.userIgnoredApplicationSnapshot("))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "userIgnoredApplicationSnapshot: userIgnoredApplicationSnapshot").count - 1,
            3
        )
        XCTAssertTrue(pipeline.contains("cachedUserIgnoredApplicationSnapshot"))
        XCTAssertTrue(pipeline.contains("contentCoversExpectedPrivacyApplications"))
        XCTAssertTrue(pipeline.contains("contentCoversUserIgnoredApplications"))
        XCTAssertTrue(policy.contains("expected.isSubset(of: represented)"))
        XCTAssertGreaterThanOrEqual(
            pipeline.components(separatedBy: "Self.contentCoversExpectedPrivacyApplications(").count - 1,
            4,
            "fresh content, active stream, update completion, and start completion must all fail closed"
        )
    }

    func testUserIgnoredShareableContentIdentityRequiresExactPIDAndBundle() throws {
        let source = try coordinatorSource
        let pipeline = try String(
            contentsOf: projectRoot.appendingPathComponent("ZBSEyeApp/Capture/FramePipeline.swift"),
            encoding: .utf8
        )
        let policy = try String(
            contentsOf: projectRoot.appendingPathComponent("ZBSEyeApp/Capture/CaptureSessionPolicy.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("case ignored(processIdentifier: Int32, bundleIdentifier: String)"))
        XCTAssertTrue(source.contains("guard case let .ignored(processIdentifier, bundleIdentifier) = identity"))
        XCTAssertTrue(policy.contains("struct UserIgnoredCaptureApplicationIdentity: Hashable, Sendable"))
        XCTAssertTrue(pipeline.contains("processIdentifier: Int32($0.processID)"))
        XCTAssertTrue(pipeline.contains("bundleIdentifier: $0.bundleIdentifier"))
        XCTAssertTrue(
            policy.contains("typealias UserIgnoredCaptureApplicationSnapshot = Set<UserIgnoredCaptureApplicationIdentity>")
        )
        XCTAssertFalse(
            policy.contains("representedBundleIdentifiers.isSuperset"),
            "a reused PID or another process from the same bundle must not satisfy exact identity attestation"
        )
    }

    func testCompleteRunningApplicationInventoryRevokesBeforeAsyncInvalidation() throws {
        let source = try coordinatorSource
        let reconciliation = try XCTUnwrap(
            source.range(of: "private func reconcileRunningPrivacyApplications()")
        )
        let synchronousBump = try XCTUnwrap(
            source.range(
                of: "CaptureSessionPolicy.recordProtectedApplicationInventoryChange()",
                range: reconciliation.upperBound..<source.endIndex
            )
        )
        let synchronousRevoke = try XCTUnwrap(
            source.range(
                of: "revokeCaptureForStreamTopologyChange(.contentTopologyChanged)",
                range: synchronousBump.upperBound..<source.endIndex
            )
        )
        let asyncRefresh = try XCTUnwrap(
            source.range(
                of: "refreshContentAfterTopologyChange()",
                range: synchronousRevoke.upperBound..<source.endIndex
            )
        )

        XCTAssertLessThan(synchronousBump.lowerBound, synchronousRevoke.lowerBound)
        XCTAssertLessThan(synchronousRevoke.lowerBound, asyncRefresh.lowerBound)
    }

    func testPrivateApplicationLifecycleRevokesCurrentCycleBeforeStreamInvalidation() throws {
        let source = try coordinatorSource
        let privateMatch = try XCTUnwrap(
            source.range(
                of: "ignored.contains(bundleIdentifier)"
            )
        )
        let synchronousRevoke = try XCTUnwrap(
            source.range(
                of: "revokeCaptureForStreamTopologyChange(.contentTopologyChanged)",
                range: privateMatch.upperBound..<source.endIndex
            )
        )
        let asyncInvalidation = try XCTUnwrap(
            source.range(
                of: "await self.pipeline.invalidateContent()",
                range: synchronousRevoke.upperBound..<source.endIndex
            )
        )

        XCTAssertLessThan(privateMatch.lowerBound, synchronousRevoke.lowerBound)
        XCTAssertLessThan(synchronousRevoke.lowerBound, asyncInvalidation.lowerBound)
        XCTAssertTrue(source.contains("contentTopologyRevision &+= 1"))
        XCTAssertTrue(source.contains("healthController.invalidatePipeline("))
        XCTAssertTrue(source.contains("recordScreenPipelineFailure("))
        XCTAssertTrue(source.contains("func privacyExclusionsDidChange()"))
        let environment = try String(
            contentsOf: projectRoot.appending(path: "ZBSEyeApp/App/AppEnvironment.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(environment.contains("privacy.onIgnoredBundleIdsChanged"))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "contentTopologyRevision == expectedContentTopologyRevision").count - 1,
            2
        )
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "privacyApplicationInventoryStillMatches(").count - 1,
            4
        )
    }

    func testIntentionalCyclesCannotHidePhysicalStreamFailures() throws {
        let source = try coordinatorSource

        XCTAssertFalse(source.contains("try? await pipeline.reconcilePersistentStream"))
        XCTAssertTrue(source.contains("reconcilePersistentStreamForIntentionalCycle"))
        XCTAssertTrue(source.contains("case .streamStartFailed, .streamUpdateFailed, .streamStopUnconfirmed:"))
        XCTAssertTrue(source.contains("healthController.recordScreenPipelineFailure("))
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
