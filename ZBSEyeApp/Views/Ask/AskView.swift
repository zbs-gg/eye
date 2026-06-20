import SwiftUI

/// «Спроси свою память»: вопрос на естественном языке → локальная LLM отвечает по найденным фрагментам
/// истории экрана и разговоров (RAG, cross-lingual). Полностью на устройстве — аналог «Ask Rewind», без облака.
struct AskView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if let store = env.ask {
                AskBody(store: store)
            } else {
                ContentUnavailableView("Инициализация…", systemImage: "questionmark.bubble")
            }
        }
        .navigationTitle("Спроси")
    }
}

private struct AskBody: View {
    @Bindable var store: AskStore
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            if store.messages.isEmpty {
                emptyState
            } else {
                conversation
            }
            Divider()
            inputBar
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(store.messages) { m in
                        MessageRow(message: m).id(m.id)
                    }
                    if store.busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Думаю над твоей историей…").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("busy")
                    }
                }
                .padding(16)
            }
            .onChange(of: store.messages.count) {
                if let last = store.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !store.llmReady {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Нужна локальная LLM", systemImage: "exclamationmark.triangle")
                                .font(.headline)
                            Text("Ответы генерирует локальная модель (Ollama / LM Studio / mlx_lm.server) — "
                                 + "никакого облака. Укажи endpoint и модель в «Подключениях».")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Открыть Подключения") { env.selectedSection = .connections }
                        }
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Спроси свою память", systemImage: "sparkles").font(.headline)
                        Text("Задай вопрос обычным языком — ZBS Eye найдёт нужные моменты в истории экрана и "
                             + "разговоров и ответит по ним, со ссылками на источники. Всё на устройстве.")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(Self.examples, id: \.self) { ex in
                            Button { store.input = ex; store.send() } label: {
                                Label(ex, systemImage: "text.magnifyingglass").font(.callout)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                            .disabled(!store.llmReady)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(store.llmReady ? "Спроси про свою историю…" : "Сначала настрой локальную LLM в «Подключениях»",
                      text: $store.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .onSubmit { store.send() }
                .disabled(!store.llmReady || store.busy)
            if !store.messages.isEmpty {
                Button { store.clear() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Очистить диалог")
            }
            Button { store.send() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(!store.canSend)
        }
        .padding(12)
    }

    static let examples = [
        "Что я читал про Swift concurrency на этой неделе?",
        "О чём был последний созвон?",
        "Какой адрес мне присылали вчера?",
    ]
}

private struct MessageRow: View {
    let message: AskStore.Message

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                Text(message.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if message.truncated {
                    Text("Ответ обрезан по лимиту длины — переформулируй короче для полного.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !message.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Источники").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(message.sources.enumerated()), id: \.element.uniqueKey) { i, s in
                            SourceChip(index: i + 1, result: s)
                        }
                    }
                }
            }
            .padding(.trailing, 40)
        }
    }
}

private struct SourceChip: View {
    let index: Int
    let result: SearchResult

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("[\(index)]").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(result.snippet).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
    }

    private var label: String {
        let when = result.ts.formatted(date: .abbreviated, time: .shortened)
        let who = result.appName ?? result.bundleId ?? (result.kind == .audio ? "Аудио" : "Экран")
        return "\(when) · \(who)"
    }
}
