import XCTest

final class CallAudioProcessEvidenceTests: XCTestCase {
    func testBrowserContinuationKeepsMicOnlyButRequiresTwoSidedSuccessorProof() {
        let microphoneOnly = CallAudioApplicationGroup(
            rootPID: 10,
            ownerBundleID: "com.google.Chrome",
            ownerKind: .browser,
            inputActive: true,
            outputActive: false,
            memberCount: 1,
            inputAudioObjectIDs: [1],
            outputAudioObjectIDs: []
        )
        XCTAssertEqual(
            CallAudioContinuationEvidence.evaluate(kind: .browser, group: microphoneOnly),
            CallAudioContinuationEvidence(
                hasContinuationAudio: true,
                hasFreshTwoSidedBrowserAudio: false
            )
        )

        let outputOnly = CallAudioApplicationGroup(
            rootPID: 10,
            ownerBundleID: "com.google.Chrome",
            ownerKind: .browser,
            inputActive: false,
            outputActive: true,
            memberCount: 1,
            inputAudioObjectIDs: [],
            outputAudioObjectIDs: [2]
        )
        XCTAssertEqual(
            CallAudioContinuationEvidence.evaluate(kind: .browser, group: outputOnly),
            CallAudioContinuationEvidence(
                hasContinuationAudio: false,
                hasFreshTwoSidedBrowserAudio: false
            )
        )
    }

    func testQuietBrowserSequencePreservesBoundaryAndSeparatesFreshSuccessor() {
        var baseline = CallAudioCarrierBaseline(
            inputAudioObjectIDs: [1],
            outputAudioObjectIDs: [2]
        )
        let quietAfterMicrophoneSwitch = CallAudioApplicationGroup(
            rootPID: 10,
            ownerBundleID: "com.google.Chrome",
            ownerKind: .browser,
            inputActive: true,
            outputActive: false,
            memberCount: 1,
            inputAudioObjectIDs: [3],
            outputAudioObjectIDs: []
        )
        let quietEvidence = CallAudioContinuationEvidence.evaluate(
            kind: .browser,
            group: quietAfterMicrophoneSwitch
        )

        XCTAssertTrue(quietEvidence.hasContinuationAudio)
        XCTAssertFalse(
            baseline.isFullyReplaced(
                by: quietAfterMicrophoneSwitch,
                kind: .browser
            ),
            "Mic-only evidence cannot prove successor B even after a microphone switch."
        )
        XCTAssertEqual(
            CallAudioSessionLiveness.decide(
                hasRequiredAudio: quietEvidence.hasContinuationAudio,
                missingSince: nil,
                now: 90,
                maximumMissingRetention: 60
            ),
            .continueActive,
            "A confirmed browser call stays active beyond grace and recovery while its mic remains."
        )

        baseline = baseline.refreshingConfirmedSide(from: quietAfterMicrophoneSwitch)
        XCTAssertEqual(baseline.inputAudioObjectIDs, [3])
        XCTAssertEqual(
            baseline.outputAudioObjectIDs,
            [2],
            "Output silence must not erase A's last positive output carrier."
        )

        let freshSuccessor = CallAudioApplicationGroup(
            rootPID: 10,
            ownerBundleID: "com.google.Chrome",
            ownerKind: .browser,
            inputActive: true,
            outputActive: true,
            memberCount: 2,
            inputAudioObjectIDs: [4],
            outputAudioObjectIDs: [5]
        )
        XCTAssertTrue(
            baseline.isFullyReplaced(by: freshSuccessor, kind: .browser),
            "Fresh two-sided B must remain distinguishable after A's quiet interval."
        )

        XCTAssertEqual(
            BrowserControlLifecycle.activeMatch(
                state: .ended,
                audioCarriersFullyReplaced: false
            ),
            false,
            "An exact Leave/End boundary remains terminal during output silence."
        )
        XCTAssertEqual(
            CallAudioSessionLiveness.decide(
                hasRequiredAudio: false,
                missingSince: 100,
                now: 161,
                maximumMissingRetention: 60
            ),
            .release,
            "Input loss remains a bounded terminal path."
        )
    }

    func testStaleProbeBatchCannotAdmitAfterStopReleaseOrAnotherAdmission() {
        XCTAssertTrue(
            MeetingDetectorLifecycleFence.permitsAdmission(
                probeGeneration: 7,
                currentGeneration: 7,
                hasActiveSession: false
            )
        )
        XCTAssertFalse(
            MeetingDetectorLifecycleFence.permitsAdmission(
                probeGeneration: 7,
                currentGeneration: 8,
                hasActiveSession: false
            ),
            "stop/release during awaited reconciliation invalidates the whole probe batch"
        )
        XCTAssertFalse(
            MeetingDetectorLifecycleFence.permitsAdmission(
                probeGeneration: 7,
                currentGeneration: 7,
                hasActiveSession: true
            ),
            "another admitted surface invalidates the remainder of the batch"
        )
    }

    func testDiaHelperResolvesToExactDiaRoot() {
        let identity = CallAudioOwnerResolution.resolve(
            ancestors: [
                CallAudioProcessAncestor(
                    pid: 102,
                    bundleID: "company.thebrowser.browser.helper",
                    executableName: "Dia Helper (Renderer)"
                ),
                CallAudioProcessAncestor(
                    pid: 10,
                    bundleID: "company.thebrowser.dia",
                    executableName: "Dia"
                ),
            ],
            currentProcessID: 999
        )

        XCTAssertEqual(
            identity,
            CallAudioApplicationIdentity(
                rootPID: 10,
                bundleID: "company.thebrowser.dia",
                kind: .browser,
                displayName: "Dia"
            )
        )
    }

