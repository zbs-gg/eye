import XCTest

final class CaptureHealthReducerTests: XCTestCase {
    private let baseline = CaptureContext(
        displayID: "display-1",
        frontmostBundleID: "com.example.editor",
        focusedWindowID: "window-a",
        axRevision: 10,
        inputRevision: 20
    )

    func testRequestedLegsStartBlockedUntilPermissionIsGranted() {
        let intent = CaptureIntent(screenEnabled: true, systemAudioEnabled: true)
        let denied = CaptureHealthReducer(
            nowMs: 0,
            intent: intent,
            permissions: [.screen: .denied, .systemAudio: .denied]
        )
        let unknown = CaptureHealthReducer(
            nowMs: 0,
            intent: intent,
            permissions: [.screen: .unknown, .systemAudio: .unknown]
        )

        XCTAssertEqual(denied.snapshot.aggregate, .permissionBlocked)
        XCTAssertEqual(denied.snapshot.legs[.screen]?.state, .permissionBlocked)
        XCTAssertEqual(unknown.snapshot.aggregate, .permissionBlocked)
        XCTAssertEqual(unknown.snapshot.legs[.systemAudio]?.reason, .permissionMissing)
    }

    func testStaticAndIntentionalObservationsNeverBecomeStale() {
        var reducer = CaptureHealthReducer(nowMs: 0)
        _ = reducer.reduce(
            .observation(.init(
                leg: .screen,
                generation: 0,
                kind: .verifiedProgress,
                fingerprint: "same",
                context: baseline
            )),
            at: 1
        )

        let intentionalReasons: [CaptureHealthReason] = [
            .staticDuplicate,
            .userIdle,
            .privacyExcluded,
            .selfAppExcluded,
            .systemAudioDisabled,
        ]
        for (offset, reason) in intentionalReasons.enumerated() {
            let effects = reducer.reduce(
                .observation(.init(
                    leg: reason == .systemAudioDisabled ? .systemAudio : .screen,
                    generation: 0,
                    kind: .intentional(reason),
                    fingerprint: "same",
                    context: baseline
                )),
                at: Int64(offset + 2)
            )
            XCTAssertTrue(effects.isEmpty)
        }

        XCTAssertEqual(reducer.snapshot.aggregate, .healthy)
        XCTAssertEqual(reducer.snapshot.legs[.screen]?.state, .healthy)
    }

    func testStrongContextChangeNeedsThreeUnchangedObservationsAndOpensOnce() throws {
        var reducer = CaptureHealthReducer(nowMs: 0)
        _ = reducer.reduce(.observation(.progress(
            leg: .screen,
            generation: 0,
            fingerprint: "old",
            context: baseline
        )), at: 1)

        let changed = CaptureContext(
            displayID: "display-1",
            frontmostBundleID: "com.example.browser",
            focusedWindowID: "window-b",
            axRevision: 10,
            inputRevision: 20
        )
        XCTAssertTrue(reducer.reduce(.observation(.unchanged(
            leg: .screen, generation: 0, fingerprint: "old", context: changed
        )), at: 2).isEmpty)
        XCTAssertTrue(reducer.reduce(.observation(.unchanged(
            leg: .screen, generation: 0, fingerprint: "old", context: changed
        )), at: 3).isEmpty)

        let effects = reducer.reduce(.observation(.unchanged(
            leg: .screen, generation: 0, fingerprint: "old", context: changed
        )), at: 4)
        let open = try XCTUnwrap(effects.compactMap(\.coverageOpen).first)
        XCTAssertEqual(open.leg, .screen)
        XCTAssertEqual(open.reason, .screenProgressUnverified)
        XCTAssertEqual(open.startMs, 2, "the interval starts at the first contradicted expectation")

        XCTAssertTrue(reducer.reduce(.observation(.unchanged(
            leg: .screen, generation: 0, fingerprint: "old", context: changed
        )), at: 5).isEmpty, "one stale episode must open exactly once")
    }

