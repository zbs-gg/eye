import XCTest

final class AutomaticCallCaptureLifecycleTests: XCTestCase {
    func testMicrophoneDisappearanceStartsOneThirtySecondGraceWithoutExtendingIt() {
        var lifecycle = AutomaticCallEndLifecycle()
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(lifecycle.didStart(callID: 42, fingerprint: "chatgpt"))
        let deadline = lifecycle.beginGrace(
            callID: 42,
            fingerprint: "chatgpt",
            now: now
        )
        XCTAssertEqual(deadline, now.addingTimeInterval(30))
        XCTAssertEqual(
            lifecycle.beginGrace(
                callID: 42,
                fingerprint: "chatgpt",
                now: now.addingTimeInterval(10)
            ),
            deadline,
            "Repeated idle evidence must not restart the 30-second window"
        )
    }

    func testMicrophoneReturnWithinGraceResumesTheSameCall() {
        var lifecycle = AutomaticCallEndLifecycle()
        let identity = AutomaticCallEndLifecycle.Identity(
            callID: 42,
            fingerprint: "chatgpt"
        )

        XCTAssertTrue(lifecycle.didStart(callID: 42, fingerprint: "chatgpt"))
        XCTAssertNotNil(
            lifecycle.beginGrace(
                callID: 42,
                fingerprint: "chatgpt",
                now: Date(timeIntervalSince1970: 1_000)
            )
        )
        XCTAssertTrue(lifecycle.resume(callID: 42, fingerprint: "chatgpt"))
        XCTAssertEqual(lifecycle.phase, .recording(identity))
        XCTAssertFalse(lifecycle.resume(callID: 43, fingerprint: "successor"))
    }

    func testStaleCoreAudioActivityDoesNotCancelGrace() {
        var lifecycle = AutomaticCallEndLifecycle()
        let identity = AutomaticCallEndLifecycle.Identity(
            callID: 42,
            fingerprint: "chatgpt"
        )
        let deadline = Date(timeIntervalSince1970: 1_030)

        XCTAssertTrue(lifecycle.didStart(callID: 42, fingerprint: "chatgpt"))
        XCTAssertEqual(
            lifecycle.beginGrace(
                callID: 42,
                fingerprint: "chatgpt",
                now: Date(timeIntervalSince1970: 1_000)
            ),
            deadline
        )
        XCTAssertFalse(
            AutomaticCallActivityResumeGate.allowsResume(
                evidenceIsStale: true,
                microphoneAudioActive: false
            )
        )
        XCTAssertEqual(lifecycle.phase, .grace(identity, deadline: deadline))

        XCTAssertTrue(
            AutomaticCallActivityResumeGate.allowsResume(
                evidenceIsStale: false,
                microphoneAudioActive: true
            )
        )
        XCTAssertTrue(lifecycle.resume(callID: 42, fingerprint: "chatgpt"))
        XCTAssertEqual(lifecycle.phase, .recording(identity))
    }

    func testEndAndSaveAndTimeoutEachHaveExactlyOneTerminalOwner() {
        for intent in [
            AutomaticCallEndLifecycle.FinishIntent.userSave,
            .automaticTimeout,
        ] {
            var lifecycle = AutomaticCallEndLifecycle()
            XCTAssertTrue(lifecycle.didStart(callID: 42, fingerprint: "chatgpt"))
            XCTAssertNotNil(
                lifecycle.beginGrace(
                    callID: 42,
                    fingerprint: "chatgpt",
                    now: Date(timeIntervalSince1970: 1_000)
                )
            )

            XCTAssertTrue(
                lifecycle.claimFinish(
                    callID: 42,
                    fingerprint: "chatgpt",
                    intent: intent,
                    allowWhileRecording: false
                )
            )
            XCTAssertFalse(
                lifecycle.claimFinish(
                    callID: 42,
                    fingerprint: "chatgpt",
                    intent: .userSave,
                    allowWhileRecording: false
                ),
                "A double click or timeout race must not claim a second finalization"
            )
            XCTAssertFalse(
                lifecycle.resume(callID: 42, fingerprint: "chatgpt"),
                "Returning microphone activity cannot reopen a Call after finalization is claimed"
            )
            XCTAssertTrue(
                lifecycle.complete(
                    callID: 42,
                    fingerprint: "chatgpt",
                    succeeded: true
                )
            )
            XCTAssertEqual(lifecycle.phase, .saved(callID: 42))
        }
    }

