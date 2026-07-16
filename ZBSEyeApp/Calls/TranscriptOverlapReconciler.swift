import Foundation

struct CallTranscriptSegmentDraft: Codable, Sendable, Equatable {
    let source: CallAudioSource
    let startMs: Int64
    let endMs: Int64
    let text: String
}

enum TranscriptOverlapReconciler {
    static func reconcile(
        committed: [CallTranscriptSegmentDraft],
        incoming: [CallTranscriptSegmentDraft],
        logicalStartMs: Int64,
        logicalEndMs: Int64,
        overlapBoundaryMs: Int64? = nil
    ) -> [CallTranscriptSegmentDraft] {
        struct Entry {
            let originalIndex: Int
            let originalStartMs: Int64
            var segment: CallTranscriptSegmentDraft?
        }

        var entries = incoming.enumerated().compactMap { index, segment -> Entry? in
            guard segment.endMs > logicalStartMs,
                  segment.startMs < logicalEndMs else { return nil }
            let text = normalizedWhitespace(segment.text)
            guard !text.isEmpty else { return nil }
            return Entry(
                originalIndex: index,
                originalStartMs: segment.startMs,
                segment: CallTranscriptSegmentDraft(
                    source: segment.source,
                    startMs: max(logicalStartMs, segment.startMs),
                    endMs: min(logicalEndMs, max(segment.endMs, logicalStartMs)),
                    text: text
                )
            )
        }
        guard !committed.isEmpty, !entries.isEmpty else {
            return entries.compactMap(\.segment)
        }

        let boundary = overlapBoundaryMs ?? logicalStartMs
        for source in [CallAudioSource.me, .system] {
            let sourceIndices = entries.indices.filter { entries[$0].segment?.source == source }
            guard let firstIndex = sourceIndices.first,
                  entries[firstIndex].originalStartMs <= boundary else { continue }
            let committedTokens = tokenize(
                committed
                    .filter { $0.source == source }
                    .map(\.text)
                    .joined(separator: " ")
            )
            let incomingTokens = sourceIndices.flatMap { index in
                entries[index].segment.map { tokenize($0.text) } ?? []
            }
            guard !committedTokens.isEmpty,
                  !incomingTokens.isEmpty else { continue }
            var tokensToRemove = boundaryOverlap(
                suffixOf: committedTokens,
                prefixOf: incomingTokens
            )
            guard tokensToRemove > 0 else { continue }
            let committedEndMs = committed
                .filter { $0.source == source }
                .map(\.endMs)
                .max() ?? Int64.min
            let hasTemporalOverlap = entries[firstIndex].originalStartMs < committedEndMs
            guard tokensToRemove > 1 || hasTemporalOverlap else { continue }

            for index in sourceIndices where tokensToRemove > 0 {
                guard let segment = entries[index].segment else { continue }
                let tokens = tokenize(segment.text)
                if tokensToRemove >= tokens.count {
                    tokensToRemove -= tokens.count
                    entries[index].segment = nil
                    continue
                }
                let remaining = tokens.dropFirst(tokensToRemove)
                    .map(\.original)
                    .joined(separator: " ")
                entries[index].segment = CallTranscriptSegmentDraft(
                    source: segment.source,
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    text: remaining
                )
                tokensToRemove = 0
                continue
            }
        }
        return entries
            .sorted { $0.originalIndex < $1.originalIndex }
            .compactMap(\.segment)
    }

    private struct Token {
        let original: String
        let comparable: String
    }

    private static func tokenize(_ text: String) -> [Token] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            let original = String(raw)
            let comparable = original
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .trimmingCharacters(in: .punctuationCharacters)
            guard !comparable.isEmpty else { return nil }
            return Token(original: original, comparable: comparable)
        }
    }

    private static func boundaryOverlap(suffixOf left: [Token], prefixOf right: [Token]) -> Int {
        let ceiling = min(64, left.count, right.count)
        guard ceiling > 0 else { return 0 }
        for count in stride(from: ceiling, through: 1, by: -1) {
            let suffix = left.suffix(count).map(\.comparable)
            let prefix = right.prefix(count).map(\.comparable)
            if suffix.elementsEqual(prefix) { return count }
        }
        return 0
    }

    private static func normalizedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
