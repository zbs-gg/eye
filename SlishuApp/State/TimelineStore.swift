import Foundation
import Observation

/// Модель time-travel таймлайна. Ось — ВРЕМЯ (не индекс массива). Держит окно [rangeStart, rangeEnd]
/// вокруг cursor, плотность для density-strip, текущий кадр, и результаты FTS-поиска.
@MainActor
@Observable
final class TimelineStore {
    /// Детальность density-strip (strip и slider — оба по ВСЕЙ истории, согласованы; zoom = размер бакета).
    enum Zoom: String, CaseIterable, Identifiable {
        case fine, medium, coarse
        var id: String { rawValue }
        var bucketMs: Int64 { switch self { case .fine: 15_000; case .medium: 60_000; case .coarse: 300_000 } }
        var label: String { switch self { case .fine: "Детально"; case .medium: "Средне"; case .coarse: "Обзор" } }
    }

    @ObservationIgnored private let search: SearchService
    @ObservationIgnored private let timeline: TimelineService
    @ObservationIgnored let mediaDirectory: URL
    @ObservationIgnored private var searchGen = 0

    var bounds = TimeBounds(oldest: nil, newest: nil)
    var cursor = Date()
    var zoom: Zoom = .medium
    var current: FrameDetail?
    var density: [DensityBucket] = []
    var searchQuery = ""
    var results: [SearchResult] = []
    var isSearching = false

    // strip и slider — оба по всей истории (согласованы). Окно с запасом, если истории ещё нет.
    var rangeStart: Date { bounds.oldest ?? Date().addingTimeInterval(-1800) }
    var rangeEnd: Date { bounds.newest ?? Date() }
    var hasData: Bool { bounds.oldest != nil }

    /// Бакет с capping: не больше ~400 столбиков на всю историю.
    private var effectiveBucketMs: Int64 {
        let span = max(1, msFromDate(rangeEnd) - msFromDate(rangeStart))
        return max(zoom.bucketMs, span / 400)
    }

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
        if let d = try? await timeline.density(from: rangeStart, to: rangeEnd, bucketMs: effectiveBucketMs) {
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
        // только density зависит от zoom; guard на устаревание при быстром переключении
        if let d = try? await timeline.density(from: rangeStart, to: rangeEnd, bucketMs: effectiveBucketMs),
           zoom == z {
            density = d
        }
    }

    func runSearch() async {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; return }
        searchGen += 1
        let gen = searchGen
        isSearching = true
        let r = (try? await search.search(query: q)) ?? []
        guard gen == searchGen else { return }   // пришёл устаревший результат — игнор
        results = r
        isSearching = false
    }

    func clearSearch() {
        searchQuery = ""
        results = []
    }

    func select(_ r: SearchResult) async {
        results = []
        searchQuery = ""
        cursor = r.ts          // сначала курсор — refresh посчитает кадр+плотность для нового момента
        await refresh()
    }

    func imageURL(_ relativePath: String?) -> URL? {
        relativePath.map { mediaDirectory.appendingPathComponent($0) }
    }
}