    func testChromeAndEdgeHelpersResolveOnlyAtQualifiedRoot() {
        let fixtures = [
            (
                helper: "com.google.Chrome.helper",
                root: "com.google.Chrome"
            ),
            (
                helper: "com.microsoft.edgemac.helper",
                root: "com.microsoft.edgemac"
            ),
        ]

        for fixture in fixtures {
            let identity = CallAudioOwnerResolution.resolve(
                ancestors: [
                    CallAudioProcessAncestor(
                        pid: 102,
                        bundleID: fixture.helper,
                        executableName: "Helper"
                    ),
                    CallAudioProcessAncestor(
                        pid: 10,
                        bundleID: fixture.root,
                        executableName: "Browser"
                    ),
                ],
                currentProcessID: 999
            )
            XCTAssertEqual(identity?.rootPID, 10)
            XCTAssertEqual(identity?.bundleID, fixture.root)
            XCTAssertEqual(identity?.kind, .browser)
        }
    }

    func testDetachedChromiumAudioHelperResolvesToVisibleQualifiedRoot() {
        let fixtures = [
            ("com.google.Chrome.helper.Renderer", "com.google.Chrome", Int32(10)),
            ("company.thebrowser.browser.helper.Renderer", "company.thebrowser.dia", Int32(20)),
            ("com.microsoft.edgemac.helper", "com.microsoft.edgemac", Int32(30)),
        ]

        for (helper, root, pid) in fixtures {
            XCTAssertEqual(
                CallAudioBrowserRootResolution.rootAncestor(
                    audioProcessBundleID: helper,
                    runningApplicationBundleIDs: [pid: root]
                ),
                CallAudioProcessAncestor(pid: pid, bundleID: root, executableName: nil)
            )
        }
    }

    func testDetachedAudioHelperRejectsLookAlikeAndMissingRoot() {
        XCTAssertNil(
            CallAudioBrowserRootResolution.rootAncestor(
                audioProcessBundleID: "com.google.Chrome.evil",
                runningApplicationBundleIDs: [10: "com.google.Chrome.evil"]
            )
        )
        XCTAssertNil(
            CallAudioBrowserRootResolution.rootAncestor(
                audioProcessBundleID: "com.google.Chrome.helper.Renderer",
                runningApplicationBundleIDs: [20: "company.thebrowser.Browser"]
            )
        )
    }

    func testEyeAndSystemVoiceDaemonsAreExcluded() {
        let eye = CallAudioOwnerResolution.resolve(
            ancestors: [
                CallAudioProcessAncestor(
                    pid: 101,
                    bundleID: "gg.zbs.eye",
                    executableName: "ZBS Eye"
                ),
            ],
            currentProcessID: 999
        )
        XCTAssertNil(eye)

        for processName in ["replayd", "coreaudiod", "audiomxd", "avconferenced", "assistantd"] {
            let identity = CallAudioOwnerResolution.resolve(
                ancestors: [
                    CallAudioProcessAncestor(
                        pid: 101,
                        bundleID: nil,
                        executableName: processName
                    ),
                ],
                currentProcessID: 999
            )
            XCTAssertNil(identity, processName)
        }

        XCTAssertNil(
            CallAudioOwnerResolution.resolve(
                ancestors: [
                    CallAudioProcessAncestor(
                        pid: 999,
                        bundleID: "com.example.current",
                        executableName: "Current"
                    ),
                ],
                currentProcessID: 999
            )
        )
        XCTAssertNotNil(
            CallAudioOwnerResolution.resolve(
                ancestors: [
                    CallAudioProcessAncestor(
                        pid: 101,
                        bundleID: nil,
                        executableName: "coreaudiod-helper"
                    ),
                ],
                currentProcessID: 999
            ),
            "System denylist matching must stay exact."
        )
    }

    func testCodexChronicleExactBasenameIsExcludedBeforeChatGPTRootFolding() {
        let chatGPTRoot = CallAudioProcessAncestor(
            pid: 10,
            bundleID: "com.openai.codex",
            executableName: "ChatGPT"
        )
        XCTAssertNil(
            CallAudioOwnerResolution.resolve(
                ancestors: [
                    CallAudioProcessAncestor(
                        pid: 101,
                        bundleID: "com.openai.codex.helper",
                        executableName: "codex_chronicle"
                    ),
                    chatGPTRoot,
                ],
                currentProcessID: 999
            ),
            "The exact Chronicle pulse must be rejected before its helper inherits ChatGPT's root."
        )

        XCTAssertEqual(
            CallAudioOwnerResolution.resolve(
                ancestors: [
                    CallAudioProcessAncestor(
                        pid: 102,
                        bundleID: "com.openai.codex.helper",
                        executableName: "Codex Service"
                    ),
                    chatGPTRoot,
                ],
                currentProcessID: 999
            ),
            CallAudioApplicationIdentity(
                rootPID: 10,
                bundleID: "com.openai.codex",
                kind: .generic,
                displayName: "ChatGPT"
            ),
            "A real Codex Service microphone owner must still fold into ChatGPT."
        )
        XCTAssertFalse(
            CallAudioOwnerResolution.isExcludedExecutableName("codex_chronicle-helper"),
            "The built-in executable exclusion must remain an exact basename match."
        )
    }

    func testArcHelperBecomesGenericOwnerAtVisibleRoot() {
        XCTAssertEqual(
            CallAudioOwnerResolution.resolve(
                ancestors: [
                    CallAudioProcessAncestor(
                        pid: 102,
                        bundleID: "company.thebrowser.Browser.helper",
                        executableName: "Arc Helper"
                    ),
                    CallAudioProcessAncestor(
                        pid: 10,
                        bundleID: "company.thebrowser.Browser",
                        executableName: "Arc"
                    ),
                ],
                currentProcessID: 999
            ),
            CallAudioApplicationIdentity(
                rootPID: 10,
                bundleID: "company.thebrowser.Browser",
                kind: .generic,
                displayName: "Arc"
            )
        )
    }