    func testWeakContextNeedsBothAXAndInputChange() throws {
        var reducer = CaptureHealthReducer(nowMs: 0)
        _ = reducer.reduce(.observation(.progress(
            leg: .screen, generation: 0, fingerprint: "old", context: baseline
        )), at: 1)

        let onlyAX = CaptureContext(
            displayID: baseline.displayID,
            frontmostBundleID: baseline.frontmostBundleID,
            focusedWindowID: baseline.focusedWindowID,
            axRevision: 11,
            inputRevision: 20
        )
        for now in 2...5 {
            XCTAssertTrue(reducer.reduce(.observation(.unchanged(
                leg: .screen, generation: 0, fingerprint: "old", context: onlyAX
            )), at: Int64(now)).isEmpty)
        }

        let paired = CaptureContext(
            displayID: baseline.displayID,
            frontmostBundleID: baseline.frontmostBundleID,
            focusedWindowID: baseline.focusedWindowID,
            axRevision: 11,
            inputRevision: 21
        )
        _ = reducer.reduce(.observation(.unchanged(
            leg: .screen, generation: 0, fingerprint: "old", context: paired
        )), at: 6)
        _ = reducer.reduce(.observation(.unchanged(
            leg: .screen, generation: 0, fingerprint: "old", context: paired
        )), at: 7)
        let effects = reducer.reduce(.observation(.unchanged(
            leg: .screen, generation: 0, fingerprint: "old", context: paired
        )), at: 8)
        XCTAssertNotNil(effects.compactMap(\.coverageOpen).first)
    }

    func testFailureAndStaleOriginsUseDifferentRecoveryProof() throws {
        var failure = CaptureHealthReducer(nowMs: 0)
        let failureOpen = try XCTUnwrap(failure.reduce(
            .observation(.failure(leg: .screen, generation: 0, reason: .screenRequestFailed)),
            at: 10
        ).compactMap(\.coverageOpen).first)
        let failureAttempt = failure.reduce(.coverageOpened(failureOpen), at: 11)
        XCTAssertEqual(failureAttempt.compactMap(\.recoveryAttempt).first?.delayMs, 1_000)
        let failureClose = failure.reduce(.observation(.progress(
            leg: .screen,
            generation: failureOpen.generation,
            fingerprint: "same",
            context: baseline
        )), at: 12)
        XCTAssertNotNil(failureClose.compactMap(\.coverageClose).first)
        XCTAssertEqual(failure.snapshot.aggregate, .recovering, "green waits for durable close acknowledgement")

        var stale = CaptureHealthReducer(nowMs: 0)
        _ = stale.reduce(.observation(.progress(
            leg: .screen, generation: 0, fingerprint: "old", context: baseline
        )), at: 1)
        let changed = CaptureContext(
            displayID: "display-2",
            frontmostBundleID: baseline.frontmostBundleID,
            focusedWindowID: baseline.focusedWindowID,
            axRevision: baseline.axRevision,
            inputRevision: baseline.inputRevision
        )
        for now in 2...3 {
            _ = stale.reduce(.observation(.unchanged(
                leg: .screen, generation: 0, fingerprint: "old", context: changed
            )), at: Int64(now))
        }
        let staleOpen = try XCTUnwrap(stale.reduce(.observation(.unchanged(
            leg: .screen, generation: 0, fingerprint: "old", context: changed
        )), at: 4).compactMap(\.coverageOpen).first)
        _ = stale.reduce(.coverageOpened(staleOpen), at: 5)
        XCTAssertEqual(stale.reduce(.observation(.progress(
            leg: .screen,
            generation: staleOpen.generation,
            fingerprint: "old",
            context: changed
        )), at: 6).compactMap(\.recoveryAttempt).first?.attempt, 2)
        XCTAssertNotNil(stale.reduce(.observation(.progress(
            leg: .screen,
            generation: staleOpen.generation,
            fingerprint: "new",
            context: changed
        )), at: 7).compactMap(\.coverageClose).first)
    }

