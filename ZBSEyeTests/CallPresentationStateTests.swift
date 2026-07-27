import XCTest

final class CallPresentationStateTests: XCTestCase {
    func testMissingModelOffersInstallWithoutCallingRecordingLost() {
        let state = CallPresentationState.resolve(
            evidence: evidence(callState: .finalizing, finalJobState: .pending),
            modelState: .absent
        )

        XCTAssertEqual(state.kind, .modelRequired)
        XCTAssertTrue(state.canInstallModel)
        XCTAssertFalse(state.canRetry)
    }

    func testModelDiscoveryDoesNotFlashADuplicateInstallOffer() {
        let state = CallPresentationState.resolve(
            evidence: evidence(callState: .finalizing, finalJobState: .pending),
            modelState: .verifying
        )

        XCTAssertEqual(state.kind, .transcribing)
        XCTAssertEqual(state.title, "Preparing local transcription")
        XCTAssertFalse(state.canInstallModel)
    }

    func testProjectionIsExplicitlyProvisionalWhileFinalRuns() {
        let state = CallPresentationState.resolve(
            evidence: evidence(
                callState: .finalizing,
                finalJobState: .running,
                revisionKind: .projection
            ),
            modelState: .ready
        )

        XCTAssertEqual(state.kind, .provisional)
        XCTAssertTrue(state.isProvisional)
        XCTAssertFalse(state.isFinal)
    }

    func testReadyFinalWithSourceGapIsDegradedNotFailed() {
        let state = CallPresentationState.resolve(
            evidence: evidence(
                callState: .ready,
                finalJobState: .readyDegraded,
                revisionKind: .final,
                degradationReason: "source_gap"
            ),
            modelState: .ready
        )

        XCTAssertEqual(state.kind, .degraded)
        XCTAssertTrue(state.isFinal)
        XCTAssertFalse(state.canRetry)
    }

    func testFailedFinalKeepsProvisionalEvidenceAndOffersRetry() {
        let state = CallPresentationState.resolve(
            evidence: evidence(
                callState: .failed,
                finalJobState: .failed,
                revisionKind: .projection
            ),
            modelState: .ready
        )

        XCTAssertEqual(state.kind, .failed)
        XCTAssertTrue(state.isProvisional)
        XCTAssertTrue(state.canRetry)
    }

    func testRecordingFinalizingTranscribingAndCleanFinalStatesStayDistinct() {
        XCTAssertEqual(
            CallPresentationState.resolve(
                evidence: evidence(callState: .recording, finalJobState: .pending),
                modelState: .ready
            ).kind,
            .recording
        )
        XCTAssertEqual(
            CallPresentationState.resolve(
                evidence: evidence(callState: .finalizing, finalJobState: .running),
                modelState: .ready
            ).kind,
            .finalizing
        )
        XCTAssertEqual(
            CallPresentationState.resolve(
                evidence: evidence(callState: .interrupted, finalJobState: .pending),
                modelState: .ready
            ).kind,
            .transcribing
        )
        let ready = CallPresentationState.resolve(
            evidence: evidence(
                callState: .ready,
                finalJobState: .ready,
                revisionKind: .final
            ),
            modelState: .ready
        )
        XCTAssertEqual(ready.kind, .ready)
        XCTAssertEqual(ready.title, "Final transcript ready")
    }

    func testRefreshKeysChangeWhenBootstrapOrRetryMakesNewEvidenceAvailable() {
        let cold = CallControlRefreshKey(
            phase: .idle,
            callID: nil,
            modelState: .absent,
            serviceReady: false
        )
        let bootstrapped = CallControlRefreshKey(
            phase: .idle,
            callID: nil,
            modelState: .absent,
            serviceReady: true
        )
        XCTAssertNotEqual(cold, bootstrapped)

        let failed = CallDetailRefreshKey(
            callID: 1,
            modelState: .ready,
            speakerModelState: .absent,
            retryGeneration: 0
        )
        let retried = CallDetailRefreshKey(
            callID: 1,
            modelState: .ready,
            speakerModelState: .absent,
            retryGeneration: 1
        )
        XCTAssertNotEqual(failed, retried)
    }

    func testCallsLibraryNamesMissingWhisperInsteadOfGenericProcessing() {
        let pending = summary(
            state: .finalizing,
            status: .processing,
            endTs: 2_000
        )

        XCTAssertEqual(
            CallLibraryStatusPresentation.resolve(
                call: pending,
                modelState: .absent
            ).title,
            "Recording saved · Whisper needed"
        )
        XCTAssertEqual(
            CallLibraryStatusPresentation.resolve(
                call: pending,
                modelState: .ready
            ).title,
            "Processing"
        )
    }

    func testCallsLibraryDoesNotCallAnActiveRecordingWhisperBlocked() {
        let recording = summary(
            state: .recording,
            status: .recording,
            endTs: nil
        )

        XCTAssertEqual(
            CallLibraryStatusPresentation.resolve(
                call: recording,
                modelState: .absent
            ).title,
            "Recording"
        )
    }

    private func evidence(
        callState: CallLifecycleState,
        finalJobState: CallTranscriptJobState,
        revisionKind: CallTranscriptRevisionKind? = nil,
        degradationReason: String? = nil
    ) -> CallEvidencePage {
        let call = CallRow(
            id: 1,
            startIdempotencyKey: "call",
            endIdempotencyKey: callState == .recording ? nil : "end",
            startTs: 1_000,
            endTs: callState == .recording ? nil : 2_000,
            state: callState,
            interrupted: false,
            degradationReason: degradationReason,
            mediaGeneration: 0,
            preferredRevisionId: revisionKind == nil ? nil : 9,
            createdAtMs: 1_000,
            updatedAtMs: 2_000
        )
        let job = CallTranscriptJobRow(
            id: 8,
            identity: "final:1:0",
            callId: 1,
            bookmarkId: nil,
            kind: .final,
            mediaGeneration: 0,
            state: finalJobState,
            priority: 0,
            logicalStartMs: 1_000,
            logicalEndMs: 2_000,
            contextStartMs: 1_000,
            meEndSample: 16_000,
            systemEndSample: nil,
            coverageFrozen: true,
            attempts: 0,
            errorCode: nil,
            createdAtMs: 2_000,
            updatedAtMs: 2_000
        )
        let revision = revisionKind.map {
            CallTranscriptRevisionSummary(id: 9, kind: $0, state: .ready)
        }
        return CallEvidencePage(
            call: call,
            sourceSpans: [],
            sourceSpansTruncated: false,
            sourceGaps: [],
            sourceGapsTruncated: false,
            bookmarks: [],
            bookmarksTruncated: false,
            finalJob: job,
            preferredRevision: revision,
            projectionGaps: [],
            projectionGapsTruncated: false,
            segments: [],
            segmentOffset: 0,
            hasMoreSegments: false
        )
    }

    private func summary(
        state: CallLifecycleState,
        status: CallEvidenceStatus,
        endTs: Int64?
    ) -> CallEvidenceSummary {
        CallEvidenceSummary(
            callId: "call:1",
            startTs: 1_000,
            endTs: endTs,
            state: state,
            status: status,
            retryable: false,
            preferredRevisionKind: nil,
            title: nil,
            participants: [],
            sourceApp: nil,
            bookmarkCount: 0,
            speakerStatus: .unavailable
        )
    }
}
