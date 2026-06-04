import SwiftUI
import AppKit

struct TimelineView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if let store = env.timelineStore {
                TimelineBody(store: store)
                    .environment(env)
                    .task { await store.load() }
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
    @State private var seekTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !store.results.isEmpty {
                resultsList
            } else {
                scrubber
            }
        }
    }

    // MARK: header (поиск + запись)

    private var header: some View {
        HStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск по экрану и аудио…", text: $store.searchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await store.runSearch() } }
                if !store.searchQuery.isEmpty {
                    Button { store.clearSearch() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

            Button {
                env.recording.toggle()
            } label: {
                Label(env.recording.isCapturing ? "Стоп" : "Запись",
                      systemImage: env.recording.isCapturing ? "stop.circle.fill" : "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(env.recording.isCapturing ? .red : .accentColor)

            Text("\(env.recording.screenFrameCount)")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .help("Кадров за сессию")
        }
        .padding(16)
    }

    // MARK: результаты поиска

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if store.isSearching { ProgressView().padding() }
                Text("\(store.results.count) результатов").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                ForEach(store.results) { r in
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
            }
            .padding(16)
        }
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
                    FramePreview(url: store.imageURL(store.current?.relativePath))
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
                if let c = store.current {
                    Text(c.appName ?? c.bundleId ?? "—").font(.headline)
                    if let w = c.windowTitle { Text(w).font(.subheadline).foregroundStyle(.secondary) }
                    if let u = c.browserURL { Text(u).font(.caption).foregroundStyle(.blue).lineLimit(2) }
                    HStack {
                        Text(c.ts.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                        if let q = c.axQuality { StatusPill(text: q, color: q == "ocr" ? .orange : .green) }
                    }
                    Divider()
                    Text(c.text.isEmpty ? "(текст не извлечён)" : c.text)
                        .font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Нет кадра на этот момент").foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            DensityStrip(buckets: store.density, start: store.rangeStart, end: store.rangeEnd, cursor: store.cursor)
                .frame(height: 36)

            if let lo = store.bounds.oldest?.timeIntervalSince1970,
               let hi = store.bounds.newest?.timeIntervalSince1970, hi > lo {
                Slider(value: Binding(
                    get: { min(max(store.cursor.timeIntervalSince1970, lo), hi) },
                    set: { v in
                        store.cursor = Date(timeIntervalSince1970: v)
                        seekTask?.cancel()
                        seekTask = Task {
                            try? await Task.sleep(for: .milliseconds(70))
                            if Task.isCancelled { return }
                            await store.seek(to: Date(timeIntervalSince1970: v))
                        }
                    }
                ), in: lo...hi)
            }

            HStack {
                Text(store.cursor.formatted(date: .abbreviated, time: .standard))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(get: { store.zoom },
                                              set: { z in Task { await store.setZoom(z) } })) {
                    ForEach(TimelineStore.Zoom.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }
}

// MARK: - кадр

private struct FramePreview: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.04)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                ContentUnavailableView("Нет кадра", systemImage: "photo")
            }
        }
        .task(id: url) {
            let u = url
            image = await Task.detached { u.flatMap { NSImage(contentsOf: $0) } }.value
        }
    }
}

// MARK: - density strip

private struct DensityStrip: View {
    let buckets: [DensityBucket]
    let start: Date
    let end: Date
    let cursor: Date

    var body: some View {
        Canvas { ctx, size in
            let span = max(1, end.timeIntervalSince1970 - start.timeIntervalSince1970)
            let maxCount = max(1, buckets.map(\.count).max() ?? 1)
            for b in buckets {
                let x = (b.ts.timeIntervalSince1970 - start.timeIntervalSince1970) / span * size.width
                guard x >= 0, x <= size.width else { continue }
                let h = CGFloat(b.count) / CGFloat(maxCount) * size.height
                let rect = CGRect(x: x, y: size.height - h, width: max(1.5, size.width / 200), height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                         with: .color(.accentColor.opacity(0.7)))
            }
            // курсор
            let cx = (cursor.timeIntervalSince1970 - start.timeIntervalSince1970) / span * size.width
            ctx.stroke(Path { p in p.move(to: CGPoint(x: cx, y: 0)); p.addLine(to: CGPoint(x: cx, y: size.height)) },
                       with: .color(.primary.opacity(0.5)), lineWidth: 1)
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}
