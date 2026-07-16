import CryptoKit
import Foundation

struct CallTranscriptInterval: Sendable, Equatable {
    let bookmarkOrdinal: Int
    let revisionID: Int64
    let logicalStartMs: Int64
    let logicalEndMs: Int64
    let segments: [CallTranscriptSegmentDraft]
}

struct CallTranscriptProjectionResult: Sendable, Equatable {
    let key: String
    let logicalStartMs: Int64
    let logicalEndMs: Int64
    let text: String
    let segments: [CallTranscriptSegmentDraft]
    let gaps: [CallTranscriptGap]
    let complete: Bool
}

struct CallTranscriptGap: Sendable, Equatable {
    let bookmarkID: Int64
    let bookmarkOrdinal: Int
    let state: CallBookmarkState
    let logicalStartMs: Int64
    let logicalEndMs: Int64
}

enum CallTranscriptProjection {
    static func build(
        callID: Int64,
        mediaGeneration: Int,
        intervals: [CallTranscriptInterval],
        gaps: [CallTranscriptGap] = []
    ) -> CallTranscriptProjectionResult? {
        let ordered = intervals.sorted {
            ($0.bookmarkOrdinal, $0.revisionID) < ($1.bookmarkOrdinal, $1.revisionID)
        }
        guard !ordered.isEmpty else { return nil }
        let orderedGaps = gaps.sorted {
            ($0.bookmarkOrdinal, $0.bookmarkID) < ($1.bookmarkOrdinal, $1.bookmarkID)
        }

        var projected: [CallTranscriptSegmentDraft] = []
        for interval in ordered {
            projected.append(
                contentsOf: TranscriptOverlapReconciler.reconcile(
                    committed: projected,
                    incoming: interval.segments,
                    logicalStartMs: interval.logicalStartMs,
                    logicalEndMs: interval.logicalEndMs
                )
            )
        }
        let identity = (
            ordered.map { "i:\($0.bookmarkOrdinal):\($0.revisionID)" }
                + orderedGaps.map {
                    "g:\($0.bookmarkOrdinal):\($0.bookmarkID):\($0.state.rawValue)"
                }
        )
            .joined(separator: ",")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return CallTranscriptProjectionResult(
            key: "projection:\(callID):\(mediaGeneration):\(digest)",
            logicalStartMs: min(
                ordered.map(\.logicalStartMs).min() ?? 0,
                orderedGaps.map(\.logicalStartMs).min() ?? Int64.max
            ),
            logicalEndMs: max(
                ordered.map(\.logicalEndMs).max() ?? 0,
                orderedGaps.map(\.logicalEndMs).max() ?? Int64.min
            ),
            text: projected.map(\.text).joined(separator: "\n"),
            segments: projected,
            gaps: orderedGaps,
            complete: orderedGaps.isEmpty
        )
    }
}
