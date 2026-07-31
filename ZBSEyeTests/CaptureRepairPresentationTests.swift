import Foundation
import XCTest

final class CaptureRepairPresentationTests: XCTestCase {
    func testHealthyCaptureIsHidden() {
        let presentation = CaptureRepairPresentation(snapshot: snapshot())

        XCTAssertEqual(presentation.state, .hidden)
        XCTAssertNil(presentation.actionTitle)
    }

    func testRecoveringCaptureHasNoCompetingAction() {
        let presentation = CaptureRepairPresentation(
            snapshot: snapshot(screen: .recovering)
        )

        XCTAssertEqual(presentation.state, .recovering)
        XCTAssertNil(presentation.actionTitle)
        XCTAssertEqual(presentation.affectedLegs, [.screen])
    }

    func testRepairRequiredHasExactlyOneActionAndGuidance() {
        let presentation = CaptureRepairPresentation(
            snapshot: snapshot(
                screen: .repairRequired,
                audio: .repairRequired,
                systemAudioEnabled: true
            )
        )

        XCTAssertEqual(presentation.state, .repairRequired)
        XCTAssertEqual(presentation.actionTitle, "Repair Capture")
        XCTAssertEqual(presentation.affectedLegs, [.screen, .systemAudio])
        XCTAssertEqual(presentation.guidance.count, 3)
    }

    func testPermissionBlockDoesNotOfferRepair() {
        let presentation = CaptureRepairPresentation(
            snapshot: snapshot(screen: .permissionBlocked)
        )

        XCTAssertEqual(presentation.state, .permissionBlocked)
        XCTAssertNil(presentation.actionTitle)
    }

    func testHydratedOpenIntervalOffersTheExplicitRepairAction() {
        var value = snapshot(screen: .recovering)
        value.legs[.screen]?.attempt = 0

        let presentation = CaptureRepairPresentation(snapshot: value)

        XCTAssertEqual(presentation.state, .repairRequired)
        XCTAssertEqual(presentation.actionTitle, "Repair Capture")
    }

    func testCaptureRepairAndCoverageStringsHaveRussianTranslations() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(
            path: "ZBSEyeApp/Resources/Localizable.xcstrings"
        ))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(object["strings"] as? [String: Any])
        let required = [
            "Allow capture in macOS Settings. ZBS Eye will retry after macOS reports that access is granted.",
            "Capture",
            "Capture coverage could not be verified for this range. Missing results do not prove inactivity.",
            "Capture may be incomplete for %@ in this range. Missing results do not prove inactivity.",
            "Capture needs repair",
            "Capture permission needed",
            "Capture repair could not safely finish — retry repair",
            "If it still fails, quit other apps currently using screen capture.",
            "Log out or restart the Mac only as the final macOS recovery step.",
            "Recovering capture…",
            "Repair Capture",
            "Screen",
            "System Audio",
            "Try the Eye-owned repair once.",
            "ZBS Eye is rebuilding only its own capture resources.",
            "ZBS Eye stopped automatic retries. Your recording choice and existing history are safe.",
            "off", "permission needed", "recovering", "repair needed", "suspended",
        ]

        for key in required {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any], key
            )
            let ru = try XCTUnwrap(localizations["ru"] as? [String: Any], key)
            let unit = try XCTUnwrap(ru["stringUnit"] as? [String: Any], key)
            XCTAssertFalse((unit["value"] as? String ?? "").isEmpty, key)
        }
    }

    private func snapshot(
        screen: CaptureLegState = .healthy,
        audio: CaptureLegState = .paused,
        systemAudioEnabled: Bool = false
    ) -> CaptureHealthSnapshot {
        func health(
            _ state: CaptureLegState,
            reason: CaptureHealthReason
        ) -> CaptureLegHealth {
            CaptureLegHealth(
                state: state,
                reason: reason,
                generation: 0,
                attempt: state == .recovering ? 1 : 0,
                stateSinceMs: 0,
                lastCycleAtMs: nil,
                lastVerifiedProgressAtMs: nil
            )
        }
        return CaptureHealthSnapshot(
            intent: CaptureIntent(
                screenEnabled: true,
                systemAudioEnabled: systemAudioEnabled
            ),
            permissions: [.screen: .granted, .systemAudio: .granted],
            suspension: nil,
            legs: [
                .screen: health(screen, reason: .awaitingVerifiedProgress),
                .systemAudio: health(audio, reason: .systemAudioDisabled),
            ],
            aggregate: .healthy
        )
    }
}
