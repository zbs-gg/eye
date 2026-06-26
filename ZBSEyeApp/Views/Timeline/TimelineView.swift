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
                ContentUnavailableView("Ошибка БД", systemImage: "exclamationmark.triangle", description: Text(err))
            } else {
                ProgressView("Инициализация…")
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
    /// Текущая сцена для правой панели (обновляется при смене cursor).
    @State private var currentScene: ActivityScene?
    @State private var sceneLoadTask: Task<Void, Never>?

    private var showResults: Bool { store.isSearching || !store.results.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Скруббер — всегда подложка; поиск выпадает Spotlight-оверлеем поверх (не mode-switch).
            ZStack(alignment: .top) {
                scrubber
                if showResults {
                    // Диммер в потоке (не overlay-окно) → без .ignoresSafeArea; тап вне списка закрывает.
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

    /// Горячие клавиши: Space (плеер), ←/→ (шаг по кадрам), Cmd+F (поиск), Esc (закрыть поиск).
    /// Невидимые кнопки — стандартный способ повесить шорткаты на вью. Space/стрелки отключены,
    /// пока фокус в поисковом поле (иначе печатать невозможно).
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

    // MARK: header (поиск + запись)

    private var header: some View {
        HStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск по экрану и аудио…", text: $store.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { searchFocused = true; Task { await store.runSearch() } }  // фокус остаётся → набор-уточнение
                if !store.searchQuery.isEmpty {
                    Button { store.clearSearch() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                // Семантика не готова (качается ~300MB / нет сети) — честно говорим, что поиск пока FTS-only.
                switch EmbeddingStatusStore.shared.status {
                case .loading:
                    Label("семантика качается", systemImage: "arrow.down.circle")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help("Модель multilingual-e5 скачивается (~300 МБ, один раз). Пока — поиск по точным словам.")
                case .failed:
                    Label("поиск по словам", systemImage: "wifi.slash")
                        .font(.caption2).foregroundStyle(.orange)
                        .help("Семантическая модель не загрузилась (нет сети?). Поиск работает по точным словам; повторим автоматически.")
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
                Label(env.recording.isCapturing ? "Стоп" : "Запись",
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
                .help("Кадров за сессию")
        }
        .padding(16)
    }

    // MARK: результаты поиска (Spotlight-оверлей)

    private var resultsOverlay: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if store.isSearching { ProgressView().controlSize(.small) }
                Text(store.isSearching ? "Поиск…" : "\(store.results.count) результатов")
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

    // MARK: скруббер

    private var scrubber: some View {
        VStack(spacing: 0) {
            if !store.hasData {
                ContentUnavailableView {
                    Label("История пуста", systemImage: "clock.badge.questionmark")
                } description: {
                    Text("Нажми «Запись» и поработай в приложениях — здесь появится перематываемая лента экрана.")
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
                                // Источник ≠ ax_quality: показываем, откуда реально пришёл текст (AX/OCR/смесь).
                                StatusPill(text: s.text, color: s.color, system: s.icon)
                            }
                        }
                        Divider()
                        // Саммари сцены вместо RAW OCR-дампа; fallback на сырой текст, если сцены нет.
                        // Гейт (Pro #4): показываем сцену ТОЛЬКО если её диапазон реально накрывает
                        // текущий кадр — иначе (устаревшая/чужая сцена при дебаунсе) показываем RAW.
                        if let scene = currentScene, scene.startTs <= c.ts, c.ts <= scene.endTs {
                            SceneSummaryCard(scene: scene) {
                                Task { await store.seek(to: scene.startTs) }
                            }
                        } else {
                            Text(c.text.isEmpty ? "(текст не извлечён)" : c.text)
                                .font(.callout).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .transition(.opacity)
                } else {
                    Text("Нет кадра на этот момент").foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .padding(14)
            .animation(reduceMotion ? .none : .smooth(duration: 0.2), value: store.current?.id)
            .animation(reduceMotion ? .none : .smooth(duration: 0.2), value: store.audioDetail?.id)
        }
        .onChange(of: store.cursor) { _, newCursor in
            // При смене курсора подгружаем сцену для правой панели.
            // Дебаунсим — только после settle (нет смысла грузить каждый кадр play).
            sceneLoadTask?.cancel()
            sceneLoadTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                currentScene = await env.sceneStore?.scene(for: newCursor)
            }
        }
    }

    /// Панель аудио-сегмента: транскрипт + прослушивание m4a (открывается кликом по аудио-хиту).
    private func audioCard(_ a: AudioDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(.tint)
                Text(a.channel == "system" ? "Системный звук" : "Микрофон").font(.headline)
                Text("· \(Int(a.durationSec))с").font(.caption).foregroundStyle(.secondary)
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
                Text("(транскрипта нет — найдено по времени)").font(.caption).foregroundStyle(.secondary)
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
        if store.isPlaying { store.pause() }            // ручная перемотка останавливает плеер сразу
        store.cursor = Date(timeIntervalSince1970: v)   // курсор следует мгновенно
        seekTask?.cancel()
        seekTask = Task {
            try? await Task.sleep(for: .milliseconds(70))
            if Task.isCancelled { return }
            await store.seek(to: Date(timeIntervalSince1970: v))
        }
    }

    // MARK: транспорт + ось времени

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
                // быстрые прыжки: «прошлый вторник 15:00» больше не требует возни со слайдером
                Button("Сегодня") { Task { await store.jumpToNewest() } }
                    .controlSize(.small)
                Button("Вчера") {
                    let y = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                    Task { await store.jump(to: y) }
                }
                .controlSize(.small)
                DatePicker("", selection: $jumpDate, displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.compact).controlSize(.small)
                    .onChange(of: jumpDate) { _, d in Task { await store.jump(to: d) } }
                    .help("Перейти к дате")
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
                            help: "Предыдущий кадр",
                            reduceMotion: reduceMotion) {
                Task { await store.stepBackward() }
            }

            PlayPauseButton(isPlaying: store.isPlaying,
                            reduceMotion: reduceMotion) {
                store.togglePlay()
            }

            TransportButton(systemImage: "forward.frame.fill",
                            help: "Следующий кадр",
                            reduceMotion: reduceMotion) {
                Task { await store.stepForward() }
            }

            Picker("", selection: Binding(get: { store.speed }, set: { store.setSpeed($0) })) {
                ForEach(TimelineStore.speeds, id: \.self) { s in Text("\(Int(s))×").tag(s) }
            }
            .pickerStyle(.segmented).fixedSize()
            .help("Скорость воспроизведения")
        }
    }

    static func qualityColor(_ q: String) -> Color {
        switch q {
        case "fullUseful": return .green
        case "partialUseful", "titleOnly": return .yellow
        case "ocr", "timedOut": return .orange
        case "sickPID": return .purple   // диагностика: процесс завис/недоступен — это НЕ пустой кадр
        default: return .red             // none
        }
    }
    static func qualityLabel(_ q: String) -> String {
        switch q {
        case "fullUseful": return "AX полный"
        case "partialUseful": return "AX частично"
        case "titleOnly": return "заголовок"
        case "ocr": return "OCR"
        case "timedOut": return "таймаут"
        case "sickPID": return "AX недоступен"
        default: return "пусто"
        }
    }

    /// Пилл источника текста (AX / OCR / AX+OCR). nil — если источников нет (context-only кадр).
    static func sourcePill(_ c: FrameDetail) -> (text: String, color: Color, icon: String)? {
        switch (c.hasAX, c.hasOCR) {
        case (true, true):  return ("AX+OCR", .teal, "rectangle.on.rectangle")
        case (true, false): return ("AX", .green, "macwindow")
        case (false, true): return ("OCR", .orange, "text.viewfinder")
        default:            return nil
        }
    }
}

// MARK: - транспортные кнопки с hover-микроанимацией

/// Bordered transport button с лёгким scale-эффектом при наведении.
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

/// Play/Pause кнопка с иконкой-crossfade при смене состояния.
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
        .help(isPlaying ? "Пауза" : "Воспроизвести")
        .scaleEffect(hovered && !reduceMotion ? 1.05 : 1.0)
        .animation(reduceMotion ? .none : .snappy(duration: 0.15), value: isPlaying)
        .animation(reduceMotion ? .none : .snappy(duration: 0.12), value: hovered)
        .onHover { hovered = $0 }
    }
}

// MARK: - кадр (crossfade при смене)

private struct FramePreview: View {
    let frameID: Int64?
    let url: URL?
    let reduceMotion: Bool
    @State private var loaded: LoadedFrame?     // что на экране — id+image атомарно (нет рассинхрона)

    private struct LoadedFrame { let id: Int64; let image: NSImage }

    var body: some View {
        ZStack {
            Color.black.opacity(0.04)
            if let loaded {
                // .id(loaded.id)+transition: уходящий кадр держит снимок СТАРОГО struct, входящий — новый.
                // id и image переключаются ОДНИМ присваиванием → фейд не ломается re-render'ом (фикс ревью).
                Image(nsImage: loaded.image).resizable().aspectRatio(contentMode: .fit)
                    .id(loaded.id)
                    .transition(.opacity)
            }
            if frameID != nil, url == nil {
                // Кадр без снимка (context-only/дедуп) — бейдж ПОВЕРХ прошлого кадра, фейд не рвём.
                ContentUnavailableView("Кадр без снимка", systemImage: "photo.badge.exclamationmark")
                    .background(.ultraThinMaterial)
            } else if loaded == nil {
                ContentUnavailableView("Нет кадра", systemImage: "photo")
            }
        }
        // При reduceMotion — мгновенная смена (nil duration = no animation); при норме — плавный crossfade.
        .animation(reduceMotion ? .none : .easeInOut(duration: 0.15), value: loaded?.id)
        .task(id: frameID) {
            guard let u = url, let fid = frameID else { return }   // url==nil: держим прошлый loaded под бейджем
            let img = await Task.detached(priority: .userInitiated) { FramePreview.thumbnail(u, maxPixel: 2400) }.value
            if Task.isCancelled { return }
            if let img { loaded = LoadedFrame(id: fid, image: img) }
        }
    }

    /// Даунскейл-thumbnail через ImageIO: не декодим полноразмерный HEIC на каждый кадр (память при play).
    /// nonisolated — чистая функция, зовётся из Task.detached вне MainActor.
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
    let audioBuckets: [DensityBucket]   // вторая дорожка (внизу): где в истории есть речь
    let start: Date
    let end: Date
    let cursor: Date
    let playing: Bool
    let reduceMotion: Bool
    let onSeek: (Date) -> Void

    // Анимированная позиция плейхеда — обновляется вместе с cursor, но плавно.
    @State private var animatedCursorFraction: Double = 0

    private var cursorFraction: Double {
        let span = max(1, end.timeIntervalSince1970 - start.timeIntervalSince1970)
        return (cursor.timeIntervalSince1970 - start.timeIntervalSince1970) / span
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Canvas для баров — не перерисовывает плейхед при каждом cursor-тике.
                Canvas { ctx, size in
                    let span = max(1, end.timeIntervalSince1970 - start.timeIntervalSince1970)
                    // верхняя дорожка — экран; нижние 6pt — аудио-полоска
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
                    // аудио: оранжевые сегменты присутствия речи (бинарная полоска, не высота)
                    for b in audioBuckets {
                        let x = (b.ts.timeIntervalSince1970 - start.timeIntervalSince1970) / span * size.width
                        guard x >= 0, x <= size.width else { continue }
                        let rect = CGRect(x: x, y: screenH + 1, width: max(1.5, size.width / 240), height: audioH - 2)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.orange.opacity(0.75)))
                    }
                }

                // Плейхед — отдельный слой, анимируется через animatedCursorFraction.
                // При ручном скрабе анимация не включается (мгновенно), только при авто-плее.
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
                // При воспроизведении — плавное движение плейхеда; при ручном скрабе — мгновенное.
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
