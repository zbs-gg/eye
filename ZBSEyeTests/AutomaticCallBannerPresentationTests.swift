import XCTest

final class AutomaticCallBannerPresentationTests: XCTestCase {
    func testEndingGraceUsesTheExplicitSaveAndDeleteCopy() {
        let state = AutomaticCallBannerState(
            phase: .endingGrace,
            callID: 42,
            deadline: Date(timeIntervalSince1970: 30),
            sourceAppName: "ChatGPT",
            sourceAppBundleID: "com.openai.codex"
        )

        XCTAssertEqual(state.presentation.title, "Call ended")
        XCTAssertEqual(
            state.presentation.detail,
            "Saving to Calls in 30 seconds. You can delete it there later."
        )
        XCTAssertTrue(state.presentation.showsEndAndSave)
        XCTAssertTrue(state.presentation.showsReject)
        XCTAssertEqual(state.presentation.endAndSaveActionRole, .primary)
        XCTAssertEqual(state.presentation.rejectActionTitle, "This wasn’t a call")
        XCTAssertEqual(state.presentation.rejectActionRole, .destructive)
        XCTAssertEqual(state.neverAutoRecordActionTitle, "Never auto-record ChatGPT")
        XCTAssertEqual(state.visibleActionCount, 3)
    }

    func testStartedBannerNamesTheMicrophoneOwner() {
        let state = AutomaticCallBannerState(
            phase: .started,
            callID: 42,
            deadline: nil,
            sourceAppName: "ChatGPT",
            sourceAppBundleID: "com.openai.codex"
        )

        XCTAssertEqual(state.presentation.title, "Call recording started")
        XCTAssertEqual(state.presentation.detail, "ChatGPT is using the microphone.")
        XCTAssertFalse(state.presentation.showsEndAndSave)
        XCTAssertTrue(state.presentation.showsReject)
        XCTAssertEqual(state.presentation.rejectActionTitle, "This isn’t a call")
        XCTAssertEqual(state.presentation.rejectActionRole, .destructive)
        XCTAssertEqual(state.neverAutoRecordActionTitle, "Never auto-record ChatGPT")
    }

    func testNeverAutoRecordConfirmationUsesAnImmutableCallAndAppSnapshot() throws {
        let state = AutomaticCallBannerState(
            phase: .started,
            callID: 42,
            deadline: nil,
            sourceAppName: "ChatGPT",
            sourceAppBundleID: "com.openai.codex"
        )

        let target = try XCTUnwrap(state.neverAutoRecordTarget)
        XCTAssertEqual(
            target,
            AutomaticCallExclusionTarget(
                callID: 42,
                bundleID: "com.openai.codex",
                displayName: "ChatGPT"
            )
        )

        let successor = AutomaticCallBannerState(
            phase: .started,
            callID: 43,
            deadline: nil,
            sourceAppName: "Krisp",
            sourceAppBundleID: "ai.krisp.krispMac"
        )
        XCTAssertNotEqual(target, successor.neverAutoRecordTarget)
    }

    func testUnknownSyntheticOwnerCannotCreateAnInvalidBundleExclusion() {
        let state = AutomaticCallBannerState(
            phase: .started,
            callID: 42,
            deadline: nil,
            sourceAppName: "MysteryAudio",
            sourceAppBundleID: "process:mysteryaudio"
        )

        XCTAssertNil(state.neverAutoRecordActionTitle)
    }

    func testSuccessorWaitsForOldEnvelopeThenRequestsExactlyOneReprobe() {
        var gate = AutomaticCallSuccessorProbeGate()

        XCTAssertFalse(
            gate.deferIfDifferentOwnerStillActive(
                activeFingerprint: nil,
                candidateFingerprint: "successor"
            )
        )
        XCTAssertTrue(
            gate.deferIfDifferentOwnerStillActive(
                activeFingerprint: "old-call",
                candidateFingerprint: "successor"
            )
        )
        XCTAssertFalse(gate.consumeReprobeIfOwnerCleared(activeFingerprint: "old-call"))
        XCTAssertTrue(gate.consumeReprobeIfOwnerCleared(activeFingerprint: nil))
        XCTAssertFalse(gate.consumeReprobeIfOwnerCleared(activeFingerprint: nil))
    }

    func testFinalizingAndSavedStatesExposeNoRepeatActionsOrUndoPhase() {
        for phase in [AutomaticCallBannerPhase.finalizing, .saved] {
            let state = AutomaticCallBannerState(
                phase: phase,
                callID: 42,
                deadline: nil
            )
            XCTAssertFalse(state.presentation.showsEndAndSave)
            XCTAssertFalse(state.presentation.showsReject)
            XCTAssertNil(state.presentation.rejectActionTitle)
            XCTAssertNil(state.presentation.rejectActionRole)
        }

        XCTAssertEqual(
            Set(AutomaticCallBannerPhase.allCases.map(\.rawValue)),
            ["started", "ending_grace", "finalizing", "saved", "save_failed"]
        )
    }

    func testSavedAndFailureMessagesAreHonest() {
        let saved = AutomaticCallBannerState(
            phase: .saved,
            callID: 42,
            deadline: nil
        )
        XCTAssertEqual(saved.presentation.title, "Call saved to Calls")
        XCTAssertEqual(saved.presentation.detail, "You can open or delete it in ZBS Eye.")

        let failed = AutomaticCallBannerState(
            phase: .saveFailed,
            callID: 42,
            deadline: nil,
            errorMessage: "The local recording was kept. Database unavailable."
        )
        XCTAssertEqual(failed.presentation.title, "Call couldn't be saved")
        XCTAssertEqual(
            failed.presentation.detail,
            "The local recording was kept. Database unavailable."
        )
    }

    func testFloatingPanelFitsNarrowAndOffsetDisplaysWithoutClipping() {
        let narrow = AutomaticCallPopupGeometry.fit(
            visibleX: -1_024,
            visibleY: 40,
            visibleWidth: 768,
            visibleHeight: 980
        )

        XCTAssertGreaterThanOrEqual(
            narrow.x,
            -1_024 + AutomaticCallPopupGeometry.horizontalMargin
        )
        XCTAssertLessThanOrEqual(
            narrow.x + narrow.width,
            -1_024 + 768 - AutomaticCallPopupGeometry.horizontalMargin
        )
        XCTAssertEqual(narrow.height, AutomaticCallPopupGeometry.compactHeight)
        XCTAssertGreaterThanOrEqual(narrow.y, 40)
        XCTAssertLessThanOrEqual(narrow.y + narrow.height, 40 + 980)

        let wide = AutomaticCallPopupGeometry.fit(
            visibleX: 0,
            visibleY: 0,
            visibleWidth: 1_440,
            visibleHeight: 900
        )
        XCTAssertEqual(wide.width, AutomaticCallPopupGeometry.targetWidth)
        XCTAssertEqual(wide.height, AutomaticCallPopupGeometry.wideHeight)
        XCTAssertEqual(wide.x, (1_440 - AutomaticCallPopupGeometry.targetWidth) / 2)

        let wideWithAllActions = AutomaticCallPopupGeometry.fit(
            visibleX: 0,
            visibleY: 0,
            visibleWidth: 1_440,
            visibleHeight: 900,
            actionCount: 3
        )
        XCTAssertEqual(
            wideWithAllActions.height,
            AutomaticCallPopupGeometry.expandedWideHeight
        )
        XCTAssertLessThanOrEqual(wideWithAllActions.y + wideWithAllActions.height, 900)
    }
}
