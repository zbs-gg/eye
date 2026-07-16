import XCTest

final class TranscriptOverlapReconcilerTests: XCTestCase {
    func testRemovesRepeatedBoundaryPhraseAndKeepsOnlyLogicalCoverage() {
        let committed = [segment(0, 10_000, "We ship on Friday.")]
        let incoming = [
            segment(8_000, 12_000, "on Friday, then celebrate"),
            segment(12_000, 14_000, "with the team"),
        ]

        let result = TranscriptOverlapReconciler.reconcile(
            committed: committed,
            incoming: incoming,
            logicalStartMs: 10_000,
            logicalEndMs: 14_000
        )

        XCTAssertEqual(result.map(\.text), ["then celebrate", "with the team"])
        XCTAssertEqual(result.first?.startMs, 10_000)
        XCTAssertEqual(result.last?.endMs, 14_000)
    }

    func testDropsWholeContextSegmentAlreadyCommitted() {
        let result = TranscriptOverlapReconciler.reconcile(
            committed: [segment(0, 1_000, "alpha beta")],
            incoming: [
                segment(900, 1_100, "alpha beta"),
                segment(1_100, 2_000, "gamma"),
            ],
            logicalStartMs: 1_000,
            logicalEndMs: 2_000
        )
        XCTAssertEqual(result.map(\.text), ["gamma"])
    }

    func testDoesNotDeleteSameWordsSpokenByOtherSource() {
        let result = TranscriptOverlapReconciler.reconcile(
            committed: [segment(0, 1_000, "yes", source: .me)],
            incoming: [segment(900, 2_000, "yes correct", source: .system)],
            logicalStartMs: 1_000,
            logicalEndMs: 2_000
        )

        XCTAssertEqual(result.map(\.text), ["yes correct"])
        XCTAssertEqual(result.map(\.source), [.system])
    }

    func testRemovesBoundaryPhraseSplitAcrossIncomingSegments() {
        let result = TranscriptOverlapReconciler.reconcile(
            committed: [segment(0, 1_000, "alpha beta")],
            incoming: [
                segment(900, 1_050, "alpha"),
                segment(1_050, 2_000, "beta gamma"),
            ],
            logicalStartMs: 1_000,
            logicalEndMs: 2_000
        )

        XCTAssertEqual(result.map(\.text), ["gamma"])
    }

    func testKeepsOneWordRepeatedAtANonOverlappingBoundary() {
        let result = TranscriptOverlapReconciler.reconcile(
            committed: [segment(0, 1_000, "yes")],
            incoming: [segment(1_000, 2_000, "yes")],
            logicalStartMs: 1_000,
            logicalEndMs: 2_000
        )

        XCTAssertEqual(result.map(\.text), ["yes"])
    }

    private func segment(
        _ start: Int64,
        _ end: Int64,
        _ text: String,
        source: CallAudioSource = .me
    ) -> CallTranscriptSegmentDraft {
        CallTranscriptSegmentDraft(source: source, startMs: start, endMs: end, text: text)
    }
}
