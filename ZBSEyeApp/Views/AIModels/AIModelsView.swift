import SwiftUI

/// "AI Models": choose WHICH model processes history excerpts (Ask / Daily Insights / day summary).
/// Local-first, bring-your-own-AI: LM Studio / Ollama / any localhost server are the default and the
/// privacy story; OpenRouter / Anthropic / OpenAI are an explicit opt-in behind a consent alert —
/// excerpts of screen history leave the Mac only for the one provider the user confirmed.
/// Capture/index/storage never leave regardless.
struct AIModelsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var consentTarget: AIProvider?
    @State private var showConsent = false

    var body: some View {
        Form {
            activeSection
            ForEach(AIProvider.allCases) { provider in
                ProviderSection(provider: provider,
                                requestCloudConsent: { p in consentTarget = p; showConsent = true })
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI Models")
        .task { await env.ai.autoProbeLocal() }   // fill pickers if LM Studio/Ollama are already running
        .alert("Enable cloud processing?", isPresented: $showConsent, presenting: consentTarget) { p in
            Button("Cancel", role: .cancel) {}
            Button("Send excerpts to \(p.displayName)") {
                env.ai.grantConsent(p)
                env.ai.activate(p)
            }
        } message: { p in
            Text("Cloud processing sends excerpts of your screen history to \(p.displayName). Your recordings and index stay local.")
        }
    }

    // MARK: active model header

    private var activeSection: some View {
        Section {
            if let p = env.ai.activeProvider, env.ai.activeConfig != nil {
                Label {
                    Text("Processing model: \(p.displayName) · \(env.ai.model(for: p))")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                Label {
                    Text("None — Ask and Daily Insights are off")
                } icon: {
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("One model processes excerpts of your history for Ask, Daily Insights and the day summary. Local providers keep everything on this Mac; cloud providers are an explicit opt-in. Recording, search index and storage stay local no matter what you pick here.")
        }
    }
}

// MARK: — one provider card

private struct ProviderSection: View {
    let provider: AIProvider
    let requestCloudConsent: (AIProvider) -> Void
    @Environment(AppEnvironment.self) private var env
    @State private var keyDraft = ""

    private var ai: AIProviderStore { env.ai }

    var body: some View {
        Section {
            if provider == .custom { endpointField }
            // OpenRouter: one-click "Sign in" (real OAuth + PKCE) ABOVE the manual key field.
            if provider == .openrouter && !ai.hasKey(provider) { openRouterOAuthRow }
            if provider.isCloud { keyRow }
            connectRow
            if !ai.fetchedModels(provider).isEmpty { modelPicker }
            // No server-provided list yet (empty /v1/models, JIT loading, or not probed) → let any LOCAL
            // provider's model be typed in by hand, so a valid model id is always selectable/activatable.
            if ai.fetchedModels(provider).isEmpty && !provider.isCloud { manualModelField }
            useRow
        } header: {
            header
        } footer: {
            footer
        }
    }

    // MARK: header (status dot + name + CLOUD badge)

    private var header: some View {
        HStack(spacing: 8) {
            statusDot
            Text(verbatim: provider.displayName)
            if provider.isCloud {
                Text(verbatim: "CLOUD")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
            }
            if ai.isActive(provider) && ai.activeConfig != nil {
                Label("Active", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
            }
        }
    }

    private var statusDot: some View {
        let color: Color = switch ai.status(provider) {
        case .connected: .green
        case .probing: .yellow
        case .error: .red
        case .notConfigured: .secondary.opacity(0.5)
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    // MARK: rows

    private var endpointField: some View {
        TextField("Endpoint", text: Binding(
            get: { ai.endpoint(for: provider) },
            set: { ai.setEndpoint($0, for: provider) }),
            prompt: Text(verbatim: "http://127.0.0.1:8080/v1"))
            .textContentType(.URL)
            .autocorrectionDisabled()
    }

    private var keyRow: some View {
        HStack(spacing: 8) {
            if ai.hasKey(provider) {
                Label("API key in Keychain", systemImage: "key.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Remove key") { ai.removeKey(for: provider) }
                    .buttonStyle(.borderless).foregroundStyle(.red)
            } else {
                // For OpenRouter the OAuth button above is the primary path; the key field is a fallback.
                SecureField(provider == .openrouter ? "…or paste a key" : "API key",
                            text: $keyDraft, prompt: Text(verbatim: "sk-…"))
                    .onSubmit { saveKey() }
                Button("Save") { saveKey() }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let url = provider.keyConsoleURL {
                    Link("Get a key…", destination: url)
                }
            }
        }
    }

    // MARK: OpenRouter one-click sign-in (OAuth + PKCE)

    @ViewBuilder
    private var openRouterOAuthRow: some View {
        switch ai.openRouterOAuthPhase {
        case .running:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Waiting for your browser…").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { ai.cancelOpenRouterOAuth() }
                    .buttonStyle(.borderless)
            }
        case .idle, .failed:
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    ai.connectOpenRouterOAuth()
                } label: {
                    Label("Connect OpenRouter", systemImage: "person.badge.key.fill")
                }
                .buttonStyle(.borderedProminent)
                if case .failed(let msg) = ai.openRouterOAuthPhase {
                    Label(msg, systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red).lineLimit(3).help(msg)
                }
            }
        }
    }

    private func saveKey() {
        ai.saveKey(keyDraft, for: provider)
        keyDraft = ""
    }

    private var connectRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { await ai.connect(provider) }
            } label: {
                Label(provider.isCloud ? "Load models" : "Connect", systemImage: "bolt.horizontal")
            }
            .disabled(isProbing || (provider.isCloud && !ai.hasKey(provider))
                      || (provider == .custom && ai.endpoint(for: provider).isEmpty))

            if isProbing { ProgressView().controlSize(.small) }
            Spacer()
            statusText
        }
    }

    private var isProbing: Bool { ai.status(provider) == .probing }

    @ViewBuilder
    private var statusText: some View {
        switch ai.status(provider) {
        case .notConfigured:
            EmptyView()
        case .probing:
            Text("connecting…").foregroundStyle(.secondary)
        case .connected(let n):
            Label("connected · \(n) models", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).lineLimit(2).help(msg)
        }
    }

    private var modelPicker: some View {
        Picker("Model", selection: Binding(
            get: { ai.model(for: provider) },
            set: { ai.setModel($0, for: provider) })) {
            ForEach(ai.modelOptions(provider), id: \.self) { Text(verbatim: $0).tag($0) }
        }
    }

    /// A local server may not implement /v1/models (or return an empty list while a model JIT-loads) —
    /// manual model entry as a fallback so LM Studio / Ollama / custom are never picker-only.
    private var manualModelField: some View {
        TextField("Model", text: Binding(
            get: { ai.model(for: provider) },
            set: { ai.setModel($0, for: provider) }),
            prompt: Text(verbatim: "llama3.2 / qwen2.5 / …"))
            .autocorrectionDisabled()
    }

    private var useRow: some View {
        HStack {
            Button("Use this model") {
                // Cloud cannot become active silently: the consent alert is the only path in.
                if provider.isCloud && !ai.hasConsent(provider) {
                    requestCloudConsent(provider)
                } else {
                    ai.activate(provider)
                }
            }
            .disabled(ai.model(for: provider).isEmpty || (provider.isCloud && !ai.hasKey(provider))
                      || (ai.isActive(provider) && ai.activeConfig != nil))
            Spacer()
            if provider.isCloud && ai.hasConsent(provider) {
                Text("Cloud opt-in confirmed").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: footer

    @ViewBuilder
    private var footer: some View {
        switch provider {
        case .lmstudio:
            Text("Runs on this Mac (port 1234). Free and private — start the LM Studio server, then Connect.")
        case .ollama:
            Text("Runs on this Mac (port 11434). Free and private — `ollama serve`, then Connect.")
        case .custom:
            Text("Any OpenAI-compatible server on localhost: mlx_lm.server, llama.cpp server, …")
        case .openrouter, .anthropic, .openai:
            Text("Cloud: excerpts of your screen history are sent to this provider — only after your explicit opt-in. The API key is stored in the Keychain.")
        }
    }
}
