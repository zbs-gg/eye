import Foundation

enum SearchKind: String, Sendable { case screen, audio }

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
}

struct TimeBounds: Sendable {
    let oldest: Date?
    let newest: Date?
}

@inline(__always) func dateFromMs(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
@inline(__always) func msFromDate(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
