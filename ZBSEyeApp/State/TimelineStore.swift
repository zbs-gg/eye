import Foundation
import Observation

/// The time-travel timeline model. The axis is TIME (not an array index). Holds a window [rangeStart, rangeEnd]
/// around the cursor, density for the density-strip, the current frame, and FTS search results.
@MainActor
@Observable
final class TimelineStore {
    /// Zoom = the width of the visible TIME window for the density-strip (overview+detail). The slider always spans the
    /// whole history (global position); the strip shows a window around the playhead. seconds=nil → all history.
    enum Zoom: String, CaseIterable, Identifiable {
        case full, day, hour, tenMin
        var id: String { rawValue }
        var seconds: Double? {
            switch self { case .full: nil; case .day: 86_400; case .hour: 3_600; case .tenMin: 600 }
        }
        var label: String {
            switch self { case .full: "All"; case .day: "Day"; case .hour: "Hour"; case .tenMin: "10 min" }
        }
    }

    @ObservationIgnored private let search: SearchService
    @ObservationIgnored private let timeline: TimelineService
    @ObservationIgnored let mediaDirectory: URL
    @ObservationIgnored private var searchGen = 0
    @ObservationIgnored private var playTask: Task<Void, Never>?
    @ObservationIgnored private var playGen = 0   // like searchGen: invalidates a stale player loop
    @ObservationIgnored private var windowStart: Date?   // left edge of the strip window; nil = all history (.full)
    @ObservationIgnored private var liveTask: Task<Void, Never>?

    var bounds = TimeBounds(oldest: nil, newest: nil)
    var cursor = Date()
    var zoom: Zoom = .full
    var current: FrameDetail?
    var density: [DensityBucket] = []
    var audioDensity: [DensityBucket] = []   // the strip's second track: where in history there's speech
    var searchQuery = ""
    var results: [SearchResult] = []
    var isSearching = false
    /// An open audio segment (click on an audio hit): transcript + playback. Previously an audio hit
    /// was a dead end — the nearest screen frame was shown, the transcript vanished.
    var audioDetail: AudioDetail?
    let audioPlayer = AudioPlayerStore()

    // Player: playback at the real cadence of captured frames, scaled by speed.
    var isPlaying = false
    var speed: Double = 1            // 1× / 2× / 4×
    static let speeds: [Double] = [1, 2, 4]

    // The density-strip window: at .full = all history; otherwise — a page [windowStart, +zoom.seconds].
    var rangeStart: Date {
        if let ws = windowStart, zoom.seconds != nil { return ws }
        return bounds.oldest ?? Date().addingTimeInterval(-1800)
    }
    var rangeEnd: Date {
        if let ws = windowStart, let w = zoom.seconds { return ws.addingTimeInterval(w) }
        return bounds.newest ?? Date()
    }
    var hasData: Bool { bounds.oldest != nil }

    /// ~300 bars for the CURRENT window at any zoom (on a 10-min window — second-level detail).
    private var effectiveBucketMs: Int64 {
        let span = max(1, msFromDate(rangeEnd) - msFromDate(rangeStart))
        return max(1000, span / 300)
    }

    /// The left edge of a window of width w around time c, clamped to the history bounds.
    private func clampedWindowStart(around c: Date, width w: Double) -> Date {
        guard let o = bounds.oldest, let n = bounds.newest else { return c.addingTimeInterval(-w / 2) }
        if n.timeIntervalSince(o) <= w { return o }       // history shorter than the window → window = all history
        var start = c.addingTimeInterval(-w / 2)
        if start < o { start = o }
        if start.addingTimeInterval(w) > n { start = n.addingTimeInterval(-w) }
        return start
    }

    /// Keeps the cursor in the window's comfort zone; on exit re-centers the page. true → recompute density.
    /// Paged shift (not every frame) — so density doesn't twitch during play on every tick.
    private func reframeWindowIfNeeded() -> Bool {
        // .full OR empty history — the window isn't used (otherwise a phantom windowStart around Date()).
        guard let w = zoom.seconds, bounds.oldest != nil else {
            if windowStart != nil { windowStart = nil; return true }
            return false
        }
        let margin = w * 0.15
        if let ws = windowStart,
           cursor >= ws.addingTimeInterval(margin), cursor <= ws.addingTimeInterval(w - margin) {
            return false                                  // inside the zone — don't touch the page
        }
        // At the edge of history the clamp lands on the same ws → return false, otherwise density would recompute
        // pointlessly every frame in the window's outer 15% (breaking the "paged, not per-frame" shift).
        let new = clampedWindowStart(around: cursor, width: w)
        let changed = (windowStart != new)
        windowStart = new
        return changed
    }