    func testExplicitSaveCanClaimRecordingButAutomaticTimeoutCannot() {
        var lifecycle = AutomaticCallEndLifecycle()
        XCTAssertTrue(lifecycle.didStart(callID: 42, fingerprint: "chatgpt"))

        XCTAssertFalse(
            lifecycle.claimFinish(
                callID: 42,
                fingerprint: "chatgpt",
                intent: .automaticTimeout,
                allowWhileRecording: false
            )
        )
        XCTAssertTrue(
            lifecycle.claimFinish(
                callID: 42,
                fingerprint: "chatgpt",
                intent: .userSave,
                allowWhileRecording: true
            )
        )
    }

    func testReturningMicrophoneCancelsClaimedAutomaticTimeoutButNotUserSave() {
        var automatic = AutomaticCallEndLifecycle()
        XCTAssertTrue(automatic.didStart(callID: 42, fingerprint: "chatgpt"))
        XCTAssertNotNil(
            automatic.beginGrace(
                callID: 42,
                fingerprint: "chatgpt",
                now: Date(timeIntervalSince1970: 1_000)
            )
        )
        XCTAssertTrue(
            automatic.claimFinish(
                callID: 42,
                fingerprint: "chatgpt",
                intent: .automaticTimeout,
                allowWhileRecording: false
            )
        )
        XCTAssertTrue(
            automatic.cancelAutomaticTimeoutForActivity(
                callID: 42,
                fingerprint: "chatgpt"
            )
        )
        XCTAssertTrue(automatic.resume(callID: 42, fingerprint: "chatgpt"))

        var userSave = AutomaticCallEndLifecycle()
        XCTAssertTrue(userSave.didStart(callID: 43, fingerprint: "chatgpt"))
        XCTAssertNotNil(
            userSave.beginGrace(
                callID: 43,
                fingerprint: "chatgpt",
                now: Date(timeIntervalSince1970: 1_000)
            )
        )
        XCTAssertTrue(
            userSave.claimFinish(
                callID: 43,
                fingerprint: "chatgpt",
                intent: .userSave,
                allowWhileRecording: false
            )
        )
        XCTAssertFalse(
            userSave.cancelAutomaticTimeoutForActivity(
                callID: 43,
                fingerprint: "chatgpt"
            )
        )

        XCTAssertTrue(
            AutomaticCallTimeoutResumeGate.allowsResume(
                microphoneActivityResumed: true,
                callCanStillPublish: true
            )
        )
        XCTAssertFalse(
            AutomaticCallTimeoutResumeGate.allowsResume(
                microphoneActivityResumed: true,
                callCanStillPublish: false
            ),
            "Call Control, Audio Off, or privacy teardown must win over a late HAL resume check"
        )
    }

    func testSavedBannerDismissesOnceAndFailureRemainsStable() {
        var saved = AutomaticCallEndLifecycle()
        XCTAssertTrue(saved.didStart(callID: 42, fingerprint: "chatgpt"))
        XCTAssertTrue(
            saved.claimFinish(
                callID: 42,
                fingerprint: "chatgpt",
                intent: .externalUserEnd,
                allowWhileRecording: true
            )
        )
        XCTAssertTrue(saved.complete(callID: 42, fingerprint: "chatgpt", succeeded: true))
        XCTAssertTrue(saved.dismissSaved(callID: 42))
        XCTAssertFalse(saved.dismissSaved(callID: 42))
        XCTAssertEqual(saved.phase, .idle)

        var failed = AutomaticCallEndLifecycle()
        let identity = AutomaticCallEndLifecycle.Identity(
            callID: 43,
            fingerprint: "krisp"
        )
        XCTAssertTrue(failed.didStart(callID: 43, fingerprint: "krisp"))
        XCTAssertTrue(
            failed.claimFinish(
                callID: 43,
                fingerprint: "krisp",
                intent: .userSave,
                allowWhileRecording: true
            )
        )
        XCTAssertTrue(failed.complete(callID: 43, fingerprint: "krisp", succeeded: false))
        XCTAssertEqual(failed.phase, .failed(identity))
        XCTAssertFalse(failed.dismissSaved(callID: 43))
    }

