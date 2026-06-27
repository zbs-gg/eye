import SwiftUI
import AppKit
import ImageIO

struct TimelineView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if let store = env.timelineStore {
                TimelineBody(store: store)
                    .environment(env)
                    .task { await store.load(); store.startLive() }
            } else if let err = env.dataError {
                ContentUnavailableView("DB error", systemImage: "exclamationmark.triangle", description: Text(err))
            } else {
                ProgressView("Initializing…")
            }
        }
    }
}

private struct TimelineBody: View {
    @Bindable var store: TimelineStore
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var seekTask: Task<Void, Never>?
    @State private var jumpDate = Date()
    @FocusState private var searchFocused: Bool
    /// The current scene for the right panel (updates when the cursor changes).
    @State private var currentScene: ActivityScene?
    @State private var sceneLoadTask: Task<Void, Never>?

    private var showResults: Bool { store.isSearching || !store.results.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // The scrubber is always the backdrop; search drops in as a Spotlight overlay on top (not a mode-switch).
            ZStack(alignment: .top) {
                scrubber
                if showResults {
                    // The dimmer is in the flow (not an overlay window) → no .ignoresSafeArea; a tap outside the list closes it.
                    Rectangle().fill(.black.opacity(0.12))
                        .onTapGesture { store.clearSearch() }
                    resultsOverlay
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? .none : .easeInOut(duration: 0.18), value: showResults)
        }
        .background { shortcuts }
    }

