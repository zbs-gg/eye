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
    @ObservationIgnored private var playTask: Task<Void, Never>?
    @ObservationIgnored private var playGen = 0   // как searchGen: инвалидирует устаревший цикл плеера

    var bounds = TimeBounds(oldest: nil, newest: nil)
    var cursor = Date()
    var zoom: Zoom = .medium
    var current: FrameDetail?
    var density: [DensityBucket] = []
    var searchQuery = ""
    var results: [SearchResult] = []
    var isSearching = false

    // Плеер: воспроизведение по реальной каденции захваченных кадров, масштабируется скоростью.
    var isPlaying = false
    var speed: Double = 1            // 1× / 2× / 4×
    static let speeds: [Double] = [1, 2, 4]

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
        // Прямое присваивание: до первого кадра истории frameAt вернёт nil — кадр надо ОЧИСТИТЬ,
        // иначе в пустой зоне залипает прежний кадр (детали-«Нет кадра» иначе недостижимы).
        current = try? await timeline.frameAt(cursor)
    }

    func seek(to t: Date) async {
        if isPlaying { pause() }        // ручная перемотка забирает управление у плеера
        cursor = t
        current = try? await timeline.frameAt(t)   // nil до начала истории → очищаем (см. refresh)
    }

    // MARK: плеер

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard hasData, !isPlaying else { return }                 // guard !isPlaying — нет двойного запуска
        // один кадр всего — играть нечего, не мигаем кнопкой play→pause
        if let o = bounds.oldest, let n = bounds.newest, o == n { return }
        // если стоим в конце — начинаем с начала истории (иначе play «ничего не делает»)
        if let newest = bounds.newest, cursor >= newest, let oldest = bounds.oldest { cursor = oldest }
        isPlaying = true
        startLoop()
    }

    func pause() {
        isPlaying = false
        playGen += 1            // инвалидирует любой живой playLoop (его проверка gen == playGen упадёт)
        playTask?.cancel()
        playTask = nil
    }

    func setSpeed(_ s: Double) {
        speed = s
        // Перезапуск цикла, чтобы текущий длинный sleep пересчитался под новую скорость (иначе лаг до 1.2с).
        if isPlaying { startLoop() }
    }

    /// Шаг по реальным кадрам (ставит на паузу — это ручная навигация).
    func stepForward() async {
        pause()
        if let f = try? await timeline.nextFrame(after: cursor) { cursor = f.ts; current = f }
    }
    func stepBackward() async {
        pause()
        if let f = try? await timeline.prevFrame(before: cursor) { cursor = f.ts; current = f }
    }

    private func startLoop() {
        playGen += 1
        let gen = playGen
        playTask?.cancel()
        playTask = Task { [weak self] in await self?.playLoop(gen: gen) }
    }

    private func playLoop(gen: Int) async {
        // gen == playGen — этот цикл актуальный; pause()/новый startLoop() бампят playGen и вытесняют старый.
        while isPlaying && !Task.isCancelled && gen == playGen {
            // try? уплощает Optional-возврат: и брошенная ошибка БД, и конец истории → nil → стоп.
            guard let next = try? await timeline.nextFrame(after: cursor) else { pause(); return }
            // Реальный зазор до следующего кадра / скорость; max(0,…) покрывает нулевой/обратный gap
            // (обратная перемотка, кадры с равным ts); cap 1.2с чтобы idle-разрывы не морозили плеер.
            let gap = max(0, next.ts.timeIntervalSince(cursor))
            let wait = min(max(gap / speed, 0.05), 1.2)
            try? await Task.sleep(for: .seconds(wait))
            guard isPlaying, !Task.isCancelled, gen == playGen else { return }  // не писать stale cursor
            cursor = next.ts
            current = next
        }
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
        isSearching = false      // иначе showResults (isSearching||!results) держит оверлей открытым
        searchGen += 1           // инвалидируем любой летящий runSearch — его результат отбросится (gen != searchGen)
    }

    func select(_ r: SearchResult) async {
        pause()                // прыжок на хит = ручная навигация, не автоплей
        results = []
        searchQuery = ""
        cursor = r.ts          // сначала курсор — refresh посчитает кадр+плотность для нового момента
        await refresh()
    }

    func imageURL(_ relativePath: String?) -> URL? {
        relativePath.map { mediaDirectory.appendingPathComponent($0) }
    }
}