    func testRetryScheduleIsBoundedAndEndsRepairRequired() throws {
        var reducer = CaptureHealthReducer(nowMs: 0)
        let open = try XCTUnwrap(reducer.reduce(
            .observation(.failure(leg: .screen, generation: 0, reason: .screenRequestFailed)),
            at: 10
        ).compactMap(\.coverageOpen).first)

        XCTAssertEqual(
            reducer.reduce(.coverageOpened(open), at: 11).compactMap(\.recoveryAttempt).first,
            .init(leg: .screen, generation: open.generation, attempt: 1, delayMs: 1_000)
        )
        XCTAssertEqual(
            reducer.reduce(.recoveryAttemptFailed(
                leg: .screen, generation: open.generation, reason: .screenRequestFailed
            ), at: 12).compactMap(\.recoveryAttempt).first?.delayMs,
            3_000
        )
        XCTAssertEqual(
            reducer.reduce(.recoveryAttemptFailed(
                leg: .screen, generation: open.generation, reason: .screenRequestFailed
            ), at: 13).compactMap(\.recoveryAttempt).first?.delayMs,
            10_000
        )
        XCTAssertTrue(reducer.reduce(.recoveryAttemptFailed(
            leg: .screen, generation: open.generation, reason: .screenRequestFailed
        ), at: 14).isEmpty)
        XCTAssertEqual(reducer.snapshot.aggregate, .repairRequired)
        XCTAssertEqual(reducer.snapshot.legs[.screen]?.attempt, 3)
    }

    func testRepeatedUnchangedStaleRecoveryFramesExhaustRetryBudget() throws {
        var reducer = CaptureHealthReducer(nowMs: 0)
        _ = reducer.reduce(.observation(.progress(
            leg: .screen, generation: 0, fingerprint: "old", context: baseline
        )), at: 1)
        let changed = CaptureContext(
            displayID: "display-2",
            frontmostBundleID: baseline.frontmostBundleID,
            focusedWindowID: baseline.focusedWindowID,
            axRevision: baseline.axRevision,
            inputRevision: baseline.inputRevision
        )
        _ = reducer.reduce(.observation(.unchanged(
            leg: .screen, generation: 0, fingerprint: "old", context: changed
        )), at: 2)
        _ = reducer.reduce(.observation(.unchanged(
            leg: .screen, generation: 0, fingerprint: "old", context: changed
        )), at: 3)
        let open = try XCTUnwrap(reducer.reduce(.observation(.unchanged(
            leg: .screen, generation: 0, fingerprint: "old", context: changed
        )), at: 4).compactMap(\.coverageOpen).first)
        _ = reducer.reduce(.coverageOpened(open), at: 5)

        for now in 6...8 {
            _ = reducer.reduce(.observation(.progress(
                leg: .screen,
                generation: open.generation,
                fingerprint: "old",
                context: changed
            )), at: Int64(now))
        }

        XCTAssertEqual(reducer.snapshot.aggregate, .repairRequired)
        XCTAssertEqual(reducer.snapshot.legs[.screen]?.reason, .screenProgressUnverified)
    }

    func testPermissionCloseCannotRestoreHealthyOrInventProgress() throws {
        var reducer = CaptureHealthReducer(nowMs: 0)
        let open = try XCTUnwrap(reducer.reduce(
            .observation(.failure(leg: .screen, generation: 0, reason: .screenRequestFailed)),
            at: 1
        ).compactMap(\.coverageOpen).first)
        _ = reducer.reduce(.coverageOpened(open), at: 2)
        let close = try XCTUnwrap(reducer.reduce(
            .permissionChanged(.screen, .denied),
            at: 3
        ).compactMap(\.coverageClose).first)

        _ = reducer.reduce(.coverageClosed(close), at: 4)

        XCTAssertEqual(reducer.snapshot.aggregate, .permissionBlocked)
        XCTAssertEqual(reducer.snapshot.legs[.screen]?.state, .permissionBlocked)
        XCTAssertNil(reducer.snapshot.legs[.screen]?.lastVerifiedProgressAtMs)
    }