    func testChatGPTKrispAndUnknownProcessesResolveWithoutGivingKrispOwnership() {
        for (bundleID, name) in [
            ("com.openai.codex", "ChatGPT"),
            ("ai.krisp.krispMac", "Krisp"),
        ] {
            XCTAssertEqual(
                CallAudioOwnerResolution.resolve(
                    ancestors: [
                        CallAudioProcessAncestor(
                            pid: 101,
                            bundleID: bundleID,
                            executableName: name
                        ),
                    ],
                    currentProcessID: 999
                ),
                CallAudioApplicationIdentity(
                    rootPID: 101,
                    bundleID: bundleID,
                    kind: .generic,
                    displayName: name
                )
            )
        }

        XCTAssertEqual(
            CallAudioOwnerResolution.resolve(
                ancestors: [
                    CallAudioProcessAncestor(
                        pid: 202,
                        bundleID: nil,
                        executableName: "MysteryAudio"
                    ),
                ],
                currentProcessID: 999
            ),
            CallAudioApplicationIdentity(
                rootPID: 202,
                bundleID: "process:mysteryaudio",
                kind: .generic,
                bundleIDIsSynthetic: true,
                displayName: "MysteryAudio"
            )
        )

        XCTAssertEqual(
            CallAudioAutomaticOwnerRolePolicy.role(forBundleID: "com.openai.codex"),
            .initiator
        )
        for krispBundleID in [
            "ai.krisp.krispMac",
            "ai.krisp.krispMac.helper",
            "ai.krisp.krispMac.helper.Audio",
            "ai.krisp.krispMac.xpc.Capture",
        ] {
            XCTAssertEqual(
                CallAudioAutomaticOwnerRolePolicy.role(forBundleID: krispBundleID),
                .relay,
                krispBundleID
            )
        }
        XCTAssertEqual(
            CallAudioAutomaticOwnerRolePolicy.role(forBundleID: "ai.krisp.krispMacBeta"),
            .initiator,
            "A look-alike bundle outside Krisp's exact namespace remains a normal owner."
        )
    }

    func testGenericDetachedHelperResolvesOnlyToExactVisibleRootNamespace() {
        XCTAssertEqual(
            CallAudioVisibleRootResolution.rootAncestor(
                audioProcessBundleID: "com.openai.codex.helper.Renderer",
                runningApplicationBundleIDs: [10: "com.openai.codex"]
            ),
            CallAudioProcessAncestor(
                pid: 10,
                bundleID: "com.openai.codex",
                executableName: nil
            )
        )
        XCTAssertNil(
            CallAudioVisibleRootResolution.rootAncestor(
                audioProcessBundleID: "com.openai.codex.evil",
                runningApplicationBundleIDs: [10: "com.openai.codex"]
            )
        )
    }

    func testChatGPTAndKrispProduceOneCallOwnedAndNamedByChatGPT() {
        let chatGPT = CallAudioApplicationGroup(
            rootPID: 10,
            ownerBundleID: "com.openai.codex",
            ownerKind: .generic,
            inputActive: true,
            outputActive: false,
            memberCount: 1,
            inputAudioObjectIDs: [10],
            outputAudioObjectIDs: []
        )
        let krisp = CallAudioApplicationGroup(
            rootPID: 20,
            ownerBundleID: "ai.krisp.krispMac",
            ownerKind: .generic,
            inputActive: true,
            outputActive: true,
            memberCount: 1,
            inputAudioObjectIDs: [20],
            outputAudioObjectIDs: [21]
        )
        let synthetic = CallAudioApplicationGroup(
            rootPID: 30,
            ownerBundleID: "process:mystery",
            ownerKind: .generic,
            ownerBundleIDIsSynthetic: true,
            inputActive: true,
            outputActive: false,
            memberCount: 1,
            inputAudioObjectIDs: [30],
            outputAudioObjectIDs: []
        )

        let participants = CallAudioAutomaticAdmission.participatingInputGroups(
            from: [chatGPT, krisp, synthetic],
            excludedBundleIDs: ["com.openai.codex", "process:mystery"]
        )
        XCTAssertEqual(
            participants.map(\.ownerBundleID),
            ["ai.krisp.krispMac", "process:mystery"],
            "Krisp may remain observable as a relay participant."
        )
        let eligible = CallAudioAutomaticAdmission.eligibleInputGroups(
            from: [chatGPT, krisp],
            excludedBundleIDs: []
        )
        XCTAssertEqual(eligible, [chatGPT])
        XCTAssertEqual(
            CallAudioAutomaticAdmission.preferredGroup(from: [chatGPT, krisp]),
            chatGPT,
            "Krisp cannot name the Call even when it exposes two-sided audio."
        )
        XCTAssertNil(CallAudioAutomaticAdmission.preferredGroup(from: [krisp]))
        XCTAssertEqual(
            CallAudioAutomaticAdmission.eligibleInputGroups(
                from: [chatGPT],
                excludedBundleIDs: ["com.openai.codex.helper"]
            ),
            [chatGPT],
            "A similar prefix must not exclude the exact app."
        )
        XCTAssertEqual(
            CallAudioAutomaticAdmission.preferredGroup(
                from: [chatGPT, krisp],
                retaining: CallAudioOwnerKey(group: chatGPT)
            ),
            chatGPT
        )
        let restartedChatGPTHelper = CallAudioApplicationGroup(
            rootPID: 999,
            ownerBundleID: "com.openai.codex",
            ownerKind: .generic,
            inputActive: true,
            outputActive: false,
            memberCount: 1,
            inputAudioObjectIDs: [999],
            outputAudioObjectIDs: []
        )
        XCTAssertEqual(
            CallAudioOwnerKey(group: chatGPT),
            CallAudioOwnerKey(group: restartedChatGPTHelper),
            "A helper/PID restart must stay inside the same suppression identity."
        )
    }