    /// Hotkeys: Space (player), ←/→ (step by frames), Cmd+F (search), Esc (close search).
    /// Invisible buttons — the standard way to attach shortcuts to a view. Space/arrows are disabled
    /// while focus is in the search field (otherwise typing is impossible).
    @ViewBuilder private var shortcuts: some View {
        Group {
            if !searchFocused {
                Button("") { store.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("") { Task { await store.stepBackward() } }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { Task { await store.stepForward() } }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
            if showResults {
                Button("") { store.clearSearch(); searchFocused = false }
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: header (search + recording)

    private var header: some View {
        HStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search across screen and audio…", text: $store.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { searchFocused = true; Task { await store.runSearch() } }  // focus stays → type-to-refine
                if !store.searchQuery.isEmpty {
                    Button { store.clearSearch() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                // Semantics not ready (downloading ~300MB / no network) — we honestly say search is FTS-only for now.
                switch EmbeddingStatusStore.shared.status {
                case .loading:
                    Label("semantics downloading", systemImage: "arrow.down.circle")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help("The multilingual-e5 model is downloading (~300 MB, once). For now — search by exact words.")
                case .failed:
                    Label("word search", systemImage: "wifi.slash")
                        .font(.caption2).foregroundStyle(.orange)
                        .help("The semantic model didn't load (no network?). Search works by exact words; we'll retry automatically.")
                case .idle, .ready:
                    EmptyView()
                }
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .animation(reduceMotion ? .none : .snappy(duration: 0.15), value: store.searchQuery.isEmpty)

            Button {
                env.recording.toggle()
            } label: {
                Label(env.recording.isCapturing ? "Stop" : "Record",
                      systemImage: env.recording.isCapturing ? "stop.circle.fill" : "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(env.recording.isCapturing ? .red : .accentColor)
            .animation(reduceMotion ? .none : .snappy(duration: 0.2), value: env.recording.isCapturing)

            Text("\(env.recording.screenFrameCount)")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? .none : .snappy(duration: 0.25), value: env.recording.screenFrameCount)
                .help("Frames this session")
        }
        .padding(16)
    }

    // MARK: search results (Spotlight overlay)

    private var resultsOverlay: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if store.isSearching { ProgressView().controlSize(.small) }
                Text(store.isSearching ? "Searching…" : "\(store.results.count) results")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { store.clearSearch() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if !store.results.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(store.results, id: \.uniqueKey) { r in resultRow(r) }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 380)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .frame(maxWidth: 760)
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private func resultRow(_ r: SearchResult) -> some View {
        Button { Task { await store.select(r) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: r.kind == .audio ? "waveform" : "macwindow")
                    Text(r.appName ?? r.bundleId ?? "—").font(.subheadline.weight(.medium))
                    if let w = r.windowTitle { Text("· \(w)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    Text(r.ts.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(r.snippet).font(.callout).foregroundStyle(.primary).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: scrubber

    private var scrubber: some View {
        VStack(spacing: 0) {
            if !store.hasData {
                ContentUnavailableView {
                    Label("History is empty", systemImage: "clock.badge.questionmark")
                } description: {
                    Text("Press \"Record\" and work in your apps — a scrubbable screen reel will appear here.")
                }
            } else {
                HSplitView {
                    FramePreview(frameID: store.current?.id, url: store.imageURL(store.current?.relativePath),
                                 reduceMotion: reduceMotion)
                        .frame(minWidth: 320)
                    detailPanel
                        .frame(minWidth: 260, idealWidth: 320)
                }
                controls
            }
        }
    }

    private var detailPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let a = store.audioDetail {
                    audioCard(a)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity.combined(with: .move(edge: .top))
                        ))
                    Divider()
                }
                if let c = store.current {
                    Group {
                        Text(c.appName ?? c.bundleId ?? "—").font(.headline)
                        if let w = c.windowTitle { Text(w).font(.subheadline).foregroundStyle(.secondary) }
                        if let u = c.browserURL { Text(u).font(.caption).foregroundStyle(.blue).lineLimit(2) }
                        HStack {
                            Text(c.ts.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                            if let q = c.axQuality { StatusPill(text: Self.qualityLabel(q), color: Self.qualityColor(q)) }
                            if let s = Self.sourcePill(c) {
                                // Source ≠ ax_quality: we show where the text actually came from (AX/OCR/mixed).
                                StatusPill(text: s.text, color: s.color, system: s.icon)
                            }
                        }
                        Divider()
                        // The scene summary instead of a RAW OCR dump; fallback to raw text if there's no scene.
                        // Gate (Pro #4): we show the scene ONLY if its range actually covers
                        // the current frame — otherwise (a stale/foreign scene during debounce) we show RAW.
                        if let scene = currentScene, scene.startTs <= c.ts, c.ts <= scene.endTs {
                            SceneSummaryCard(scene: scene) {
                                Task { await store.seek(to: scene.startTs) }
                            }
                        } else {
                            Text(c.text.isEmpty ? "(no text extracted)" : c.text)
                                .font(.callout).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .transition(.opacity)
                } else {
                    Text("No frame at this moment").foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .padding(14)
            .animation(reduceMotion ? .none : .smooth(duration: 0.2), value: store.current?.id)
            .animation(reduceMotion ? .none : .smooth(duration: 0.2), value: store.audioDetail?.id)
        }
        .onChange(of: store.cursor) { _, newCursor in
            // When the cursor changes we load the scene for the right panel.
            // We debounce — only after it settles (no point loading every frame during play).
            sceneLoadTask?.cancel()
            sceneLoadTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                currentScene = await env.sceneStore?.scene(for: newCursor)
            }
        }
    }

    /// Audio segment panel: transcript + m4a playback (opens on a click on an audio hit).
    private func audioCard(_ a: AudioDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(.tint)
                Text(a.channel == "system" ? "System audio" : "Microphone").font(.headline)
                Text("· \(Int(a.durationSec))s").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { store.closeAudio() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            Text(a.ts.formatted(date: .abbreviated, time: .standard))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    if let url = store.imageURL(a.relativePath) { store.audioPlayer.toggle(url: url) }
                } label: {
                    Image(systemName: playIcon(a)).font(.title3)
                }
                .buttonStyle(.borderless)
                .animation(reduceMotion ? .none : .snappy(duration: 0.15), value: playIcon(a))
                ProgressView(value: isCurrent(a) ? store.audioPlayer.progress : 0)
                    .progressViewStyle(.linear)
                    .animation(reduceMotion ? .none : .linear(duration: 0.1), value: store.audioPlayer.progress)
            }
            if let t = a.transcript, !t.isEmpty {
                Text(t).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("(no transcript — found by time)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func isCurrent(_ a: AudioDetail) -> Bool {
        store.imageURL(a.relativePath) == store.audioPlayer.currentURL
    }
    private func playIcon(_ a: AudioDetail) -> String {
        isCurrent(a) && store.audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill"
    }

    private func scheduleSeek(toEpoch v: Double) {
        if store.isPlaying { store.pause() }            // a manual scrub stops the player immediately
        store.cursor = Date(timeIntervalSince1970: v)   // the cursor follows instantly
        seekTask?.cancel()
        seekTask = Task {
            try? await Task.sleep(for: .milliseconds(70))
            if Task.isCancelled { return }
            await store.seek(to: Date(timeIntervalSince1970: v))
        }
    }

    // MARK: transport + time axis

    private var controls: some View {
        VStack(spacing: 8) {
            DensityStrip(buckets: store.density, audioBuckets: store.audioDensity,
                         start: store.rangeStart, end: store.rangeEnd,
                         cursor: store.cursor, playing: store.isPlaying,
                         reduceMotion: reduceMotion,
                         onSeek: { scheduleSeek(toEpoch: $0.timeIntervalSince1970) })
                .frame(height: 46)

            if let lo = store.bounds.oldest?.timeIntervalSince1970,
               let hi = store.bounds.newest?.timeIntervalSince1970, hi > lo {
                Slider(value: Binding(
                    get: { min(max(store.cursor.timeIntervalSince1970, lo), hi) },
                    set: { scheduleSeek(toEpoch: $0) }
                ), in: lo...hi)
                .animation(reduceMotion ? .none : .smooth(duration: 0.15), value: store.cursor.timeIntervalSince1970)
            }

            HStack(spacing: 12) {
                transport
                Spacer(minLength: 8)
                Text(store.cursor.formatted(date: .abbreviated, time: .standard))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? .none : .snappy(duration: 0.2), value: store.cursor)
                Spacer(minLength: 8)
                // quick jumps: "last Tuesday 3pm" no longer needs slider fiddling
                Button("Today") { Task { await store.jumpToNewest() } }
                    .controlSize(.small)
                Button("Yesterday") {
                    let y = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                    Task { await store.jump(to: y) }
                }
                .controlSize(.small)
                DatePicker("", selection: $jumpDate, displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.compact).controlSize(.small)
                    .onChange(of: jumpDate) { _, d in Task { await store.jump(to: d) } }
                    .help("Go to a date")
                Picker("", selection: Binding(get: { store.zoom },
                                              set: { z in Task { await store.setZoom(z) } })) {
                    ForEach(TimelineStore.Zoom.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
                .animation(reduceMotion ? .none : .smooth(duration: 0.25), value: store.zoom)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    private var transport: some View {
        HStack(spacing: 8) {
            TransportButton(systemImage: "backward.frame.fill",
                            help: "Previous frame",
                            reduceMotion: reduceMotion) {
                Task { await store.stepBackward() }
            }

            PlayPauseButton(isPlaying: store.isPlaying,
                            reduceMotion: reduceMotion) {
                store.togglePlay()
            }

            TransportButton(systemImage: "forward.frame.fill",
                            help: "Next frame",
                            reduceMotion: reduceMotion) {
                Task { await store.stepForward() }
            }

            Picker("", selection: Binding(get: { store.speed }, set: { store.setSpeed($0) })) {
                ForEach(TimelineStore.speeds, id: \.self) { s in Text("\(Int(s))×").tag(s) }
            }
            .pickerStyle(.segmented).fixedSize()
            .help("Playback speed")
        }
    }

    static func qualityColor(_ q: String) -> Color {
        switch q {
        case "fullUseful": return .green
        case "partialUseful", "titleOnly": return .yellow
        case "ocr", "timedOut": return .orange
        case "sickPID": return .purple   // diagnostics: the process hung/is unavailable — this is NOT an empty frame
        default: return .red             // none
        }
    }
    static func qualityLabel(_ q: String) -> String {
        switch q {
        case "fullUseful": return "AX full"
        case "partialUseful": return "AX partial"
        case "titleOnly": return "title"
        case "ocr": return "OCR"
        case "timedOut": return "timeout"
        case "sickPID": return "AX unavailable"
        default: return "empty"
        }
    }

    /// The text source pill (AX / OCR / AX+OCR). nil — if there are no sources (a context-only frame).
    static func sourcePill(_ c: FrameDetail) -> (text: String, color: Color, icon: String)? {
        switch (c.hasAX, c.hasOCR) {
        case (true, true):  return ("AX+OCR", .teal, "rectangle.on.rectangle")
        case (true, false): return ("AX", .green, "macwindow")
        case (false, true): return ("OCR", .orange, "text.viewfinder")
        default:            return nil
        }
    }
}

// MARK: - transport buttons with a hover micro-animation

/// A bordered transport button with a slight scale effect on hover.
private struct TransportButton: View {
    let systemImage: String
    let help: String
    let reduceMotion: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.bordered)
        .help(help)
        .scaleEffect(hovered && !reduceMotion ? 1.06 : 1.0)
        .animation(reduceMotion ? .none : .snappy(duration: 0.12), value: hovered)
        .onHover { hovered = $0 }
    }
}

/// A Play/Pause button with an icon crossfade on state change.
private struct PlayPauseButton: View {
    let isPlaying: Bool
    let reduceMotion: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .frame(width: 30, height: 22)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.downUp.wholeSymbol))
        }
        .buttonStyle(.borderedProminent)
        .help(isPlaying ? "Pause" : "Play")
        .scaleEffect(hovered && !reduceMotion ? 1.05 : 1.0)
        .animation(reduceMotion ? .none : .snappy(duration: 0.15), value: isPlaying)
        .animation(reduceMotion ? .none : .snappy(duration: 0.12), value: hovered)
        .onHover { hovered = $0 }
    }
}

// MARK: - frame (crossfade on change)

private struct FramePreview: View {
    let frameID: Int64?
    let url: URL?
    let reduceMotion: Bool
    @State private var loaded: LoadedFrame?     // what's on screen — id+image atomically (no desync)

    private struct LoadedFrame { let id: Int64; let image: NSImage }

    var body: some View {
        ZStack {
            Color.black.opacity(0.04)
            if let loaded {
                // .id(loaded.id)+transition: the outgoing frame holds the snapshot of the OLD struct, the incoming — the new one.
                // id and image switch in ONE assignment → the fade isn't broken by a re-render (review fix).
                Image(nsImage: loaded.image).resizable().aspectRatio(contentMode: .fit)
                    .id(loaded.id)
                    .transition(.opacity)
            }
            if frameID != nil, url == nil {
                // A frame without a snapshot (context-only/dedup) — a badge OVER the previous frame, we don't break the fade.
                ContentUnavailableView("Frame without a snapshot", systemImage: "photo.badge.exclamationmark")
                    .background(.ultraThinMaterial)
            } else if loaded == nil {
                ContentUnavailableView("No frame", systemImage: "photo")
            }
        }
        // With reduceMotion — an instant change (nil duration = no animation); when normal — a smooth crossfade.
        .animation(reduceMotion ? .none : .easeInOut(duration: 0.15), value: loaded?.id)
        .task(id: frameID) {
            guard let u = url, let fid = frameID else { return }   // url==nil: keep the previous loaded under the badge
            let img = await Task.detached(priority: .userInitiated) { FramePreview.thumbnail(u, maxPixel: 2400) }.value
            if Task.isCancelled { return }
            if let img { loaded = LoadedFrame(id: fid, image: img) }
        }
    }

    /// A downscaled thumbnail via ImageIO: we don't decode a full-size HEIC for every frame (memory during play).
    /// nonisolated — a pure function, called from Task.detached off the MainActor.
    nonisolated static func thumbnail(_ url: URL, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - density strip

private struct DensityStrip: View {
    let buckets: [DensityBucket]
    let audioBuckets: [DensityBucket]   // the second track (at the bottom): where in history there's speech
    let start: Date
    let end: Date
    let cursor: Date
    let playing: Bool
    let reduceMotion: Bool
    let onSeek: (Date) -> Void

    // The animated playhead position — updates together with the cursor, but smoothly.
    @State private var animatedCursorFraction: Double = 0

    private var cursorFraction: Double {
        let span = max(1, end.timeIntervalSince1970 - start.timeIntervalSince1970)
        return (cursor.timeIntervalSince1970 - start.timeIntervalSince1970) / span
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Canvas for the bars — doesn't redraw the playhead on every cursor tick.
                Canvas { ctx, size in
                    let span = max(1, end.timeIntervalSince1970 - start.timeIntervalSince1970)
                    // top track — screen; the bottom 6pt — the audio strip
                    let audioH: CGFloat = audioBuckets.isEmpty ? 0 : 6
                    let screenH = size.height - audioH
                    let maxCount = max(1, buckets.map(\.count).max() ?? 1)
                    for b in buckets {
                        let x = (b.ts.timeIntervalSince1970 - start.timeIntervalSince1970) / span * size.width
                        guard x >= 0, x <= size.width else { continue }
                        let h = CGFloat(b.count) / CGFloat(maxCount) * screenH
                        let rect = CGRect(x: x, y: screenH - h, width: max(1.5, size.width / 240), height: h)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.accentColor.opacity(0.7)))
                    }
                    // audio: orange segments of speech presence (a binary strip, not height)
                    for b in audioBuckets {
                        let x = (b.ts.timeIntervalSince1970 - start.timeIntervalSince1970) / span * size.width
                        guard x >= 0, x <= size.width else { continue }
                        let rect = CGRect(x: x, y: screenH + 1, width: max(1.5, size.width / 240), height: audioH - 2)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.orange.opacity(0.75)))
                    }
                }

                // The playhead — a separate layer, animated via animatedCursorFraction.
                // During a manual scrub the animation doesn't engage (instant), only during auto-play.
                let cx = animatedCursorFraction * geo.size.width
                Rectangle()
                    .fill(playing ? Color.accentColor : Color.primary.opacity(0.6))
                    .frame(width: playing ? 2.5 : 1.5, height: geo.size.height)
                    .offset(x: max(0, cx - (playing ? 1.25 : 0.75)))
                    .animation(
                        (reduceMotion || !playing) ? .none : .linear(duration: 0.12),
                        value: animatedCursorFraction
                    )
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let frac = max(0, min(1, v.location.x / max(1, geo.size.width)))
                let span = end.timeIntervalSince1970 - start.timeIntervalSince1970
                onSeek(Date(timeIntervalSince1970: start.timeIntervalSince1970 + frac * span))
            })
            .onChange(of: cursor) { _, _ in
                // During playback — smooth playhead movement; during a manual scrub — instant.
                if playing && !reduceMotion {
                    withAnimation(.linear(duration: 0.12)) {
                        animatedCursorFraction = cursorFraction
                    }
                } else {
                    animatedCursorFraction = cursorFraction
                }
            }
            .onChange(of: start) { _, _ in animatedCursorFraction = cursorFraction }
            .onChange(of: end)   { _, _ in animatedCursorFraction = cursorFraction }
            .onAppear { animatedCursorFraction = cursorFraction }
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}
