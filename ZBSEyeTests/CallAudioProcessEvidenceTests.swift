import XCTest

final class CallAudioProcessEvidenceTests: XCTestCase {
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
                kind: .browser
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
    }

    func testUnsupportedBrowserHelperDoesNotBecomeOwner() {
        XCTAssertNil(
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
            )
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
