import AppKit
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
    @ObservationIgnored private let coverageQuery: CaptureCoverageQuery?
    @ObservationIgnored let mediaDirectory: URL
    @ObservationIgnored let imageLoader: VisualFrameImageLoader
    @ObservationIgnored private var searchGen = 0
    @ObservationIgnored private var coverageGen = 0
    @ObservationIgnored private var playTask: Task<Void, Never>?
    @ObservationIgnored private var playGen = 0   // like searchGen: invalidates a stale player loop
    @ObservationIgnored private var windowStart: Date?   // left edge of the strip window; nil = all history (.full)
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var visualLoadTask: Task<Void, Never>?
    @ObservationIgnored private var visualGeneration = 0
    /// One monotonic token for every direct user movement through history. It
    /// is bumped synchronously at intent time, before any database/image await,
    /// so an older seek can never write over a newer one when it comes back.
    @ObservationIgnored private var navigationGeneration = 0
    @ObservationIgnored private var followsLiveTail = true
    @ObservationIgnored private var isPresentationActive = false

    var bounds = TimeBounds(oldest: nil, newest: nil)
    var cursor = Date()
    var zoom: Zoom = .full
    var current: FrameDetail?
    var visualFrames: [FrameVisualRef] = []
    var selectedVisualID: Int64?
    var previewVisual: FrameVisualRef?
    var previewImage: NSImage?
    var isVisualLoading = false
    var density: [DensityBucket] = []
    var audioDensity: [DensityBucket] = []   // the strip's second track: where in history there's speech
    var callSpans: [CallTimelineSpan] = []
    var searchQuery = ""
    var results: [SearchResult] = []
    var isSearching = false
    var coverageDisclosure: CaptureCoverageDisclosure = .clean
    /// An open audio segment (click on an audio hit): transcript + playback. Previously an audio hit
    /// was a dead end — the nearest screen frame was shown, the transcript vanished.
    var audioDetail: AudioDetail?
    var selectedCallID: Int64?
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
    var selectedMomentAskScope: AskScope {
        .moment(current?.ts ?? cursor)
    }
    var selectedDayAskScope: AskScope {
        .day(current?.ts ?? cursor)
    }
    var visibleRangeAskScope: AskScope {
        .range(from: rangeStart, to: rangeEnd)
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

    private func navigationIsCurrent(_ expected: Int?) -> Bool {
        expected == nil || expected == navigationGeneration
    }

    @discardableResult
    private func beginUserNavigation() -> Int {
        navigationGeneration &+= 1
        // A visual load may be suspended in ImageIO or SQLite. Invalidate it
        // now, not later when the next lookup happens to start.
        visualGeneration &+= 1
        visualLoadTask?.cancel()
        visualLoadTask = nil
        isVisualLoading = false
        return navigationGeneration
    }

    private func refreshDensity(navigationGeneration expected: Int? = nil) async {
        let from = rangeStart
        let to = rangeEnd
        let bucketMs = effectiveBucketMs
        if let d = try? await timeline.density(from: from, to: to, bucketMs: bucketMs) {
            guard navigationIsCurrent(expected) else { return }
            density = d
        }
        guard navigationIsCurrent(expected) else { return }
        if let a = try? await timeline.audioDensity(from: from, to: to, bucketMs: bucketMs) {
            guard navigationIsCurrent(expected) else { return }
            audioDensity = a
        }
        guard navigationIsCurrent(expected) else { return }
        if let calls = try? await timeline.callSpans(from: from, to: to) {
            guard navigationIsCurrent(expected) else { return }
            callSpans = calls
        }
        guard navigationIsCurrent(expected) else { return }
        await refreshCoverage(
            from: from,
            to: to,
            navigationGeneration: expected
        )
    }

    init(
        search: SearchService,
        timeline: TimelineService,
        coverage: CaptureCoverageQuery? = nil,
        mediaDirectory: URL,
        imageLoader: VisualFrameImageLoader
    ) {
        self.search = search
        self.timeline = timeline
        coverageQuery = coverage
        self.mediaDirectory = mediaDirectory
        self.imageLoader = imageLoader
    }

    var previewCarriesEarlierFrame: Bool {
        guard let previewVisual else { return false }
        return current?.id != previewVisual.id
    }

    /// Starts a latest-wins visual lookup. A previous preview may remain while
    /// a newer image loads only when it is still in the selected moment's past;
    /// an image from the future is cleared immediately.
    private func refreshVisualContext(
        at time: Date,
        anchorID: Int64? = nil,
        navigationGeneration expectedNavigationGeneration: Int? = nil
    ) async {
        guard isPresentationActive,
              navigationIsCurrent(expectedNavigationGeneration) else { return }
        visualLoadTask?.cancel()
        visualGeneration += 1
        let generation = visualGeneration
        visualFrames = []
        selectedVisualID = nil
        if let previewVisual,
           previewIsAfterAnchor(previewVisual, time: time, anchorID: anchorID) {
            self.previewVisual = nil
            previewImage = nil
        }
        isVisualLoading = true

        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performVisualLoad(
                at: time,
                anchorID: anchorID,
                generation: generation,
                navigationGeneration: expectedNavigationGeneration
            )
        }
        visualLoadTask = task
        await task.value
        guard isPresentationActive,
              navigationIsCurrent(expectedNavigationGeneration) else { return }
        if generation == visualGeneration {
            isVisualLoading = false
            visualLoadTask = nil
        }
    }

    private func previewIsAfterAnchor(
        _ preview: FrameVisualRef,
        time: Date,
        anchorID: Int64?
    ) -> Bool {
        if preview.ts != time { return preview.ts > time }
        guard let anchorID else { return false }
        return preview.id > anchorID
    }

    private func performVisualLoad(
        at time: Date,
        anchorID: Int64?,
        generation: Int,
        navigationGeneration expectedNavigationGeneration: Int?
    ) async {
        guard !Task.isCancelled,
              isPresentationActive,
              navigationIsCurrent(expectedNavigationGeneration),
              let initialWindow = try? await timeline.visualWindow(
                  atOrBefore: time,
                  anchorID: anchorID
              ), generation == visualGeneration,
              isPresentationActive,
              navigationIsCurrent(expectedNavigationGeneration) else { return }

        visualFrames = initialWindow.frames
        selectedVisualID = initialWindow.selectedID
        imageLoader.replacePrefetch(with: initialWindow.frames.compactMap { frame in
            guard frame.id != initialWindow.selectedID else { return nil }
            return VisualFrameImageRequest(
                relativePath: frame.relativePath,
                maxPixel: 360
            )
        })

        guard var candidate = initialWindow.selected else {
            previewVisual = nil
            previewImage = nil
            return
        }

        var visited: Set<Int64> = []
        while !Task.isCancelled, generation == visualGeneration,
              isPresentationActive,
              navigationIsCurrent(expectedNavigationGeneration),
              visited.insert(candidate.id).inserted {
            if let image = await imageLoader.image(
                relativePath: candidate.relativePath,
                maxPixel: 2_400,
                priority: .current
            ) {
                guard !Task.isCancelled, generation == visualGeneration,
                      isPresentationActive,
                      navigationIsCurrent(expectedNavigationGeneration) else { return }
                previewVisual = candidate
                previewImage = image
                selectedVisualID = candidate.id

                // A missing current file may have pushed the preview beyond the
                // initial two-item look-back. Re-center so the strip remains
                // exactly 2 previous + current + 4 next around what is shown.
                if candidate.id != initialWindow.selectedID,
                   let fallbackWindow = try? await timeline.visualWindow(
                       atOrBefore: time,
                       anchorID: candidate.id
                   ), generation == visualGeneration,
                   isPresentationActive,
                   navigationIsCurrent(expectedNavigationGeneration) {
                    visualFrames = fallbackWindow.frames
                    selectedVisualID = candidate.id
                    imageLoader.replacePrefetch(with: fallbackWindow.frames.compactMap { frame in
                        guard frame.id != candidate.id else { return nil }
                        return VisualFrameImageRequest(
                            relativePath: frame.relativePath,
                            maxPixel: 360
                        )
                    })
                }
                return
            }
            guard !Task.isCancelled, generation == visualGeneration,
                  isPresentationActive,
                  navigationIsCurrent(expectedNavigationGeneration),
                  let previous = try? await timeline.previousVisualFrame(before: candidate) else { break }
            candidate = previous
        }

        guard !Task.isCancelled, generation == visualGeneration,
              isPresentationActive,
              navigationIsCurrent(expectedNavigationGeneration) else { return }
        previewVisual = nil
        previewImage = nil
        selectedVisualID = nil
    }

    private func refreshCoverage(
        from: Date?,
        to: Date?,
        navigationGeneration expectedNavigationGeneration: Int? = nil
    ) async {
        guard navigationIsCurrent(expectedNavigationGeneration) else { return }
        coverageGen += 1
        let generation = coverageGen
        let disclosure: CaptureCoverageDisclosure
        guard let coverageQuery else {
            disclosure = .clean
            guard generation == coverageGen,
                  navigationIsCurrent(expectedNavigationGeneration) else { return }
            coverageDisclosure = disclosure
            return
        }
        do {
            disclosure = try await coverageQuery.disclosure(from: from, to: to)
        } catch {
            disclosure = .metadataUnavailable
        }
        guard generation == coverageGen,
              navigationIsCurrent(expectedNavigationGeneration) else { return }
        coverageDisclosure = disclosure
    }

    func load() async {
        let generation = navigationGeneration
        if let b = try? await timeline.bounds() {
            guard generation == navigationGeneration else { return }
            bounds = b
            if let newest = b.newest { cursor = newest }
            followsLiveTail = true
        }
        guard generation == navigationGeneration else { return }
        await refresh(navigationGeneration: generation)
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

    func setPresentationActive(_ active: Bool) {
        guard isPresentationActive != active else { return }
        isPresentationActive = active
        if !active {
            visualGeneration &+= 1
            visualLoadTask?.cancel()
            visualLoadTask = nil
            imageLoader.cancelPrefetch()
            isVisualLoading = false
            return
        }

        // Restore the selected moment only after Timeline is visible again.
        // The captured token prevents an older activation task from racing a
        // seek or a new selection made immediately afterwards.
        let generation = navigationGeneration
        let selectedTime = cursor
        let anchorID = current?.id
        Task { @MainActor [weak self] in
            guard let self,
                  self.isPresentationActive,
                  self.navigationGeneration == generation else { return }
            await self.refreshVisualContext(
                at: selectedTime,
                anchorID: anchorID,
                navigationGeneration: generation
            )
        }
    }

    /// Drop every strong reference to decoded history pixels at a manual
    /// privacy-erasure boundary. The shared loader is invalidated separately
    /// by AppEnvironment because Activities uses it too.
    func discardVisualStateForPrivacyErase() {
        visualGeneration &+= 1
        navigationGeneration &+= 1
        visualLoadTask?.cancel()
        visualLoadTask = nil
        imageLoader.cancelPrefetch()
        visualFrames = []
        selectedVisualID = nil
        previewVisual = nil
        previewImage = nil
        isVisualLoading = false
    }

    private func liveTick() async {
        guard isPresentationActive else { return }
        guard !isPlaying else { return }                       // the player moves time itself
        let generation = navigationGeneration
        guard let b = try? await timeline.bounds() else { return }
        guard generation == navigationGeneration, !isPlaying else { return }
        guard b.newest != bounds.newest || b.oldest != bounds.oldest else { return }
        bounds = b
        if followsLiveTail, let n = b.newest {
            cursor = n
            let loadedCurrent = try? await timeline.frameAt(n)
            guard generation == navigationGeneration, followsLiveTail else { return }
            current = loadedCurrent
            await refreshVisualContext(at: n, anchorID: current?.id)
        }
        guard generation == navigationGeneration else { return }
        _ = reframeWindowIfNeeded()
        await refreshDensity(navigationGeneration: generation)
    }

    /// Immediate post-commit hook for AppEnvironment. It preserves the same
    /// four-second poll as a safety net, but a live Timeline can move as soon as
    /// IngestService has durably committed a frame.
    func noteFrameAvailable(at timestamp: Date) async {
        guard isPresentationActive else { return }
        let generation = navigationGeneration
        guard !isPlaying, let b = try? await timeline.bounds() else { return }
        guard generation == navigationGeneration, !isPlaying else { return }
        let changed = b.newest != bounds.newest || b.oldest != bounds.oldest
        bounds = b
        if followsLiveTail, let newest = b.newest {
            cursor = newest
            let loadedCurrent = try? await timeline.frameAt(newest)
            guard generation == navigationGeneration, followsLiveTail else { return }
            current = loadedCurrent
            await refreshVisualContext(
                at: newest,
                anchorID: current?.id
            )
        }
        guard generation == navigationGeneration else { return }
        if changed || timestamp >= rangeStart {
            _ = reframeWindowIfNeeded()
            await refreshDensity(navigationGeneration: generation)
        }
    }

    func refresh(navigationGeneration expectedNavigationGeneration: Int? = nil) async {
        guard navigationIsCurrent(expectedNavigationGeneration) else { return }
        _ = reframeWindowIfNeeded()
        await refreshDensity(navigationGeneration: expectedNavigationGeneration)
        guard navigationIsCurrent(expectedNavigationGeneration) else { return }
        // Direct assignment: before the first frame of history frameAt returns nil — the frame must be CLEARED,
        // otherwise the previous frame sticks in an empty zone (the "No frame" details would be unreachable).
        let loadedCurrent = try? await timeline.frameAt(cursor)
        guard navigationIsCurrent(expectedNavigationGeneration) else { return }
        current = loadedCurrent
        await refreshVisualContext(
            at: cursor,
            anchorID: current?.id,
            navigationGeneration: expectedNavigationGeneration
        )
    }

    func seek(to t: Date) async {
        if isPlaying { pause() }        // a manual scrub takes control away from the player
        let generation = beginUserNavigation()
        followsLiveTail = false
        cursor = t
        let loadedCurrent = try? await timeline.frameAt(t)   // nil before the start of history → clear (see refresh)
        guard generation == navigationGeneration else { return }
        current = loadedCurrent
        await refreshVisualContext(
            at: t,
            anchorID: current?.id,
            navigationGeneration: generation
        )
        guard generation == navigationGeneration else { return }
        if reframeWindowIfNeeded() { await refreshDensity(navigationGeneration: generation) }   // the window shifted (e.g. coarse-seek via the slider)
        guard generation == navigationGeneration else { return }
        // moved far from the open audio segment and it isn't playing → the card of someone else's moment closes
        if let a = audioDetail, !audioPlayer.isPlaying,
           abs(t.timeIntervalSince(a.ts)) > max(60, a.durationSec + 60) {
            closeAudio()
        }
    }

    /// Slider and density-strip drags have a short debounce before their
    /// database lookup. Mark them as manual immediately so a live frame cannot
    /// snap the thumb back to the tail during those 70 milliseconds.
    func beginManualScrub() {
        if isPlaying { pause() }
        _ = beginUserNavigation()
        followsLiveTail = false
    }

    // MARK: date navigation

    /// "Today" = the tail of history (the newest frame).
    func jumpToNewest() async {
        guard let newest = bounds.newest else { return }
        let generation = beginUserNavigation()
        followsLiveTail = true
        cursor = newest
        let loadedCurrent = try? await timeline.frameAt(newest)
        guard generation == navigationGeneration else { return }
        current = loadedCurrent
        await refreshVisualContext(
            at: newest,
            anchorID: current?.id,
            navigationGeneration: generation
        )
        guard generation == navigationGeneration else { return }
        if reframeWindowIfNeeded() { await refreshDensity(navigationGeneration: generation) }
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
        followsLiveTail = false
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
        let generation = beginUserNavigation()
        followsLiveTail = false
        let anchor = current?.ts ?? cursor   // anchor — the visible frame: cursor may have drifted via the slider
        if let f = try? await timeline.nextFrame(after: anchor, afterId: current?.id) {
            guard generation == navigationGeneration else { return }
            cursor = f.ts; current = f
            await refreshVisualContext(
                at: f.ts,
                anchorID: f.id,
                navigationGeneration: generation
            )
        }
    }
    func stepBackward() async {
        pause()
        let generation = beginUserNavigation()
        followsLiveTail = false
        let anchor = current?.ts ?? cursor   // otherwise the first "step back" after a seek returned the same frame
        if let f = try? await timeline.prevFrame(before: anchor, beforeId: current?.id) {
            guard generation == navigationGeneration else { return }
            cursor = f.ts; current = f
            await refreshVisualContext(
                at: f.ts,
                anchorID: f.id,
                navigationGeneration: generation
            )
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
            await refreshVisualContext(
                at: next.ts,
                anchorID: next.id
            )
            guard isPlaying, !Task.isCancelled, gen == playGen else { return }
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
        let calls = try? await timeline.callSpans(from: rangeStart, to: rangeEnd)
        guard zoom == z else { return }
        if let d { density = d }
        if let a { audioDensity = a }
        if let calls { callSpans = calls }
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
        await refreshCoverage(from: nil, to: nil)
        isSearching = false
    }

    func clearSearch() {
        searchQuery = ""
        results = []
        isSearching = false      // otherwise showResults (isSearching||!results) keeps the overlay open
        searchGen += 1           // invalidate any in-flight runSearch — its result will be dropped (gen != searchGen)
        Task { [weak self] in
            guard let self else { return }
            await self.refreshCoverage(from: self.rangeStart, to: self.rangeEnd)
        }
    }

    func select(_ r: SearchResult) async {
        pause()                // jumping to a hit = manual navigation, not autoplay
        let generation = beginUserNavigation()
        followsLiveTail = false
        results = []
        searchQuery = ""
        cursor = r.ts          // cursor first — refresh computes the frame+density for the new moment
        if r.kind == .call {
            closeAudio()
            selectedCallID = r.id
            return
        }
        await refresh(navigationGeneration: generation)
        guard generation == navigationGeneration else { return }
        // Audio hit: open the transcript/playback panel (instead of silently losing the found call).
        if r.kind == .audio {
            if audioDetail?.id != r.id { audioPlayer.stop() }   // call A's audio must not play under card B
            let loadedAudioDetail = try? await timeline.audioDetail(id: r.id)
            guard generation == navigationGeneration else { return }
            audioDetail = loadedAudioDetail
        } else {
            closeAudio()
        }
    }

    func openCall(_ call: CallTimelineSpan) {
        pause()
        _ = beginUserNavigation()
        followsLiveTail = false
        cursor = call.start
        closeAudio()
        selectedCallID = call.id
    }

    func closeCall() {
        selectedCallID = nil
    }

    func closeAudio() {
        audioPlayer.stop()
        audioDetail = nil
    }

    func selectVisual(_ frame: FrameVisualRef) async {
        pause()
        let generation = beginUserNavigation()
        followsLiveTail = false
        cursor = frame.ts
        let loadedCurrent = try? await timeline.frameDetail(id: frame.id)
        guard generation == navigationGeneration else { return }
        current = loadedCurrent
        await refreshVisualContext(
            at: frame.ts,
            anchorID: frame.id,
            navigationGeneration: generation
        )
        guard generation == navigationGeneration else { return }
        if reframeWindowIfNeeded() { await refreshDensity(navigationGeneration: generation) }
    }

    func imageURL(_ relativePath: String?) -> URL? {
        relativePath.map { mediaDirectory.appendingPathComponent($0) }
    }
}