    func testCoveragePersistenceFailuresBecomeRepairableAndRetryExactWrite() throws {
        var reducer = CaptureHealthReducer(nowMs: 0)
        let open = try XCTUnwrap(reducer.reduce(
            .observation(.failure(leg: .screen, generation: 0, reason: .screenRequestFailed)),
            at: 1
        ).compactMap(\.coverageOpen).first)

        _ = reducer.reduce(.coverageOpenPersistenceFailed(open), at: 2)
        XCTAssertEqual(reducer.snapshot.aggregate, .repairRequired)
        XCTAssertEqual(
            reducer.reduce(.repairRequested(.screen), at: 3).compactMap(\.coverageOpen).first,
            open
        )

        _ = reducer.reduce(.coverageOpened(open), at: 4)
        let close = try XCTUnwrap(reducer.reduce(.observation(.progress(
            leg: .screen,
            generation: open.generation,
            fingerprint: "recovered",
            context: baseline
        )), at: 5).compactMap(\.coverageClose).first)
        _ = reducer.reduce(.coverageClosePersistenceFailed(close), at: 6)
        XCTAssertEqual(reducer.snapshot.aggregate, .repairRequired)
        XCTAssertFalse(reducer.repairRequiresPhysicalDrain(for: .screen))
        XCTAssertEqual(
            reducer.reduce(.repairRequested(.screen), at: 7).compactMap(\.coverageClose).first,
            close
        )
    }

    func testLateOpenPersistenceFailureHonorsCurrentGatesAndRetriesWhenTheyReopen() throws {
        enum Gate {
            case intent
            case permission
            case suspension
        }

        for gate in [Gate.intent, .permission, .suspension] {
            var reducer = CaptureHealthReducer(nowMs: 0)
            let open = try XCTUnwrap(reducer.reduce(
                .observation(.failure(
                    leg: .screen,
                    generation: 0,
                    reason: .screenRequestFailed
                )),
                at: 1
            ).compactMap(\.coverageOpen).first)

            switch gate {
            case .intent:
                _ = reducer.reduce(
                    .intentChanged(.init(screenEnabled: false, systemAudioEnabled: false)),
                    at: 2
                )
            case .permission:
                _ = reducer.reduce(.permissionChanged(.screen, .denied), at: 2)
            case .suspension:
                _ = reducer.reduce(.suspensionChanged(.locked), at: 2)
            }

            _ = reducer.reduce(.coverageOpenPersistenceFailed(open), at: 3)
            switch gate {
            case .intent:
                XCTAssertEqual(reducer.snapshot.legs[.screen]?.state, .paused)
            case .permission:
                XCTAssertEqual(reducer.snapshot.legs[.screen]?.state, .permissionBlocked)
            case .suspension:
                XCTAssertEqual(reducer.snapshot.legs[.screen]?.state, .suspended)
            }

            let effects: [CaptureHealthEffect]
            switch gate {
            case .intent:
                effects = reducer.reduce(
                    .intentChanged(.init(screenEnabled: true, systemAudioEnabled: false)),
                    at: 4
                )
            case .permission:
                effects = reducer.reduce(.permissionChanged(.screen, .granted), at: 4)
            case .suspension:
                effects = reducer.reduce(.suspensionChanged(nil), at: 4)
            }
            XCTAssertEqual(effects.compactMap(\.coverageOpen).first, open)
            XCTAssertEqual(reducer.snapshot.legs[.screen]?.state, .recovering)
        }
    }

    func testLateClosePersistenceFailureCannotOverrideStopAndRetriesExactCloseOnResume() throws {
        var reducer = CaptureHealthReducer(nowMs: 0)
        let open = try XCTUnwrap(reducer.reduce(
            .observation(.failure(
                leg: .screen,
                generation: 0,
                reason: .screenRequestFailed
            )),
            at: 1
        ).compactMap(\.coverageOpen).first)
        _ = reducer.reduce(.coverageOpened(open), at: 2)
        let close = try XCTUnwrap(reducer.reduce(.observation(.progress(
            leg: .screen,
            generation: open.generation,
            fingerprint: "recovered",
            context: baseline
        )), at: 3).compactMap(\.coverageClose).first)

        _ = reducer.reduce(
            .intentChanged(.init(screenEnabled: false, systemAudioEnabled: false)),
            at: 4
        )
        _ = reducer.reduce(.coverageClosePersistenceFailed(close), at: 5)

        XCTAssertEqual(reducer.snapshot.legs[.screen]?.state, .paused)
        let effects = reducer.reduce(
            .intentChanged(.init(screenEnabled: true, systemAudioEnabled: false)),
            at: 6
        )
        XCTAssertEqual(effects.compactMap(\.coverageClose).first, close)
    }

