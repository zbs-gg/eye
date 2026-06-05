import Foundation
import Observation

/// Модель time-travel таймлайна. Ось — ВРЕМЯ (не индекс массива). Держит окно [rangeStart, rangeEnd]
/// вокруг cursor, плотность для density-strip, текущий кадр, и результаты FTS-поиска.
@MainActor
@Observable
final class TimelineStore {
    /// Зум = ширина видимого ОКНА времени для density-strip (overview+detail). Слайдер всегда по всей
    /// истории (глобальная позиция); strip показывает окно вокруг playhead. seconds=nil → вся история.
    enum Zoom: String, CaseIterable, Identifiable {
        case full, day, hour, tenMin
        var id: String { rawValue }
        var seconds: Double? {
            switch self { case .full: nil; case .day: 86_400; case .hour: 3_600; case .tenMin: 600 }
        }
        var label: String {
            switch self { case .full: "Вся"; case .day: "День"; case .hour: "Час"; case .tenMin: "10 мин" }
        }
    }

    @ObservationIgnored private let search: SearchService
    @ObservationIgnored private let timeline: TimelineService
    @ObservationIgnored let mediaDirectory: URL
    @ObservationIgnored private var searchGen = 0
    @ObservationIgnored private var playTask: Task<Void, Never>?
    @ObservationIgnored private var playGen = 0   // как searchGen: инвалидирует устаревший цикл плеера
    @ObservationIgnored private var windowStart: Date?   // левый край окна strip; nil = вся история (.full)

    var bounds = TimeBounds(oldest: nil, newest: nil)
    var cursor = Date()
    var zoom: Zoom = .full
    var current: FrameDetail?
    var density: [DensityBucket] = []
    var searchQuery = ""
    var results: [SearchResult] = []
    var isSearching = false

    // Плеер: воспроизведение по реальной каденции захваченных кадров, масштабируется скоростью.
    var isPlaying = false
    var speed: Double = 1            // 1× / 2× / 4×
    static let speeds: [Double] = [1, 2, 4]

    // Окно density-strip: при .full = вся история; иначе — страница [windowStart, +zoom.seconds].
    var rangeStart: Date {
        if let ws = windowStart, zoom.seconds != nil { return ws }
        return bounds.oldest ?? Date().addingTimeInterval(-1800)
    }
    var rangeEnd: Date {
        if let ws = windowStart, let w = zoom.seconds { return ws.addingTimeInterval(w) }
        return bounds.newest ?? Date()
    }
    var hasData: Bool { bounds.oldest != nil }

    /// ~300 столбиков на ТЕКУЩЕЕ окно при любом зуме (на 10-мин окне — секундная детализация).
    private var effectiveBucketMs: Int64 {
        let span = max(1, msFromDate(rangeEnd) - msFromDate(rangeStart))
        return max(1000, span / 300)
    }

    /// Левый край окна шириной w вокруг времени c, прижатый к границам истории.
    private func clampedWindowStart(around c: Date, width w: Double) -> Date {
        guard let o = bounds.oldest, let n = bounds.newest else { return c.addingTimeInterval(-w / 2) }
        if n.timeIntervalSince(o) <= w { return o }       // история короче окна → окно = вся история
        var start = c.addingTimeInterval(-w / 2)
        if start < o { start = o }
        if start.addingTimeInterval(w) > n { start = n.addingTimeInterval(-w) }
        return start
    }

    /// Держит cursor в комфортной зоне окна; при выходе перецентрирует страницу. true → density пересчитать.
    /// Страничный сдвиг (не каждый кадр) — поэтому density не дёргается при play на каждом тике.
    private func reframeWindowIfNeeded() -> Bool {
        // .full ИЛИ пустая история — окно не используется (иначе фантомный windowStart вокруг Date()).
        guard let w = zoom.seconds, bounds.oldest != nil else {
            if windowStart != nil { windowStart = nil; return true }
            return false
        }
        let margin = w * 0.15
        if let ws = windowStart,
           cursor >= ws.addingTimeInterval(margin), cursor <= ws.addingTimeInterval(w - margin) {
            return false                                  // в зоне — страницу не трогаем
        }
        // У края истории clamp упирается в тот же ws → возвращаем false, иначе density пересчитывался бы
        // вхолостую каждый кадр в крайних 15% окна (нарушало бы «страничный, не покадровый» сдвиг).
        let new = clampedWindowStart(around: cursor, width: w)
        let changed = (windowStart != new)
        windowStart = new
        return changed
    }

    private func refreshDensity() async {
        if let d = try? await timeline.density(from: rangeStart, to: rangeEnd, bucketMs: effectiveBucketMs) {
            density = d
        }
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
        _ = reframeWindowIfNeeded()
        await refreshDensity()
        // Прямое присваивание: до первого кадра истории frameAt вернёт nil — кадр надо ОЧИСТИТЬ,
        // иначе в пустой зоне залипает прежний кадр (детали-«Нет кадра» иначе недостижимы).
        current = try? await timeline.frameAt(cursor)
    }

    func seek(to t: Date) async {
        if isPlaying { pause() }        // ручная перемотка забирает управление у плеера
        cursor = t
        current = try? await timeline.frameAt(t)   // nil до начала истории → очищаем (см. refresh)
        if reframeWindowIfNeeded() { await refreshDensity() }   // окно сдвинулось (напр. coarse-seek слайдером)
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
            if reframeWindowIfNeeded() { await refreshDensity() }   // playhead дошёл до края окна → сдвиг страницы
        }
    }

    func setZoom(_ z: Zoom) async {
        zoom = z
        _ = reframeWindowIfNeeded()
        // guard на устаревание при быстром переключении зума
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