    func testKrispAloneAndExcludedHandyPlusKrispProduceNoCallCandidate() {
        let krisp = CallAudioApplicationGroup(
            rootPID: 20,
            ownerBundleID: "ai.krisp.krispMac",
            ownerKind: .generic,
            inputActive: true,
            outputActive: false,
            memberCount: 1,
            inputAudioObjectIDs: [20],
            outputAudioObjectIDs: []
        )
        let handy = CallAudioApplicationGroup(
            rootPID: 10,
            ownerBundleID: "com.pais.handy",
            ownerKind: .generic,
            inputActive: true,
            outputActive: false,
            memberCount: 1,
            inputAudioObjectIDs: [10],
            outputAudioObjectIDs: []
        )

        XCTAssertEqual(
            CallAudioAutomaticAdmission.participatingInputGroups(
                from: [krisp],
                excludedBundleIDs: []
            ),
            [krisp]
        )
        XCTAssertTrue(
            CallAudioAutomaticAdmission.eligibleInputGroups(
                from: [krisp],
                excludedBundleIDs: []
            ).isEmpty,
            "Krisp alone is relay activity, not a Call."
        )
        XCTAssertEqual(
            CallAudioAutomaticAdmission.eligibleInputGroups(
                from: [handy, krisp],
                excludedBundleIDs: ["com.pais.handy"]
            ).count,
            0,
            "An excluded Handy pulse plus Krisp relay activity must not open a Call."
        )
    }

    func testSiblingHelpersAggregateIntoOneBrowserAudioGroup() {
        let samples = [
            sample(pid: 101, rootPID: 10, input: true, output: false),
            sample(pid: 102, rootPID: 10, input: false, output: true),
            sample(pid: 101, rootPID: 10, input: true, output: false),
        ]

        XCTAssertEqual(
            CallAudioProcessGrouping.groups(from: samples),
            [
                CallAudioApplicationGroup(
                    rootPID: 10,
                    ownerBundleID: "com.google.Chrome",
                    ownerKind: .browser,
                    inputActive: true,
                    outputActive: true,
                    memberCount: 2,
                    inputAudioObjectIDs: [101],
                    outputAudioObjectIDs: [102]
                ),
            ]
        )
    }

    func testSeparateBrowserRootsNeverShareTwoSidedEvidence() {
        let samples = [
            sample(pid: 101, rootPID: 10, input: true, output: false),
            sample(pid: 201, rootPID: 20, input: false, output: true),
        ]

        let groups = CallAudioProcessGrouping.groups(from: samples)

        XCTAssertEqual(groups.count, 2)
        XCTAssertFalse(groups.contains(where: { $0.inputActive && $0.outputActive }))
    }