    func testPendingCoverageOpenDoesNotPublishRecoveryAndHonorsAConcurrentStop() throws {
        var reducer = CaptureHealthReducer(nowMs: 0)
        let open = try XCTUnwrap(reducer.reduce(
            .observation(.failure(leg: .screen, generation: 0, reason: .screenRequestFailed)),
            at: 10
        ).compactMap(\.coverageOpen).first)

        XCTAssertEqual(reducer.snapshot.legs[.screen]?.state, .healthy)
        _ = reducer.reduce(
            .intentChanged(.init(screenEnabled: false, systemAudioEnabled: false)),
            at: 11
        )
        XCTAssertEqual(reducer.snapshot.legs[.screen]?.state, .paused)

        let effects = reducer.reduce(.coverageOpened(open), at: 12)
        XCTAssertEqual(effects.compactMap(\.coverageClose).first?.cause, .manualStop)
        XCTAssertNil(effects.compactMap(\.recoveryAttempt).first)
        XCTAssertEqual(reducer.snapshot.legs[.screen]?.state, .paused)
    }

    func testOpenIntervalHydratesConservativelyBeforeAnyGreenProjection() {
        let open = CaptureCoverageInterval(
            id: 1,
            leg: .screen,
            reason: .screenRequestFailed,
            episodeID: "survived-crash",
            generation: 7,
            startMs: 100,
            endMs: nil,
            closeCause: nil
        )
        var reducer = CaptureHealthReducer(nowMs: 200, openIntervals: [open])

        XCTAssertEqual(reducer.snapshot.aggregate, .recovering)
        XCTAssertEqual(reducer.snapshot.legs[.screen]?.generation, 7)
        let effects = reducer.reduce(.repairRequested(.screen), at: 201)
        XCTAssertEqual(
            effects.compactMap(\.recoveryAttempt).first,
            .init(leg: .screen, generation: 7, attempt: 1, delayMs: 0)
        )
    }

    func testHydratedOpenIntervalRespectsPermissionUntilGranted() {
        let open = CaptureCoverageInterval(
            id: 1,
            leg: .screen,
            reason: .screenRequestFailed,
            episodeID: "survived-without-permission",
            generation: 7,
            startMs: 100,
            endMs: nil,
            closeCause: nil
        )
        var reducer = CaptureHealthReducer(
            nowMs: 200,
            permissions: [.screen: .denied, .systemAudio: .denied],
            openIntervals: [open]
        )

        XCTAssertEqual(reducer.snapshot.aggregate, .permissionBlocked)
        XCTAssertTrue(reducer.reduce(.repairRequested(.screen), at: 201).isEmpty)
        _ = reducer.reduce(.permissionChanged(.screen, .granted), at: 202)
        XCTAssertEqual(reducer.snapshot.legs[.screen]?.state, .recovering)
    }
}

private extension CaptureObservation {
    static func progress(
        leg: CaptureLeg,
        generation: Int64,
        fingerprint: String,
        context: CaptureContext
    ) -> Self {
        .init(
            leg: leg,
            generation: generation,
            kind: .verifiedProgress,
            fingerprint: fingerprint,
            context: context
        )
    }

    static func unchanged(
        leg: CaptureLeg,
        generation: Int64,
        fingerprint: String,
        context: CaptureContext
    ) -> Self {
        .init(
            leg: leg,
            generation: generation,
            kind: .unchanged(.staticDuplicate),
            fingerprint: fingerprint,
            context: context
        )
    }

    static func failure(
        leg: CaptureLeg,
        generation: Int64,
        reason: CaptureHealthReason
    ) -> Self {
        .init(
            leg: leg,
            generation: generation,
            kind: .failed(reason),
            fingerprint: nil,
            context: nil
        )
    }
}

private extension CaptureHealthEffect {
    var coverageOpen: CaptureCoverageOpen? {
        guard case .openCoverage(let value) = self else { return nil }
        return value
    }

    var recoveryAttempt: CaptureRecoveryAttempt? {
        guard case .attemptRecovery(let value) = self else { return nil }
        return value
    }

    var coverageClose: CaptureCoverageClose? {
        guard case .closeCoverage(let value) = self else { return nil }
        return value
    }
}
