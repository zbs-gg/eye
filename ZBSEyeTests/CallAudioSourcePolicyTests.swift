import Foundation
import XCTest

final class CallAudioSourcePolicyTests: XCTestCase {
    private var audioCoordinatorSource: String {
        get throws {
            let projectRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(
                contentsOf: projectRoot.appending(path: "ZBSEyeApp/Audio/AudioCoordinator.swift"),
                encoding: .utf8
            )
        }
    }

    func testConfirmedCallRequestsBothLegsWhenAudioEnabled() {
        for mode in [AudioMode.meetingsOnly, .always] {
            XCTAssertEqual(
                CallAudioSourcePolicy.requestedSources(
                    audioMode: mode,
                    manualOverride: nil
                ),
                CallSourceSelection(me: true, system: true)
            )
        }
    }

    func testAudioOffRemainsHardPrivacyStop() {
        XCTAssertEqual(
            CallAudioSourcePolicy.requestedSources(
                audioMode: .off,
                manualOverride: true
            ),
            .none
        )
    }

    func testForcedOffBlocksCurrentAndFutureAutomaticCalls() {
        XCTAssertEqual(
            CallAudioSourcePolicy.requestedSources(
                audioMode: .meetingsOnly,
                manualOverride: false
            ),
            .none
        )
        XCTAssertFalse(
            CallAudioSourcePolicy.allowsAutomaticCallStart(
                audioMode: .meetingsOnly,
                manualOverride: false,
                microphoneAvailable: true,
                systemAudioAvailable: true
            )
        )
    }

    func testAutomaticAdmissionNeedsAtLeastOneAvailableTrackAndReopensWhenGranted() {
        XCTAssertFalse(
            CallAudioSourcePolicy.allowsAutomaticCallStart(
                audioMode: .meetingsOnly,
                manualOverride: nil,
                microphoneAvailable: false,
                systemAudioAvailable: false
            )
        )
        XCTAssertTrue(
            CallAudioSourcePolicy.allowsAutomaticCallStart(
                audioMode: .meetingsOnly,
                manualOverride: nil,
                microphoneAvailable: true,
                systemAudioAvailable: false
            )
        )
        XCTAssertTrue(
            CallAudioSourcePolicy.allowsAutomaticCallStart(
                audioMode: .meetingsOnly,
                manualOverride: nil,
                microphoneAvailable: false,
                systemAudioAvailable: true
            )
        )
    }

    func testClosedExplicitCallSinkCannotFallThroughToTimeline() throws {
        let source = try audioCoordinatorSource
        let methodStart = try XCTUnwrap(source.range(of: "private func routeToCallIfOwned"))
        let classEnd = try XCTUnwrap(
            source.range(
                of: "\n}\n\n/// Auto-restart budget",
                range: methodStart.upperBound..<source.endIndex
            )
        )
        let method = String(source[methodStart.lowerBound..<classEnd.lowerBound])

        let explicitCall = try XCTUnwrap(method.range(of: "if case .explicitCall = admission"))
        let rejectedSink = try XCTUnwrap(
            method.range(of: "_ = await sink(frame)", range: explicitCall.upperBound..<method.endIndex)
        )
        let consumed = try XCTUnwrap(
            method.range(of: "return true", range: rejectedSink.upperBound..<method.endIndex)
        )
        let backgroundFallback = try XCTUnwrap(
            method.range(
                of: "return await CallAudioFrameRouter.route",
                range: consumed.upperBound..<method.endIndex
            )
        )

        XCTAssertLessThan(rejectedSink.lowerBound, consumed.lowerBound)
        XCTAssertLessThan(consumed.lowerBound, backgroundFallback.lowerBound)
        XCTAssertFalse(method.contains("return await sink(frame)"))
    }
}