    func testPrivacyOrAudioOffResetAllowsTheNextAutomaticCall() {
        var lifecycle = AutomaticCallEndLifecycle()
        XCTAssertTrue(lifecycle.didStart(callID: 42, fingerprint: "first"))
        lifecycle.reset()
        XCTAssertTrue(lifecycle.didStart(callID: 43, fingerprint: "second"))
    }

    func testStuckFalseCallEraseDoesNotBlockTheNextAutomaticCall() {
        var gate = AutomaticCallRejectedEraseGate()

        gate.enqueue(callID: 42)
        XCTAssertTrue(gate.allowsAutomaticCallAdmission)
        XCTAssertFalse(
            gate.allowsDataRootMutation,
            "Quit and relocation must still wait for the accepted privacy erase"
        )

        gate.enqueue(callID: 43)
        XCTAssertEqual(gate.pendingCallIDs, [42, 43])
        XCTAssertTrue(gate.allowsAutomaticCallAdmission)

        gate.finish(callID: 42)
        XCTAssertFalse(gate.allowsDataRootMutation)
        gate.finish(callID: 43)
        XCTAssertTrue(gate.allowsDataRootMutation)
    }

    func testFailedFalseCallPreflightWithJoinedUserSaveStillReleasesAutomaticOwner() {
        let joinedUserSave = AutomaticCallEndCompletionResolution.resolve(
            reportedReason: .user,
            pendingUserFingerprint: nil,
            automaticFingerprint: "chatgpt",
            claimedFingerprint: nil
        )

        XCTAssertEqual(joinedUserSave.effectiveReason, .user)
        XCTAssertEqual(joinedUserSave.fingerprint, "chatgpt")

        let explicitUserSave = AutomaticCallEndCompletionResolution.resolve(
            reportedReason: .automatic,
            pendingUserFingerprint: "krisp",
            automaticFingerprint: "chatgpt",
            claimedFingerprint: nil
        )
        XCTAssertEqual(explicitUserSave.effectiveReason, .user)
        XCTAssertEqual(explicitUserSave.fingerprint, "krisp")
    }

    func testQueuedMicrophoneStartRechecksTheCurrentExactExclusion() {
        let excluded: Set<String> = ["com.openai.codex"]

        XCTAssertTrue(
            AutomaticCallExclusionBoundary.blocks(
                sourceBundleID: "com.openai.codex",
                excludedBundleIDs: excluded
            )
        )
        XCTAssertFalse(
            AutomaticCallExclusionBoundary.blocks(
                sourceBundleID: "com.openai.codex.helper",
                excludedBundleIDs: excluded
            ),
            "User exclusions are exact bundle identifiers"
        )
        XCTAssertFalse(
            AutomaticCallExclusionBoundary.blocks(
                sourceBundleID: "process:unknown",
                excludedBundleIDs: ["process:unknown"]
            ),
            "Synthetic unknown owners cannot become durable app exclusions"
        )
    }

    func testFailedFalseCallReceiptKeepsOrReplacesTheCorrectGraceTimer() {
        XCTAssertFalse(
            AutomaticCallRejectionGraceRecovery.shouldRestartGrace(
                bannerPhase: .endingGrace,
                originalTimerExists: true
            ),
            "A live original timer must keep ownership of the unchanged grace phase"
        )
        XCTAssertTrue(
            AutomaticCallRejectionGraceRecovery.shouldRestartGrace(
                bannerPhase: .endingGrace,
                originalTimerExists: false
            ),
            "An expired timer must be replaced after rejection preflight fails"
        )
        XCTAssertFalse(
            AutomaticCallRejectionGraceRecovery.shouldRestartGrace(
                bannerPhase: .started,
                originalTimerExists: false
            )
        )
    }

