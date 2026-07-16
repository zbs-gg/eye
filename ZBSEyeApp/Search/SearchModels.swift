import Foundation

enum SearchKind: String, Sendable, Equatable { case screen, audio, call }

/// Search filters (UI, REST, MCP — one contract): "what did I see about X last week in Safari".
struct SearchFilters: Sendable, Equatable {
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

    /// Inclusive bounds shared by FTS SQL, semantic post-filtering, and Ask's
    /// second database read after ranked search.
    func includes(timestamp: Date) -> Bool {
        if let from, timestamp < from { return false }
        if let to, timestamp > to { return false }
        return true
    }
}

struct SearchResult: Sendable, Identifiable {
    let id: Int64
    let kind: SearchKind
    let ts: Date
    let endTs: Date?
    let bundleId: String?
    let appName: String?
    let windowTitle: String?
    let browserURL: String?
    let snippet: String
    let relativePath: String?

    init(
        id: Int64,
        kind: SearchKind,
        ts: Date,
        endTs: Date? = nil,
        bundleId: String?,
        appName: String?,
        windowTitle: String?,
        browserURL: String?,
        snippet: String,
        relativePath: String?
    ) {
        self.id = id
        self.kind = kind
        self.ts = ts
        self.endTs = endTs
        self.bundleId = bundleId
        self.appName = appName
        self.windowTitle = windowTitle
        self.browserURL = browserURL
        self.snippet = snippet
        self.relativePath = relativePath
    }

    /// `id` (rowid) on its own is not unique between screen and audio — in a ForEach that's a collision.
    /// The composite key kind:id is unique.
    var uniqueKey: String { "\(kind.rawValue):\(id)" }
}

struct DensityBucket: Sendable, Identifiable {
    let ts: Date
    let count: Int
    var id: Double { ts.timeIntervalSince1970 }
}

enum CallTimelineStatus: String, Sendable, Equatable {
    case processing
    case retryable
    case ready
    case degraded
}

struct CallTimelineBookmark: Sendable, Identifiable, Equatable {
    let id: Int64
    let acceptedAt: Date
    let state: CallBookmarkState
}

struct CallTimelineSpan: Sendable, Identifiable, Equatable {
    let id: Int64
    let start: Date
    let end: Date
    let status: CallTimelineStatus
    let bookmarks: [CallTimelineBookmark]
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

/// Monthly bucket (YYYYMM) for the vec0 temporal partition.
func monthBucket(_ date: Date) -> Int {
    let c = Calendar.current.dateComponents([.year, .month], from: date)
    return (c.year ?? 2026) * 100 + (c.month ?? 1)
}

/// [Float] → Data (little-endian float32) for binding into vec0.
func floatBlob(_ v: [Float]) -> Data {
    v.withUnsafeBufferPointer { Data(buffer: $0) }
}