    private func refreshDensity() async {
        if let d = try? await timeline.density(from: rangeStart, to: rangeEnd, bucketMs: effectiveBucketMs) {
            density = d
        }
        if let a = try? await timeline.audioDensity(from: rangeStart, to: rangeEnd, bucketMs: effectiveBucketMs) {
            audioDensity = a
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

    /// Live timeline: while recording, bounds/density update by themselves (previously "History is empty" hung
    /// until you switched sections — the first experience of "pressed Record and nothing" was a silent failure).
    /// If the playhead is "stuck to the tail" (on the newest frame) — it follows new frames.
    func startLive() {
        guard liveTask == nil else { return }
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await self?.liveTick()
            }
        }
    }

    private func liveTick() async {
        guard !isPlaying else { return }                       // the player moves time itself
        guard let b = try? await timeline.bounds() else { return }
        guard b.newest != bounds.newest || b.oldest != bounds.oldest else { return }
        let wasEmpty = bounds.oldest == nil
        // "at the tail" = cursor on/after the previous newest (5s tolerance) — then we follow the recording
        let atTail = wasEmpty || (bounds.newest.map { cursor >= $0.addingTimeInterval(-5) } ?? true)
        bounds = b
        if atTail, let n = b.newest {
            cursor = n
            current = try? await timeline.frameAt(n)
        }
        _ = reframeWindowIfNeeded()
        await refreshDensity()
    }

    func refresh() async {
        _ = reframeWindowIfNeeded()
        await refreshDensity()
        // Direct assignment: before the first frame of history frameAt returns nil — the frame must be CLEARED,
        // otherwise the previous frame sticks in an empty zone (the "No frame" details would be unreachable).
        current = try? await timeline.frameAt(cursor)
    }

    func seek(to t: Date) async {
        if isPlaying { pause() }        // a manual scrub takes control away from the player
        cursor = t
        current = try? await timeline.frameAt(t)   // nil before the start of history → clear (see refresh)
        if reframeWindowIfNeeded() { await refreshDensity() }   // the window shifted (e.g. coarse-seek via the slider)
        // moved far from the open audio segment and it isn't playing → the card of someone else's moment closes
        if let a = audioDetail, !audioPlayer.isPlaying,
           abs(t.timeIntervalSince(a.ts)) > max(60, a.durationSec + 60) {
            closeAudio()
        }
    }

    // MARK: date navigation

    /// "Today" = the tail of history (the newest frame).
    func jumpToNewest() async {
        if let n = bounds.newest { await seek(to: n) }
    }

    /// Jump to a day: noon of the chosen date, clamped to the history bounds.
    func jump(to day: Date) async {
        let cal = Calendar.current
        let noon = cal.date(byAdding: .hour, value: 12, to: cal.startOfDay(for: day))
            ?? cal.startOfDay(for: day)
        var target = noon
        if let o = bounds.oldest, target < o { target = o }
        if let n = bounds.newest, target > n { target = n }
        await seek(to: target)
    }