    func testInactiveAndDuplicateSamplesDoNotInflateMembership() {
        let samples = [
            sample(pid: 101, rootPID: 10, input: false, output: false),
            sample(pid: 102, rootPID: 10, input: true, output: false),
            sample(pid: 102, rootPID: 10, input: true, output: false),
        ]

        let groups = CallAudioProcessGrouping.groups(from: samples)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].memberCount, 1)
        XCTAssertTrue(groups[0].inputActive)
        XCTAssertFalse(groups[0].outputActive)
    }

    func testGroupingKeepsNativeAndBrowserOwnersDistinct() {
        let samples = [
            sample(pid: 101, rootPID: 10, input: true, output: true),
            CallAudioProcessSample(
                audioObjectID: 301,
                pid: 301,
                rootPID: 30,
                ownerBundleID: "us.zoom.xos",
                ownerKind: .native,
                inputActive: true,
                outputActive: false
            ),
        ]

        let groups = CallAudioProcessGrouping.groups(from: samples)

        XCTAssertEqual(groups.map(\.ownerKind), [.browser, .native])
        XCTAssertEqual(groups.map(\.ownerBundleID), ["com.google.Chrome", "us.zoom.xos"])
    }

    func testActiveAudioContinuesAndClearsAnyMissingWindow() {
        XCTAssertEqual(
            CallAudioSessionLiveness.decide(
                hasRequiredAudio: true,
                missingSince: 100,
                now: 130,
                maximumMissingRetention: 60
            ),
            .continueActive
        )
    }

    func testRecoverableSessionKeepsOriginalMissingTimestampWithinBound() {
        XCTAssertEqual(
            CallAudioSessionLiveness.decide(
                hasRequiredAudio: false,
                missingSince: nil,
                now: 100,
                maximumMissingRetention: 60
            ),
            .retainMissing(since: 100)
        )
        XCTAssertEqual(
            CallAudioSessionLiveness.decide(
                hasRequiredAudio: false,
                missingSince: 100,
                now: 160,
                maximumMissingRetention: 60
            ),
            .retainMissing(since: 100)
        )
    }

    func testRecoverableSessionReleasesAfterBound() {
        XCTAssertEqual(
            CallAudioSessionLiveness.decide(
                hasRequiredAudio: false,
                missingSince: 100,
                now: 160.001,
                maximumMissingRetention: 60
            ),
            .release
        )
    }

    func testRejectedSurfaceSurvivesRouteGapButDifferentSurfaceIsEligible() {
        let rejectedA = CallDetectorFingerprint.makeSurfaceKey(
            bundleID: "com.google.Chrome",
            rootPID: 10,
            surfaceDiscriminator: "meet-a",
            originHost: "meet.google.com"
        )
        let eligibleB = CallDetectorFingerprint.makeSurfaceKey(
            bundleID: "com.microsoft.edgemac",
            rootPID: 20,
            surfaceDiscriminator: "teams-b",
            originHost: "teams.microsoft.com"
        )
        let suppressed = Set([rejectedA])

        XCTAssertFalse(
            CallSurfaceSuppressionPolicy.allows(
                candidateSurfaceKey: rejectedA,
                suppressedSurfaceKeys: suppressed
            )
        )
        XCTAssertTrue(
            CallSurfaceSuppressionPolicy.allows(
                candidateSurfaceKey: eligibleB,
                suppressedSurfaceKeys: suppressed
            ),
            "Rejecting A must not occupy the active slot or block eligible B."
        )

        XCTAssertFalse(
            CallSurfaceSuppressionPolicy.shouldRelease(
                rootApplicationRunning: true
            ),
            "An eight-second device switch cannot re-arm the same surface."
        )
        XCTAssertFalse(
            CallSurfaceSuppressionPolicy.shouldRelease(
                rootApplicationRunning: true
            ),
            "Elapsed audio absence alone must never re-arm the same rejected surface."
        )
        XCTAssertTrue(
            CallSurfaceSuppressionPolicy.shouldRelease(
                rootApplicationRunning: false
            ),
            "A terminated root process is full disappearance."
        )
    }

    func testFailedSurfaceRefreshCannotBeMaskedByAssistantMicAndPlayback() {
        let failedRefresh = CallSurfaceContinuity.decide(
            hasRequiredAudio: true,
            previouslyConfirmed: true,
            latestSurfaceMatch: false
        )
        XCTAssertEqual(
            failedRefresh,
            CallSurfaceContinuityDecision(
                surfaceConfirmed: false,
                hasRequiredEvidence: false
            )
        )

        let betweenProbes = CallSurfaceContinuity.decide(
            hasRequiredAudio: true,
            previouslyConfirmed: failedRefresh.surfaceConfirmed,
            latestSurfaceMatch: nil
        )
        XCTAssertFalse(
            betweenProbes.hasRequiredEvidence,
            "Two-sided browser audio must not revive a surface that AX no longer confirms."
        )

        let recoveredSurface = CallSurfaceContinuity.decide(
            hasRequiredAudio: true,
            previouslyConfirmed: betweenProbes.surfaceConfirmed,
            latestSurfaceMatch: true
        )
        XCTAssertTrue(recoveredSurface.hasRequiredEvidence)
    }

    func testBackgroundTabNoMatchPreservesSameCoreAudioSession() {
        XCTAssertNil(
            BrowserSurfaceRevalidation.latestSurfaceMatch(
                trustedSurfaceFound: false,
                sameSurface: false,
                authoritativeNoMatch: true,
                audioSessionIdentityChanged: false
            )
        )
    }

    func testAuthoritativeNoMatchRejectsReplacementCoreAudioSession() {
        XCTAssertEqual(
            BrowserSurfaceRevalidation.latestSurfaceMatch(
                trustedSurfaceFound: false,
                sameSurface: false,
                authoritativeNoMatch: true,
                audioSessionIdentityChanged: true
            ),
            false
        )
    }

    func testInvalidatedRetainedControlRequiresAudioBoundaryForTrustLoss() {
        XCTAssertFalse(
            BrowserSurfaceRevalidation.startsBoundedTrustLoss(
                retainedControlState: .invalidated,
                trustedSurfaceFound: false,
                authoritativeNoMatch: true,
                audioSessionIdentityChanged: false
            ),
            "A background tab/root rebuild cannot end a call while the same carriers survive."
        )
        XCTAssertTrue(
            BrowserSurfaceRevalidation.startsBoundedTrustLoss(
                retainedControlState: .invalidated,
                trustedSurfaceFound: false,
                authoritativeNoMatch: true,
                audioSessionIdentityChanged: true
            )
        )
        XCTAssertTrue(
            BrowserSurfaceRevalidation.startsBoundedTrustLoss(
                retainedControlState: .invalidated,
                trustedSurfaceFound: true,
                authoritativeNoMatch: false,
                audioSessionIdentityChanged: true
            )
        )
    }

    func testUnknownOrMissingRetainedControlStartsBoundedTrustLossWithSameCarriers() {
        for state in [
            BrowserCallControlState?.none,
            BrowserCallControlState?.some(.unknown),
        ] {
            XCTAssertTrue(
                BrowserSurfaceRevalidation.startsBoundedTrustLoss(
                    retainedControlState: state,
                    trustedSurfaceFound: false,
                    authoritativeNoMatch: false,
                    audioSessionIdentityChanged: false
                ),
                "A missing capability or true AX read failure must start the 12-second bound."
            )
        }
    }

    func testInvalidatedControlPlusFailedFullScanStartsBoundWithSameCarriers() {
        XCTAssertTrue(
            BrowserSurfaceRevalidation.startsBoundedTrustLoss(
                retainedControlState: .invalidated,
                trustedSurfaceFound: false,
                authoritativeNoMatch: false,
                audioSessionIdentityChanged: false
            ),
            "A timed-out/failed full AX scan must not let assistant audio record forever."
        )
    }

    func testBackgroundAmbiguityWithoutInvalidatedControlDoesNotStartTrustLoss() {
        for state in [
            BrowserCallControlState.active,
            .rebound,
            .ended,
            .replaced,
        ] {
            XCTAssertFalse(
                BrowserSurfaceRevalidation.startsBoundedTrustLoss(
                    retainedControlState: state,
                    trustedSurfaceFound: false,
                    authoritativeNoMatch: true,
                    audioSessionIdentityChanged: true
                )
            )
        }
    }

    func testUnrelatedSiblingAudioObjectDoesNotReplaceBackgroundCallSession() {
        XCTAssertFalse(
            BrowserSurfaceRevalidation.baselineAudioSessionWasReplaced(
                baselineInput: [10],
                baselineOutput: [11],
                currentInput: [10],
                currentOutput: [11, 12]
            )
        )
        XCTAssertTrue(
            BrowserSurfaceRevalidation.baselineAudioSessionWasReplaced(
                baselineInput: [10],
                baselineOutput: [11],
                currentInput: [20],
                currentOutput: [11, 12]
            )
        )
        XCTAssertFalse(
            BrowserSurfaceRevalidation.baselineAudioSessionWasReplaced(
                baselineInput: [10, 13],
                baselineOutput: [11, 14],
                currentInput: [10],
                currentOutput: [11]
            ),
            "A sibling object disappearing cannot prove that the call carrier disappeared."
        )
    }

    func testFullCarrierReplacementRequiresBothSidesAndDoesNotSplitMicSwitch() {
        XCTAssertFalse(
            BrowserSurfaceRevalidation.baselineAudioSessionWasFullyReplaced(
                baselineInput: [1],
                baselineOutput: [2],
                currentInput: [3],
                currentOutput: [2]
            )
        )
        XCTAssertFalse(
            BrowserSurfaceRevalidation.baselineAudioSessionWasFullyReplaced(
                baselineInput: [1],
                baselineOutput: [2],
                currentInput: [1],
                currentOutput: [4]
            )
        )
        XCTAssertTrue(
            BrowserSurfaceRevalidation.baselineAudioSessionWasFullyReplaced(
                baselineInput: [1],
                baselineOutput: [2],
                currentInput: [3],
                currentOutput: [4]
            )
        )
    }

    func testRetainedRootLifecycleKeepsRebuildButEndsSuccessorAndExactEnd() {
        XCTAssertEqual(
            BrowserControlLifecycle.activeMatch(
                state: .rebound,
                audioCarriersFullyReplaced: false
            ),
            true
        )
        XCTAssertEqual(
            BrowserControlLifecycle.activeMatch(
                state: .rebound,
                audioCarriersFullyReplaced: true
            ),
            false
        )
        XCTAssertEqual(
            BrowserControlLifecycle.activeMatch(
                state: .ended,
                audioCarriersFullyReplaced: false
            ),
            false
        )
        XCTAssertEqual(
            BrowserControlLifecycle.activeMatch(
                state: .replaced,
                audioCarriersFullyReplaced: false
            ),
            false
        )
        XCTAssertNil(
            BrowserControlLifecycle.activeMatch(
                state: .invalidated,
                audioCarriersFullyReplaced: false
            )
        )
        XCTAssertNil(
            BrowserControlLifecycle.activeMatch(
                state: .unknown,
                audioCarriersFullyReplaced: false
            )
        )
    }

    func testFullCarrierReplacementRetiresSuccessorBeforeSecondActivePollCanReviveA() {
        XCTAssertTrue(
            BrowserControlLifecycle.establishesSuccessorBoundary(
                state: .rebound,
                audioCarriersFullyReplaced: true
            )
        )
        XCTAssertTrue(
            BrowserControlLifecycle.establishesSuccessorBoundary(
                state: .active,
                audioCarriersFullyReplaced: true
            ),
            "A Chromium SPA may reuse the same hard control for a successor call."
        )
        XCTAssertTrue(
            BrowserControlLifecycle.establishesSuccessorBoundary(
                state: .unknown,
                audioCarriersFullyReplaced: true
            ),
            "AX throttling or uncertainty must not publish B's carriers under A."
        )

        var retainedFingerprint: String? = "call-a"
        for state in [BrowserCallControlState.rebound, .active] {
            guard retainedFingerprint != nil else { continue }
            if BrowserControlLifecycle.establishesSuccessorBoundary(
                state: state,
                audioCarriersFullyReplaced: true
            ) {
                retainedFingerprint = nil
            }
        }
        XCTAssertNil(
            retainedFingerprint,
            "Poll two must not apply `.active` to the fingerprint retired on poll one."
        )
    }

    func testFullCarrierReplacementForbidsCrossRootAdoptionOfSameDiscriminator() {
        XCTAssertTrue(
            BrowserControlLifecycle.permitsCrossRootAdoption(
                identityMatches: true,
                audioCarriersFullyReplaced: false
            )
        )
        XCTAssertFalse(
            BrowserControlLifecycle.permitsCrossRootAdoption(
                identityMatches: true,
                audioCarriersFullyReplaced: true
            )
        )
        XCTAssertFalse(
            BrowserControlLifecycle.permitsCrossRootAdoption(
                identityMatches: false,
                audioCarriersFullyReplaced: false
            )
        )
    }

    func testSuppressionUsesAudioTombstoneOnlyForAmbiguousControlLoss() {
        XCTAssertFalse(
            BrowserControlLifecycle.shouldReleaseSuppression(
                state: .rebound,
                audioCarriersFullyReplaced: false,
                allowsDocumentReplacementRelease: true
            )
        )
        XCTAssertTrue(
            BrowserControlLifecycle.shouldReleaseSuppression(
                state: .rebound,
                audioCarriersFullyReplaced: true,
                allowsDocumentReplacementRelease: true
            )
        )
        XCTAssertFalse(
            BrowserControlLifecycle.shouldReleaseSuppression(
                state: .ended,
                audioCarriersFullyReplaced: false,
                allowsDocumentReplacementRelease: true
            )
        )
        XCTAssertTrue(
            BrowserControlLifecycle.shouldReleaseSuppression(
                state: .ended,
                audioCarriersFullyReplaced: true,
                allowsDocumentReplacementRelease: true
            )
        )
        XCTAssertTrue(
            BrowserControlLifecycle.shouldReleaseSuppression(
                state: .replaced,
                audioCarriersFullyReplaced: false,
                allowsDocumentReplacementRelease: true
            ),
            "An explicit document/session replacement is a collision-safe end boundary."
        )
        XCTAssertFalse(
            BrowserControlLifecycle.shouldReleaseSuppression(
                state: .replaced,
                audioCarriersFullyReplaced: false,
                allowsDocumentReplacementRelease: false
            ),
            "Generic Teams routes must retain a fail-closed tombstone across SPA replacement."
        )
        XCTAssertTrue(
            BrowserControlLifecycle.shouldReleaseSuppression(
                state: .replaced,
                audioCarriersFullyReplaced: true,
                allowsDocumentReplacementRelease: false
            ),
            "A complete input/output carrier boundary can release a generic Teams tombstone."
        )
        XCTAssertTrue(
            BrowserControlLifecycle.shouldDetachSuppressedCapability(state: .ended)
        )
        XCTAssertTrue(
            BrowserControlLifecycle.shouldDetachSuppressedCapability(state: .invalidated)
        )
        XCTAssertFalse(
            BrowserControlLifecycle.shouldDetachSuppressedCapability(state: .unknown),
            "AX uncertainty must retain the exact rejected capability."
        )
        XCTAssertTrue(BrowserControlLifecycle.needsAudioIdentityFallback(state: .invalidated))
        XCTAssertTrue(BrowserControlLifecycle.needsAudioIdentityFallback(state: .unknown))
        XCTAssertFalse(BrowserControlLifecycle.needsAudioIdentityFallback(state: .active))
    }

    func testSuppressedRootReplacementRequiresSameOpaquePageIdentity() {
        XCTAssertTrue(
            BrowserSurfaceIdentity.matches(
                expectedService: .googleMeet,
                expectedDiscriminator: "hash-a",
                expectedAllowsCrossRootReconciliation: true,
                observedService: .googleMeet,
                observedDiscriminator: "hash-a",
                observedAllowsCrossRootReconciliation: true
            )
        )
        XCTAssertFalse(
            BrowserSurfaceIdentity.matches(
                expectedService: .googleMeet,
                expectedDiscriminator: "hash-a",
                expectedAllowsCrossRootReconciliation: true,
                observedService: .googleMeet,
                observedDiscriminator: "hash-b",
                observedAllowsCrossRootReconciliation: true
            )
        )
        XCTAssertFalse(
            BrowserSurfaceIdentity.matches(
                expectedService: .googleMeet,
                expectedDiscriminator: "hash-a",
                expectedAllowsCrossRootReconciliation: true,
                observedService: .microsoftTeams,
                observedDiscriminator: "hash-a",
                observedAllowsCrossRootReconciliation: true
            )
        )
        XCTAssertFalse(
            BrowserSurfaceIdentity.matches(
                expectedService: .microsoftTeams,
                expectedDiscriminator: "generic-v2",
                expectedAllowsCrossRootReconciliation: false,
                observedService: .microsoftTeams,
                observedDiscriminator: "generic-v2",
                observedAllowsCrossRootReconciliation: false
            )
        )
    }

    func testSuppressionHasNoTimeBasedAudioExpiry() {
        XCTAssertFalse(
            CallSurfaceSuppressionPolicy.shouldRelease(rootApplicationRunning: true)
        )
        XCTAssertTrue(
            CallSurfaceSuppressionPolicy.shouldRelease(rootApplicationRunning: false)
        )
    }

    func testDetachedSurfaceTombstoneRequiresStableFullAudioDisappearance() {
        XCTAssertEqual(
            DetachedSuppressionBoundary.decide(
                boundaryAbsent: false,
                boundarySince: nil,
                now: 100
            ),
            .retain(authoritativeEndSince: nil)
        )
        XCTAssertEqual(
            DetachedSuppressionBoundary.decide(
                boundaryAbsent: true,
                boundarySince: nil,
                now: 102
            ),
            .retain(authoritativeEndSince: 102)
        )
        XCTAssertEqual(
            DetachedSuppressionBoundary.decide(
                boundaryAbsent: false,
                boundarySince: 102,
                now: 104
            ),
            .retain(authoritativeEndSince: nil),
            "A partial carrier return resets the full-disappearance proof."
        )
        XCTAssertEqual(
            DetachedSuppressionBoundary.decide(
                boundaryAbsent: true,
                boundarySince: nil,
                now: 106
            ),
            .retain(authoritativeEndSince: 106)
        )
        XCTAssertEqual(
            DetachedSuppressionBoundary.decide(
                boundaryAbsent: true,
                boundarySince: 106,
                now: 110
            ),
            .release
        )
    }

    func testAutomaticTimeoutReleasesSameAppForImmediateBackToBackCall() {
        XCTAssertNil(
            CallAudioOwnerSuppressionBoundary.stateWhenSuppressing(
                fingerprint: "call-a",
                alreadyIdleSince: 100,
                now: 130
            ),
            "Thirty seconds of proven idle must not tombstone the same app's next Call."
        )
    }

    func testKrispRelayNeverEntersTheCallSuppressionIdentity() {
        let chatGPT = CallAudioOwnerKey(
            group: CallAudioApplicationGroup(
                rootPID: 10,
                ownerBundleID: "com.openai.codex",
                ownerKind: .generic,
                inputActive: false,
                outputActive: false,
                memberCount: 1,
                inputAudioObjectIDs: [],
                outputAudioObjectIDs: []
            )
        )
        let krisp = CallAudioApplicationGroup(
            rootPID: 11,
            ownerBundleID: "ai.krisp.krispMac",
            ownerKind: .generic,
            inputActive: true,
            outputActive: false,
            memberCount: 1,
            inputAudioObjectIDs: [11],
            outputAudioObjectIDs: []
        )
        let chatGPTGroup = CallAudioApplicationGroup(
            rootPID: 10,
            ownerBundleID: "com.openai.codex",
            ownerKind: .generic,
            inputActive: true,
            outputActive: false,
            memberCount: 1,
            inputAudioObjectIDs: [10],
            outputAudioObjectIDs: []
        )

        let ownerKeys = Set(
            CallAudioAutomaticAdmission.eligibleInputGroups(
                from: [chatGPTGroup, krisp],
                excludedBundleIDs: []
            ).map(CallAudioOwnerKey.init)
        )
        XCTAssertEqual(ownerKeys, [chatGPT])
        XCTAssertFalse(ownerKeys.contains(CallAudioOwnerKey(group: krisp)))
    }

    func testIndependentUnknownProcessesDoNotShareOneSuppressionKey() {
        func unknownGroup(rootPID: Int32) -> CallAudioApplicationGroup {
            CallAudioApplicationGroup(
                rootPID: rootPID,
                ownerBundleID: "process:unknown",
                ownerKind: .generic,
                ownerBundleIDIsSynthetic: true,
                inputActive: true,
                outputActive: false,
                memberCount: 1,
                inputAudioObjectIDs: [UInt32(rootPID)],
                outputAudioObjectIDs: []
            )
        }

        XCTAssertNotEqual(
            CallAudioOwnerKey(group: unknownGroup(rootPID: 101)),
            CallAudioOwnerKey(group: unknownGroup(rootPID: 202)),
            "Two anonymous processes must not inherit each other's false-call tombstone."
        )
    }

    func testDetachedBrowserTombstoneReleasesImmediatelyForFreshTwoSidedReplacement() {
        XCTAssertEqual(
            DetachedSuppressionBoundary.decide(
                freshTwoSidedReplacement: true,
                boundaryAbsent: false,
                boundarySince: nil,
                now: 100
            ),
            .release,
            "A complete fresh input+output carrier pair is an authoritative successor boundary."
        )
    }

    func testNativeMuteWithContinuingOutputIsNotAnAudioBoundary() {
        XCTAssertFalse(
            NativeSuppressionAudioBoundary.isAbsent(
                inputActive: false,
                outputActive: true
            )
        )
        XCTAssertFalse(
            NativeSuppressionAudioBoundary.isAbsent(
                inputActive: true,
                outputActive: false
            )
        )
        XCTAssertTrue(
            NativeSuppressionAudioBoundary.isAbsent(
                inputActive: false,
                outputActive: false
            )
        )
    }

    func testNativeSuccessorRequiresAuthoritativeEndedWindowAndAbsentInput() {
        XCTAssertFalse(
            NativeSurfaceLifecycle.allowsSuccessor(suppressedSessionCount: 1),
            "A distinct native window cannot bypass a still-live or not-yet-confirmed tombstone."
        )
        XCTAssertTrue(
            NativeSurfaceLifecycle.allowsSuccessor(suppressedSessionCount: 0)
        )
        XCTAssertEqual(
            NativeSurfaceLifecycle.suppressionBoundary(
                state: .ended,
                inputActive: false,
                authoritativeEndSince: nil,
                now: 100
            ),
            .retain(authoritativeEndSince: 100)
        )
        XCTAssertEqual(
            NativeSurfaceLifecycle.suppressionBoundary(
                state: .ended,
                inputActive: false,
                authoritativeEndSince: 100,
                now: 104
            ),
            .release
        )
        XCTAssertEqual(
            NativeSurfaceLifecycle.suppressionBoundary(
                state: .ended,
                inputActive: true,
                authoritativeEndSince: 100,
                now: 110
            ),
            .release,
            "A new input owner cannot erase a stable authoritative end on the exact old root."
        )
        XCTAssertEqual(
            NativeSurfaceLifecycle.suppressionBoundary(
                state: .unknown,
                inputActive: false,
                authoritativeEndSince: 196,
                now: 200
            ),
            .retain(authoritativeEndSince: nil)
        )
        XCTAssertEqual(
            NativeSurfaceLifecycle.suppressionBoundary(
                state: .obscured,
                inputActive: true,
                authoritativeEndSince: 196,
                now: 220
            ),
            .retain(authoritativeEndSince: nil),
            "A minimized window or temporarily hidden hard control is known continuity."
        )
        XCTAssertEqual(
            NativeSurfaceLifecycle.suppressionBoundary(
                state: .invalidated,
                inputActive: false,
                authoritativeEndSince: nil,
                now: 200
            ),
            .retain(authoritativeEndSince: nil)
        )
        XCTAssertEqual(
            NativeSurfaceLifecycle.suppressionBoundary(
                state: .ended,
                inputActive: false,
                authoritativeEndSince: nil,
                now: 202
            ),
            .retain(authoritativeEndSince: 202),
            "An unknown poll must reset, not contribute to, the authoritative-end streak."
        )
    }

    func testInvalidatedNativeWindowCannotRebindSuccessorUnderOldFingerprint() {
        XCTAssertEqual(
            NativeSurfaceLifecycle.invalidatedSurfaceMatch(
                replacementHasCallSignature: true,
                authoritativeNoMatch: false
            ),
            false,
            "A different hard-control window is a call boundary, not continuity."
        )
        XCTAssertEqual(
            NativeSurfaceLifecycle.invalidatedSurfaceMatch(
                replacementHasCallSignature: false,
                authoritativeNoMatch: true
            ),
            false
        )
        XCTAssertNil(
            NativeSurfaceLifecycle.invalidatedSurfaceMatch(
                replacementHasCallSignature: false,
                authoritativeNoMatch: false
            ),
            "An AX read failure remains bounded unknown."
        )
    }

    func testAXFailureCannotContradictConfirmedBackgroundSession() {
        XCTAssertNil(
            BrowserSurfaceRevalidation.latestSurfaceMatch(
                trustedSurfaceFound: false,
                sameSurface: false,
                authoritativeNoMatch: false,
                audioSessionIdentityChanged: true
            )
        )
    }

    private func sample(
        pid: Int32,
        rootPID: Int32,
        input: Bool,
        output: Bool
    ) -> CallAudioProcessSample {
        CallAudioProcessSample(
            audioObjectID: UInt32(bitPattern: pid),
            pid: pid,
            rootPID: rootPID,
            ownerBundleID: "com.google.Chrome",
            ownerKind: .browser,
            inputActive: input,
            outputActive: output
        )
    }
}