    func testTemporaryHardGatesRearmWithoutWaitingForMicrophoneIdle() {
        XCTAssertFalse(
            AutomaticCallTemporaryRearmPolicy.allowsRelease(
                kind: .privacyPause,
                audioIsDisabled: false,
                privacyPauseIsActive: true
            )
        )
        XCTAssertTrue(
            AutomaticCallTemporaryRearmPolicy.allowsRelease(
                kind: .privacyPause,
                audioIsDisabled: false,
                privacyPauseIsActive: false
            )
        )
        XCTAssertFalse(
            AutomaticCallTemporaryRearmPolicy.allowsRelease(
                kind: .audioDisabled,
                audioIsDisabled: true,
                privacyPauseIsActive: false
            )
        )
        XCTAssertTrue(
            AutomaticCallTemporaryRearmPolicy.allowsRelease(
                kind: .audioDisabled,
                audioIsDisabled: false,
                privacyPauseIsActive: false
            )
        )
        XCTAssertFalse(
            AutomaticCallTemporaryRearmPolicy.allowsRelease(
                kind: .sessionLock,
                audioIsDisabled: false,
                privacyPauseIsActive: false,
                sessionLockIsActive: true
            ),
            "Unlock, not wake alone, owns rearming a microphone that stayed active"
        )
        XCTAssertFalse(
            AutomaticCallTemporaryRearmPolicy.allowsRelease(
                kind: .sessionLock,
                audioIsDisabled: true,
                privacyPauseIsActive: true,
                sessionLockIsActive: false
            ),
            "Opening one of several privacy gates must not reopen Call admission early"
        )
        XCTAssertTrue(
            AutomaticCallTemporaryRearmPolicy.allowsRelease(
                kind: .sessionLock,
                audioIsDisabled: false,
                privacyPauseIsActive: false,
                sessionLockIsActive: false
            )
        )
        XCTAssertTrue(
            AutomaticCallRearmAdmissionGate.isClosed(
                releaseInProgressFingerprint: "old-call"
            ),
            "Queued positive evidence cannot start until the detector actor releases the old owner"
        )
        XCTAssertFalse(
            AutomaticCallRearmAdmissionGate.isClosed(
                releaseInProgressFingerprint: nil
            )
        )
    }

    func testPrivacyAdmissionBarriersAreCountedAndCannotReleaseEachOther() {
        var barrier = AutomaticCallAdmissionBarrier()
        let privacy = barrier.acquire(.privacyTransition)
        let deletion = barrier.acquire(.evidenceDeletion)

        XCTAssertTrue(barrier.isClosed)
        XCTAssertEqual(barrier.activeLeaseCount, 2)
        XCTAssertTrue(barrier.release(privacy))
        XCTAssertTrue(barrier.isClosed)
        XCTAssertEqual(barrier.activeLeaseCount, 1)
        XCTAssertFalse(barrier.release(privacy), "A duplicate release cannot reopen admission")

        var foreignBarrier = AutomaticCallAdmissionBarrier()
        let foreign = foreignBarrier.acquire(.evidenceDeletion)
        XCTAssertFalse(barrier.release(foreign))
        XCTAssertTrue(barrier.isClosed)

        XCTAssertTrue(barrier.release(deletion))
        XCTAssertFalse(barrier.isClosed)
        XCTAssertEqual(barrier.activeLeaseCount, 0)
    }

    func testDiskAdmissionStaysClosedAcrossHysteresisDrainAndUnreadableVolume() {
        XCTAssertTrue(
            AutomaticCallDiskAdmissionPolicy.isClosed(
                guardState: .unknown,
                recordingLowDiskPaused: false,
                availableBytes: 1_000,
                pauseBytes: 100
            )
        )
        XCTAssertTrue(
            AutomaticCallDiskAdmissionPolicy.isClosed(
                guardState: .paused,
                recordingLowDiskPaused: false,
                availableBytes: 150,
                pauseBytes: 100
            ),
            "The guard's recovery hysteresis must outlive the asynchronous drain"
        )
        XCTAssertTrue(
            AutomaticCallDiskAdmissionPolicy.isClosed(
                guardState: .healthy,
                recordingLowDiskPaused: true,
                availableBytes: 1_000,
                pauseBytes: 100
            )
        )
        XCTAssertTrue(
            AutomaticCallDiskAdmissionPolicy.isClosed(
                guardState: .healthy,
                recordingLowDiskPaused: false,
                availableBytes: nil,
                pauseBytes: 100
            ),
            "An unreadable or unplugged media volume is not infinite free space"
        )
        XCTAssertTrue(
            AutomaticCallDiskAdmissionPolicy.isClosed(
                guardState: .healthy,
                recordingLowDiskPaused: false,
                availableBytes: 99,
                pauseBytes: 100
            )
        )
        XCTAssertFalse(
            AutomaticCallDiskAdmissionPolicy.isClosed(
                guardState: .healthy,
                recordingLowDiskPaused: false,
                availableBytes: 100,
                pauseBytes: 100
            )
        )
    }