    // MARK: player

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard hasData, !isPlaying else { return }                 // guard !isPlaying — no double start
        // only one frame total — nothing to play, don't blink the button play→pause
        if let o = bounds.oldest, let n = bounds.newest, o == n { return }
        // if we're at the end — start from the beginning of history (otherwise play "does nothing")
        if let newest = bounds.newest, cursor >= newest, let oldest = bounds.oldest { cursor = oldest }
        isPlaying = true
        startLoop()
    }

    func pause() {
        isPlaying = false
        playGen += 1            // invalidates any live playLoop (its check gen == playGen will fail)
        playTask?.cancel()
        playTask = nil
    }

    func setSpeed(_ s: Double) {
        speed = s
        // Restart the loop so the current long sleep recomputes for the new speed (otherwise lag up to 1.2s).
        if isPlaying { startLoop() }
    }

    /// Step by real frames (pauses — this is manual navigation). The current frame's id —
    /// the tie-breaker for equal ts (multi-monitor): each frame is visited exactly once.
    func stepForward() async {
        pause()
        let anchor = current?.ts ?? cursor   // anchor — the visible frame: cursor may have drifted via the slider
        if let f = try? await timeline.nextFrame(after: anchor, afterId: current?.id) {
            cursor = f.ts; current = f
        }
    }
    func stepBackward() async {
        pause()
        let anchor = current?.ts ?? cursor   // otherwise the first "step back" after a seek returned the same frame
        if let f = try? await timeline.prevFrame(before: anchor, beforeId: current?.id) {
            cursor = f.ts; current = f
        }
    }

    private func startLoop() {
        playGen += 1
        let gen = playGen
        playTask?.cancel()
        playTask = Task { [weak self] in await self?.playLoop(gen: gen) }
    }

    private func playLoop(gen: Int) async {
        // gen == playGen — this loop is current; pause()/a new startLoop() bump playGen and evict the old one.
        while isPlaying && !Task.isCancelled && gen == playGen {
            // try? flattens the Optional return: both a thrown DB error and the end of history → nil → stop.
            let anchor = current?.ts ?? cursor
            guard let next = try? await timeline.nextFrame(after: anchor, afterId: current?.id)
            else { pause(); return }
            // The real gap to the next frame / speed; max(0,…) covers a zero/reverse gap
            // (reverse scrub, frames with equal ts); cap 1.2s so idle gaps don't freeze the player.
            let gap = max(0, next.ts.timeIntervalSince(cursor))
            let wait = min(max(gap / speed, 0.05), 1.2)
            try? await Task.sleep(for: .seconds(wait))
            guard isPlaying, !Task.isCancelled, gen == playGen else { return }  // don't write a stale cursor
            cursor = next.ts
            current = next
            if reframeWindowIfNeeded() { await refreshDensity() }   // the playhead reached the window's edge → page shift
        }
    }

    func setZoom(_ z: Zoom) async {
        zoom = z
        _ = reframeWindowIfNeeded()
        // guard against staleness on fast zoom switching; update BOTH tracks (otherwise the orange
        // audio strip kept the buckets of the previous window — the strip lied about where the calls are)
        let d = try? await timeline.density(from: rangeStart, to: rangeEnd, bucketMs: effectiveBucketMs)
        let a = try? await timeline.audioDensity(from: rangeStart, to: rangeEnd, bucketMs: effectiveBucketMs)
        guard zoom == z else { return }
        if let d { density = d }
        if let a { audioDensity = a }
    }

    func runSearch() async {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; return }
        AchievementCounters.bump(.searches)                 // "Detective" achievement
        searchGen += 1
        let gen = searchGen
        isSearching = true
        let r = (try? await search.search(query: q)) ?? []
        guard gen == searchGen else { return }   // a stale result arrived — ignore
        results = r
        isSearching = false
    }

    func clearSearch() {
        searchQuery = ""
        results = []
        isSearching = false      // otherwise showResults (isSearching||!results) keeps the overlay open
        searchGen += 1           // invalidate any in-flight runSearch — its result will be dropped (gen != searchGen)
    }

    func select(_ r: SearchResult) async {
        pause()                // jumping to a hit = manual navigation, not autoplay
        results = []
        searchQuery = ""
        cursor = r.ts          // cursor first — refresh computes the frame+density for the new moment
        await refresh()
        // Audio hit: open the transcript/playback panel (instead of silently losing the found call).
        if r.kind == .audio {
            if audioDetail?.id != r.id { audioPlayer.stop() }   // call A's audio must not play under card B
            audioDetail = try? await timeline.audioDetail(id: r.id)
        } else {
            closeAudio()
        }
    }

    func closeAudio() {
        audioPlayer.stop()
        audioDetail = nil
    }

    func imageURL(_ relativePath: String?) -> URL? {
        relativePath.map { mediaDirectory.appendingPathComponent($0) }
    }
}
