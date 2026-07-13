import SwiftUI

/// "Ask your memory": a natural-language question → the active optional AI answers
/// from the retrieved fragments of your screen and conversation history (RAG, cross-lingual).
/// Local-first: on-device by default, a cloud provider only with the explicit opt-in.
struct AskView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if let store = env.ask {
                AskBody(store: store)
            } else {
                ContentUnavailableView("Initializing…", systemImage: "questionmark.bubble")
            }
        }
        .navigationTitle("Ask")
    }
}

private struct AskBody: View {
    @Bindable var store: AskStore
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            scopeBar
            Divider()
            if store.messages.isEmpty {
                emptyState
            } else {
                conversation
            }
            Divider()
            inputBar
        }
    }

    private var scopeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(.secondary)
            Text("Asking about")
                .font(.callout)
                .foregroundStyle(.secondary)
            Menu {
                Button("Today") {
                    env.workspace.setAskScope(.day(Date()))
                }
                Button("All history") {
                    env.workspace.setAskScope(.all)
                }
            } label: {
                Text(store.currentScope.displayLabel)
                    .font(.callout.weight(.medium))
            }
            .menuStyle(.borderlessButton)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                            Text("Thinking about your history…").foregroundStyle(.secondary)
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
                            Label("AI is off", systemImage: "pause.circle")
                                .font(.headline)
                            Text("Timeline and local search keep working. Add AI only when you want a generated answer.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Add AI") { env.aiSetup.present(origin: .ask) }
                        }
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Ask your memory", systemImage: "sparkles").font(.headline)
                        Text("Ask a question in plain language — ZBS Eye will find the relevant moments in your screen and conversation history and answer from them, with links to the sources.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(store.executionDisclosure)
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(examples, id: \.self) { ex in
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
        // Reuse the cached progress snapshot to size the examples; throttled so opening Ask doesn't run a
        // full history scan on every appear (Pro perf #5).
        .task { await env.progress?.refreshThrottled() }
    }

    /// Example prompts adapt to available history: little/no history (a fresh install, < ~1 day of
    /// memory) gets the "day one" prompts; ample history (a day or more) gets the week-scale ones.
    private var examples: [String] {
        let ageDays = env.progress?.snapshot.memoryAgeDays ?? 0
        return ageDays < 1 ? Self.dayOneExamples : Self.weekExamples
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask about your history…", text: $store.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .onSubmit { store.send() }
                .disabled(store.busy)   // input is available even without an LLM: a real question → a hint, while easter eggs always work 🥚
            if !store.messages.isEmpty {
                Button { store.clear() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Clear conversation")
            }
            Button { store.send() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(!store.canSend)
        }
        .padding(12)
    }

    /// Week-scale prompts once there's more than a day of history.
    static let weekExamples = [
        "What did I read about Swift concurrency this week?",
        "What was the last call about?",
        "What address did someone send me yesterday?",
    ]

    /// Day-one prompts for a fresh install with only a few hours of memory.
    static let dayOneExamples = [
        "What was I just doing?",
        "Summarize the last hour",
        "What did I read today?",
    ]
}

private struct MessageRow: View {
    let message: AskStore.Message

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .bottom) {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(message.text)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.18),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    if let scope = message.scope {
                        Text(scope.displayLabel)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                Text(message.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let provenance = message.provenance {
                    Label(provenanceLabel(provenance), systemImage: provenance.executedLocally ? "desktopcomputer" : "cloud")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if message.truncated {
                    Text("Answer cut off by the length limit — rephrase it shorter for the full one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if message.contextTruncated {
                    Text("Only the highest-ranked fragments fit the selected model's context window.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !message.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sources").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(message.sources.enumerated()), id: \.element.uniqueKey) { i, s in
                            SourceChip(index: i + 1, result: s)
                        }
                    }
                }
            }
            .padding(.trailing, 40)
        }
    }

    private func provenanceLabel(_ provenance: AIExecutionProvenance) -> String {
        let provider = AIProvider(rawValue: provenance.providerID)?.displayName
            ?? provenance.providerID
        if provenance.executedLocally {
            return String(localized: "On this Mac · \(provider) · \(provenance.modelID)")
        }
        if let upstream = provenance.brokerUpstream {
            return String(localized: "Cloud · \(provider) → \(upstream) · \(provenance.modelID)")
        }
        return String(localized: "Cloud · \(provider) · \(provenance.modelID)")
    }
}

private struct SourceChip: View {
    @Environment(AppEnvironment.self) private var env
    let index: Int
    let result: SearchResult

    var body: some View {
        // Clicking a citation → the exact frame in the timeline ("don't take my word for it — here's the proof"). That's what sets
        // "memory you trust" apart from a RAG demo, and it hedges against a weak local LLM.
        Button {
            env.workspace.returnToTimeline(source: result)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Text("[\(index)]").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Text(result.snippet).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward.square").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open this moment in the timeline")
    }

    private var label: String {
        let when = result.ts.formatted(date: .abbreviated, time: .shortened)
        let who = result.appName ?? result.bundleId ?? (result.kind == .audio ? "Audio" : "Screen")
        return "\(when) · \(who)"
    }
}
