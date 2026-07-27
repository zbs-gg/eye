import XCTest

final class CallDetectionPolicyTests: XCTestCase {
    func testNativeCallNeedsMicrophoneAndIndependentCallMarker() {
        var policy = CallDetectionPolicy()

        XCTAssertEqual(
            policy.reduce(native(bundleID: "us.zoom.xos", marker: .nativeCallControls)),
            .start(fingerprint: "zoom-session")
        )

        var voiceMessage = native(
            bundleID: "ru.keepcoder.Telegram",
            marker: nil,
            fingerprint: "telegram-voice-message"
        )
        voiceMessage.now = 20
        voiceMessage.monotonicNow = 20
        var secondPolicy = CallDetectionPolicy()
        XCTAssertEqual(secondPolicy.reduce(voiceMessage), .none)
    }

    func testTelegramCallSurfaceStartsButPlaybackAndCalendarDoNot() {
        var policy = CallDetectionPolicy()
        XCTAssertEqual(
            policy.reduce(native(
                bundleID: "ru.keepcoder.Telegram",
                marker: .accessibilityParticipantRoster,
                fingerprint: "telegram-call"
            )),
            .start(fingerprint: "telegram-call")
        )

        var playbackPolicy = CallDetectionPolicy()
        let playback = CallEvidenceSnapshot(
            now: 10,
            monotonicNow: 10,
            microphoneOwnerBundleID: nil,
            surface: nil,
            microphoneAudioActive: false,
            systemAudioActive: true,
            calendarHint: false,
            isStale: false,
            fingerprint: "playback"
        )
        XCTAssertEqual(playbackPolicy.reduce(playback), .none)

        var calendarPolicy = CallDetectionPolicy()
        let calendar = CallEvidenceSnapshot(
            now: 10,
            monotonicNow: 10,
            microphoneOwnerBundleID: nil,
            surface: nil,
            microphoneAudioActive: false,
            systemAudioActive: false,
            calendarHint: true,
            isStale: false,
            fingerprint: "calendar"
        )
        XCTAssertEqual(calendarPolicy.reduce(calendar), .none)
    }

    func testBrowserCallRequiresTrustedHTTPSOriginMarkerAndTwoSidedAudio() {
        var policy = CallDetectionPolicy()
        XCTAssertEqual(
            policy.reduce(browser(origin: "https://meet.google.com/abc-defg-hij")),
            .start(fingerprint: "browser-session")
        )

        var copiedTitlePolicy = CallDetectionPolicy()
        XCTAssertEqual(
            copiedTitlePolicy.reduce(browser(origin: nil)),
            .none
        )

        var untrustedPolicy = CallDetectionPolicy()
        XCTAssertEqual(
            untrustedPolicy.reduce(browser(origin: "https://evil.example/meet.google.com")),
            .none
        )

        var oneSidedPolicy = CallDetectionPolicy()
        var oneSided = browser(origin: "https://app.zoom.us/wc/123")
        oneSided.systemAudioActive = false
        XCTAssertEqual(oneSidedPolicy.reduce(oneSided), .none)
    }

    func testQualifiedBrowserAndServiceCrossProductCanStart() {
        let browsers = [
            "com.google.Chrome",
            "company.thebrowser.dia",
            "com.microsoft.edgemac",
        ]
        let services = [
            "https://meet.google.com/abc-defg-hij",
            "https://zoom.us/wc/123/join",
            "https://app.zoom.us/wc/123/join",
            "https://teams.microsoft.com/v2/",
            "https://teams.live.com/meet/123",
        ]

        for bundleID in browsers {
            for origin in services {
                var policy = CallDetectionPolicy()
                let evidence = browser(bundleID: bundleID, origin: origin)
                XCTAssertEqual(
                    policy.reduce(evidence),
                    .start(fingerprint: "browser-session"),
                    "\(bundleID) should accept \(origin)"
                )
            }
        }
    }

    func testUnqualifiedBrowsersCannotStart() {
        for bundleID in [
            "com.apple.Safari",
            "company.thebrowser.Browser",
            "com.kagi.kagimacOS",
            "com.google.Chrome.canary",
        ] {
            var policy = CallDetectionPolicy()
            XCTAssertEqual(
                policy.reduce(browser(bundleID: bundleID, origin: "https://meet.google.com/abc")),
                .none,
                "\(bundleID) is manual-only in 0.5.1"
            )
        }
    }

