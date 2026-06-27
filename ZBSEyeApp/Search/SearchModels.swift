import Foundation

enum SearchKind: String, Sendable { case screen, audio }

/// Search filters (UI, REST, MCP — one contract): "what did I see about X last week in Safari".
struct SearchFilters: Sendable {
    var from: Date?
    var to: Date?
    var app: String?          // substring of bundleId or app name (case-insensitive), screen only
    var kind: SearchKind?     // nil = both
    var limit: Int = 60
    var offset: Int = 0       // pagination on top of RRF ranking

    init(from: Date? = nil, to: Date? = nil, app: String? = nil, kind: SearchKind? = nil,
         limit: Int = 60, offset: Int = 0) {
        self.from = from; self.to = to; self.app = app; self.kind = kind
        self.limit = max(1, min(limit, 200)); self.offset = max(0, offset)
    }
}

struct SearchResult: Sendable, Identifiable {
    let id: Int64
    let kind: SearchKind
    let ts: Date
    let bundleId: String?
    let appName: String?
    let windowTitle: String?
    let browserURL: String?
    let snippet: String
    let relativePath: String?

    /// `id` (rowid) on its own is not unique between screen and audio — in a ForEach that's a collision.
    /// The composite key kind:id is unique.
    var uniqueKey: String { "\(kind.rawValue):\(id)" }
}

struct DensityBucket: Sendable, Identifiable {
    let ts: Date
    let count: Int
    var id: Double { ts.timeIntervalSince1970 }
}

struct FrameDetail: Sendable, Identifiable {
    let id: Int64
    let ts: Date
    let relativePath: String?
    let bundleId: String?
    let appName: String?
    let windowTitle: String?
    let browserURL: String?
    let text: String
    let axQuality: String?
    /// Text sources for this frame (distinct over text_blocks.source): "ax" and/or "ocr".
    /// ax_quality ≠ source: a frame can be fullUseful while its blocks are a mix of ax+ocr.
    var sources: [String] = []

    var hasAX: Bool { sources.contains("ax") }
    var hasOCR: Bool { sources.contains("ocr") }
}

struct TimeBounds: Sendable {
    let oldest: Date?
    let newest: Date?
}

/// Audio segment for the timeline: transcript + file to play back. Previously a click on an audio hit
/// showed the nearest SCREEN frame and the transcript vanished — the call you found was a dead end.
struct AudioDetail: Sendable, Identifiable {
    let id: Int64
    let ts: Date
    let durationSec: Double
    let channel: String          // "mic" | "system"
    let relativePath: String
    let transcript: String?
    let language: String?
    let speaker: String?      // "me" / "other party" (channel-proxy diarization)
}

@inline(__always) func dateFromMs(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
@inline(__always) func msFromDate(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
