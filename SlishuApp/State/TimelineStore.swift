import Foundation
import Observation

/// Модель time-travel таймлайна. Ось — ВРЕМЯ (не индекс массива). Держит окно [rangeStart, rangeEnd]
/// вокруг cursor, плотность для density-strip, текущий кадр, и результаты FTS-поиска.
@MainActor
@Observable
final class TimelineStore {
    enum Zoom: String, CaseIterable, Identifiable {
        case tenMin, hour, day
        var id: String { rawValue }
        var span: TimeInterval { switch self { case .tenMin: 600; case .hour: 3600; case .day: 86400 } }
        var bucketMs: Int64 { switch self { case .tenMin: 10_000; case .hour: 60_000; case .day: 300_000 } }
        var label: String { switch self { case .tenMin: "10 мин"; case .hour: "Час"; case .day: "День" } }
    }

    @ObservationIgnored private let search: SearchService
    @ObservationIgnored private let timeline: TimelineService
    @ObservationIgnored let mediaDirectory: URL

    var bounds = TimeBounds(oldest: nil, newest: nil)
    var cursor = Date()
    var zoom: Zoom = .hour
    var current: FrameDetail?
    var density: [DensityBucket] = []
    var searchQuery = ""
    var results: [SearchResult] = []
    var isSearching = false

    var rangeStart: Date { cursor.addingTimeInterval(-zoom.span / 2) }
    var rangeEnd: Date { cursor.addingTimeInterval(zoom.span / 2) }
    var hasData: Bool { bounds.oldest != nil }

    init(search: SearchService, timeline: TimelineService, mediaDirectory: URL) {
        self.search = search
        self.timeline = timeline
        self.mediaDirectory = mediaDirectory
    }

    func load() async {
        if let b = try? await timeline.bounds() {
            bounds = b
            if let newest = b.newest { cursor = newest }
        }
        await refresh()
    }

    func refresh() async {
        if let d = try? await timeline.density(from: rangeStart, to: rangeEnd, bucketMs: zoom.bucketMs) {
            density = d
        }
        current = (try? await timeline.frameAt(cursor)) ?? current
    }

    func seek(to t: Date) async {
        cursor = t
        if let f = try? await timeline.frameAt(t) { current = f }
    }

    func setZoom(_ z: Zoom) async {
        zoom = z
        await refresh()
    }

    func runSearch() async {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; return }
        isSearching = true
        results = (try? await search.search(query: q)) ?? []
        isSearching = false
    }

    func clearSearch() {
        searchQuery = ""
        results = []
    }

    func select(_ r: SearchResult) async {
        results = []
        searchQuery = ""
        await refresh()
        await seek(to: r.ts)
    }

    func imageURL(_ relativePath: String?) -> URL? {
        relativePath.map { mediaDirectory.appendingPathComponent($0) }
    }
}
