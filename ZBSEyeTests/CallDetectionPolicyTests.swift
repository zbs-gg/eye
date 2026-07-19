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

    func testRejectionSuppressesOnlySameFingerprintUntilIdle() {
        var policy = CallDetectionPolicy()
        let call = native(bundleID: "us.zoom.xos", marker: .nativeCallControls)
        XCTAssertEqual(policy.reduce(call), .start(fingerprint: "zoom-session"))

        policy.reject(fingerprint: "zoom-session")
        XCTAssertEqual(policy.reduce(call), .none)

        var idle = call
        idle.now = 20
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

    func testActivePolicyEmitsActivityAndStrongEndEvidence() {
        var policy = CallDetectionPolicy()
        let call = native(bundleID: "us.zoom.xos", marker: .nativeCallControls)
        XCTAssertEqual(policy.reduce(call), .start(fingerprint: "zoom-session"))

        var continuing = call
        continuing.now = 12
        XCTAssertEqual(policy.reduce(continuing), .activity(fingerprint: "zoom-session"))

        var ended = call
        ended.now = 15
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

    private func browser(origin: String?) -> CallEvidenceSnapshot {
        CallEvidenceSnapshot(
            now: 10,
            microphoneOwnerBundleID: "com.google.Chrome",
            surface: CallSurfaceEvidence(
                kind: .browser,
                ownerBundleID: "com.google.Chrome",
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
}
