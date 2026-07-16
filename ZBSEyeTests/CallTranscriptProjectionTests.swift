import XCTest

final class CallTranscriptProjectionTests: XCTestCase {
    func testEarlierRetryRebuildsProjectionInBookmarkOrderWithoutBoundaryDuplicate() throws {
        let second = CallTranscriptInterval(
            bookmarkOrdinal: 2,
            revisionID: 22,
            logicalStartMs: 2_000,
            logicalEndMs: 3_000,
            segments: [segment(1_500, 3_000, "decision approved ship tomorrow")]
        )
        let partial = try XCTUnwrap(
            CallTranscriptProjection.build(callID: 7, mediaGeneration: 0, intervals: [second])
        )
        XCTAssertEqual(partial.text, "decision approved ship tomorrow")

        let first = CallTranscriptInterval(
            bookmarkOrdinal: 1,
            revisionID: 11,
            logicalStartMs: 1_000,
            logicalEndMs: 2_000,
            segments: [segment(1_000, 2_000, "we reached a decision approved")]
        )
        let rebased = try XCTUnwrap(
            CallTranscriptProjection.build(
                callID: 7,
                mediaGeneration: 0,
                intervals: [second, first]
            )
        )
        XCTAssertEqual(rebased.segments.map(\.text), [
            "we reached a decision approved",
            "ship tomorrow",
        ])
        XCTAssertNotEqual(rebased.key, partial.key)
    }

    func testUnresolvedEarlierBookmarkRemainsExplicitInProjectionCoverage() throws {
        let second = CallTranscriptInterval(
            bookmarkOrdinal: 2,
            revisionID: 22,
            logicalStartMs: 2_000,
            logicalEndMs: 3_000,
            segments: [segment(2_000, 3_000, "second interval")]
        )
        let gap = CallTranscriptGap(
            bookmarkID: 11,
            bookmarkOrdinal: 1,
            state: .failed,
            logicalStartMs: 1_000,
            logicalEndMs: 2_000
        )

        let projection = try XCTUnwrap(
            CallTranscriptProjection.build(
                callID: 7,
                mediaGeneration: 0,
                intervals: [second],
                gaps: [gap]
            )
        )

        XCTAssertEqual(projection.logicalStartMs, 1_000)
        XCTAssertEqual(projection.logicalEndMs, 3_000)
        XCTAssertEqual(projection.gaps, [gap])
        XCTAssertFalse(projection.complete)
        XCTAssertEqual(projection.text, "second interval")
    }

    private func segment(_ start: Int64, _ end: Int64, _ text: String) -> CallTranscriptSegmentDraft {
        CallTranscriptSegmentDraft(source: .system, startMs: start, endMs: end, text: text)
    }
}