    func testCallFrameAdmissionRequiresTheExactPreparedLeaseAndSealsAcrossResume() throws {
        var latch = CallAudioFrameAdmissionLatch()

        XCTAssertEqual(latch.route(hasCallSink: false), .background)
        let first = try XCTUnwrap(latch.installSink(present: true))
        XCTAssertEqual(
            latch.route(hasCallSink: true),
            .dropAtBoundary,
            "A prepared sink cannot accept frames before the final live lifecycle check"
        )
        XCTAssertTrue(latch.admit(first))
        XCTAssertEqual(latch.route(hasCallSink: true), .explicitCall)

        latch.close()
        latch.close()
        XCTAssertEqual(
            latch.route(hasCallSink: true),
            .dropAtBoundary,
            "A still-installed closing sink must consume-and-drop rather than leak into Timeline"
        )

        // Merely reopening the outer session/privacy gate cannot resurrect the old sink.
        XCTAssertFalse(latch.permitsCallFrames)
        XCTAssertFalse(latch.admit(first))
        XCTAssertEqual(latch.route(hasCallSink: true), .dropAtBoundary)

        // Only a successor sink installed while every lifecycle gate is open may accept again.
        XCTAssertNil(latch.installSink(present: false))
        let successor = try XCTUnwrap(latch.installSink(present: true))
        XCTAssertNotEqual(first, successor)
        XCTAssertFalse(latch.admit(first), "An ABA-stale lease cannot open a replacement sink")
        XCTAssertTrue(latch.admit(successor))
        XCTAssertEqual(latch.route(hasCallSink: true), .explicitCall)
        XCTAssertNil(latch.installSink(present: false))
        XCTAssertEqual(latch.route(hasCallSink: false), .background)
    }

    func testSealedPreBoundaryFrameCannotFallThroughWhenCallSinkIsAlreadyClosed() async {
        let frame = AudioFrame(
            samples: [0],
            rms: 0,
            timing: AudioFrameTiming(
                source: .me,
                epoch: 1,
                ingressSequence: 10,
                normalizedHostTimeNs: 10,
                sourceSampleTime: 10,
                captureSampleRate: 48_000,
                frameCount: 1,
                capturedAt: Date(timeIntervalSince1970: 10),
                provenance: .microphone
            )
        )
        let boundary = CallAudioFrameBoundary(
            targets: AudioIngressTargets(me: 10, system: nil)
        )
        let probe = RejectingCallFrameSinkProbe()

        let consumed = await CallAudioFrameRouter.route(
            frame,
            admission: .dropAtBoundary,
            sealedBoundary: boundary,
            sink: { frame in await probe.reject(frame) }
        )

        let receivedCount = await probe.receivedCount
        XCTAssertTrue(consumed, "A closed Call sink must not leak its frame into Timeline")
        XCTAssertEqual(receivedCount, 1, "The accepted pre-boundary frame should still be offered for drain")
    }

    func testSealedCallFinalizationIgnoresPostBoundaryEngineProgress() {
        let boundary = CallAudioFrameBoundary(
            targets: AudioIngressTargets(me: 10, system: 20)
        )
        XCTAssertTrue(boundary.contains(source: .me, ingressSequence: 10))
        XCTAssertFalse(boundary.contains(source: .me, ingressSequence: 11))
        XCTAssertTrue(boundary.contains(source: .system, ingressSequence: 19))
        XCTAssertFalse(boundary.contains(source: .system, ingressSequence: 21))

        let liveAfterClose = AudioIngressTargets(me: 1_000, system: 2_000)
        XCTAssertEqual(
            CallAudioFinalizationTargetPolicy.targets(
                hasCallSink: true,
                sealedBoundary: boundary,
                liveTargets: liveAfterClose
            ),
            boundary.targets,
            "Post-boundary HAL progress must not create a false two-second spool timeout or gap"
        )
        XCTAssertEqual(
            CallAudioFinalizationTargetPolicy.targets(
                hasCallSink: false,
                sealedBoundary: boundary,
                liveTargets: liveAfterClose
            ),
            liveAfterClose,
            "Without a Call sink the ordinary baseline remains the live engine watermark"
        )
    }

}

private actor RejectingCallFrameSinkProbe {
    private(set) var receivedCount = 0

    func reject(_ frame: AudioFrame) -> Bool {
        _ = frame
        receivedCount += 1
        return false
    }
}