    func testBrowserCallContinuesAcrossHiddenToolbarAndBackgroundTab() {
        var policy = CallDetectionPolicy()
        let initial = browser(origin: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(policy.reduce(initial), .start(fingerprint: "browser-session"))

        var hiddenToolbar = initial
        hiddenToolbar.now = 12
        hiddenToolbar.monotonicNow = 12
        hiddenToolbar.surface = nil
        XCTAssertEqual(
            policy.reduce(hiddenToolbar),
            .activity(fingerprint: "browser-session")
        )
    }

    func testOutputOnlyBrowserAudioStartsGraceAndRecoveryKeepsFingerprint() {
        var policy = CallDetectionPolicy()
        let initial = browser(origin: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(policy.reduce(initial), .start(fingerprint: "browser-session"))

        var microphoneSwitch = initial
        microphoneSwitch.now = 14
        microphoneSwitch.monotonicNow = 14
        microphoneSwitch.surface = nil
        microphoneSwitch.microphoneAudioActive = false
        XCTAssertEqual(
            policy.reduce(microphoneSwitch),
            .strongEnd(fingerprint: "browser-session")
        )

        var recovered = initial
        recovered.now = 18
        recovered.monotonicNow = 18
        recovered.surface = nil
        XCTAssertEqual(
            policy.reduce(recovered),
            .activity(fingerprint: "browser-session")
        )
    }

    func testConfirmedBrowserCallContinuesThroughLongOutputSilence() {
        var policy = CallDetectionPolicy()
        let initial = browser(origin: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(policy.reduce(initial), .start(fingerprint: "browser-session"))

        // More than the 30-second end grace plus the 15-second recovery window. The detector only
        // emits this same-fingerprint evidence while the mic and exact trusted call control remain.
        for elapsed in [20.0, 46.0, 90.0] {
            var quietCall = initial
            quietCall.now = elapsed
            quietCall.monotonicNow = elapsed
            quietCall.surface = nil
            quietCall.systemAudioActive = false
            XCTAssertEqual(
                policy.reduce(quietCall),
                .activity(fingerprint: "browser-session")
            )
        }

        var realEnd = initial
        realEnd.now = 92
        realEnd.monotonicNow = 92
        realEnd.surface = nil
        realEnd.microphoneAudioActive = false
        realEnd.systemAudioActive = false
        realEnd.isRetainedMissing = true
        XCTAssertEqual(
            policy.reduce(realEnd),
            .strongEnd(fingerprint: "browser-session")
        )
    }

    func testBrowserAssistantPodcastDictationAndVoiceMessageCannotStart() {
        let falsePositives: [CallEvidenceSnapshot] = [
            // Dia assistant mic: input, but no output or trusted call surface.
            browserCandidate(bundleID: "company.thebrowser.dia", input: true, output: false),
            // Podcast/video playback: output only.
            browserCandidate(bundleID: "com.google.Chrome", input: false, output: true),
            // Browser dictation: microphone only.
            browserCandidate(bundleID: "com.microsoft.edgemac", input: true, output: false),
            // Voice message recording: microphone only, even if the tab happens to be on Meet.
            CallEvidenceSnapshot(
                now: 10,
                monotonicNow: 10,
                microphoneOwnerBundleID: "com.google.Chrome",
                surface: CallSurfaceEvidence(
                    kind: .browser,
                    ownerBundleID: "com.google.Chrome",
                    trustedOrigin: TrustedCallOrigin.normalize(
                        "https://meet.google.com/abc-defg-hij"
                    ),
                    marker: .trustedBrowserCallState,
                    observedAt: 10
                ),
                microphoneAudioActive: true,
                systemAudioActive: false,
                calendarHint: false,
                isStale: false,
                fingerprint: "voice-message"
            ),
        ]

        for evidence in falsePositives {
            var policy = CallDetectionPolicy()
            XCTAssertEqual(policy.reduce(evidence), .none)
        }
    }

    func testRejectionSuppressesOnlySameFingerprintUntilIdle() {
        var policy = CallDetectionPolicy()
        let call = native(bundleID: "us.zoom.xos", marker: .nativeCallControls)
        XCTAssertEqual(policy.reduce(call), .start(fingerprint: "zoom-session"))

        policy.reject(fingerprint: "zoom-session")
        XCTAssertEqual(policy.reduce(call), .none)

        var idle = call
        idle.now = 20
        idle.monotonicNow = 20
        idle.microphoneOwnerBundleID = nil
        idle.surface = nil
        idle.microphoneAudioActive = false
        idle.systemAudioActive = false
        XCTAssertEqual(policy.reduce(idle), .becameIdle)

        let restarted = native(
            bundleID: "us.zoom.xos",
            marker: .nativeCallControls,
            now: 30
        )
        XCTAssertEqual(policy.reduce(restarted), .start(fingerprint: "zoom-session"))
    }

    func testAuthoritativeNativeSuccessorCanStartInSameAppWithoutIdle() {
        var policy = CallDetectionPolicy()
        let rejectedA = native(
            bundleID: "us.zoom.xos",
            marker: .nativeCallControls,
            fingerprint: "native-a"
        )
        XCTAssertEqual(policy.reduce(rejectedA), .start(fingerprint: "native-a"))
        policy.reject(fingerprint: "native-a")
        XCTAssertEqual(policy.reduce(rejectedA), .none)

        let successorB = native(
            bundleID: "us.zoom.xos",
            marker: .nativeCallControls,
            fingerprint: "native-b",
            now: 20
        )
        XCTAssertEqual(
            policy.reduce(successorB),
            .start(fingerprint: "native-b")
        )
    }

    func testNativeSuccessorCannotStartUntilPreviousEnvelopeCloses() {
        var policy = CallDetectionPolicy()
        let callA = native(
            bundleID: "us.zoom.xos",
            marker: .nativeCallControls,
            fingerprint: "native-a"
        )
        XCTAssertEqual(policy.reduce(callA), .start(fingerprint: "native-a"))

        let callB = native(
            bundleID: "us.zoom.xos",
            marker: .nativeCallControls,
            fingerprint: "native-b",
            now: 20
        )
        XCTAssertEqual(policy.reduce(callB), .strongEnd(fingerprint: "native-a"))
        XCTAssertEqual(
            policy.reduce(callB),
            .strongEnd(fingerprint: "native-a"),
            "B remains end evidence for A throughout its grace/tail ownership."
        )

        policy.resetAfterCompletion()
        XCTAssertEqual(policy.reduce(callB), .start(fingerprint: "native-b"))
    }

    func testBrowserCarrierSuccessorEndsABeforeBReceivesANewFingerprint() {
        var policy = CallDetectionPolicy()
        let callA = browser(origin: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(policy.reduce(callA), .start(fingerprint: "browser-session"))
        XCTAssertTrue(
            BrowserControlLifecycle.establishesSuccessorBoundary(
                state: .rebound,
                audioCarriersFullyReplaced: true
            )
        )

        var boundary = callA
        boundary.now = 12
        boundary.monotonicNow = 12
        boundary.microphoneOwnerBundleID = nil
        boundary.surface = nil
        boundary.microphoneAudioActive = false
        boundary.systemAudioActive = false
        boundary.fingerprint = "idle"
        XCTAssertEqual(
            policy.reduce(boundary),
            .strongEnd(fingerprint: "browser-session")
        )

        var callB = callA
        callB.now = 14
        callB.monotonicNow = 14
        callB.fingerprint = "browser-successor"
        XCTAssertEqual(
            policy.reduce(callB),
            .strongEnd(fingerprint: "browser-session"),
            "B cannot be admitted while A still owns the Call Envelope."
        )

        policy.resetAfterCompletion()
        XCTAssertEqual(
            policy.reduce(callB),
            .start(fingerprint: "browser-successor")
        )
    }

    func testRejectedCallADoesNotBlockEligibleCallBWhileAPersists() {
        var policy = CallDetectionPolicy()
        let rejectedA = browser(
            bundleID: "com.google.Chrome",
            origin: "https://meet.google.com/call-a"
        )
        XCTAssertEqual(
            policy.reduce(rejectedA),
            .start(fingerprint: "browser-session")
        )
        policy.reject(fingerprint: "browser-session")
        XCTAssertEqual(policy.reduce(rejectedA), .none)

        var eligibleB = browser(
            bundleID: "com.microsoft.edgemac",
            origin: "https://teams.microsoft.com/v2/"
        )
        eligibleB.now = 12
        eligibleB.monotonicNow = 12
        eligibleB.surface = eligibleB.surface.map {
            CallSurfaceEvidence(
                kind: $0.kind,
                ownerBundleID: $0.ownerBundleID,
                trustedOrigin: $0.trustedOrigin,
                marker: $0.marker,
                observedAt: 12
            )
        }
        eligibleB.fingerprint = "eligible-b"

        XCTAssertEqual(
            policy.reduce(eligibleB),
            .start(fingerprint: "eligible-b")
        )
    }

    func testSuppressionDoesNotBecomeIdleDuringRetainedAudioRouteGap() {
        var policy = CallDetectionPolicy()
        let call = browser(origin: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(policy.reduce(call), .start(fingerprint: "browser-session"))
        policy.reject(fingerprint: "browser-session")

        var retainedGap = call
        retainedGap.now = 20
        retainedGap.monotonicNow = 20
        retainedGap.microphoneOwnerBundleID = nil
        retainedGap.surface = nil
        retainedGap.microphoneAudioActive = false
        retainedGap.systemAudioActive = false
        retainedGap.isRetainedMissing = true
        XCTAssertEqual(policy.reduce(retainedGap), .none)

        var recovered = call
        recovered.now = 22
        recovered.monotonicNow = 22
        recovered.surface = nil
        XCTAssertEqual(policy.reduce(recovered), .none)

        var released = retainedGap
        released.now = 30
        released.monotonicNow = 30
        released.isRetainedMissing = false
        released.fingerprint = "idle"
        XCTAssertEqual(policy.reduce(released), .becameIdle)
    }

    func testFailedAutomaticStartCanSuppressThenAdmitNextCallAfterIdle() {
        var policy = CallDetectionPolicy()
        let failed = browser(origin: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(policy.reduce(failed), .start(fingerprint: "browser-session"))

        // Mirrors AppEnvironment's explicit startAutomatic(nil) transition.
        policy.reject(fingerprint: "browser-session")
        XCTAssertEqual(policy.reduce(failed), .none)

        var idle = failed
        idle.now = 20
        idle.monotonicNow = 20
        idle.microphoneOwnerBundleID = nil
        idle.surface = nil
        idle.microphoneAudioActive = false
        idle.systemAudioActive = false
        idle.fingerprint = "idle"
        XCTAssertEqual(policy.reduce(idle), .becameIdle)

        var next = browser(origin: "https://teams.live.com/meet/next")
        next.now = 30
        next.monotonicNow = 30
        next.surface = next.surface.map {
            CallSurfaceEvidence(
                kind: $0.kind,
                ownerBundleID: $0.ownerBundleID,
                trustedOrigin: $0.trustedOrigin,
                marker: $0.marker,
                observedAt: 30
            )
        }
        next.fingerprint = "next-browser-session"
        XCTAssertEqual(
            policy.reduce(next),
            .start(fingerprint: "next-browser-session")
        )
    }

    func testStaleCollectionFailureDoesNotClearSuppression() {
        var policy = CallDetectionPolicy()
        let call = browser(origin: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(policy.reduce(call), .start(fingerprint: "browser-session"))
        policy.reject(fingerprint: "browser-session")

        var failedRead = call
        failedRead.now = 20
        failedRead.monotonicNow = 20
        failedRead.microphoneOwnerBundleID = nil
        failedRead.surface = nil
        failedRead.microphoneAudioActive = false
        failedRead.systemAudioActive = false
        failedRead.isStale = true
        failedRead.fingerprint = "stale"
        XCTAssertEqual(policy.reduce(failedRead), .none)

        XCTAssertEqual(policy.reduce(call), .none)
    }

    func testStaleCollectionFailureDoesNotSplitActiveCall() {
        var policy = CallDetectionPolicy()
        let call = browser(origin: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(policy.reduce(call), .start(fingerprint: "browser-session"))

        var failedRead = call
        failedRead.now = 20
        failedRead.monotonicNow = 20
        failedRead.microphoneOwnerBundleID = nil
        failedRead.surface = nil
        failedRead.microphoneAudioActive = false
        failedRead.systemAudioActive = false
        failedRead.isStale = true
        failedRead.fingerprint = "stale"
        XCTAssertEqual(
            policy.reduce(failedRead),
            .activity(fingerprint: "browser-session")
        )

        failedRead.now = 28.001
        failedRead.monotonicNow = 28.001
        XCTAssertEqual(
            policy.reduce(failedRead),
            .strongEnd(fingerprint: "browser-session")
        )

        var recovered = call
        recovered.now = 29
        recovered.monotonicNow = 29
        recovered.surface = nil
        XCTAssertEqual(
            policy.reduce(recovered),
            .activity(fingerprint: "browser-session")
        )
    }

    func testMonotonicStaleLatchEndsEvenWhenWallClockRollsBackward() {
        var policy = CallDetectionPolicy()
        let call = browser(origin: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(policy.reduce(call), .start(fingerprint: "browser-session"))

        var failedRead = call
        failedRead.isStale = true
        failedRead.fingerprint = "stale"
        failedRead.microphoneOwnerBundleID = nil
        failedRead.surface = nil
        failedRead.microphoneAudioActive = false
        failedRead.systemAudioActive = false
        failedRead.now = -3_600
        failedRead.monotonicNow = 20
        XCTAssertEqual(
            policy.reduce(failedRead),
            .activity(fingerprint: "browser-session")
        )

        failedRead.now = -7_200
        failedRead.monotonicNow = 28.001
        XCTAssertEqual(
            policy.reduce(failedRead),
            .strongEnd(fingerprint: "browser-session")
        )
    }

    func testTemporaryCapturePauseCanRearmSameSurfaceAfterCompletionReset() {
        var policy = CallDetectionPolicy()
        var call = browser(origin: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(policy.reduce(call), .start(fingerprint: "browser-session"))

        policy.resetAfterCompletion()
        call.now = 30
        call.monotonicNow = 30
        call.surface = call.surface.map {
            CallSurfaceEvidence(
                kind: $0.kind,
                ownerBundleID: $0.ownerBundleID,
                trustedOrigin: $0.trustedOrigin,
                marker: $0.marker,
                observedAt: 30
            )
        }
        XCTAssertEqual(policy.reduce(call), .start(fingerprint: "browser-session"))
    }

    func testRealCaptureFailureRemainsSuppressedWithoutIdle() {
        var policy = CallDetectionPolicy()
        let call = browser(origin: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(policy.reduce(call), .start(fingerprint: "browser-session"))

        policy.reject(fingerprint: "browser-session")
        XCTAssertEqual(policy.reduce(call), .none)
    }

    func testActivePolicyEmitsActivityAndStrongEndEvidence() {
        var policy = CallDetectionPolicy()
        let call = native(bundleID: "us.zoom.xos", marker: .nativeCallControls)
        XCTAssertEqual(policy.reduce(call), .start(fingerprint: "zoom-session"))

        var continuing = call
        continuing.now = 12
        continuing.monotonicNow = 12
        XCTAssertEqual(policy.reduce(continuing), .activity(fingerprint: "zoom-session"))

        var ended = call
        ended.now = 15
        ended.monotonicNow = 15
        ended.microphoneOwnerBundleID = nil
        ended.surface = nil
        ended.microphoneAudioActive = false
        ended.systemAudioActive = false
        XCTAssertEqual(policy.reduce(ended), .strongEnd(fingerprint: "zoom-session"))

        var replacementPolicy = CallDetectionPolicy()
        XCTAssertEqual(
            replacementPolicy.reduce(call),
            .start(fingerprint: "zoom-session")
        )
        var unrelatedMic = call
        unrelatedMic.now = 16
        unrelatedMic.monotonicNow = 16
        unrelatedMic.fingerprint = "browser-assistant"
        unrelatedMic.microphoneOwnerBundleID = "com.google.Chrome"
        unrelatedMic.surface = nil
        XCTAssertEqual(
            replacementPolicy.reduce(unrelatedMic),
            .strongEnd(fingerprint: "zoom-session")
        )
    }

    func testStaleEvidenceCannotStartAndOriginNormalizationIsStrict() {
        var policy = CallDetectionPolicy()
        var stale = browser(origin: "https://meet.google.com/abc")
        stale.isStale = true
        XCTAssertEqual(policy.reduce(stale), .none)

        XCTAssertEqual(
            TrustedCallOrigin.normalize("https://MEET.GOOGLE.COM/abc")?.host,
            "meet.google.com"
        )
        XCTAssertNil(TrustedCallOrigin.normalize("http://meet.google.com/abc"))
        XCTAssertNil(TrustedCallOrigin.normalize("https://user@meet.google.com/abc"))
        XCTAssertNil(TrustedCallOrigin.normalize("https://meet.google.com.evil.example/abc"))
        XCTAssertNil(TrustedCallOrigin.normalize("https://evil.example/?next=https://meet.google.com/abc"))
        XCTAssertNil(TrustedCallOrigin.normalize("https://calendar.google.com/calendar/u/0/r"))
        XCTAssertNil(TrustedCallOrigin.normalize("https://teams.microsoft.com.evil.example/v2/"))
        XCTAssertNil(TrustedCallOrigin.normalize("https://notzoom.us/wc/123"))
        XCTAssertNil(TrustedCallOrigin.normalize("https://zoom.us.evil.example/wc/123"))
        XCTAssertNil(TrustedCallOrigin.normalize("https://zoom.us:8443/wc/123"))
        XCTAssertEqual(
            TrustedCallOrigin.normalize("https://eu01.zoom.us/wc/123")?.host,
            "eu01.zoom.us"
        )
        XCTAssertEqual(
            TrustedCallOrigin.normalize("https://teams.live.com/meet/123")?.host,
            "teams.live.com"
        )

        let fingerprint = CallDetectorFingerprint.make(
            bundleID: "com.google.Chrome",
            sessionMarker: "123",
            originHost: "meet.google.com"
        )
        XCTAssertEqual(fingerprint.count, 64)
        XCTAssertFalse(fingerprint.contains("Chrome"))
        XCTAssertFalse(fingerprint.contains("meet.google.com"))
    }

    private func native(
        bundleID: String,
        marker: CallStateMarker?,
        fingerprint: String = "zoom-session",
        now: TimeInterval = 10
    ) -> CallEvidenceSnapshot {
        CallEvidenceSnapshot(
            now: now,
            monotonicNow: now,
            microphoneOwnerBundleID: bundleID,
            surface: CallSurfaceEvidence(
                kind: .native,
                ownerBundleID: bundleID,
                trustedOrigin: nil,
                marker: marker,
                observedAt: now
            ),
            microphoneAudioActive: true,
            systemAudioActive: true,
            calendarHint: false,
            isStale: false,
            fingerprint: fingerprint
        )
    }

    private func browser(
        bundleID: String = "com.google.Chrome",
        origin: String?
    ) -> CallEvidenceSnapshot {
        CallEvidenceSnapshot(
            now: 10,
            monotonicNow: 10,
            microphoneOwnerBundleID: bundleID,
            surface: CallSurfaceEvidence(
                kind: .browser,
                ownerBundleID: bundleID,
                trustedOrigin: origin.flatMap(TrustedCallOrigin.normalize),
                marker: .trustedBrowserCallState,
                observedAt: 10
            ),
            microphoneAudioActive: true,
            systemAudioActive: true,
            calendarHint: false,
            isStale: false,
            fingerprint: "browser-session"
        )
    }

    private func browserCandidate(
        bundleID: String,
        input: Bool,
        output: Bool
    ) -> CallEvidenceSnapshot {
        CallEvidenceSnapshot(
            now: 10,
            monotonicNow: 10,
            microphoneOwnerBundleID: input ? bundleID : nil,
            surface: nil,
            microphoneAudioActive: input,
            systemAudioActive: output,
            calendarHint: false,
            isStale: false,
            fingerprint: "candidate"
        )
    }
}
